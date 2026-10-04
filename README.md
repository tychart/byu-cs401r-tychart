# NorthStar Retail AI Platform — CS 401R

Terraform for the NorthStar ML platform (Labs 1–2) plus the Lab 2 data
pipeline: raw customer transactions → cleaned records → engineered features →
SageMaker Feature Store.

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
infrastructure/
  modules/{vpc,storage,iam,sagemaker,glue,feature_store}/
  environments/dev/               real AWS: the deploy environment
  environments/local/             LocalStack: vpc/storage/iam only, NAT + lifecycle off
scripts/                          verify-lab1.sh, verify-lab2.sh, teardown-lab2.sh
docs/                             apply/verify logs, data contract, lineage diagram
```

## Prerequisites

- Terraform ≥ 1.5, AWS CLI v2, authenticated credentials for the lab account.
- For `scripts/verify-lab2.sh`: `python3` with `pandas` and `pyarrow`
  (the data-quality checks parse Parquet).
- Remote state lives in `s3://northstar-tfstate-<account-id>` (see
  `infrastructure/environments/dev/backend.tf`).

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
