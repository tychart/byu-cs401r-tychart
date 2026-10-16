# NorthStar Retail AI Platform — CS 401R

> **Log in before anything else.** `AWS_PROFILE=tf` is exported in this shell, and
> the `tf` profile gets its credentials from the `[default]` login session via
> `credential_process`. So authenticate the **`default`** profile, never `tf`:
>
> ```bash
> aws login --profile default
> aws sts get-caller-identity    # expect the mgt-admin IAM user
> ```
>
> A bare `aws login` fails with *"Profile 'tf' is already configured with
> Credential Process credentials"* — that is the wrong profile. Logging in to
> `default` refreshes the session that Terraform, the AWS CLI and boto3 all
> inherit through `tf`. Full explanation in [`docs/lab3-plan.md`](docs/lab3-plan.md) Phase 0.

Terraform for the NorthStar ML platform (Labs 1–3): the Lab 2 data pipeline
(raw customer transactions → cleaned records → engineered features → SageMaker
Feature Store), the Lab 3 churn model (Track A) and the Lab 3 customer service
agent on Bedrock AgentCore (Track C).

The full Lab 3 work plan, cost model and pause/resume strategy live in
[`docs/lab3-plan.md`](docs/lab3-plan.md).

## Lab 2 additions

| Layer | Added in Lab 2 |
| --- | --- |
| `modules/vpc` | Private subnet `10.0.1.0/24`, Elastic IP, NAT Gateway, private route table, and a self-referencing all-ports ingress rule on the SageMaker SG (Glue requires it to place job ENIs inside a VPC) |
| `modules/storage` | Five S3 lifecycle rules (`expire-raw-data` 90d, noncurrent versions for `raw/`/`processed/`/`features/`, `expire-datacapture` 7d) |
| `modules/iam` | `DataEngineer` (Glue/Lambda/SageMaker trust; reads `artifacts/glue/`, writes `raw/`/`processed/`/`features/`, cannot write `artifacts/`) and `ModelMonitor` (read-only drift observation) |
| `modules/sagemaker` | Domain moved to the private subnet with `app_network_access_type = "VpcOnly"` |
| `modules/glue` | **new** — catalog database `northstar_dev`, on-demand raw crawler, VPC `NETWORK` connection, and two Glue 4.0 Spark jobs |
| `modules/feature_store` | **new** — `northstar-dev-customer-features` feature group (16 definitions, online + offline store) |
| `glue-scripts/` | `transform.py` (clean) and `feature_engineer.py` (engineer + label) |

## The pipeline

```
raw/customers/*.csv            (dirty transactions, ~163k rows)
      │  crawler northstar-dev-raw-crawler
      ▼
Glue catalog: northstar_dev.customers
      │  job northstar-dev-transform          (glue-scripts/transform.py)
      ▼
processed/customers/*.parquet  (157,627 rows, transaction grain)
      │  job northstar-dev-feature-engineer   (glue-scripts/feature_engineer.py)
      ▼
features/customers/*.parquet   (9,999 rows, one per customer)
      └─► SageMaker Feature Store northstar-dev-customer-features (online + offline)
```

The feature job splits each customer's **timeline** at `T = 2026-04-01`: every
feature is computed from purchases on or before `T`, and `churn_label` only
from the outcome window `(T, 2026-06-30]`. See `glue-scripts/feature_engineer.py`.

Data/documentation deliverables live in `docs/`:
`lab2-data-contract.md`, `lab2-data-lineage.png`, and the apply/verify logs.

## Repository layout

```
glue-scripts/                     PySpark ETL scripts (uploaded to S3 by Terraform)
churn_training_skeleton.py        Lab 3 Track A: Athena → XGBoost → MLflow → Registry
evaluation_harness.py             Lab 3 Track C: scenario evaluation for the agent
agent/                            Lab 3 Track C: tools, gateway Lambda handler,
                                  harness client (trace/cost evidence), policy tests
northstar-policy-docs/            policy corpus bundled into the tools Lambda
notebooks/                        lab3-demo.ipynb (committed with outputs)
infrastructure/
  modules/{vpc,storage,iam,sagemaker,glue,feature_store}/
  environments/dev/               real AWS: the deploy environment (Labs 1–2)
  environments/agent/             Track C AgentCore stack; aws 6.x, OWN state key
  environments/local/             LocalStack: vpc/storage/iam only, NAT + lifecycle off
scripts/                          verify-lab1.sh, verify-lab2.sh, teardown-lab2.sh,
                                  collect-lab3-evidence.sh, teardown-lab3.sh,
                                  pause-lab3.sh, pause-lab3-deep.sh, resume-lab3.sh
docs/                             apply/verify logs, data contract, lineage diagram,
                                  lab3-plan.md, lab3-evaluation-report.md,
                                  lab3-model-design.md, lab3-evidence/
```

Work on the Track C stack always happens inside
`infrastructure/environments/agent/` — it needs Terraform provider `aws` 6.x
and keeps its own state key (`agent/terraform.tfstate`). Do not add AgentCore
resources to `environments/dev/`, which is pinned to 5.x.

## Prerequisites

- Terraform ≥ 1.5, AWS CLI v2, authenticated credentials for the lab account.
- `uv` for the Python environment (`uv sync`), Python 3.12.
- For `scripts/verify-lab2.sh`: `pandas` and `pyarrow` (the data-quality checks
  parse Parquet).
- Remote state lives in `s3://northstar-tfstate-<account-id>` (see
  `infrastructure/environments/dev/backend.tf`).
- AWS CLI ≥ 2.36 and `boto3` ≥ 1.43.57 for Lab 3's AgentCore commands
  (`create-mlflow-app`, `invoke_harness`).

## Lab 3 — train, evaluate, and where artifacts land

### Track A: churn model

The graded run reads the Lab 2 Feature Store **offline store through Athena**
(never a CSV), trains XGBoost locally, tracks runs in a SageMaker **MLflow
App** and registers the model in the **Model Registry** as
`PendingManualApproval`.

```fish
# one-time, after the Labs 1–2 stack is applied
aws sagemaker create-mlflow-app --name northstar-mlflow \
  --artifact-store-uri s3://(terraform -chdir=infrastructure/environments/dev output -raw s3_bucket_name)/artifacts/mlflow/ \
  --role-arn (terraform -chdir=infrastructure/environments/dev output -raw ml_engineer_role_arn) \
  --query Arn --output text

# the graded run
set MLFLOW_APP_ARN arn:aws:sagemaker:us-east-1:<account>:mlflow-app/app-XXXX
uv run python churn_training_skeleton.py \
  --feature-group-name northstar-dev-customer-features \
  --artifacts-bucket northstar-dev-data-<account> \
  --max-depth 6 --eta 0.1 --num-round 200 \
  --mlflow-arn $MLFLOW_APP_ARN --run-name xgb-final \
  --output-data-dir docs/lab3-evidence \
  2>&1 | tee docs/lab3-evidence/train-final.log
```

Artifacts land in:

| Path | Contents |
| --- | --- |
| `docs/lab3-evidence/` | `train-final.log`, `evaluation_metrics.json`, `slice-evaluation.csv`, plots, Track C evidence |
| `./model/` (or `--model-dir`) | `model.xgb`, `model_metadata.json` |
| `s3://<bucket>/artifacts/athena-results/` | Athena result sets |
| `s3://<bucket>/artifacts/mlflow/` | the MLflow App artifact store |
| MLflow App / Model Registry | runs and model versions, in AWS (free), exported by the evidence script |

### Track C: customer service agent

```bash
# 1. Once: store a DEDICATED LiteLLM proxy key in Secrets Manager.
#    `read -rs` keeps it out of your shell history.
read -rs KEY
aws secretsmanager create-secret \
  --name northstar-agent-litellm-api-key \
  --secret-string "$KEY" --region us-east-1
unset KEY

# 2. Deploy. Terraform looks the secret up by name and only ever sees its ARN.
cd infrastructure/environments/agent   # separate root, aws 6.x provider
cp backend.tf.example backend.tf       # fill in the account ID
terraform init && terraform apply

cd ../../..
uv run python agent/policy_tests.py        # 7/7; the gateway denies credits > $50
```

**Model backend.** The starter kit hardcodes Anthropic Claude Haiku 4.5; this
stack defaults to a model on your own **LiteLLM proxy** instead, and keeps
Bedrock behind a switch:

```text
model_backend = "litellm"  (default)  →  deepseek-flash @ https://litellm.tychart.com/v1
model_backend = "bedrock"            →  openai.gpt-oss-20b-1:0 (Apache-2.0)
```

Switching is one flag (`-var model_backend=bedrock`) and touches nothing else:
the gateway, the Cedar `$50` cap, the tools and the trace/cost evidence are all
independent of the model.

The proxy key lives in Secrets Manager, deliberately **not** in Terraform. This
stack looks the secret up by name and uses only its ARN, so the key value never
enters the repo, git history, or `terraform.tfstate`, and `terraform destroy` does
not delete it. Two consequences to remember: the secret must exist *before*
`terraform plan`, and because Terraform does not own it, it bills ~$0.40/month
until you delete it by hand (the teardown step in `docs/lab3-plan.md` Phase 8).
See Phase 5 for the full verified detail.

The five tools live in `agent/tools.py` and are exposed through the AgentCore
Gateway with Cedar policy enforced in `ENFORCE` mode. `agent/harness_client.py`
writes `docs/lab3-evidence/agent-traces.jsonl` and `agent-cost.csv` on every
call; `evaluation_harness.LocalAgentEvaluator` drives the six scenarios and
writes `docs/lab3-evidence/agent_eval.csv`.

### Cost control between work sessions

The Lab 2 NAT Gateway is the only meaningful idle cost (~$1.20/day). Pause it
without touching any data:

```bash
bash scripts/pause-lab3.sh        # NAT off; keeps S3 + Feature Store + Glue catalog
bash scripts/resume-lab3.sh       # back on
```

`scripts/pause-lab3-deep.sh` destroys the VPC, Glue and Studio layer for real
while keeping S3, the Feature Store and IAM. Full teardown (including the S3
bucket) is `scripts/teardown-lab2.sh`, run only at the end of the lab.

## Run it end to end

All commands from the repository root unless noted.

```fish
# 1. Deploy the platform (Task 1 + 2), capturing the apply log
cd infrastructure/environments/dev
terraform init
terraform apply 2>&1 | tee ../../../docs/lab2-extend-output.txt

# 2. Upload the raw sample data
cd ../../..
set ACCOUNT (aws sts get-caller-identity --query Account --output text)
set BUCKET northstar-dev-data-$ACCOUNT
aws s3 cp northstar-raw-sample.csv s3://$BUCKET/raw/customers/northstar-raw-sample.csv

# 3. Crawl raw/ and register the table
aws glue start-crawler --name northstar-dev-raw-crawler
aws glue get-crawler --name northstar-dev-raw-crawler   # wait for READY + SUCCEEDED

# 4. Transform: raw -> processed
aws glue start-job-run --job-name northstar-dev-transform
aws glue get-job-runs --job-name northstar-dev-transform --max-items 1

# 5. Deploy the Feature Store + feature job, then run it (Task 3)
cd infrastructure/environments/dev
terraform apply 2>&1 | tee -a ../../../docs/lab2-extend-output.txt
aws glue start-job-run --job-name northstar-dev-feature-engineer
aws glue get-job-runs --job-name northstar-dev-feature-engineer --max-items 1

# 6. Verify (run BEFORE teardown; the output is graded)
cd ../../..
bash scripts/verify-lab2.sh 2>&1 | tee docs/lab2-verify-output.txt

# 7. Tear everything down (also removes resources Terraform does not own)
bash scripts/teardown-lab2.sh
```

`terraform apply` creates job *definitions*; the pipeline runs when you start
the crawler and the jobs. The Glue job scripts are uploaded to
`artifacts/glue/` by Terraform, so editing a script and re-applying is all it
takes to change what the jobs run.

## LocalStack validation

`make local-validate LOCAL_OUT=docs/lab2-localstack-output.txt` applies the
`vpc`, `storage`, and `iam` modules against LocalStack with the NAT Gateway and
the S3 lifecycle rules disabled (`enable_nat_gateway = false`,
`enable_lifecycle_rules = false` in `environments/local`). SageMaker, Glue, and
Feature Store are not emulated locally.
