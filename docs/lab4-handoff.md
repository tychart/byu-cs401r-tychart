# Lab 4 Handoff — XOps + CI/CD

Snapshot: **2026-10-30**, `main` at `edb4a62`. Repo `byu-cs401r-tychart`.
Lab 3 remains tagged `lab3-submit`; nothing here changed it.

## Position

**All six Lab 4 prerequisites are done and verified.** The CI stack
`northstar-cicd` is up. The very first pipeline run **stops at `pre_build`** on
`tests/test_features.py` because `data/feature_engineering.py` does not exist
yet — that is Task 1, not a prerequisite failure.

| Prereq | State | Evidence |
| --- | --- | --- |
| 1. Versioned artifacts bucket | done | `northstar-dev-cicd-artifacts-345594594463`, versioning `Enabled` |
| 2. GitHub connection | done | `northstar-github` = `AVAILABLE` |
| 3. `churn_model.train()` + pipeline | done | reproduced Lab 3 exactly; 18/18 model tests on the pipeline-trained model; pipeline `northstar-churn-pipeline` |
| 4. MLEngineer PassRole + tags | done | live policy v2 has `PassSelfToSageMaker` + `sagemaker:AddTags/ListTags` |
| 5. Lab 2 up + fresh feature job | done | feature job SUCCEEDED 2026-10-30 06:40Z, `event_time` age 0.05 h |
| 6. `CAPABILITY_NAMED_IAM` deploy | done | stack `CREATE_COMPLETE`; outputs below |

Stack outputs: `northstar-pipeline`, `northstar-ci`,
`arn:aws:sns:us-east-1:345594594463:northstar-model-approvals`,
`arn:aws:iam::345594594463:role/northstar-github-actions-trigger`.

## Two account-specific deviations

1. **Training quota.** Applied spot quota is **0** for every CPU type
   (`L-29688C85`: applied 0, AWS default 4). Request `CASE_OPENED` on
   2026-10-29. Until it clears, `scripts/run_sagemaker_pipeline.sh` tries
   `ml.m5.large` (fails fast on quota), then `ml.g6.2xlarge` (spot quota 1, and
   it has capacity — three successful train+register runs), then further GPU
   types. The ladder also abandons a job stuck in "Insufficient capacity"
   after `STALL_SECONDS` (default 300). A real training error is never retried.
2. **Push trigger.** The CodeConnections GitHub webhook never delivered a push
   (no `WebhookV2` execution in 6+ minutes; manual executions download the same
   repo). `.github/workflows/trigger-pipeline.yml` starts CodePipeline over
   GitHub OIDC instead. Verified: a push produced an execution whose trigger is
   `assumed-role/northstar-github-actions-trigger/github-<run-id>`.

## Next steps (Task 1 first)

1. Port the Lab 2 feature logic to `data/feature_engineering.py` with the five
   functions `tests/test_features.py` imports.
2. Implement the `TODO`s in `tests/test_data.py` (leakage recompute + freshness)
   and write `tests/test_fairness.py` (flag, do not block; `train()` already puts
   per-tier results in `metrics["slices"]`).
3. Push → green run. Approve that package, then run the failure demo
   (`snap "BEFORE"`, failing test, `snap "AFTER FAILED RUN"`, revert, `snap
   "AFTER REVERT"`) and capture the evidence files listed in the handout.
4. Subscribe an email to `northstar-model-approvals` and confirm the link.

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
