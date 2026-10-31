# Lab 4 Handoff — XOps + CI/CD

Snapshot: **2026-10-31**, `main` at `929d388` (green run). Lab 3 remains tagged
`lab3-submit`; nothing here changed it.

## Position

**Task 1 is done and the pipeline is green for the first time.** `929d388` run:
`PRE_BUILD` (29 + 21 passed) → `BUILD` (26 passed, 5 warnings) → `POST_BUILD`
SUCCEEDED, and the registry gained **v8 `PendingManualApproval`**. **v7 is the
`Approved` champion** (auc 0.7823) the regression test compares against.

Evidence already saved (regenerate only while the stack is up):
`docs/lab4-build-green.log`, `docs/lab4-pipeline-runs.txt`,
`docs/lab4-model-registry.json`.

The pipeline execution reads `InProgress` because the `ManualApproval` stage is
waiting for a human. That is the design, not a hang.

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

1. **Task 2 failure demo**: `snap "BEFORE"` (alarm is `OK`, newest version v8) →
   push a deliberately failing assertion → `snap "AFTER FAILED RUN"` → revert →
   `snap "AFTER REVERT"`. Needs an SNS email subscription first; there is **no
   subscription on `northstar-model-approvals` yet**, so the alarm currently
   cannot deliver.
2. Approve v8 (or the revert's new version) so the pipeline's `ManualApproval`
   stage completes and stays the champion for later runs.
3. **Task 3**: lineage onto the final green package via
   `update-model-package --customer-metadata-properties`, then
   `docs/lab4-model-package.json`; `docs/lab4-mlflow-runs.txt` from the MLflow App.
4. **Task 4**: `docs/lab4-xops-assessment.md` — needs `## Pipeline Stage Mapping`,
   `## Champion-Challenger`, `## Retraining Triggers`, `## DataOps Maturity`,
   `## MLOps Maturity`.
5. Re-run the feature job before any push after `2026-11-01 06:40Z`, or the
   freshness test fails the build (by design).

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
