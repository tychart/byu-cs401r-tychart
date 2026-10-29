 Lab 4: XOps + CI/CD Pipeline + Testing body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif; line-height:1.55;max-width:52rem;margin:2rem auto;padding:0 1.25rem;color:#1a1a1a} code{background:#f4f4f4;padding:.12em .35em;border-radius:3px;font-size:.92em} pre{background:#f4f4f4;padding:1rem;border-radius:5px;overflow-x:auto} pre code{background:none;padding:0} table{border-collapse:collapse;width:100%;margin:1rem 0} th,td{border:1px solid #ccc;padding:.5rem .6rem;text-align:left;vertical-align:top} th{background:#f0f0f0} blockquote{border-left:4px solid #c8102e;margin:1rem 0;padding:.4rem 1rem;background:#fafafa} h1,h2,h3{line-height:1.25} hr{border:none;border-top:1px solid #ddd;margin:2rem 0}

Lab 4: XOps + CI/CD Pipeline + Testing
======================================

**Assigned:** Thu Oct 15 | **Due:** Sat Oct 31, midnight **Chapters:** _The XOps Stack_ (Week 06), _Testing & Evaluation_, _XOps and Continuous Delivery_ (CI/CD sections, Week 08) **Builds on:** Labs 1–3 — automates the lifecycle of your Lab 3 churn model **Prerequisite:** None beyond Labs 1–3. The pipeline's training step runs on managed spot capacity, which fits within a new account's default quota, so there is no quota request to file.

Objective
---------

Automate everything. A model that requires manual steps to test, evaluate, and deploy is not a production system — it is a science project. This lab builds the pipeline that takes a code commit all the way to a model approved for deployment, without human intervention in the happy path.

Starter Kit (Canvas: Lab 4)
---------------------------

*   `buildspec.yml` — the CodeBuild build specification. It runs as shipped; read it.
*   `pipeline.yaml` — the CloudFormation stack: CodePipeline, CodeBuild, the approval topic and the build-failure alarm.
*   `requirements.txt` — what CodeBuild installs in its first phase. Without it every build fails before a test runs. Add to it if your own tests import something else.
*   `pytest.ini` — puts the repo root on the import path so plain `pytest tests/` can import `data/feature_engineering.py`. Keep it at the repo root.
*   `tests/test_data.py`, `tests/test_features.py`, `tests/test_model.py` — populated pytest suites covering the processed dataset, the Lab 2 feature functions, and the Lab 3 model contract. Several assertions are left as `TODO` for you to implement.
*   `tests/conftest.py` — registers `--model-path` and `--eval-metrics-path`. Leave it where it is; pytest only reads `pytest_addoption` from `conftest.py`.
*   `models/churn/pipeline_definition.py` — defines the SageMaker Pipeline (spot training step, then `RegisterModel` as `PendingManualApproval`). The buildspec runs it on every build. Don't edit it.
*   `models/churn/train_sagemaker.py` — the training job's entry point. It reads the staged data, calls your `churn_model.train()`, and writes the model and metrics where SageMaker, the CI gate and Lab 5's serving container expect them. Don't edit it.
*   `models/churn/churn_model.py` — **template you complete.** Your Lab 3 training logic goes here, behind a three-name contract described at the top of the file.

* * *

Getting Your Repository
-----------------------

Keep working in the repository you created for Lab 1, `cs401r-<your-netid>`. This lab extends the platform you already built; **do not start a new repository.**

Lab 4 ships **new** starter files. Download the Lab 4 starter kit from Canvas (or copy them from [https://github.com/byu-cs401r4-f26/cs401r-lab4-template](https://github.com/byu-cs401r4-f26/cs401r-lab4-template)) into your existing repository before you begin. Add to what you have — do not replace it.

### Submitting Lab 4

When you are ready to submit, tag the commit you want graded and push the tag:

    git tag lab4-submit
    git push origin lab4-submit
    

Then submit **your repository URL** in Canvas. You do not submit the tag name — it is always `lab4-submit` for this lab, and the TA looks for it.

The TA grades `git checkout lab4-submit`, so anything you push afterwards while starting the next lab does not change this lab's grade. **If you forget the tag, you are graded at your last commit before the Canvas deadline** — which, if you have already started the next lab, may not be the work you meant to submit. Tag it.

> **Public repositories, deliberately.** You may read how other students approached the problem. Copying their work is plagiarism and is handled under the BYU Honor Code — commit your own. And because these are public: never commit credentials. No `.env`, no `terraform.tfvars`, no AWS keys. Committed secrets are an automatic zero. The provided `.gitignore` already excludes them; do not remove those lines.

* * *

Before you deploy anything — six prerequisites
----------------------------------------------

None of these are created for you, and each one fails in a way that does not name the real cause. Do them first.

**1\. An artifacts bucket, versioned.** CodePipeline needs a working bucket of its own for stage artifacts. This is **not** the `northstar-dev-data-<account>` data bucket and must not be pointed at it. Versioning is required — CodePipeline will not use an unversioned bucket.

    AB=northstar-dev-cicd-artifacts-$(aws sts get-caller-identity --query Account --output text)
    aws s3api create-bucket --bucket "$AB"
    aws s3api put-bucket-versioning --bucket "$AB" \
      --versioning-configuration Status=Enabled
    

**2\. A GitHub connection, created and authorized _before_ the stack.** A CodeStar connection created by CloudFormation is born `PENDING`, and a `PENDING` connection can only be completed by a human in the console — so a stack that creates its own connection comes up "successfully" with a Source stage that can never pull. Create it once, authorize it, then pass the ARN in.

    aws codeconnections create-connection \
      --provider-type GitHub --connection-name northstar-github
    # Console: Developer Tools → Settings → Connections → Update pending connection
    aws codeconnections list-connections \
      --query "Connections[?ConnectionName=='northstar-github'].[ConnectionStatus,ConnectionArn]" \
      --output text
    

It must read **`AVAILABLE`** before the pipeline will run.

**3\. Your training code must be in `models/churn/churn_model.py`, and the SageMaker Pipeline must exist.** The build triggers a pipeline named `northstar-churn-pipeline`; a `start-pipeline-execution` against a pipeline that was never defined fails with `ValidationException`. `pipeline_definition.py` creates it (and the `northstar-churn-models` package group if it is missing), and the buildspec upserts it on every build so each execution is pinned to the commit that triggered it.

The training job runs your code, not ours. Implement `train(df, seed=42)` in `churn_model.py` from your Lab 3 script: split, train, baseline, evaluate, return `(booster, metrics)`. Three rules, all explained in the file:

*   **Copy the functions in. Don't import your Lab 3 script.** Only `models/churn/` is uploaded to the training job, so `import churn_training_skeleton` works on your laptop and fails in the container.
*   **No `mlflow` or `sagemaker` imports at the top.** The XGBoost container doesn't ship them. MLflow tracking stays in your Lab 3 script.
*   **The metrics dict needs `precision_top10`, `recall_top10`, `lift_ci_low` and `lift_ci_high`.** Your Lab 3 `evaluate_model()` already returns all four, and the CI gate reads them.

Test it on your machine before you push. A broken contract fails in seconds here, where a pipeline run takes minutes to tell you the same thing:

    pip install -r requirements.txt
    mkdir -p /tmp/channel && aws s3 cp s3://<your-data-bucket>/features/customers/ /tmp/channel/ --recursive
    python models/churn/train_sagemaker.py --train-channel /tmp/channel \
      --model-dir /tmp/model --output-data-dir /tmp/out
    cp /tmp/out/model_metadata.json /tmp/model/
    EVAL_METRICS_PATH=/tmp/out/evaluation_metrics.json \
      pytest tests/test_model.py --model-path /tmp/model/xgboost-model
    

Expect your numbers to differ a little between your laptop and the pipeline. The training container runs XGBoost 1.7; you probably have 3.x. On the reference data both pass every gate.

When the training step fails in the pipeline, the build log shows only `AlgorithmError: ExecuteUserScriptError`. The reason is in the training job's own log, under `/aws/sagemaker/TrainingJobs` in CloudWatch Logs.

**4\. Your MLEngineer role must be allowed to pass itself to SageMaker.** The SageMaker Pipeline runs _as_ MLEngineer and starts a training job that is handed the same role, which is an `iam:PassRole` call. Labs 1–3 never needed it because you started training as yourself. Without it, every run fails 30 seconds into the SageMaker Pipeline with `... is not authorized to perform: iam:PassRole on resource: .../northstar-dev-MLEngineer`. Add this statement to the MLEngineer policy in your `modules/iam/main.tf` and `terraform apply`:

    {
      Sid       = "PassSelfToSageMaker"
      Effect    = "Allow"
      Action    = ["iam:PassRole"]
      Resource  = aws_iam_role.ml_engineer.arn
      Condition = { StringEquals = { "iam:PassedToService" = "sagemaker.amazonaws.com" } }
    },
    

While you are there, confirm the policy has `sagemaker:AddTags` and `sagemaker:ListTags`: pipelines tag every job they create.

**5\. Lab 2's stack is up, and its feature job ran in the last 48 hours.** Every build reads `raw/`, `processed/` and `features/` from your data bucket, and the freshness test you write in Task 1 fails a feature set older than 48 hours. Re-run the feature job (about 90 seconds) at the start of any session in which you will push:

    aws glue start-job-run --job-name northstar-dev-feature-engineer
    

If you tore Lab 2 down, re-apply it and re-run its whole pipeline first, and wait for `terraform apply` to finish before starting a Glue job. A job started while the NAT route is still being created fails with `Could not find S3 endpoint or NAT gateway`.

**6\. Deploy with `CAPABILITY_NAMED_IAM`**, not `CAPABILITY_IAM` — the template creates named roles. `GitHubRepo` is **your** repository, `cs401r-<your-netid>`.

    aws cloudformation deploy \
      --template-file pipeline.yaml --stack-name northstar-cicd \
      --parameter-overrides \
          ProjectName=northstar Environment=dev \
          GitHubOwner=YOUR_GITHUB_USERNAME GitHubRepo=cs401r-<your-netid> \
          GitHubBranch=main ArtifactsBucket="$AB" \
          GitHubConnectionArn=<arn from step 2> \
          SageMakerRoleArn=$(terraform -chdir=infrastructure/environments/dev \
                              output -raw ml_engineer_role_arn) \
      --capabilities CAPABILITY_NAMED_IAM
    

Creating the stack starts a pipeline run immediately on whatever is on `main`, so push your work first. After that, **every push to `main` runs the whole pipeline**, including a training job, even if you changed only `docs/`.

> **The training job runs on spot capacity, and that is deliberate.** On a new AWS account the on-demand training quota is **0** for every instance type, so an on-demand TrainingStep fails with `ResourceLimitExceeded`. Spot training quota is not zero: `ml.m5.large for spot training job usage` (`L-29688C85`) defaults to **4**. That is why the estimator in `pipeline_definition.py` sets:
> 
> `python max_run=1800, # hard cap on training time use_spot_instances=True, # managed spot, not on-demand max_wait=3600, # total budget incl. waiting for capacity; must be >= max_run`
> 
> Keep all three. Remove `use_spot_instances` and you're back to a quota of zero.
> 
> AWS can reclaim spot capacity mid-job. If it does, SageMaker waits for capacity and restarts the job, within `max_wait`. This job trains in about two minutes, so restarting from scratch is cheap and it needs no checkpointing. A job that trains for hours would need checkpoints to survive an interruption. Knowing which side of that line a workload falls on is a design decision you should be able to explain.
> 
> Confirm your spot quota before the first run. Any value of 1 or more works:
> 
> `bash aws service-quotas get-service-quota --service-code sagemaker \ --quota-code L-29688C85 --query 'Quota.Value' --output text`

Tasks
-----

### Task 1 — Test Suite (30 points)

Build a test suite that runs automatically in CI. Tests must be executable via `pytest tests/` from the repo root.

**Required test categories:**

**Data validation tests** (`tests/test_data.py`): - Schema check: all required columns present across raw, processed, and features - Grain check: processed data stays at transaction level (many rows per customer) - Leakage check: `churn_label` is not perfectly separable by recency alone - Distribution checks: bounded features within \[0, 1\]; frequency windows monotonic (180d ≥ 90d ≥ 30d) - Freshness check: latest `event_time` < 48 hours old

> **A missing dataset must FAIL, not skip.** The supplied `test_data.py` fails loudly when it cannot find pipeline output, and requires `ALLOW_MISSING_DATA=1` to defer. If you weaken that, `pytest tests/` goes green having validated nothing, and your Task 2 pipeline gate becomes decorative.

**Feature engineering unit tests** (`tests/test_features.py`): - At least 5 unit tests for feature computation functions - Cover: normal case, boundary case (customer with 0 purchases), edge case (single transaction)

**Model evaluation test** (`tests/test_model.py`): - Precision@top10% ≥ 0.50 and recall@top10% ≥ 0.25 - **Baseline gate: the 95% CI on (model AUC − recency-only baseline AUC) must exclude zero.** Your training script has to emit `baseline_auc_roc` and the CI bounds alongside `auc_roc` for this to be checkable. This is the gate that stops a model that has learned nothing beyond "days since last purchase" from reaching the registry. - **There is deliberately no absolute AUC threshold.** A fixed AUC gate was removed on 2026-08-02: across 200 splits of the same data the reference model fell below the old 0.72 bar on 58% of them, so the gate was testing the random seed. Report AUC, gate on the interval. - Regression test: new model AUC ≥ (champion model AUC − 0.02) - Prediction shape: output is a probability between 0 and 1 for every input

**Fairness check** (`tests/test_fairness.py`): - Use SageMaker Clarify or a manual slice evaluation - Flag (do not block) if recall gap between highest and lowest loyalty tier exceeds 10 percentage points - `buildspec.yml` runs this file in the build phase, next to `test_model.py`, once it exists. It reads the same `EVAL_METRICS_PATH`, so the simplest design has `train()` put per-tier results in its metrics dict. Expect the flag to fire on this data; the point is that it is visible to the approver, not that it is quiet.

**Make the regression test leave a record.** A passing test prints nothing under `pytest -v`, so a log can't show _which_ champion it compared against. Have the test call `warnings.warn(f"champion v{version} auc={champ_auc:.4f}; candidate auc={new_auc:.4f}")` before it asserts. The buildspec runs `test_model.py` with `-rw`, so that line lands in the warnings summary of the build log. If no package is `Approved` yet, the test has nothing to compare against. Approve the version from an earlier green run before your final green run (see _Evidence You Submit_).

**Rubric:**

Item

Points

Pass Criteria

Evidence (in your `lab4-submit` commit)

All 4 test categories implemented

12

Each category has ≥2 passing tests

The four files in `tests/`, plus `docs/lab4-build-green.log` showing each of `test_data.py`, `test_features.py`, `test_model.py` and `test_fairness.py` running with ≥2 `PASSED` lines apiece. `SKIPPED` does not count as passing. The fairness flag should appear in the warnings summary

≥5 feature unit tests with edge cases

10

Tests cover normal, boundary, and edge cases

`tests/test_features.py` (the TA reads the test names and bodies), plus ≥5 `test_features.py ... PASSED` lines in `docs/lab4-build-green.log`

Regression test compares against champion

8

Test retrieves champion AUC from Model Registry and fails if new model regresses. The champion is the newest **Approved** package: the candidate under test is already registered as `PendingManualApproval` when the test runs

The test code in `tests/test_model.py`. `docs/lab4-build-green.log` shows the regression test `PASSED` (not skipped), with your `champion vN auc=...` warning. `docs/lab4-model-registry.json` shows version N as `Approved`

### Task 2 — CI/CD Pipeline (30 points)

Implement a CI/CD pipeline that connects: **code push → test → build → evaluate → register**.

**Acceptable implementations:** AWS CodePipeline, GitHub Actions, or GitLab CI (your choice — document the rationale).

**Required pipeline phases.** Your pipeline must perform all five of these, in this order:

1.  **Source** — triggered by push to `main` branch
2.  **Test** — runs `pytest tests/`; pipeline fails and alerts if any test fails
3.  **Build** — packages training code; runs SageMaker Training Job with the new code
4.  **Evaluate** — runs the promotion gate against the new model's metrics
5.  **Register** — promotes model to SageMaker Model Registry with status `PendingManualApproval` if all gates pass

**The model the pipeline trains is yours.** The Build phase runs `models/churn/train_sagemaker.py`, which does no training itself: it calls `train()` in `models/churn/churn_model.py`, and the kit ships that function as a TODO. Before the pipeline can go green, turn your Lab 3 training code into `train(df, seed=42)`. It takes the labeled feature DataFrame and returns `(xgboost.Booster, metrics)`. Copy your Lab 3 functions into `churn_model.py`: preprocessing, the XGBoost model, the recency-only baseline, and `evaluate_model()`. Then call them in that order. The contract and three rules are under prerequisite 3 above and at the top of the file. Run the local test there before your first push.

Two consequences for grading:

*   **A pipeline running the unmodified template can't score here.** Its Build phase stops on the template's `NotImplementedError`, so no run reaches Register.
*   **The gate in Evaluate checks your model, not ours.** Precision and recall at the top 10%, and a lift CI that excludes zero, are the same bars Lab 3 set. A Lab 3 model that cleared them will clear them here, provided `train()` reproduces your Lab 3 preprocessing, split and hyperparameters.

> **Five phases is not five CodePipeline stages, and you are not required to make them line up.** A CodePipeline _stage_ is a deployment boundary — it exists so artifacts can hand off and so a human can be inserted between two points. A CI _phase_ is a logical step. Forcing one stage per phase means passing the model artifact between stages and standing up a CodeBuild project per stage, which buys nothing here.
> 
> The reference implementation uses **three** CodePipeline stages:
> 
> CodePipeline stage
> 
> Phases it performs
> 
> Where
> 
> `Source`
> 
> Source
> 
> CodeStar connection → GitHub `main`
> 
> `Build`
> 
> Test, Build, Evaluate, Register
> 
> `buildspec.yml`: `pre_build` runs `pytest tests/`; `build` upserts and runs the SageMaker Pipeline, which trains and registers; then the gate runs against the emitted metrics
> 
> `ManualApproval`
> 
> the human promotion decision
> 
> SNS-notified approval action
> 
> **Where registration sits.** The SageMaker Pipeline registers before CodeBuild runs `tests/test_model.py`. A model that fails a gate _inside_ training never registers: keep Lab 3's `evaluate_model()` raising, and the training step fails first. A model that fails a CodeBuild-only test is already in the registry, so `buildspec.yml`'s `post_build` sets that package to `Rejected`. Either way, a red build leaves nothing approvable behind.
> 
> Grading is on the five **phases** being present, ordered and enforced — not on the stage count in the console. Document your mapping either way.

**Gate behavior:** - The pipeline must halt at the failed phase — not silently skip - A failed gate must halt the build **and** notify. The stack creates a CloudWatch alarm `northstar-ci-build-failure` and an SNS topic `northstar-model-approvals`; subscribe an address to the topic:

    aws sns subscribe --topic-arn <ModelApprovalTopicArn from stack outputs> \
      --protocol email --notification-endpoint you@example.com
    

Then click the confirmation link in the email. Until you do, the alarm still reports _Successfully executed action_ (SNS accepted the message) and nothing reaches you.

> **Two traps in the notification path, both of which fail silently.** Wiring an alarm is the easy part; proving it can actually tell you something is the exercise.
> 
> **1\. `post_build` does not always run.** It runs when the _build_ phase fails, but **not** when `pre_build` fails — CodeBuild goes straight to `FINALIZING` and skips it entirely. So a metric published from `post_build` is absent for exactly the failure the rubric asks you to demonstrate. The reference alarm watches `AWS/CodeBuild` `FailedBuilds`, which CodeBuild emits itself and which no phase failure can skip. If you publish your own metric instead, prove it survives a _test_ failure, not just a gate failure.
> 
> **2\. An SNS topic policy that omits `cloudwatch.amazonaws.com` breaks notification without breaking the alarm.** The alarm still evaluates, still transitions to `ALARM`, still turns the console red — and publishes nothing. The only evidence is one line here:
> 
> \`\`\`bash aws cloudwatch describe-alarm-history --alarm-name northstar-ci-build-failure \\ --history-item-type Action --max-records 5
> 
> Failed to execute action arn:aws:sns:...:northstar-model-approvals
> ==================================================================
> 
> \`\`\`
> 
> Run that command against your own alarm. **An alarm that fires and cannot notify is worse than no alarm, because it looks like coverage.** Note also that SNS rejects a multi-statement topic policy unless every statement has a unique `Sid`.
> 
> **How to demonstrate all of this:** start with the alarm in `OK` (an alarm notifies on a state _change_; one already in `ALARM` sends nothing new). Add a deliberately failing assertion to `tests/`, push, and confirm four things: the run halts in the phase that owns tests, the Model Registry gains **no** new version, the alarm goes `ALARM`, and `describe-alarm-history` says _Successfully executed action_. Then revert and confirm the reverse: green build, registry gains a version, alarm returns to `OK`.
> 
> _Successfully executed action_ means SNS **accepted** the message. It does not mean anyone received it (see the confirmation-link note above). Delivery is proved by the email itself and by a confirmed subscription.

**Recording the demonstration.** A claim that the registry "gained no version" needs a _before_ to compare against, so take three snapshots: before you push the failure, after the failed run, and after the revert. Define this once in your shell (bash or zsh), from the repo root, while the CI stack is still up:

    TOPIC=$(aws cloudformation describe-stacks --stack-name northstar-cicd \
      --query "Stacks[0].Outputs[?OutputKey=='ModelApprovalTopicArn'].OutputValue" --output text)
    
    snap () {   # usage: snap "LABEL"  -> appends a labelled snapshot to docs/lab4-failure-demo.txt
      {
        echo; echo "===== $1  ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ====="
        echo "--- newest CodeBuild build: id, commit, status, then phases"
        B=$(aws codebuild list-builds-for-project --project-name northstar-ci --query 'ids[0]' --output text)
        aws codebuild batch-get-builds --ids "$B" --query 'builds[0].[id,resolvedSourceVersion,buildStatus]' --output text
        aws codebuild batch-get-builds --ids "$B" --query 'builds[0].phases[].[phaseType,phaseStatus]' --output text
        echo "--- newest 3 model packages"
        aws sagemaker list-model-packages --model-package-group-name northstar-churn-models \
          --sort-by CreationTime --sort-order Descending --max-results 3 \
          --query 'ModelPackageSummaryList[].[ModelPackageVersion,ModelApprovalStatus,CreationTime]' --output text
        echo "--- alarm state"
        aws cloudwatch describe-alarms --alarm-names northstar-ci-build-failure \
          --query 'MetricAlarms[0].[StateValue,StateUpdatedTimestamp]' --output text
        echo "--- alarm action history"
        aws cloudwatch describe-alarm-history --alarm-name northstar-ci-build-failure \
          --history-item-type Action --max-records 5 --query 'AlarmHistoryItems[].[Timestamp,HistorySummary]' --output text
        echo "--- SNS subscriptions (an ARN, not PendingConfirmation)"
        aws sns list-subscriptions-by-topic --topic-arn "$TOPIC" --query 'Subscriptions[].[Protocol,SubscriptionArn]' --output text
      } 2>&1 | tee -a docs/lab4-failure-demo.txt
    }
    

Then:

1.  `snap "BEFORE"`: the alarm reads `OK`. Note the newest package version.
2.  Push the deliberately failing test. Wait for the build to fail **and** for the alarm to reach `ALARM`, which takes about 2 minutes after the build ends. Then run `snap "AFTER FAILED RUN"`. Save that build's log as `docs/lab4-build-failed.log` (the `save_log` helper is under _Evidence You Submit_). Screenshot the alarm email you received and save it as `docs/lab4-alarm-email.png`. Its subject starts `ALARM: "northstar-ci-build-failure"`, and the screenshot must show the received time. You may blur your address.
3.  Revert and push. Wait for the green build and for the alarm to return to `OK`, then run `snap "AFTER REVERT"`.

Leave both commits (the deliberate failure and its revert) in your `main` history. They are part of the evidence: the TA can `git show` the failing assertion and match its SHA to the build in `lab4-failure-demo.txt`.

**Rubric:**

Item

Points

Pass Criteria

Evidence (in your `lab4-submit` commit)

All 5 phases present, ordered, with a documented stage mapping

10

Pipeline config plus your mapping shows all five; a green run trained **your** Lab 3 model through `churn_model.train()` (not the unmodified template) and reached Register

`buildspec.yml` and `pipeline.yaml` (or your GitHub Actions / GitLab CI file); the `## Pipeline Stage Mapping` section of `docs/lab4-xops-assessment.md`, which maps the five phases to stages and gives your rationale; `docs/lab4-pipeline-runs.txt` with a `SUCCEEDED` build whose phases run through `POST_BUILD`; `docs/lab4-build-green.log` showing the SageMaker Pipeline `Succeeded` and a model package registered. The TA runs `git show <commit>:models/churn/churn_model.py` on that build's commit SHA to confirm `train()` is yours, not the template

Pipeline halts correctly on test failure

8

Your deliberate test failure stopped the run in the phase that owns tests, and it did **not** reach Register

`docs/lab4-failure-demo.txt`, `AFTER FAILED RUN`: build `FAILED`, `PRE_BUILD FAILED`, no `BUILD` phase. `docs/lab4-build-failed.log` showing the failing assertion. The deliberate-failure commit is in `main` history, and its SHA matches the build

Model Registry promotion only on green gates

6

The registry gained **no** version on the failed run, and gained a `PendingManualApproval` version on the clean one

`docs/lab4-failure-demo.txt`: the newest version is the same in `BEFORE` and `AFTER FAILED RUN`, and `AFTER REVERT` shows one more version, `PendingManualApproval`. Cross-checked against `docs/lab4-model-registry.json`

Failure notification demonstrably delivers

6

On the failed run the alarm reached `ALARM`, SNS accepted the notification, and it reached a confirmed subscriber

`docs/lab4-failure-demo.txt`: `OK` in `BEFORE`, `ALARM` in `AFTER FAILED RUN`, _Successfully executed action_ in the history, and a subscription ARN rather than `PendingConfirmation`. Plus `docs/lab4-alarm-email.png`. An alarm that fires without delivering scores 0 here

The TA has no access to your AWS account, so Task 2 is graded from the evidence files in your tagged commit, not by re-running your pipeline.

### Task 3 — MLOps Configuration (20 points)

Document and implement the MLOps configuration for the churn model lifecycle.

**Required artifacts** in `pipeline/` or `docs/lab4-xops-assessment.md`:

*   **Champion-challenger definition**: When is a new model "better enough" to replace the champion? Write the numeric criterion.
*   **Retraining triggers**: Define (a) a scheduled trigger (e.g., weekly) and (b) a performance-based trigger (e.g., AUC drops below threshold on production data). Both must be automatable — not manual decisions.
*   **Experiment tracking**: Show your **MLflow App** (created in Lab 3) tracking at least 3 hyperparameter combinations with their metrics. Include `mlflow.search_runs` output or a screenshot of the comparison view.

> **Your pipeline will create SageMaker Experiments whether you ask it to or not.** A SageMaker Pipeline auto-creates an Experiment named after the pipeline and one Trial per execution — the reference account has `northstar-churn-pipeline` with 11 trials and `SourceType: SageMakerPipeline`, none of which anyone requested. So you will see Experiments in the console even though this course tracks with MLflow.
> 
> **Do not submit those as your experiment-tracking evidence.** They record _that a pipeline ran_, not _what you varied and what it did to the metrics_. That distinction is the point of the requirement. Auto-generated lineage is free and nearly content-free; deliberate tracking is the thing that costs you effort and earns the marks. - **Model lineage**: For each model version in the Registry, the associated training data version (S3 URI + timestamp), code commit SHA, and evaluation metrics must be stored as model card metadata. The pipeline's `RegisterModel` step records only the artifact and a pointer to the metrics. The commit SHA (the training job's `COMMIT_SHA` environment variable) and the data URI (its input channel) are on the **training job**. Copy them onto the package with `update-model-package --customer-metadata-properties`, either from your own shell after a run or from the buildspec (the CodeBuild role may call `UpdateModelPackage`). Then save the package description. `describe-model-package` needs the full **ARN**: the short form `northstar-churn-models/N` is rejected with a `ValidationException`.

    ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
    N=<the version your final green run registered>
    aws sagemaker describe-model-package \
      --model-package-name "arn:aws:sagemaker:us-east-1:${ACCOUNT}:model-package/northstar-churn-models/${N}" \
      > docs/lab4-model-package.json
    

**Saving your MLflow runs.** Printing a `search_runs` DataFrame truncates the `params.*` columns to `...`, which hides the thing being graded. Write the whole table instead:

    runs = mlflow.search_runs(experiment_names=["northstar-churn-lab4"])   # your experiment name
    cols = ["run_id", "tags.mlflow.runName", "start_time"] + \
           [c for c in runs.columns if c.startswith(("params.", "metrics."))]
    with open("docs/lab4-mlflow-runs.txt", "w") as f:
        f.write(f"tracking_uri: {mlflow.get_tracking_uri()}\n\n{runs[cols].to_string()}\n")
    

A screenshot of the MLflow comparison view, saved as `docs/lab4-mlflow-compare.png`, is optional extra support. It does not replace the text file.

Write the champion–challenger criterion and both retraining triggers under the headings `## Champion-Challenger` and `## Retraining Triggers` in `docs/lab4-xops-assessment.md`, so the TA can find them.

**Rubric:**

Item

Points

Pass Criteria

Evidence (in your `lab4-submit` commit)

Champion-challenger criterion is numeric and binary

5

Criterion is a specific number, not "if it is better"

`## Champion-Challenger` in `docs/lab4-xops-assessment.md`

Both retraining triggers defined and automatable

8

Each trigger has a specific threshold and names the AWS service that would fire it

`## Retraining Triggers` in `docs/lab4-xops-assessment.md`: for each trigger, the threshold or schedule expression and the AWS service that fires it. Designed, not deployed, is fine

Experiment tracking shows ≥3 runs

4

≥3 **MLflow App** runs with differing hyperparameters and logged metrics. Pipeline-auto-generated Experiments do not count

`docs/lab4-mlflow-runs.txt`: a tracking URI that is an MLflow App ARN (`...:mlflow-app/...`), and ≥3 rows whose `params.*` values differ and whose `metrics.*` are filled in

Model lineage metadata stored in Model Registry

3

`describe_model_package()` output shows training data URI and commit SHA

`docs/lab4-model-package.json`: `CustomerMetadataProperties` contains the training data S3 URI, its timestamp, the commit SHA and the evaluation metrics. The commit SHA must be one the TA can find in your `main` history

### Task 4 — XOps Maturity Assessment (20 points)

Write a ~400-word maturity assessment in `docs/lab4-xops-assessment.md`.

For **DataOps** and **MLOps** (the two disciplines you have implemented so far), assess your NorthStar platform against the Level 0–4 maturity model from the chapter.

**Structure:**

    ## DataOps Maturity
    Current level: [0/1/2/3/4]
    Evidence: [Specific artifacts from Labs 1–4 that support this assessment]
    Gap to Level [N+1]: [What is the specific missing capability?]
    Top priority investment: [One concrete change that would advance maturity]
    
    ## MLOps Maturity
    [Same structure]
    

**Rubric:**

Item

Points

Pass Criteria

Evidence (in your `lab4-submit` commit)

Maturity level supported by specific evidence

10

Assessment references specific files/configs in the repo, not generic claims

`## DataOps Maturity` and `## MLOps Maturity` in `docs/lab4-xops-assessment.md`. Every path you cite must exist at your `lab4-submit` tag; the TA opens them. Citing a measured result from your own evidence files (for example a line in `lab4-build-green.log`) is stronger than citing a config file

Gap analysis is specific, not vague

6

"Missing automated drift detection (see Lab 6)" not "need more automation"

The `Gap to Level` line of each section

Priority investment is actionable

4

Names a specific tool or practice, not "improve testing"

The `Top priority investment` line of each section

* * *

Evidence You Submit
-------------------

The TA grades your `lab4-submit` tag **after your AWS stack is gone**. Nothing in your account is inspected, and nothing in it survives teardown: CodePipeline history goes with the stack, and the CodeBuild logs go when you delete their log group. **If the evidence is not committed to the repository, the task was not done.** Every rubric item above names its evidence; this section lists the same files in one place and shows how to capture them. File names are exact.

> **Clarified Fri Oct 23, 2026.** This section, the Evidence columns in the rubrics, and four files were added after Lab 4 was assigned: `lab4-build-green.log`, `lab4-build-failed.log`, `lab4-model-registry.json` and `lab4-alarm-email.png`. The failure demo also now needs a `BEFORE` snapshot. Everything else was already required. If you have already torn your stack down, tell the TA before the deadline.

### Recommended order

1.  **Green run, then approve it.** Get one green run and set its package to `Approved`. It becomes the champion your regression test compares against: `aws sagemaker update-model-package --model-package-arn <arn> --model-approval-status Approved`
2.  **Failure demo** (Task 2): `snap "BEFORE"`, push the failing test, `snap "AFTER FAILED RUN"`, revert, `snap "AFTER REVERT"`. The revert's green run is your **final green run**. Its regression test runs against the champion from step 1.
3.  **Lineage** (Task 3): write metadata onto the final green run's package, then save `docs/lab4-model-package.json`.
4.  **MLflow runs** (Task 3): save `docs/lab4-mlflow-runs.txt`.
5.  **Capture everything else** with the block below. The stack must still be up.
6.  **Delete the CI stack** (see Teardown), _then_ commit `docs/`, tag and push. Deleting first means the docs push doesn't start one more training run.
7.  Finish the teardown.

### Capture block

Run from the repo root before you delete anything. `save_log` writes a CodeBuild build's complete log to a file. It is also used in the failure demo.

    save_log () {   # usage: save_log <codebuild-build-id> <output-file>
      read -r G S <<< "$(aws codebuild batch-get-builds --ids "$1" \
          --query 'builds[0].logs.[groupName,streamName]' --output text)"
      aws logs filter-log-events --log-group-name "$G" --log-stream-names "$S" --output json \
        | python3 -c 'import json,sys; sys.stdout.write("".join(e["message"] if e["message"].endswith("\n") else e["message"]+"\n" for e in json.load(sys.stdin)["events"]))' \
        > "$2"
    }
    
    # 1. Every run: CodePipeline, CodeBuild (with phases and pytest summary lines), SageMaker Pipeline
    {
      echo "===== CodePipeline executions: start, status, commit, execution id ====="
      aws codepipeline list-pipeline-executions --pipeline-name northstar-pipeline \
        --query 'pipelineExecutionSummaries[].[startTime,status,sourceRevisions[0].revisionId,pipelineExecutionId]' --output text
      echo; echo "===== CodeBuild builds, newest first: start, status, commit, build id ====="
      for B in $(aws codebuild list-builds-for-project --project-name northstar-ci --query 'ids[]' --output text); do
        aws codebuild batch-get-builds --ids "$B" --query 'builds[0].[startTime,buildStatus,resolvedSourceVersion,id]' --output text
        aws codebuild batch-get-builds --ids "$B" --query 'builds[0].phases[].[phaseType,phaseStatus]' --output text | sed 's/^/    /'
        save_log "$B" /tmp/lab4-build.log && grep -E '^=+ .*(passed|failed|error)' /tmp/lab4-build.log | sed 's/^/    pytest: /'
      done
      echo; echo "===== SageMaker Pipeline executions: start, status, name ====="
      aws sagemaker list-pipeline-executions --pipeline-name northstar-churn-pipeline \
        --query 'PipelineExecutionSummaries[].[StartTime,PipelineExecutionStatus,PipelineExecutionDisplayName]' --output text
    } 2>&1 | tee docs/lab4-pipeline-runs.txt
    
    # 2. The full log of your final green build (the newest SUCCEEDED build above)
    save_log <final-green-build-id> docs/lab4-build-green.log
    
    # 3. Every version in the registry, with approval status and metadata
    aws sagemaker list-model-packages --model-package-group-name northstar-churn-models \
      --sort-by CreationTime --sort-order Descending --output json > docs/lab4-model-registry.json
    

Open each file and read it before you tear down. An empty `lab4-build-green.log` usually means the wrong build ID. A `pytest:` line that reads `1 failed` on what you thought was your green build means it wasn't. None of these files can be regenerated once the stack and log group are deleted.

### The complete list

File

Task

What it must show

`tests/test_data.py`, `test_features.py`, `test_model.py`, `test_fairness.py`

1

The tests themselves

`models/churn/churn_model.py`

2

Your Lab 3 training logic behind `train()`

`buildspec.yml`, `pipeline.yaml` (or your CI config)

2

The five phases

`docs/lab4-build-green.log`

1, 2

Full log of the final green build: every test file's `-v` output, the champion and fairness warnings, SageMaker Pipeline `Succeeded`, package registered

`docs/lab4-build-failed.log`

2

Full log of the deliberate-failure build: the failing assertion, `PRE_BUILD` failed

`docs/lab4-pipeline-runs.txt`

2

Every run: commit, status, phases, pytest summary, SageMaker Pipeline executions

`docs/lab4-failure-demo.txt`

2

`BEFORE`, `AFTER FAILED RUN` and `AFTER REVERT` snapshots

`docs/lab4-alarm-email.png`

2

The `ALARM` email as received, with its time

`docs/lab4-model-registry.json`

1, 2

Every package version and its approval status, including your `Approved` champion

`docs/lab4-model-package.json`

3

Lineage in `CustomerMetadataProperties` on the final green run's package

`docs/lab4-mlflow-runs.txt`

3

MLflow App tracking URI; ≥3 runs with params and metrics

`docs/lab4-xops-assessment.md`

2, 3, 4

`## Pipeline Stage Mapping`, `## Champion-Challenger`, `## Retraining Triggers`, `## DataOps Maturity`, `## MLOps Maturity`

Git history on `main`

2

The deliberate-failure commit and its revert

Teardown and cost
-----------------

**Cost.** A pipeline run costs about $0.02: about five minutes of CodeBuild, plus a spot training job that bills about a minute. The Lab 2 NAT Gateway costs about $0.045 an hour while the stack is up, so don't leave it running between sessions.

**Teardown, in this order.** Run the capture block under _Evidence You Submit_ first. Deleting the stack erases CodePipeline's run history, and deleting the log group erases every build log. Delete the CI stack before your final docs-only push, or that push starts one more training run.

    aws cloudformation delete-stack --stack-name northstar-cicd
    aws cloudformation wait stack-delete-complete --stack-name northstar-cicd
    # the artifacts bucket is versioned: empty it (console "Empty", or delete all versions), then
    aws s3api delete-bucket --bucket "$AB"
    aws logs delete-log-group --log-group-name /aws/codebuild/northstar-ci
    bash scripts/teardown-lab2.sh        # when you are done with Lab 2's infrastructure
    

Before the data bucket goes, set any `Approved` package to `Rejected`, so no approved package points at a deleted artifact.