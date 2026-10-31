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
| `Build` | **3. Build** | `buildspec.yml` → `build`: upsert `pipeline_definition.py`, then run the SageMaker Pipeline `TrainChurnModel` TrainingStep |
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
