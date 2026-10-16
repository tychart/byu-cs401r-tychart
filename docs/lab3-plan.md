# Lab 3 — Plan of Record

**Lab 3: Model Development** · CS 401R · due **Sat Oct 17, 2026, midnight**
**Tracks: A (required) + C (chosen)** — no RAG. Every rubric item for Track C below.
Tag to submit: **`lab3-submit`**.

This document is the working plan. It assumes you are new to training classic
ML models and comfortable with LLMs/agents. The ML primer in §2 is there on
purpose; skip it if you already know it.

---

## 0. Where this repo stands right now

| Thing | State |
| --- | --- |
| Lab 1 Terraform (VPC, S3, IAM, SageMaker domain) | Built, graded, **currently destroyed** |
| Lab 2 pipeline (Glue transform + feature engineer, Feature Store) | Built, ran, **currently destroyed** |
| S3 data (`raw/`, `processed/`, `features/`) | **Gone** — the Lab 2 teardown emptied and deleted the bucket |
| `docs/bedrock-access-verification.txt` | ✅ present, both checks PASS (Titan embed, Claude Haiku 4.5) — Task 4 item already satisfied |
| Lab 3 starter kit | ✅ integrated (see §5 for the file map) |
| Python env | ✅ `.venv` (uv, Python 3.12) with xgboost 3.4.1, sagemaker 2.257.7, mlflow 3.17.1, boto3 1.43.114 |
| Pause/resume tooling | ✅ `scripts/pause-lab3.sh`, `pause-lab3-deep.sh`, `resume-lab3.sh` |
| AWS credentials | ❌ expired — `aws login --profile default` (see Phase 0; **not** bare `aws login`) |

**The one unavoidable cost:** the Lab 1–2 data has to be rebuilt once (§4
Phase 1). After that it is never recomputed again — the pause tooling below
keeps the S3 bucket *and* the Feature Store alive across every teardown.

---

## 1. What the lab actually asks for

Two systems, on top of the platform you already built:

| | Track A (35 pts) | Track C (35 pts) |
| --- | --- | --- |
| **System** | Churn prediction | Customer service agent |
| **Approach** | XGBoost on Lab 2's Feature Store features | Amazon Bedrock AgentCore (Harness + Gateway + Policy) via Terraform |
| **Training data** | Feature Store **offline store, via Athena** | — |
| **Model** | XGBoost, params as CLI args, no hardcoding | **`deepseek-flash` on your own LiteLLM proxy** (default), with Bedrock `openai.gpt-oss-20b-1:0` as a one-flag fallback. **No Anthropic.** See Phase 5 |
| **Tracking** | SageMaker **MLflow App** (≥3 real runs) | every tool call traced, cost per run |
| **Registry** | Model Registry, `PendingManualApproval` | — |
| **Evaluation** | Precision/Recall @ top 10%, AUC, lift CI vs recency baseline, loyalty-tier slices | 6 scenarios (5 required + injection bonus) ≥2 runs, `policy_tests.py` 7/7 |
| **Failure analysis** | — | ≥2 failure modes incl. the **split-credit hole** |

Plus **Task 3** (`docs/lab3-model-design.md`, ~700 words, 20 pts) and
**Task 4** (repo quality, 10 pts).

You are **not** deploying an endpoint. The lab says so twice, in bold.

---

## 2. ML primer — the concepts this lab grades

Read once. This is the vocabulary the rest of the plan uses.

**The prediction.** Every customer from Lab 2 is one row with 13 features and a
label. `churn_label = 1` means "this customer made no purchase in the 90 days
after the cutoff `T = 2026-04-01`". About **22%** of customers are churners
(that fraction is the *positive rate*). The model outputs a probability per
customer; the retention team works the list top-down.

**Feature matrix and label.** `X` is an `n × 13` grid of numbers, `y` is a
length-`n` vector of 0/1. A **feature** must be observable at `T`. Anything
computed *after* `T` is **leakage** — it secretly tells the model the answer,
the model looks brilliant offline, and it is worthless in production. This is
why `churn_label` is never an input and why `loyalty_tier` is carried alongside
`X` for slicing rather than fed into it (it correlates with spend and would
make the fairness check circular).

**Train/test split.** Fit on a random 70%, score on the held-out 30%. The test
rows are the only honest measurement; a model that memorised the training rows
scores perfectly there and poorly here. The split is **stratified**, meaning
each side keeps the same ~22% churn rate, and seeded (`random_state=42`) so
runs are comparable. The `T` split from Lab 2 is *not* this split — that one
built the labels.

**Gradient boosting / XGBoost.** A decision tree asks yes/no questions
("is `days_since_last_purchase` > 45?"). A boosted ensemble builds hundreds of
small trees in sequence, each one trained to fix the mistakes the previous
trees made; the final score is their sum. It is the standard, strong, cheap
default for tabular data of this size, and it gives you importances you can
show a business audience — which is exactly what Task 3 asks you to justify.

**Class imbalance.** With 22% positives, a model that predicts "no churn" for
everyone is 78% accurate and completely useless. `scale_pos_weight` tells
XGBoost to weight each positive example more heavily so it stops ignoring them.
The right value is roughly `negatives / positives` **computed on your training
split** — about **3.545** here. Do not hardcode it; the skeleton computes it.

**AUC-ROC.** The probability that a randomly chosen churner is ranked above a
randomly chosen non-churner. 0.5 = coin flip, 1.0 = perfect. It measures
*ranking* quality across all thresholds, which is why it is the headline metric
and why the lab does **not** gate on an absolute value (the reference model's
AUC moves ±0.03 across random splits — a fixed gate would just grade your
seed).

**Precision @ top 10% / Recall @ top 10%.** The retention team has a fixed
budget: contact 10% of customers. So:
- **Precision @ 10%** = of the 10% you flagged, how many actually churned? Gate: **≥ 0.50**.
- **Recall @ 10%** = of all the churners that exist, how many are inside your
  top 10%? Gate: **≥ 0.25**. Note the ceiling: with 22% positives, targeting
  10% of customers can capture at most ~45% of churners. 0.25 means you got
  roughly half of what is reachable in that budget.

**The baseline that matters.** "Contact whoever has not purchased in a while"
is free and needs no model. So the baseline is an XGBoost model trained on
`days_since_last_purchase` **alone**, scored on the same test rows. Your full
model must beat it. But two numbers that differ is not evidence, so the lab
requires a **95% confidence interval on the difference**: resample the test
rows with replacement ~2,000 times, score *both* models on each resample, and
take the 2.5th/97.5th percentiles of the difference. If that interval excludes
zero, the feature engineering did real work. The skeleton's
`bootstrap_lift_ci()` already does this correctly (paired resampling).

**Confusion matrix.** The 2×2 table of predicted-vs-actual at a chosen
threshold. Report it at your chosen threshold so a reviewer can see the
trade-off you picked.

**Feature importance.** How much each feature contributed. This is what tells
you which of your Lab 2 features earned their keep and which were decorative —
Task 3 §2 grades your honesty about this.

**Slice evaluation.** The same metrics computed per loyalty tier. The trap this
lab is guarding against: on a small slice (say 30 test customers, 2 churners)
AUC swings between 0.0 and 1.0 depending purely on the split. **Always report
`n` and the positive count next to a slice metric**, and say a slice is too
small to conclude from rather than reporting a dramatic-looking number.

**Why "churners who still buy at T" matters.** About a third of churners are
still purchasing right up to the cutoff, so their recency looks healthy. A
model that leans on recency alone misses exactly the customers a retention
program could still save. That is the argument for Lab 2's diversity / channel /
basket features, and it is the thing the lift CI proves.

---

## 3. Track C primer — the agent side (brief)

```
your code ──invoke_harness──▶ Harness ─────▶ Gateway ──────────────▶ Lambda
                              managed agent   MCP, IAM auth            agent/tools.py
                              ReAct loop       Policy engine (Cedar)    + policy corpus
                              deepseek-flash   ENFORCE mode
```

- **Harness** — AgentCore runs the reason → call tool → observe → respond loop
  for you. You configure model, system prompt, tools, limits. You do not write
  the loop.
- **Gateway** — exposes the five NorthStar tools from one Lambda. It is the
  **enforcement point**: Cedar policies are evaluated *before* a tool runs.
- **Policy (Cedar)** — the `$50` credit cap lives here, so it still holds even
  if the model is argued out of the system prompt. This is the lab's core point
  about defence in depth: the cap is stated in the prompt, checked in
  `tools.py`, *and* enforced at the gateway. Task 3 §3 asks which one you would
  trust alone.

Two things worth internalising before you write any policy:
1. **A per-call rule cannot see aggregates.** Two `$40` credits pass a
   `$50`-per-call rule and total `$80`. That hole is required content for
   `track-c-failures.md`.
2. **IAM propagation to AgentCore lags up to a minute.** If an apply or a call
   fails with `AccessDenied` immediately after you added the permission it
   names, wait 60s and retry before changing anything.

---

## 4. Cost model and the pause/resume strategy

### What actually costs money

| Resource | Idle | On use |
| --- | --- | --- |
| **NAT Gateway + its public IPv4** | **~$0.05/hr ≈ $1.20/day** | $0.045/GB processed |
| SageMaker Studio domain | $0 | app ~$0.05/hr (**only while running**) |
| Studio EFS home dir | ~$0.30/GB-month (pennies) | — |
| S3 bucket (all prefixes) | ~$0.023/GB-month → **cents/month** | ~0 |
| Feature Store (standard online store) | storage only → cents | write/read units |
| Glue catalog, crawler/job **definitions**, VPC connection | $0 | Glue run $0.44/DPU-hr, 2 DPU min |
| VPC/subnets/routes/IGW/SGs, IAM | $0 | — |
| Athena | $0 | $5/TB scanned (your query scans MB → <$0.001) |
| MLflow **App** | **$0** (serverless) | — |
| MLflow **Tracking Server** | **$0.60/hr** — never create one | — |
| Model Registry | $0 | — |
| AgentCore Identity token vault (LiteLLM key) | **$0** | Not charged when used through AgentCore Runtime, and no per-secret storage fee. The key is stored in a **service-managed** secret (`OwningService: bedrock-agentcore-identity`), not one you own or pay for |
| AgentCore harness session | $0 | ~$0.003/session at 60s idle |
| Model tokens (`deepseek-flash` via LiteLLM) | $0 | $0.14 / $0.28 per 1M → **~$0.002 per eval run** |

Caching ~100 MB in S3 costs **~0.2¢/month**; re-running the Glue pipeline costs
**~$0.03–0.10 and 5–10 minutes** each time. Keeping the data is the cheap
option, and the pause tooling makes it free to keep.

A full Track C evaluation (6 scenarios, run twice) costs about **4¢**, and
roughly **90% of that is AgentCore session runtime, not tokens**. Swapping the
model therefore saves cents, not dollars — the reason to use `deepseek-flash` is
that it is not Anthropic and it is genuinely good at agentic tool use, not the
price.

### The three scripts

| Command | What it does | Idle cost after | Resume |
| --- | --- | --- | --- |
| `bash scripts/pause-lab3.sh` | `terraform apply -var enable_nat_gateway=false` — destroys **only** the NAT Gateway + EIP | **~$0.01/mo** | `bash scripts/resume-lab3.sh` |
| `bash scripts/pause-lab3-deep.sh` | real `terraform destroy -target=module.vpc -target=module.glue -target=module.sagemaker`, guarded by a plan check that aborts if `storage`/`feature_store`/`iam` appear | ~$0.01/mo | `bash scripts/resume-lab3.sh` |
| `bash scripts/teardown-lab2.sh` | full destroy incl. S3 — **only at the very end** | $0 | rebuild from raw |

`pause-lab3.sh` is the default: it is one reversible apply, and because the Glue
catalog and Feature Store survive, re-running the pipeline never needs a
re-crawl. Use `pause-lab3-deep.sh` when you want the VPC and Studio domain
actually gone.

Both keep `module.storage` + `module.feature_store` + `module.iam`. That is
deliberate — destroying the Feature Store would delete the offline-store Glue
table, break the Task 1 Athena query, and force a re-ingest. That is the exact
recompute being avoided.

> ⚠ **While paused the private subnet has no internet.** Glue jobs and Studio
> apps will not work. Run `resume-lab3.sh` first.

---

## 5. Starter files now in the repo

```
churn_training_skeleton.py            Task 1 entry point (4 TODO areas)
evaluation_harness.py                 Track B/C harness (Track B parts unused)
agent/
  tools.py                            the 5 NorthStar tools (complete)
  harness_client.py                   invoke_fn + trace/cost evidence writer
  policy_tests.py                     drives the gateway directly, 7 cases
  lambda/handler.py                   gateway -> tools.py dispatch
northstar-policy-docs/                4 markdown policy docs (the corpus)
prompt_templates/                     Track B only, unused
notebooks/README.md                   lab3-demo.ipynb goes here
infrastructure/environments/agent/    Track C TF root (aws 6.67.0, own state key)
  main.tf                             ← 3 TODO (student) items
  tool_definitions.json               5 tool schemas (Cedar actions)
  system_prompt.md                    "Alex" the assistant
  backend.tf.example                  copy to backend.tf, fill account ID
scripts/
  collect-lab3-evidence.sh|.py        exports AWS-only evidence, checks everything
  teardown-lab3.sh                    endpoints/jobs/AgentCore + teardown report
  pause-lab3.sh | pause-lab3-deep.sh | resume-lab3.sh
```

`terraform validate` passes on the AgentCore root and `py_compile` passes on
every copied Python file. Nothing is committed yet.

---

## 6. The plan, phase by phase

### Phase 0 — Prep (15 min)

- [ ] **Re-authenticate the `default` profile, not `tf`:**
      `aws login --profile default`
      Your `~/.aws/config` gives `[default]` the `login_session` and `[profile tf]` a
      `credential_process` that delegates to it, and `AWS_PROFILE=tf` is exported.
      A bare `aws login` therefore tries to attach a login session to `tf` and
      fails with *"Profile 'tf' is already configured with Credential Process
      credentials"*. Only `[default]` ever needs refreshing; `tf` inherits it.
      If the env var still interferes: `AWS_PROFILE=default aws login`.
- [ ] Verify with the profile Terraform and boto3 actually use:
      `aws sts get-caller-identity` (with `AWS_PROFILE=tf` set, expect `mgt-admin`)
- [ ] `uv sync` (already resolved; re-run if `uv.lock` changes)
- [ ] `export SAGEMAKER_SUPPRESS_V2_WARNING=1` — silences the noisy SDK v2 deprecation warning
- [ ] Confirm `docs/bedrock-access-verification.txt` exists ✅
- [ ] `cd infrastructure/environments/dev && terraform init`
- [ ] Declare your track at the top of `docs/lab3-model-design.md` **before writing code** (rubric line item)

---

### Phase 1 — Rebuild the platform and the data, once (**the only recompute**)

- [ ] `terraform -chdir=infrastructure/environments/dev apply 2>&1 | tee docs/lab3-rebuild-output.txt`
- [ ] Upload raw data:
      `aws s3 cp northstar-raw-sample.csv s3://northstar-dev-data-345594594463/raw/customers/northstar-raw-sample.csv`
- [ ] Crawl: `aws glue start-crawler --name northstar-dev-raw-crawler`, wait for `READY`+`SUCCEEDED`
- [ ] Transform: `aws glue start-job-run --job-name northstar-dev-transform`, wait for `SUCCEEDED`
- [ ] Feature engineer: `aws glue start-job-run --job-name northstar-dev-feature-engineer`, wait for `SUCCEEDED`
- [ ] `bash scripts/verify-lab2.sh 2>&1 | tee docs/lab2-verify-output.txt`
- [ ] Confirm the feature group is queryable:
      `aws sagemaker describe-feature-group --feature-group-name northstar-dev-customer-features`
- [ ] **Then pause immediately** — `bash scripts/pause-lab3.sh` (NAT off, the data is now safe and free to keep)

*Done when:* `features/customers/` and the Feature Store offline store have the
9,999 customers, and the NAT is off.

> If you need to re-run the pipeline later, `resume-lab3.sh` first, then start
> the jobs. The crawler does **not** need re-running unless raw data changed.

---

### Phase 2 — Create the MLflow App (once, ~5 min)

- [ ] `aws --version` → needs a recent CLI for `create-mlflow-app` (you have 2.36.49 ✅)
- [ ] Get inputs:
      `terraform -chdir=infrastructure/environments/dev output -raw ml_engineer_role_arn`
      `terraform -chdir=infrastructure/environments/dev output -raw s3_bucket_name`
- [ ] Create it — note `artifacts/mlflow/`, the only prefix MLEngineer can write:
      ```bash
      aws sagemaker create-mlflow-app \
        --name northstar-mlflow \
        --artifact-store-uri s3://northstar-dev-data-345594594463/artifacts/mlflow/ \
        --role-arn arn:aws:iam::345594594463:role/northstar-dev-MLEngineer \
        --query Arn --output text
      ```
- [ ] Poll `aws sagemaker describe-mlflow-app --arn <ARN>` until `Status: Created` (~5 min)
- [ ] `export MLFLOW_APP_ARN=<ARN>` (the skeleton reads `$MLFLOW_APP_ARN` by default)

> ❌ **Do not create a tracking server.** `create-mlflow-tracking-server` is
> $0.60/hr and breaches the whole $10 course budget in 16.7 hours. If anything
> asks you to choose an instance size, you are on the wrong product.

---

### Phase 3 — Implement Track A's four TODO areas

All in `churn_training_skeleton.py`.

**3a. `load_features_from_feature_store` (5 pts — the Athena path)**
- [ ] Uncomment/complete `query.run(...)` → `query.wait()` → `query.as_dataframe()`
- [ ] Print the query ID immediately after `run()`, before `wait()`:
      ```python
      print(f"Athena QueryExecutionId: {query.get_query_execution()['QueryExecution']['QueryExecutionId']}")
      ```
      The evidence script regex-matches that exact line and looks the ID up in
      Athena. No line ⇒ the 5 points fail.
- [ ] Keep the given SQL's three non-obvious parts: `event_time` is **epoch
      seconds** (the helper already converts), the offline store is
      **append-only** so dedup with `ROW_NUMBER()` keeping the newest
      `event_time`, and the outer **`ORDER BY customer_id` is load-bearing** —
      without it Athena's row order varies and `train_test_split` produces a
      different split (and different metrics) every run.
- [ ] Do **not** pass `--local-data-path` for the graded run. Athena queries at
      this size cost <$0.001, so just always use the real path.

**3b. `preprocess_features` (part of Task 4)**
- [ ] Decide and **document** the imputation strategy. The skeleton uses a `-1`
      sentinel. XGBoost handles `NaN` natively, so either is defensible; write
      down which and why.
- [ ] Decide on `churn_risk_score`. It is a pure recency heuristic that
      doubles as your baseline, so including it muddies the "did my features
      add signal" story. Default is **excluded**. If you include it, you must
      report metrics **with and without** it.

**3c. Pass `loyalty_tier` through the split**
- [ ] Change to a three-way split so tier lines up with the val rows:
      ```python
      X_train, X_val, y_train, y_val, tier_train, tier_val = train_test_split(
          X, y, df[SLICE_COLUMN], test_size=0.30, random_state=42, stratify=y)
      ```
      Re-deriving tiers after the split will **not** line up.

**3d. `evaluate_slices` (5 pts)**
- [ ] Per tier: `n`, `positives`, `auc`, `recall@10%`, `too_small` flag
- [ ] Flag slices with `n` small or positives < ~10; the report must say which
      tiers cannot support a claim
- [ ] Write `docs/lab3-evidence/slice-evaluation.csv`. Column names must
      contain `tier`, `n`, `auc`, `recall` (the checker greps for those)

**3e. Plots**
- [ ] `docs/lab3-evidence/confusion-matrix.png` at your chosen threshold
- [ ] `docs/lab3-evidence/feature-importance.png` from the trained model

**3f. `track_run` (5 pts)**
- [ ] `mlflow.set_tracking_uri(args.mlflow_arn)` then `set_experiment("northstar-churn")`
- [ ] Log params **and** metrics every run; include `xgboost_version` as a param
- [ ] Plan for **≥3 runs that vary something defensible** — e.g. `max_depth`
      4/6/8, or `eta` 0.05/0.1/0.2 — and be ready to say what the variation
      did. Three runs with identical params and different seeds earns 2/5.

**3g. `save_and_register_model` (5 pts)**
- [ ] **Create the model package group first — it does not exist yet.** Nothing in
      Lab 1–2 Terraform, and nothing in the starter kit, creates
      `northstar-churn-models`; `create_model_package` fails with
      `ValidationException: Model Package Group ... does not exist` on the first
      run, and the evidence script's `list_model_packages` fails with it. Create
      it **idempotently inside the script**, not in Terraform:
      ```python
      try:
          sm_client.create_model_package_group(
              ModelPackageGroupName="northstar-churn-models",
              ModelPackageGroupDescription="NorthStar churn models")
      except sm_client.exceptions.ClientError as e:
          if "already exists" not in str(e).lower():
              raise
      ```
      It must **not** live in the Lab 1–2 Terraform root: `pause-lab3-deep.sh`
      and `teardown-lab2.sh` destroy that root, and Model Registry entries are
      deliberately kept (they cost nothing) for Labs 4–5.
- [ ] `create_model_package` into group **`northstar-churn-models`** (Lab 5
      deploys from that exact name)
- [ ] `ModelApprovalStatus="PendingManualApproval"` — never approve from code
- [ ] `CustomerMetadataProperties` must carry `auc_roc`, `precision_top10`,
      `recall_top10` as strings — the evidence script cross-checks these
      against `evaluation_metrics.json` and an MLflow run

*Done when:* the script runs end to end from Athena, writes
`evaluation_metrics.json`, logs to MLflow and registers a pending version.

---

### Phase 4 — The graded run and the evaluation report

- [ ] Run it (this exact shape is what the evidence expects):
      ```bash
      python churn_training_skeleton.py \
        --feature-group-name northstar-dev-customer-features \
        --artifacts-bucket northstar-dev-data-345594594463 \
        --max-depth 6 --eta 0.1 --num-round 200 \
        --mlflow-arn "$MLFLOW_APP_ARN" \
        --run-name xgb-final \
        --output-data-dir docs/lab3-evidence \
        2>&1 | tee docs/lab3-evidence/train-final.log
      ```
- [ ] Confirm from the log: the `Athena QueryExecutionId:` line, the
      `Training XGBoost with params:` line, precision ≥ 0.50, recall ≥ 0.25,
      lift CI excludes zero
- [ ] Confirm the local XGBoost version in the log (expect **3.4.1**). Report
      it; the reference numbers were measured on 3.2.0 and the SageMaker
      container is 1.7 — the numbers move with the version, and that is expected
- [ ] Write `docs/lab3-evaluation-report.md`:
  - [ ] the metric table (AUC, precision@10, recall@10, baseline AUC, lift, 95% CI)
  - [ ] confusion matrix + feature importance (embedded or linked)
  - [ ] slice discussion with `n` and positives per tier, weakest tier flagged,
        too-small tiers called out
  - [ ] the MLflow run names and which run is the graded one

*Done when:* `docs/lab3-evidence/evaluation_metrics.json` opens and every number
in it matches the report, an MLflow run, and the registry metadata.

---

### Phase 5 — Track C Terraform (3 TODOs)

Work only in `infrastructure/environments/agent/`. **Do not touch the dev
root** — AgentCore needs provider 6.x and the dev root is pinned to 5.x.

#### The model backend — already wired, LiteLLM by default

The starter kit hardcodes Anthropic Claude Haiku 4.5. This stack defaults to
your own LiteLLM proxy instead, with Bedrock kept behind a switch:

```text
model_backend = "litellm"  (default)  →  deepseek-flash @ https://litellm.tychart.com/v1
model_backend = "bedrock"            →  openai.gpt-oss-20b-1:0  (Apache-2.0, $0.07/$0.30)
```

Everything below was verified on 2026-10-15 **before** wiring it up, so none of
it is a guess:

| Check | Result |
| --- | --- |
| Terraform provider supports it | `aws 6.67.0` exposes `litellm_model_config` (`model_id` required; `api_base` / `api_key_arn` optional) |
| Proxy reachable from AWS | `litellm.tychart.com` → `66.7.118.26`, public IP, valid TLS, `401` = auth enforced. The harness runs `network_mode = "PUBLIC"`, so it can reach it |
| Model exists on the proxy | `deepseek-flash`, $0.14/$0.28 per 1M, 1M context, prompt caching active |
| **Native tool calling** | ✅ verified live against the proxy: `lookup_order`, `query_policy`, and the TC-005 adversarial prompt each returned proper `tool_calls` — and on TC-005 it reached for `query_policy`, *not* `apply_loyalty_credit`/`initiate_return` |
| Both paths plan clean | litellm = 16 to add; bedrock = 13 to add with **zero** Secrets Manager resources |

The switch touches **nothing else**. The gateway, the Cedar `$50` cap, the tools
Lambda, `agent-traces.jsonl` and `agent-cost.csv` are all independent of the
model — which is exactly why the lab barely changes.

```bash
cd infrastructure/environments/agent
cp backend.tf.example backend.tf               # replace <ACCOUNT_ID> with 345594594463
cp terraform.tfvars.example terraform.tfvars   # paste a DEDICATED LiteLLM key
terraform init && terraform apply
```

The key goes into the **AgentCore Identity token vault**, created here as an
`aws_bedrockagentcore_api_key_credential_provider`. Verified end to end on
2026-10-15 with a throwaway key that was created, planned against, applied, and
deleted:

| | |
| --- | --- |
| ARN shape | `arn:aws:bedrock-agentcore:us-east-1:345594594463:token-vault/default/apikeycredentialprovider/northstar-litellm` — exactly the pattern `apiKeyArn` requires. **A Secrets Manager ARN is rejected** |
| Cost | **$0.** AgentCore Identity is not charged when used through AgentCore Runtime, and the token vault has no per-secret storage fee. My first attempt used Secrets Manager, which would have been $0.40/month |
| Key in state? | **No.** `api_key_wo` is write-only — `terraform state show` prints `(write-only attribute)` and grepping `terraform.tfstate` for the key returns **0** hits |
| Cleanup | Deleting the credential provider also removes the service-managed secret behind it (`bedrock-agentcore-identity!default/apikey/...`). Verified: after destroy, `list-secrets` is empty |
| Rotation | Automatic — the version counter is derived from the key (a hash), so a changed key is resent without bumping anything by hand |

**The one rough edge.** The provider requires exactly one of `api_key`,
`api_key_secret_config` or `api_key_wo` on **every** operation, and a write-only
argument cannot be read back from state. So `terraform destroy` needs the key
present too — which is why it lives in the gitignored `terraform.tfvars` rather
than a shell variable, so every command (including the destroy inside
`teardown-lab3.sh`) finds it with no setup. If you ever lose the key, delete the
provider by hand and drop the state entry:

```bash
aws bedrock-agentcore-control delete-api-key-credential-provider --name northstar-litellm
terraform state rm aws_bedrockagentcore_api_key_credential_provider.litellm
```

If the proxy is ever unreachable, `-var model_backend=bedrock` switches to
`openai.gpt-oss-20b-1:0` with no other change.

> **Spike before investing.** Deploy, then run exactly ONE scenario:
> `LocalAgentEvaluator(invoke_fn=HarnessAgent().invoke).evaluate_scenario(eh.AGENT_TEST_CASES[0])`.
> The one thing a plan cannot prove is whether the harness accepts
> `litellm_model_config` server-side. If it is rejected, flip to Bedrock and
> carry on — nothing downstream changes.

- [ ] `cp backend.tf.example backend.tf` and replace `<ACCOUNT_ID>` with
      `345594594463`
- [ ] `terraform init` (provider 6.67.0)
- [ ] **TODO 1** — gateway role permission to call the policy engine. The first
      `apply` **is supposed to fail** at the gateway with `Access denied while
      calling GetPolicyEngine`. That is the exercise. Read the error, then add
      the policy-engine actions scoped to the policy engine ARN and
      `local.gateway_glob` from the AgentCore "Gateway and Policy IAM
      Permissions" page. It names one missing action per attempt, so use the
      docs to add them all at once.
- [ ] **TODO 2** — harness role permission to call the gateway, scoped to this
      gateway's ARN. Symptom if missing: `Failed to load tool 'northstar_tools'
      ... 403 Forbidden`.
- [ ] **TODO 3** — the Cedar `forbid` for the `$50` cap. Mirror `permit_tools`
      and add `depends_on = [aws_bedrockagentcore_policy.permit_tools]`:
      ```hcl
      resource "aws_bedrockagentcore_policy" "cap_loyalty_credit" {
        name             = "forbid_credit_over_cap"
        policy_engine_id = aws_bedrockagentcore_policy_engine.this.policy_engine_id
        validation_mode  = "FAIL_ON_ANY_FINDINGS"
        definition {
          cedar {
            statement = <<-CEDAR
              forbid (
                principal,
                action == AgentCore::Action::"${local.target_name}___apply_loyalty_credit",
                resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.this.gateway_arn}"
              ) when {
                context.input.amount > ${var.credit_cap_dollars}
              };
            CEDAR
          }
        }
        depends_on = [aws_bedrockagentcore_policy.permit_tools]
      }
      ```
      **Two type traps, both verified against the repo:**
      - `amount` is declared **`"integer"`** in `tool_definitions.json`, so Cedar
        sees a `Long`. `var.credit_cap_dollars` is a Terraform `number` that
        renders as `50`, also a `Long`. Do **not** write `50.0` — a Decimal
        literal does not compare as you expect against a Long, and the rule
        silently stops firing.
      - The forbid must depend on the permit, or the validator rejects it as
        *"Overly Restrictive: Policy Engine will deny every request"*.
      Symptom if it does not work: `policy_tests.py` reports `BAD` for the `$51`
      and `$75` credits, which the gateway should have denied.
- [ ] `terraform apply` → confirm `idle_session_timeout_seconds` is still **60**
- [ ] `terraform output -raw harness_arn` / `gateway_url` (or rely on the
      scripts, which read them for you)

> Remember the 60-second IAM propagation lag before concluding a permission is
> wrong.

---

### Phase 6 — Track C evaluation (15 pts) and failure analysis (10 pts)

- [ ] `python agent/policy_tests.py` → **7/7**, writes
      `docs/lab3-evidence/policy-tests.json`. The `$51` and `$75` credits must
      come back `DENY`; the two `$40` split credits come back `ALLOW` (that is
      the hole, not a bug in your policy).
- [ ] Wire the agent to the harness. The lab's documented shape:
      ```python
      import evaluation_harness as eh
      from agent.harness_client import HarnessAgent
      evaluator = eh.LocalAgentEvaluator(invoke_fn=HarnessAgent(run_label="eval-1").invoke)
      df = evaluator.run(eh.AGENT_TEST_CASES)          # 5 required + 1 bonus
      df.to_csv("docs/lab3-evidence/agent_eval.csv", index=False)
      ```
      Do this from `notebooks/lab3-demo.ipynb` so the run is reproducible and
      the outputs are committed. (Consider a thin `scripts/run_agent_eval.py`
      wrapper so the command is repeatable outside the notebook.)
- [ ] Run it **at least twice**, report both runs. Reference stack scored 6/6
      six times and 5/6 twice — variation is normal.
- [ ] Give every scenario its **own session** (the client already does this
      unless you pass a shared `session_id`).
- [ ] Confirm the evidence writer produced
      `docs/lab3-evidence/agent-traces.jsonl` (one line per tool call, with
      `tool`/`input`/`output`/`latency_ms`) and `docs/lab3-evidence/agent-cost.csv`
- [ ] Confirm `escalate_to_human` appears as a **tool call** in the traces for
      TC-003 and TC-005, not only in the reply text
- [ ] Write `docs/lab3-evidence/track-c-failures.md` with ≥2 failure modes,
      each with a concrete fix, citing trace `session_id`s. One **must** be the
      split-credit hole: explain *why* a per-call rule cannot stop it (it has
      no memory of prior calls in the session), what would (an accumulated,
      session-scoped credit ledger — i.e. AgentCore's session-aware "temporal"
      policies bound to a per-session state key rather than a stateless
      per-call predicate), and whether a harness supports it today.

---

### Phase 7 — Design doc and demo notebook

- [ ] `docs/lab3-model-design.md` (~700 words + track declaration at top):
      1. why **gradient boosting** for 10k rows × 13 tabular features with an
         interpretability requirement — and what would make you switch
      2. what the features bought you — baseline vs full with numbers, **which
         features carried signal and which were decorative**
      3. Track C: **agent over a simpler pipeline** (name the alternative and
         the technical reason for rejecting it), the primary production risk,
         and why the `$50` cap appears in three places — which single layer
         you would trust alone
      4. what you would do differently with 10× the time or data (a specific
         architectural or evaluation change, not "more testing")
- [ ] `notebooks/lab3-demo.ipynb` — the end-to-end demo. **Kernel → Restart &
      Run All**, save, commit **with outputs**. Execution counts must be
      `1, 2, 3, …` or the evidence script warns. The TA cannot re-run it, so
      the saved outputs *are* the evidence.

---

### Phase 8 — Evidence, teardown, tag

Order matters: the AgentCore export only exists while the stack is up.

- [ ] `bash scripts/collect-lab3-evidence.sh --track C` → fix every `FAIL`, re-run.
      Writes `docs/lab3-evidence/collect-output.txt` plus the AWS-only exports
      (`account.json`, `athena-query.json`, `mlflow-app.json`, `mlflow-runs.csv`,
      `model-registry.json`, `agentcore-config.json`).
- [ ] Update `README.md` for Lab 3 (Task 4): how to train, how to evaluate,
      where artifacts land. ✅ stub added; refine once the commands are real.
- [ ] `bash scripts/teardown-lab3.sh` → `docs/lab3-teardown-output.txt` (deletes
      endpoints/configs, stops in-flight jobs, destroys the AgentCore stack,
      deletes the harness runtime log group, verifies).
- [ ] Confirm `aws sagemaker list-endpoints` is empty and no AgentCore
      harness/gateway/policy-engine/runtime remains (the script checks).
- [ ] **Keep the MLflow App** — free, and Labs 4 and 6 log to it.
- [ ] **Nothing to clean up for the LiteLLM key.** It is a Terraform resource, so
      `teardown-lab3.sh` destroys it, and deleting the credential provider also
      removes the service-managed secret behind it. Confirm with:
      `aws secretsmanager list-secrets --region us-east-1` (expect empty).
- [ ] Commit everything under `docs/` and `notebooks/`.
- [ ] `git tag lab3-submit && git push origin lab3-submit` ← **do not forget this**;
      an untagged repo is graded at your last commit before the deadline.
- [ ] *After* the tag, when you are truly finished with the data:
      `bash scripts/teardown-lab2.sh` (full destroy, **including S3**).

---

## 7. Evidence map

| File | Task | What it proves |
| --- | --- | --- |
| `docs/lab3-evidence/train-final.log` | 1 | graded run; contains `Athena QueryExecutionId:` and `Training XGBoost with params:` |
| `docs/lab3-evidence/evaluation_metrics.json` | 1 | written by the script; gates + baseline + lift CI |
| `docs/lab3-evidence/slice-evaluation.csv` | 1 | tier, n, positives, AUC, recall, too-small flag |
| `docs/lab3-evidence/confusion-matrix.png` | 1 | threshold behaviour |
| `docs/lab3-evidence/feature-importance.png` | 1 | what carried signal |
| `docs/lab3-evaluation-report.md` | 1 | the table + baseline CI + slice discussion |
| `docs/lab3-model-design.md` | 3 | track declared; ~700 words |
| `docs/lab3-evidence/agent_eval.csv` | 2C | ≥5 scenarios, ≥2 runs |
| `docs/lab3-evidence/agent-traces.jsonl` | 2C | tool, input, output, latency_ms per call |
| `docs/lab3-evidence/agent-cost.csv` | 2C | tokens + cost per run |
| `docs/lab3-evidence/policy-tests.json` | 2C | 7/7 incl. over-cap credits denied at the gateway |
| `docs/lab3-evidence/track-c-failures.md` | 2C | ≥2 failures + fixes, incl. split-credit hole |
| `notebooks/lab3-demo.ipynb` | 2 | one clean Restart & Run All, with outputs |
| `docs/bedrock-access-verification.txt` | 4 | ✅ already present |
| `docs/lab3-teardown-output.txt` | gate | no endpoints, no running jobs, no AgentCore |
| `docs/lab3-evidence/{account,athena-query,mlflow-app,mlflow-runs,model-registry,agentcore-config}` | exported | AWS-only evidence, captured before teardown |

**One chain of numbers.** `auc_roc` / `precision_top10` / `recall_top10` in the
report = `evaluation_metrics.json` = one MLflow run = the
`CustomerMetadataProperties` of a `PendingManualApproval` registry version. The
evidence script checks this chain; so does the grader.

---

## 8. Known traps and where the instructions deserve a grain of salt

**Things the starter code's own comments flag (all verified true):**
1. **MLflow App ≠ MLflow Tracking Server.** App is free; the server is $0.60/hr.
2. **`eval_metric` order matters.** XGBoost early-stops on the *last* metric.
   `["logloss", "auc"]` is correct — the skeleton already is.
3. **`ORDER BY customer_id` is not cosmetic.** Without it, metrics move run to
   run on byte-identical data (measured: AUC 0.7276–0.7431).
4. **Offline store is append-only and soft-deleting.** Dedup with
   `ROW_NUMBER()`; exclude `is_deleted`.
5. **`event_time` is `Fractional` epoch seconds**, not an ISO string.
6. **`scale_pos_weight` must be derived from your training split** (~3.545), not
   hardcoded.
7. **Recall@10% ceiling is ~45%.** Do not chase a number the budget forbids.
8. **Slice metrics need `n`.** Platinum once "measured" AUC 0.0 on ~2 positives
   and it was pure split noise.

**Track C traps:**
9. **Only applies to the Bedrock fallback.** `anthropic.claude-haiku-4-5-...`
   invoked by its bare model ID fails with `ValidationException` — Claude 4.5+
   needs the `us.` cross-region inference profile. Never Claude 3 Haiku
   (LEGACY). The default LiteLLM backend is unaffected, and so is
   `openai.gpt-oss-20b-1:0`, which has no inference profile and is invoked
   on demand by its bare model ID.
10. **`boto3` ≥ 1.43.57** for `invoke_harness` (you have 1.43.114 ✅).
11. **IAM propagation lag up to 60s** after adding a permission.
12. **`runtimeSessionId` must be ≥ 33 chars** — the client handles it.
13. **One session per scenario**, or scenarios contaminate each other.
14. **The forbid must depend on the permit** or the policy validator refuses it.
15. **`teardown-lab3.sh` checks need AWS CLI ≥ 2.36** (you have 2.36.49 ✅). It
    treats a failed AWS call as a FAILED check, so expired credentials show as
    failures rather than a clean report.
16. **The harness delete takes ~5 minutes.** Let it finish. AWS creates the
    runtime log group itself and Terraform misses it — the script deletes it,
    and it holds full conversations.
17. **`agent/lambda/` cannot be imported as a Python module.** `lambda` is a
    reserved word, so `import agent.lambda.handler` is a `SyntaxError`, not an
    `ImportError`. The kit's Terraform zips `handler.py` and `tools.py` to the
    archive root, where `import tools` resolves and Lambda loads `handler.handler`
    as a top-level module — which is correct. If you write a local test that
    needs the handler, load it by path:
    `importlib.util.spec_from_file_location("handler", "agent/lambda/handler.py")`
    with `agent/` on `sys.path`.
18. **Verified working locally (no AWS needed):** `agent/tools.py` finds the
    corpus at `northstar-policy-docs/`, `query_policy` returns grounded answers
    with `POL-XXX-NNN` citations (`{answer, source_documents, confidence}`), the
    five tool schemas match `handler.DISPATCH` exactly, and
    `apply_loyalty_credit` already refuses >$50 at the *tool* layer with
    `success: False, approval_required: True`. That is the second of the three
    defence layers — the gateway policy (TODO 3) is the third.
19. **`escalate_to_human` priority values** are `"normal"`/`"urgent"`,
    not `"high"`. An unrecognised value silently falls back to `"normal"`.
    The schema does not enumerate them, so the model has to infer it from the
    description.

**Where I would treat the lab text as approximate:**
- The **status of Lab 1–2 resources** in the instructions assumes an applied
  stack. Yours was torn down (`docs/lab2-destroy-output.txt`), so Phase 1 is
  mandatory, not optional.
- **"Every Track A rubric item is reachable locally"** — true, and that is the
  path chosen (§decisions below). The spot-training instructions (quota 4,
  `max_wait ≤ 3600`) are simply unused here.
- The **XGBoost version** note says the container is 1.7 and the reference
  3.2.0. You will be on **3.4.1**, so expect your numbers to sit near the
  reference column but not match it to four decimals. Report the version.
- **RAGAS pins** and the whole `prompt_templates/` block are Track B only —
  ignore them. `evaluation_harness.py` imports RAGAS behind a `try/except`, so
  its absence prints a harmless warning.
- The **`--local-data-path`** escape hatch is for development only. The graded
  run must be Athena; a log showing the CSV loader fails the 5-point item.
- **`docs/bedrock-access-verification.txt`** is a pasted shell transcript
  rather than an AWS artefact. It satisfies the item (both checks PASS) and the
  evidence script only checks presence.
- **The Model Registry group is created nowhere.** Neither the Lab 1–2
  Terraform nor the starter kit creates `northstar-churn-models`, and the
  skeleton's TODO does not mention it, so the first `create_model_package`
  fails. Create it idempotently in the script (see §3g) and keep it out of
  Terraform, because Model Registry entries are meant to survive teardown.
- **`sagemaker:CreateModelPackageGroup` is not in the MLEngineer policy.**
  Irrelevant for the graded run, which uses *your own* credentials locally, but
  it will bite Lab 4's pipeline, which runs as a SageMaker execution role. A
  one-line addition to `modules/iam/main.tf` (next to the existing
  `CreateModelPackage`) fixes it and costs nothing to apply in Phase 1. Optional
  for this lab.

---

## 9. Open risks

| Risk | Mitigation |
| --- | --- |
| `pandas 3.0.6` + `sagemaker 2.257.7` runtime incompatibility in the offline-store path | Resolution succeeded and `sagemaker.feature_store` imports cleanly. If `query.as_dataframe()` breaks, drop to `query.as_dataframe()` → raw `boto3` Athena paging, or pin `pandas<3` in a follow-up commit. |
| Feature Store online-store throughput defaults to *provisioned* | Check `aws sagemaker describe-feature-group ... --query 'OnlineStoreConfig.ThroughputConfig'`. If it is not `OnDemand`, pin it in `modules/feature_store` so the paused stack really is ~$0. |
| Track C policy-engine IAM action list is undocumented in the kit | Expected: iterate on the apply error using the AgentCore "Gateway and Policy IAM Permissions" doc page. Budget an hour. |
| AgentCore availability/quota on a new account | Track A is 35 points and can proceed regardless; sequence A first. |
| Harness rejects `litellm_model_config` server-side (the one thing a plan cannot prove; the Terraform schema allows it) | Phase 5's one-scenario spike catches it in seconds. Fallback: `-var model_backend=bedrock` → `openai.gpt-oss-20b-1:0`, nothing else changes. |
| The provider demands the key on every terraform operation, including `destroy` | The key lives in the gitignored `terraform.tfvars`, so it is always present. Escape hatch if the key is ever lost: `aws bedrock-agentcore-control delete-api-key-credential-provider --name northstar-litellm` then `terraform state rm aws_bedrockagentcore_api_key_credential_provider.litellm`. |
| Secret value exposure | None. `api_key_wo` is write-only: the key is sent to AWS and never persisted, so `terraform state show` prints `(write-only attribute)`. |
| Proxy unavailable or key revoked during grading | The TA never runs it — the notebook is committed **with outputs**, so the evidence is static. The proxy matters only while you are producing it. |
| Secret value exposure | None: the key is written to AgentCore's token vault through a Terraform write-only argument, so it is never persisted to state, the repo, or git history. |
| `.terraform.lock.hcl` is git-ignored repo-wide (`**/*.lock.hcl`) | The agent root pins `6.67.0` exactly in `versions.tf`, so the lock file is redundant. Leave as-is, or narrow the ignore rule later. |

---

## 10. Decisions already made

| Decision | Choice |
| --- | --- |
| Tracks | **A + C** (no RAG) |
| Training path | **Local, XGBoost 3.x** — no SageMaker training job, no quota dependency |
| Python env | Dependencies added to the **existing uv project** (`.venv`) |
| Data preservation | **NAT-toggle pause by default** + a guarded deep-destroy script; full teardown only at the end |
| Keep-set across a pause | `module.storage` (S3) + `module.feature_store` (offline-store Glue table) + `module.iam` (MLflow App role) |
| Track C model backend | **LiteLLM proxy** — `deepseek-flash` at `https://litellm.tychart.com/v1`, key in Secrets Manager. **No Anthropic.** |
| Track C model fallback | `-var model_backend=bedrock` → `openai.gpt-oss-20b-1:0` (Apache-2.0, $0.07/$0.30). One flag, no other change. |
| If the adversarial scenario fails | Escalate to bigger **open-weight** models (gpt-oss-120b, Qwen3 32B). Never Anthropic. Report the model and the failure honestly — that is graded content (failure modes + mitigations). |
| Model wiring | `model_backend` switches `litellm_model_config` ↔ `bedrock_model_config`; the API key credential provider and its IAM policy exist only in the LiteLLM path, so the Bedrock path stays dependency-free |
| Where the LiteLLM key lives | **AgentCore Identity token vault** (`aws_bedrockagentcore_api_key_credential_provider`), supplied via a Terraform **write-only** argument. **$0**, not in state, auto-removed on destroy. Rejected alternatives: Secrets Manager ($0.40/month), a local encrypted file (the harness runs in AWS and cannot read it) |
