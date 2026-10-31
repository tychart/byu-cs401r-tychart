# Lab 4 Handoff — XOps + CI/CD

Snapshot: **2026-10-31**, `main` at `929d388` (green run). Lab 3 remains tagged
`lab3-submit`; nothing here changed it.

## Position

**Task 1 and Task 2 are both done.** Two green runs and one deliberate red run.

| Run | Commit | Result |
| --- | --- | --- |
| first green | `929d388` | 76 tests, v8 registered |
| deliberate failure | `037a947` | `PRE_BUILD FAILED`, no `BUILD` phase, no package, alarm `ALARM` |
| **final green** | `2bede51` | 76 tests, v9 registered, champion compared = **v8** |

Registry: v7 / v8 / v9 all `Approved`. The final green log's champion warning reads
`champion v8 auc=0.7823; candidate auc=0.7823`.

Evidence is committed in `66589f1` and **not pushed** — a docs-only push starts
another training run and registers v10. Per the handout, delete the CI stack
before the final docs push.

### Task 2 evidence (committed)

| File | What it shows |
| --- | --- |
| `docs/lab4-failure-demo.txt` | `BEFORE` (alarm `OK`, v8 newest) → `AFTER FAILED RUN` (`ALARM`, registry unchanged) → `AFTER REVERT` (v9 `PendingManualApproval`, alarm `OK`), plus a dated note that the `InProgress` pipeline in the last snapshot was the `ManualApproval` gate, not a hang |
| `docs/lab4-build-failed.log` | build `b050a7e0` on `037a947`: the assertion verbatim, `PRE_BUILD FAILED`, no `BUILD` phase, `1 failed / 29 passed` |
| `docs/lab4-build-green.log` | final green run `2bede51`: 29/21/26 passed, `champion v8` warning, fairness flag at 31.8 pp, `[pipeline] … pipeline Succeeded`, `[pipeline] registered: …/9` |
| `docs/lab4-pipeline-runs.txt` | every run with phases and pytest summaries |
| `docs/lab4-model-registry.json` | v1–v9 with approval status |
| `docs/lab4-xops-assessment.md` | `## Pipeline Stage Mapping` (Tasks 3/4 sections still to write) |

**Still missing for Task 2: `docs/lab4-alarm-email.png`.** The alarm email was
received and confirmed correct (subject `ALARM: "northstar-ci-build-failure"`,
received time visible, `OK -> ALARM`, timestamp `21:37:35 UTC`); the PNG has to be
saved by hand from Tyler's mailbox.

### Task 1 — what landed in `929d388`

| File | Change |
| --- | --- |
| `data/feature_engineering.py` | new — pandas port of the Glue job, 5 functions + derives |
| `tests/test_data.py` | leakage recompute + control, and the <48 h freshness check |
| `tests/test_model.py` | `TestChampionRegression` (was missing entirely; 8 of 30 pts) |
| `tests/test_fairness.py` | new — per-tier recall gap, flags above 10 pp, never blocks |
| `tests/test_features.py` | the two TODOs implemented (boundary + edge cases) |

Measured: champion gate fails at 0.7350 and passes at 0.7650 against champion
0.7823; fairness flag fires at 31.8 pp (25.9 pp excluding Platinum's 21
positives).

## Prerequisites (verified live 2026-10-31)

All six pass. Note that the CodeBuild role carries `AmazonS3FullAccess`
attached **out of band** — `pipeline.yaml` grants only the artifacts bucket, so a
fresh deploy from the template would fail `pre_build` on the data-bucket copy.

| Prereq | State |
| --- | --- |
| 1. Versioned artifacts bucket | done — `Enabled` |
| 2. GitHub connection | done — `northstar-github` `AVAILABLE` |
| 3. `churn_model.train()` + pipeline | done — `northstar-churn-pipeline` `Active`; v8 registered |
| 4. MLEngineer PassRole + tags | done — live policy **v2**, 45 actions |
| 5. Lab 2 up + fresh feature job | **expires 2026-11-01 06:40Z** — re-run before any later push |
| 6. `CAPABILITY_NAMED_IAM` stack | done — `northstar-cicd` `UPDATE_COMPLETE`, 4 outputs |

## Two account-specific deviations

1. **Training quota — RESOLVED 2026-10-30.** Applied spot quota `L-29688C85` is
   now **4** (`CASE_CLOSED`); `ml.m5.large` is the working cheapest rung and the
   GPU ladder stays only as capacity insurance.
2. **Push trigger.** The CodeConnections webhook never delivered a push;
   `.github/workflows/trigger-pipeline.yml` starts CodePipeline over GitHub OIDC.
   Verified again on 2026-10-31: `929d388` started execution
   `1f8460f5-c0a8-4823-ad76-0f1ce9ce918d` within seconds.

## Next steps

1. **Task 3**: lineage onto **v9** (the final green run's package) via
   `update-model-package --customer-metadata-properties` — needs the training data
   S3 URI + timestamp, the commit SHA (`2bede51`), and the evaluation metrics —
   then `aws sagemaker describe-model-package` with the **full ARN** into
   `docs/lab4-model-package.json`. Plus `docs/lab4-mlflow-runs.txt` from the
   MLflow App (≥3 runs, differing params) and `## Champion-Challenger` /
   `## Retraining Triggers`.
2. **Task 4**: `## DataOps Maturity` and `## MLOps Maturity` in
   `docs/lab4-xops-assessment.md`.
3. Save `docs/lab4-alarm-email.png`.
4. Delete the CI stack, then push the docs commit, tag `lab4-submit`, push the tag.
5. Re-run the feature job before any later push after `2026-11-01 06:40Z`.

## Useful commands

```bash
# Feature job must run in the last 48 h before pushing (needs NAT).
bash scripts/resume-lab3.sh
aws glue start-job-run --job-name northstar-dev-feature-engineer
bash scripts/pause-lab3.sh

# Re-prove the training path without CodeBuild (~$0.01):
COMMIT_SHA=manual bash scripts/run_sagemaker_pipeline.sh

# Local model gate on a pipeline artifact:
EVAL_METRICS_PATH=/tmp/pipe-out/evaluation_metrics.json \
  .venv/bin/pytest tests/test_model.py --model-path /tmp/pipe-model/xgboost-model -q
```

This run currently costs ~$0.01-0.02 (CodeBuild + one spot training job). The
stack is idle-free; NAT stays paused.
