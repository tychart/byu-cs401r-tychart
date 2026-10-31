# Lab 4 — XOps Assessment and Pipeline Documentation

NorthStar churn model, CS 401R. `main` at the `lab4-submit` tag.

---

## Pipeline Stage Mapping

The handout requires five **CI phases** — Source, Test, Build, Evaluate, Register
— in that order, each halting the pipeline if it fails. It also states clearly
that five phases do **not** imply five CodePipeline *stages*, and that the
reference implementation uses three.

This implementation uses **three CodePipeline stages** carrying five phases,
plus a fourth stage for the human promotion decision:

| CodePipeline stage | CI phase(s) it performs | Where it actually runs |
| --- | --- | --- |
| `Source` | **1. Source** | CodeConnections → GitHub `main`, `OutputArtifactFormat: CODE_ZIP` |
| `Build` | **2. Test** | `buildspec.yml` → `pre_build` |
| `Build` | **3. Build** | `buildspec.yml` → `build`: upsert `models/churn/pipeline_definition.py`, then run the SageMaker Pipeline `TrainChurnModel` TrainingStep |
| `Build` | **4. Evaluate** | `buildspec.yml` → `build`: the in-training gates inside `churn_model.evaluate_model()`, then `tests/test_model.py` + `tests/test_fairness.py` |
| `Build` | **5. Register** | SageMaker Pipeline `RegisterChurnModel` step, status `PendingManualApproval` |
| `ManualApproval` | *(the human decision)* | `ReviewModelMetrics` approval action, SNS-notified via `northstar-model-approvals` |

### Why three stages and not five

A CodePipeline **stage** is a deployment boundary: it exists so artifacts can
hand off and so a human can be inserted between two points. A CI **phase** is a
logical step. Splitting Test, Build, Evaluate and Register into four stages would
mean four CodeBuild projects, publishing the model artifact as a stage artifact,
and re-downloading it — buying no additional safety, because every one of those
phases already runs inside one container against one checkout and halts on
failure via `set -e`-style command failure. The `pre_build` phases stop the build
exactly as a separate stage would, and the evidence below shows it.

The one boundary that genuinely earns a stage is the last one: a model awaiting
human approval must sit *outside* the automated path, and the artifact that
produced it must already exist when the human looks. That is why
`ManualApproval` is a real stage rather than a step inside `build`.

### Ordering and enforcement

The phases are ordered in one file (`buildspec.yml`), so "ordered" is a property
of line position rather than of a graph. Each stage of the sequence enforces its
own failure:

1. **Test → Build.** `pre_build` runs `tests/test_data.py` (29 tests) and
   `tests/test_features.py` (21 tests). A failure exits non-zero and CodeBuild
   never enters `build`. Verified by the deliberate-failure demo: `PRE_BUILD
   FAILED`, **no `BUILD` phase at all**, no package registered.
2. **Build → Evaluate.** The TrainingStep runs `churn_model.train()`, whose
   `evaluate_model()` **raises** when precision@10% < 0.50, recall@10% < 0.25, or
   the lift confidence interval includes zero. A model that misses the bar never
   registers, because registration is the *next* pipeline step.
3. **Evaluate → Register.** Two gates live only in CodeBuild, not in the training
   container: the artifact loads and predicts sanely (`TestModelLoading`,
   `TestPredictionOutput`, `TestModelRobustness`), and the candidate has not
   regressed against the champion. These run **after** registration, so
   `post_build` sets the package to `Rejected` when the build is failing — see
   the comment block at `buildspec.yml` "Reject a package registered by a build
   that then failed". A red build leaves nothing approvable behind.

### Where the five phases are visible in the evidence

| Phase | Evidence |
| --- | --- |
| Source | `docs/lab4-pipeline-runs.txt` — execution `1f8460f5` carries `sourceRevisions[0].revisionId = 929d388e` |
| Test | `docs/lab4-build-green.log` — `29 passed` (data) and `21 passed` (features) under `PRE_BUILD` |
| Build | `docs/lab4-build-green.log` — SageMaker Pipeline execution `Succeeded`; `docs/lab4-pipeline-runs.txt` lists it |
| Evaluate | `docs/lab4-build-green.log` — `26 passed, 5 warnings`, including the champion warning and the fairness flag |
| Register | `docs/lab4-model-registry.json` — **v8**, `PendingManualApproval`, from this build's commit |

### The trigger, and why it is not the default one

Both the `Source` stage and the pipeline's change detection are driven by
`.github/workflows/trigger-pipeline.yml`, which calls
`codepipeline:StartPipelineExecution` over **GitHub OIDC** (role
`northstar-github-actions-trigger`, no stored access key). The CodeConnections
webhook did not deliver pushes on this account: the V2 trigger was configured,
the connection read `AVAILABLE`, and manual executions downloaded the same
repository, yet no `WebhookV2` execution appeared after a push. The push that
produced the green run started execution `1f8460f5` within seconds, with
`trigger.triggerDetail = assumed-role/northstar-github-actions-trigger/github-41235372196`.

### What a run costs

One run is about **$0.02**–**$0.03**: roughly five minutes of
`BUILD_GENERAL1_MEDIUM` CodeBuild (~$0.005/min) plus a managed-spot training job
that bills about a minute at `ml.m5.large` (~$0.01). The stack's own idle cost is
$0 because every component is either serverless (CodePipeline, CodeBuild,
SageMaker Pipeline definitions, Model Registry, SNS) or storage-only; the only
idle-charging resource in this platform is the Lab 2 NAT Gateway, which is paused
and is not needed by any phase of this pipeline.

---

## Champion-Challenger

Two different questions, deliberately separated. **Blocking** is about not getting
worse; **promoting** is about being better enough to justify a production change.
This pipeline does the first automatically and requires both for the second.

### Definitions

* **Champion** — the newest model package in `northstar-churn-models` with
  approval status `Approved`. Not the newest package: the candidate is registered
  as `PendingManualApproval` before the gate runs, so "newest" would compare the
  model with itself and always pass. This is what
  `tests/test_model.py::TestChampionRegression` retrieves via
  `list_model_packages(ModelApprovalStatus="Approved", SortBy="CreationTime")`.
* **Challenger** — the package this build just registered: the newest
  `PendingManualApproval` package, and the `evaluation_metrics.json` written to
  `s3://northstar-dev-data-345594594463/artifacts/evaluations/<commit>/`.

### Blocking rule (automated, in CI)

A build **fails** — and `post_build` sets the package to `Rejected` — if any of:

| # | Condition | Threshold | Where enforced |
| --- | --- | --- | --- |
| 1 | `precision_top10` | `< 0.50` fails | `evaluate_model()` in training, then `TestStoredMetricsGate` |
| 2 | `recall_top10` | `< 0.25` fails | same |
| 3 | `lift_ci_low` vs recency-only baseline | `<= 0` fails | same — the CI must exclude zero |
| 4 | `auc_roc` vs champion | `< champion − 0.02` fails | `TestChampionRegression` |

**Why 0.02.** It is the split-to-split noise floor, measured rather than guessed:
four runs on byte-identical data produced AUC 0.7276–0.7431, a spread of 0.0155
(`docs/lab3-plan.md`). A tolerance tighter than the noise would fail good models on
a re-roll of the random seed; 0.02 sits just above it, so it catches real
degradation and forgives re-draws of the validation split.

### Promotion rule (the human decision)

Approve the challenger — i.e. it becomes the new champion — **only if all four
blocking conditions hold AND**:

| # | Condition | Threshold |
| --- | --- | --- |
| 5 | Point-estimate improvement | `auc_roc ≥ champion_auc + 0.01` |
| 6 | Improvement is distinguishable from split noise | paired bootstrap 95% CI on `(AUC_challenger − AUC_champion)` over one shared held-out set **excludes zero** |

**Why both.** Condition 5 is a practical floor, not a statistical one. Condition 6
is the real test: the measured split noise is 0.0155, so a +0.01 AUC "improvement"
measured on two *different* validation splits is indistinguishable from luck. The
only defensible way to claim a gain is to score both models on the same rows and
bootstrap the difference — the same paired-bootstrap method `evaluate_model()`
already uses against the recency baseline.

**Stated honestly: condition 6 is not automated today.** The CI gate compares two
AUCs that were each measured on their own 30% validation split, so it can enforce
non-regression but it cannot certify improvement. Closing that is the "Top priority
investment" in the MLOps section below. Until then, promotion on grounds of
improvement is a human check against a re-scored comparison, and the
`ManualApproval` summary record is where that reasoning is written down — see
`docs/lab4-failure-demo.txt` and the `put-approval-result` summary for v9.

**Why not just gate on AUC > 0.75.** A fixed AUC bar was removed from this course
on 2026-08-02 after 200 splits showed the reference model falling below 0.72 on
58% of them: it was gating the random seed. A relative, interval-based rule does
the job the absolute one was pretending to do.

---

## Retraining Triggers

Both triggers are automated decisions, not standing invitations for someone to
notice something. Both are **designed here and not deployed** — the pipeline and
role they would call already exist (`northstar-pipeline`,
`northstar-dev-feature-engineer`).

### (a) Scheduled trigger — weekly, Monday 06:00 UTC

| Element | Value |
| --- | --- |
| AWS service that fires it | **EventBridge Scheduler** (`aws_scheduler_schedule`) |
| Schedule expression | `cron(0 6 ? * MON *)` — 06:00 UTC every Monday |
| Targets, in order | 1) `glue:StartJobRun` on `northstar-dev-feature-engineer`; 2) on job success, `codepipeline:StartPipelineExecution` on `northstar-pipeline` |
| Guard | the build's freshness test refuses a feature set older than 48 h, so a silently skipped Glue run fails the pipeline instead of training on stale data |

**Why weekly and why 06:00 UTC.** The customers, transactions and churn labels are
regenerated on a monthly cadence, so a weekly rebuild is already more frequent than
the data changes — it exists to catch *pipeline* drift (a transform change, a
dependency bump) within a week rather than a month. 06:00 UTC is 00:00 in
Provo: the job finishes before the working day, and nothing on the critical path
depends on it, so a failure is discovered in business hours.

**Measured cost per run: ~$0.08.** The last feature job ran 216 s (not the
handout's ~90 s — measured `ExecutionTime` on
`northstar-dev-feature-engineer`), which is 0.12 DPU-hour at $0.44 ≈ $0.053; plus
~5 min of `BUILD_GENERAL1_MEDIUM` CodeBuild ≈ $0.025; plus 53 s of `ml.m5.large`
spot ≈ $0.001. Fifty-two weekly runs is roughly **$4/year**, and the monthly
cadence of the underlying data means a monthly schedule would cost $1/year for no
loss of protection against pipeline drift within the month.

### (b) Performance-based trigger — AUC degrades in production

| Element | Value |
| --- | --- |
| Metric | `NorthStar/Model` → `AucRoc`, dimension `ModelPackageGroup=northstar-churn-models` |
| Emitted by | a daily scoring job that joins the previous 30 days of predictions to realised churn labels and calls `cloudwatch:PutMetricData` |
| Threshold | `AucRoc < 0.70` for **2 consecutive** 1-day periods |
| AWS service that fires it | **CloudWatch alarm** (2 × 1-day periods, `TreatMissingData: breaching`) → **EventBridge rule** → `codepipeline:StartPipelineExecution` |

**Why 0.70.** Champion AUC is 0.7823 and the recency-only baseline is 0.7208.
0.70 is below *both*: it does not mean "a bit worse", it means the model has
stopped beating the free three-line rule, which is the point at which the model has
no reason to exist. It is also far outside the measured split noise (0.0155), so
it fires on real degradation rather than on a bad week of labels.

**Why 2 consecutive periods.** A single daily AUC is computed from the handful of
churn outcomes that resolve each day — roughly 25, if the 2,200 churners in the
90-day label window are spread across the customer base — so it moves by several
points on which cases happened to resolve. Requiring persistence costs one day of
latency and removes almost all of the false alarms — the asymmetry is right,
because a spurious retrain costs ~$0.08 and a forgotten degraded model costs
revenue.

**Why this is not yet real.** Nothing in this platform scores production traffic:
there is no endpoint and no realised-label feed, so `AucRoc` is a designed metric
with no emitter. That gap is named as the Level 2 → 3 blocker in the MLOps
assessment below, and it is deliberately not papered over — an alarm on a metric
nobody publishes would look like coverage while measuring nothing.

### A third trigger considered and rejected

Retrain whenever the feature distribution shifts (PSI on
`days_since_last_purchase` > 0.2). Rejected for now: this dataset is regenerated,
not accumulated, so a distribution shift here is far more likely to be a bug in the
regeneration than genuine drift, and a retrain would happily fit the bug. The AUC
trigger catches the same failure a week later, with a signal that means something.

---

## DataOps Maturity

*Ladder, stated because the chapter's table is not in this repository:* **0**
manual · **1** defined but hand-run · **2** automated happy path · **3** measured
in production · **4** self-optimising.

**Current level: 2**

**Evidence:** The path is code, not clicks. `infrastructure/environments/dev/main.tf`
and `infrastructure/modules/iam/main.tf` build the VPC, bucket, catalog, feature
group and least-privilege roles. Grain is enforced by `glue-scripts/transform.py`;
the temporal split lives in `glue-scripts/feature_engineer.py` and is *proven*
rather than asserted — `tests/test_data.py::TestTemporalSplit` recomputes the
time-sensitive features from `processed/` via `data/feature_engineering.py` and
matches `features/` for all 9,999 customers on every build, with a control test
showing it detects leakage. Missing data fails rather than skips (50 tests in
`docs/lab4-build-green.log`), staleness is gated at 48 h, the contract is
`docs/lab2-data-contract.md`, and the exact data version reaches the model card
(`training_data_timestamp`, `feature_job_run_id`) in `docs/lab4-model-package.json`.

**Gap to Level 3:** every check above runs at *build* time. Nothing observes the
data between builds — no drift detection on the 11 feature distributions, no
ingest volume or schema anomaly alert, and no signal when the Glue job writes a
materially shifted distribution but still exits `SUCCEEDED`.

**Top priority investment:** a **Great Expectations** suite run daily by
EventBridge Scheduler → Glue Python shell, publishing per-feature population
stability index to `NorthStar/Data` with a CloudWatch alarm above 0.2. It turns
the existing build-time assertions into production observation for roughly the
cost of one feature job (~$0.08/day).

## MLOps Maturity

**Current level: 2**

**Evidence:** Commit→test→train→evaluate→register is automated and demonstrably
halts: `pipeline.yaml` + `buildspec.yml`, green in `docs/lab4-build-green.log` (76
tests, package 9 registered) and red in `docs/lab4-build-failed.log` (`PRE_BUILD
FAILED`, no package). The bar is relative, not absolute —
`tests/test_model.py::TestChampionRegression` reads the newest `Approved` package
and warns `champion v8 auc=0.7823`. Promotion is human and recorded
(`put-approval-result` summaries in `docs/lab4-failure-demo.txt`). Tracking is
deliberate (`docs/lab4-mlflow-runs.txt`, `max_depth` 4/6/8). Failure reached a
confirmed subscriber (`docs/lab4-alarm-email.png`). Fairness is measured per tier
— 31.8 pp, flagged not blocked.

**Gap to Level 3:** no production signal. No endpoint means no scoring traffic, no
realised labels and no `AucRoc` to alarm on, so both retraining triggers are
designed and unemitted. The improvement criterion is likewise only half-automated:
CI compares two separately-measured AUCs, which cannot separate a 0.01 gain from
the measured 0.0155 split noise.

**Top priority investment:** a **shadow SageMaker endpoint** plus a daily
outcome-join job publishing `NorthStar/Model AucRoc` — the one missing emitter
that makes the designed performance trigger real — and a shared holdout to
automate the paired promotion check.
