# Lab 2: Data & Feature Engineering

**Assigned:** Thu Sep 17 | **Due:** Sat Oct 3, midnight **Chapter:** *Data & Feature Engineering* **Builds on:** Lab 1 — your S3 bucket, VPC, MLEngineer role, and Terraform codebase **Primary tool:** Terraform (all infrastructure changes are IaC from this point forward)

## Objective

Extend the NorthStar platform in two directions. First, harden the infrastructure left intentionally simple in Lab 1: move SageMaker into a private subnet behind a NAT Gateway, add the DataEngineer and ModelMonitor IAM roles, and add S3 lifecycle rules. Second, build the data pipeline that feeds the ML platform: raw data lands in S3, Glue crawls and transforms it, and engineered features are written to SageMaker Feature Store.

By the end of this lab, you will have a working end-to-end data pipeline: raw customer event data → cleaned and transformed records → feature vectors in Feature Store → ready for model training in Lab 3.

---

## What's New in Lab 2

These additions build on Lab 1's foundation. Your existing Terraform modules will be modified and extended — not replaced.

| Component | Lab 1 State | Lab 2 Change |
| --- | --- | --- |
| VPC networking | Public subnet only | Add private subnet + NAT Gateway; move SageMaker there |
| IAM roles | MLEngineer only | Add DataEngineer (Glue + Lambda trust) and ModelMonitor |
| S3 lifecycle rules | Deferred | Add 90-day expiration on `raw/`, version cleanup on all prefixes |
| Data ingestion | No pipeline | Glue crawler on `raw/` + ETL job → `processed/` |
| Feature engineering | No features | Glue ETL → `features/` + SageMaker Feature Group |

---

## Architecture Reference

This specification describes the **complete** Lab 2 platform — Lab 1 components plus all Lab 2 additions. Use it to build your architecture diagram before writing Terraform.

### What the Data Layer Needs to Do

The data pipeline must:

1. **Ingest raw data at rest** — customer transaction records land in `raw/` as CSV files
2. **Discover schema automatically** — a Glue Crawler scans `raw/` and registers the schema in the Glue Data Catalog so ETL jobs can query it without hardcoded column definitions
3. **Transform and validate** — a Glue ETL job reads from the catalog, applies type enforcement and null handling, and writes Parquet to `processed/`
4. **Engineer features and label them** — a second Glue ETL job reads `processed/`, splits each customer's history in time into an observation window and an outcome window, computes 13 churn-predictive features from the observation window, derives `churn_label` from the outcome window, and writes one labeled row per customer to `features/`
5. **Register features for ML** — a SageMaker Feature Group ingests the feature vectors so training jobs in Labs 3–4 can pull them without re-computing
6. **Enforce data boundaries** — DataEngineer writes `raw/`, `processed/`, and `features/` but cannot write `artifacts/`; MLEngineer reads `features/` and writes `artifacts/`; ModelMonitor reads `artifacts/` and writes CloudWatch metrics only
7. **Expire stale data automatically** — raw files older than 90 days are deleted by S3 lifecycle rules

### Component Specification

---

#### Boundary: AWS Region `us-east-1`

---

##### Boundary: VPC — `northstar-dev-vpc` (extended from Lab 1)

- CIDR: `10.0.0.0/16` (unchanged)

---

###### Boundary: Availability Zone `us-east-1a`

**Public Subnet — `northstar-dev-public-1`** *(Lab 1 — no changes)* - CIDR: `10.0.100.0/24` - New purpose: NAT Gateway anchor point only (Studio moved out of here)

→ Contains: **NAT Gateway — `northstar-dev-nat`** *(new in Lab 2)* - Elastic IP: `northstar-dev-eip` (allocated, associated with NAT) - Purpose: provides outbound internet access for the private subnet; SageMaker pulls ECR images, calls AWS APIs, reaches S3 via this path

**Private Subnet — `northstar-dev-private-1`** *(new in Lab 2)* - CIDR: `10.0.1.0/24` - Public IP on launch: no - Contains: SageMaker Domain, Glue job workers

---

###### VPC-Level Network Resources

**Internet Gateway — `northstar-dev-igw`** *(Lab 1 — no changes)*

**Route Table — `northstar-dev-public-rt`** *(Lab 1 — updated association only)* - Associated subnet: `northstar-dev-public-1` - Routes: `0.0.0.0/0` → Internet Gateway

**Route Table — `northstar-dev-private-rt`** *(new in Lab 2)* - Associated subnet: `northstar-dev-private-1` - Routes: `0.0.0.0/0` → NAT Gateway - Effect: private subnet resources reach the internet outbound; no inbound internet connections possible

**Security Group — `northstar-dev-sagemaker-sg`** *(Lab 1 — one rule added)* - **New in Lab 2:** a self-referencing ingress rule, all ports, all protocols (`self = true` in Terraform) - Why: Glue refuses to start a job inside a VPC unless an attached security group opens all ingress ports *to itself*. A rule written with the VPC CIDR as its source is equivalent in effect but does not pass Glue's check. - Attached to: the SageMaker Domain (as in Lab 1) and the Glue `NETWORK` connection

---

##### Regional Service: Amazon S3

**Bucket — `northstar-dev-data-{account-id}`** *(Lab 1 — extended)* - All Lab 1 settings unchanged (versioning, SSE-S3, public access blocked) - **New in Lab 2:** Lifecycle configuration added

Lifecycle rules *(new in Lab 2)*:

| Rule | Scope | Action |
| --- | --- | --- |
| `expire-raw-data` | `raw/` | Delete current versions after 90 days |
| `expire-raw-versions` | `raw/` | Delete noncurrent versions after 30 days |
| `expire-processed-versions` | `processed/` | Delete noncurrent versions after 30 days |
| `expire-feature-versions` | `features/` | Delete noncurrent versions after 60 days |
| `expire-datacapture` | `datacapture/` | Delete current versions after 7 days |

The fifth rule covers a prefix nothing writes to yet. Endpoint data capture (Lab 5) writes one object per capture interval for as long as an endpoint is live, and nothing else ever prunes it; it is the only prefix in the platform that grows in proportion to how long someone forgets to tear down. Retention is set now so it exists before the writer does.

---

##### Global Service: AWS IAM

**Role — `northstar-dev-MLEngineer`** *(Lab 1 — no changes)*

**Role — `northstar-dev-DataEngineer`** *(new in Lab 2)* - Trust: `glue.amazonaws.com`, `lambda.amazonaws.com`, **`sagemaker.amazonaws.com`** (the third is required in Task 3: `CreateFeatureGroup` rejects an execution role that does not trust SageMaker, even though this role is otherwise a pure data-plane identity) - Allowed: - Glue: full access (databases, tables, crawlers, jobs, runs) **plus `glue:GetConnection`** - EC2: network-interface lifecycle (`CreateNetworkInterface`, `DeleteNetworkInterface`, the `Describe*` calls) **plus `ec2:CreateTags` / `ec2:DeleteTags` on `network-interface/*`** - S3: read/write `raw/`, `processed/`, and `features/` prefixes (`features/` is required — the feature engineering job in Task 3 writes Parquet there and the Feature Store offline store is backed by it) - S3: `s3:GetBucketAcl` on the bucket, and `s3:PutObjectAcl` on `features/*` (Feature Store checks the bucket ACL before accepting the offline store target, and writes offline-store objects with an ACL; see the Task 3 traps) - SageMaker Feature Store: `PutRecord`, `CreateFeatureGroup`, `DescribeFeatureGroup` - CloudWatch Logs: write - S3: read-only on `artifacts/glue/` (Glue must fetch its own job scripts) - Denied by omission: cannot write `artifacts/`; cannot run SageMaker training jobs

**Role — `northstar-dev-ModelMonitor`** *(new in Lab 2)* - Trust: `sagemaker.amazonaws.com` - Allowed: - CloudWatch: `PutMetricData`, `GetMetricStatistics`, `PutMetricAlarm`, `DescribeAlarms` - SageMaker: `ListProcessingJobs`, `DescribeProcessingJob` — **read-only visibility into drift runs** - S3: read-only on `artifacts/` prefix - CloudWatch Logs: write - Denied by omission: cannot invoke endpoints; cannot write to S3; cannot modify models; **cannot start a processing job** — that is `ModelMonitorExecution`'s job, not this one

> **This role observes; it does not act.** The distinction matters in Lab 6, where the drift analysis runs under `northstar-dev-ModelMonitorExecution` (which writes reports and pulls containers) while this role only watches. A drift alarm that cannot itself remediate is a design choice, not an oversight.

---

##### Regional Service: Amazon SageMaker

**Domain — `northstar-dev-domain`** *(Lab 1 — subnet changed)* - Subnet: `northstar-dev-private-1` *(changed from public-1; Terraform forces replacement — ~10 min)* - All other settings unchanged

**User Profile — `MLEngineer`** *(Lab 1 — no changes)*

**Feature Group — `northstar-dev-customer-features`** *(new in Lab 2)* - Record identifier: `customer_id` - Event time feature: `event_time` - Online store: enabled (for real-time inference in Labs 3–4) - Offline store: enabled, backed by the `features/offline-store/` prefix in S3

> **Keep the two `features/` writers apart.** The feature engineering job writes its own Parquet to `features/customers/`. The Feature Store offline store manages its own directory tree (`<account>/sagemaker/<region>/offline-store/...`) underneath whatever prefix you give it. Point them at the same prefix and the offline store's layout gets interleaved with your job output, which makes both hard to query. Use `features/customers/` for the job and `features/offline-store/` for Feature Store.

- IAM role: `northstar-dev-DataEngineer` (writes records). In Lab 3 the offline store is queried with Athena from your own machine, under your own credentials, not as `northstar-dev-MLEngineer`. MLEngineer needs nothing new in Lab 2.
- Features — 16 definitions: 2 keys, 13 features, 1 label

| Feature | Type | Meaning |
| --- | --- | --- |
| `customer_id` | String | Record identifier |
| `event_time` | Fractional | Unix epoch seconds — **not** an ISO 8601 string |
| `days_since_last_purchase` | Fractional | Recency at T |
| `customer_tenure_days` | Fractional | T minus first purchase |
| `purchase_frequency_30d` | Fractional | Orders in the 30 days before T |
| `purchase_frequency_90d` | Fractional | Orders in the 90 days before T |
| `purchase_frequency_180d` | Fractional | Orders in the 180 days before T |
| `avg_order_value` | Fractional | Mean order value, all purchases on or before T |
| `total_spend_90d` | Fractional | Spend in the 90 days before T |
| `total_lifetime_value` | Fractional | Sum of order values on or before T |
| `avg_basket_size_6m` | Fractional | Mean items per order, last 180 days |
| `category_diversity_score` | Fractional | Distinct categories ÷ 8 |
| `online_to_store_ratio` | Fractional | 1.0 = pure online, 0.0 = pure in-store |
| `loyalty_tier` | String | Bronze / Silver / Gold / Platinum |
| `churn_risk_score` | Fractional | Rule-based recency heuristic, 0.0–1.0 — **not the label** |
| `churn_label` | **Integral** | 1 if no purchase in the outcome window, else 0 |

> **The temporal split is the point of this feature group.**
>
>
>
> `|<------- observation window -------->|<-- outcome window -->|
> 2025-04-01                       2026-04-01             2026-06-30
>                                       T                  SNAPSHOT`
>
>
>
> Every feature is computed **only** from purchases on or before `T`. `churn_label` is derived **only** from the outcome window: 1 if the customer made no purchase in `(T, SNAPSHOT]`.
>
>
>
> **This is not a train/test split.** It splits each customer's *timeline*, not the set of customers. Every customer contributes exactly one labeled row: features (X) from the observation window, paired with a ground-truth label (y) from the outcome window. That is how churn data has to be labeled: churn is a fact about the future, so the answer can only come from what happened after `T`. Lab 3 splits these ~10,000 labeled rows into training and test sets. *(Earlier versions of this lab called the outcome window the "holdout." In ML "holdout" normally means a test set, which this is not. The starter code still names the DataFrame `holdout`; keep that name.)*
>
>
>
> Features describe the past; the label describes the future. This is the only construction that produces a model worth deploying. Compute recency over the full date range instead and it encodes the answer directly — you get a near-perfect AUC in the lab and a model that collapses the moment it sees real data. This is the single most common way churn models fail in industry, and it is why the split is baked into the lab rather than left as an exercise.
>
>
>
> `churn_risk_score` is retained deliberately and is **not** a substitute for the label. It is a pure recency rule, and Lab 3 requires your trained model to beat it. A model that cannot outperform a three-line heuristic has not earned its deployment.
>
>
>
> **Event time type — read this before you write the feature group.** SageMaker Feature Store accepts an event-time feature as either `String` (ISO 8601) or `Fractional` (Unix epoch seconds). This lab requires **`Fractional`**. The starter `feature_engineer.py` already sends epoch seconds (`float(int(time.time()))`); do not change that line. If the declared type and the value disagree (`String` declared with an epoch value, or `Fractional` declared with an ISO string), every `PutRecord` call is rejected with `ValidationError`, the feature engineering job ends `FAILED`, and the error message names the `event_time` feature. If your job fails at the ingest step, check the feature group's declared type first.
>
>
>
> *(Corrected 2026-10-02. Earlier versions said a mismatch was accepted and silently dropped. Tested against AWS: it is rejected with an explicit error.)*

---

##### Regional Service: AWS Glue

**Catalog Database — `northstar_dev`** *(new in Lab 2)* - Contains tables auto-discovered by the crawler and registered by ETL jobs

**Crawler — `northstar-dev-raw-crawler`** *(new in Lab 2)* - Role: `northstar-dev-DataEngineer` - Target: S3 `raw/customers/` prefix - Output: table `customers` in `northstar_dev` database — the crawler names the table after the S3 prefix (`raw/customers/`) and no `TablePrefix` is set, so it is **`customers`, not `raw_customers`** - Schedule: on-demand (run manually or trigger from ingestion)

**Connection — `northstar-dev-vpc-connection`** *(new in Lab 2)* - Type: `NETWORK` - Subnet: `northstar-dev-private-1`; security group: `northstar-dev-sagemaker-sg` (with the self-referencing rule above) - Attached to both ETL jobs. This is what places Glue workers in the private subnet; without it they run outside your VPC.

**ETL Job — `northstar-dev-transform`** *(new in Lab 2)* - Type: Glue Spark (`glueetl`), Glue 4.0 - Role: `northstar-dev-DataEngineer` - Source: `northstar_dev.customers` (via Glue catalog) - Transforms: type casting, null imputation, deduplication, timestamp normalization - Sink: `processed/customers/` in S3 as Parquet

**ETL Job — `northstar-dev-feature-engineer`** *(new in Lab 2)* - Role: `northstar-dev-DataEngineer` - Source: `processed/customers/` in S3 - Computes: RFM features, loyalty tier, churn risk proxy score - Sink: `features/customers/` in S3 (Parquet) + Feature Store `PutRecord` calls

---

### Connection Map (Arrows for Your Diagram)

Draw this as two layers: infrastructure (VPC/network) and data flow (S3/Glue/Feature Store).

**Infrastructure layer:**

| From | To | Direction | Label |
| --- | --- | --- | --- |
| Internet | Internet Gateway | ↔ | public traffic |
| Public Subnet | Public Route Table | → | associated |
| Public Route Table | Internet Gateway | → | `0.0.0.0/0` |
| NAT Gateway | Public Subnet | — | resides in |
| Private Subnet | Private Route Table | → | associated |
| Private Route Table | NAT Gateway | → | `0.0.0.0/0` |
| NAT Gateway | Internet Gateway | → | outbound only (via public route table) |
| SageMaker Domain | Private Subnet | ↔ | runs in |
| Glue Job Workers | Private Subnet | ↔ | run in |

**Data flow layer:**

| From | To | Direction | Label |
| --- | --- | --- | --- |
| Source data (external) | S3 `raw/customers/` | → | CSV upload |
| Raw Crawler | S3 `raw/customers/` | → | scans schema |
| Raw Crawler | Glue Catalog `customers` | → | registers table |
| Transform Job | Glue Catalog `customers` | → | reads |
| Transform Job | S3 `processed/customers/` | → | writes Parquet |
| Feature Engineer Job | S3 `processed/customers/` | → | reads |
| Feature Engineer Job | S3 `features/customers/` | → | writes Parquet |
| Feature Engineer Job | Feature Store `northstar-dev-customer-features` | → | PutRecord |
| You (Lab 3, Athena from your machine) | Feature Store offline store | → | reads for training |

**IAM access layer:**

| Role | Resource | Access |
| --- | --- | --- |
| DataEngineer | S3 `raw/` + `processed/` + `features/` | read/write |
| DataEngineer | S3 `artifacts/glue/` | read only (job scripts) |
| DataEngineer | Feature Store | write |
| MLEngineer | S3 `features/` + `artifacts/` | read/write |
| ModelMonitor | S3 `artifacts/` | read only |
| ModelMonitor | CloudWatch | write metrics |

---

## Starter Kit (Canvas: Lab 2)

- `northstar-raw-sample.csv` — roughly 163,000 synthetic **transaction** rows across ~11,400 customers, spanning 2025-04-01 to 2026-06-30. Deliberately dirty: null `customer_id` values, duplicate `transaction_id` rows, mixed date formats, missing numeric fields, and stray whitespace — Task 2 is where you clean them. After cleaning, expect ~157,600 rows; ~10,000 customers have enough history in the observation window to carry features.

The date range is not arbitrary. It covers an observation window (to 2026-04-01) and a 90-day outcome window after it, which is what makes the churn label in Task 3 possible. About 21% of customers churn, and roughly a third of those are still buying right up to the cutoff — those are the ones a recency rule will miss.

Schema:

| Column | Type | Notes |
| --- | --- | --- |
| `transaction_id` | string | `TXN-{12 alphanumeric}`. Natural key — dedup on this. |
| `customer_id` | string | `CUST-{8 digits}`. Repeats across rows by design. |
| `purchase_date` | date | ISO 8601, with ~3% injected in `MM/DD/YYYY` to force real parsing |
| `order_value` | float | USD, gross. ~4% null. |
| `num_items` | integer | Line items in the order |
| `payment_method` | string | `credit_card`, `debit_card`, `gift_card`, `cash` |
| `channel` | string | `store` or `online` |
| `store_id` | string | `STORE-{3 digits}`, or `ONLINE` |
| `product_category` | string | Primary category for the order |

Note there is no `loyalty_tier` column: tier is *derived* from lifetime value at T in Task 3. A tier supplied by a source system is usually computed as of whenever that system last ran, which can be after T, and would carry outcome-window information into the features. - `glue-scripts/transform.py` — starter Glue ETL script with the schema defined and read/write wired up; the three transform functions are stubbed out - `glue-scripts/feature_engineer.py` — starter feature engineering script with the Feature Store client wired up; the five feature functions are stubbed out - `scripts/verify-lab2.sh` — automated rubric verification script. Run it from the repo root before you tear down and commit its output as `docs/lab2-verify-output.txt`. The TA has no access to your AWS account, so that file is the evidence for most of the Task 1–3 rubric. - `Makefile` — replaces your Lab 1 Makefile. `local-validate` now takes `LOCAL_OUT=` so Lab 2's LocalStack evidence goes to `docs/lab2-localstack-output.txt` instead of overwriting your Lab 1 file, reads the bucket name from `terraform output`, and confirms no NAT Gateway was created locally. Copy it over the old one. - `scripts/teardown-lab2.sh` — full teardown. `terraform destroy` alone does not finish the job in this lab; see the Teardown section.

---

## Getting Your Repository

Keep working in the repository you created for Lab 1, `cs401r-<your-netid>`. This lab extends the platform you already built; **do not start a new repository.**

Lab 2 ships **new** starter files. Download the Lab 2 starter kit from Canvas (or copy them from [https://github.com/byu-cs401r4-f26/cs401r-lab2-template](https://github.com/byu-cs401r4-f26/cs401r-lab2-template)) into your existing repository before you begin. Add to what you have — do not replace it.

## Submitting Lab 2

#### What the Grader Expects to Find

Everything below is evidence the grader reads under `docs/`. Commit all of it before you tag:

| File | Task | Produced by / Description |
| --- | --- | --- |
| `docs/lab2-extend-output.txt` | 1, 2, 3 & 5 | Every `terraform apply` in this lab, appended in order with `tee -a` (Tasks 1–3) |
| `docs/lab2-localstack-output.txt` | 1 | Terminal output of `make local-validate LOCAL_OUT=docs/lab2-localstack-output.txt` |
| `docs/lab2-verify-output.txt` | 1, 2, 3 | `bash scripts/verify-lab2.sh 2>&1 \\| tee docs/lab2-verify-output.txt`, run after both Glue jobs succeed and **before** teardown |
| `docs/lab2-data-contract.md` | 4 | Data contract for `processed/customers/` (schema, SLA, quality guarantees, versioning) |
| `docs/lab2-data-lineage.png` | 4 | Drawn data lineage diagram with formats and IAM write roles labeled |
| `docs/lab2-destroy-output.txt` | Teardown | `bash scripts/teardown-lab2.sh` clean teardown evidence. Committed **after** you tag, on your default branch (see Teardown) |

> **Note on Screenshots:** Unlike Lab 1, **no AWS console screenshots are required for Lab 2.** The TA has no access to your AWS account, and by grading time your infrastructure is torn down. Graders verify your work from your committed code, your apply and verification logs (`docs/lab2-verify-output.txt` above all), the data contract, and your lineage diagram. The only image file in this lab is `docs/lab2-data-lineage.png`, which is an architecture diagram you draw (e.g., via draw.io or Cloudcraft), not a console screenshot. You do not need to take screenshots of the Glue console, NAT Gateway, or Feature Store before teardown.

#### Tag and Submit

When you are ready to submit, tag the commit you want graded and push the tag:

```
git tag lab2-submit
git push origin lab2-submit
```

Then submit **your repository URL** in Canvas. You do not submit the tag name — it is always `lab2-submit` for this lab, and the TA looks for it.

The TA grades `git checkout lab2-submit`, so anything you push afterward while starting the next lab does not change this lab's grade. **If you forget the tag, you are graded at your last commit before the Canvas deadline** — which, if you have already started the next lab, may not be the work you meant to submit. Tag it.

**One file is committed after the tag:** `docs/lab2-destroy-output.txt`. You tear down after you submit, so push that file to `main` and leave the tag where it is. The TA checks it on `main` (see Teardown).

## > **Public repositories, deliberately.** You may read how other students approached the problem. Copying their work is plagiarism and is handled under the BYU Honor Code — commit your own. And because these are public: never commit credentials. No `.env`, no `terraform.tfvars`, no AWS keys. Committed secrets are an automatic zero. The provided `.gitignore` already excludes them; do not remove those lines.

## Tasks

All infrastructure changes in this lab are made through Terraform. Do not use the console to create or modify resources (exception: the console is fine for verifying that resources exist as expected).

---

### Task 1 — Extend Platform Infrastructure (25 points)

Modify your existing Terraform modules and apply the changes to a real AWS account.

**Changes to `modules/vpc/`:** - Add `aws_subnet` (private, `10.0.1.0/24`, `us-east-1a`, no public IP) - Add `aws_eip` for the NAT Gateway - Add `aws_nat_gateway` in the public subnet, dependent on the EIP - Add `aws_route_table` for the private subnet with `0.0.0.0/0 → aws_nat_gateway` - Add `aws_route_table_association` for the private subnet - Add variable `enable_nat_gateway` (bool, default true) — set to false in `environments/local/` - Add a self-referencing ingress rule (all ports, protocol `-1`, `self = true`) to the existing security group — Glue requires it in Task 2 - Update output to expose `private_subnet_id`

**Changes to `modules/storage/`:** - Add `aws_s3_bucket_lifecycle_configuration` with the five rules from the Architecture Reference - Add variable `enable_lifecycle_rules` (bool, default true) — set to false in `environments/local/`

**Changes to `modules/iam/`:** - Add `northstar-dev-DataEngineer` role, policy, and attachment - Add `northstar-dev-ModelMonitor` role, policy, and attachment

**Changes to `modules/sagemaker/`:** - Update `subnet_ids` in `aws_sagemaker_domain` to use the new private subnet - Set `app_network_access_type = "VpcOnly"` so Studio egress routes through the NAT Gateway instead of straight out the Internet Gateway - If you still have Lab 1 running, both of these force **replacement** — Terraform destroys and recreates the domain (~10 min). That is expected, not a mistake; run `terraform plan` first and confirm the replacement is the only destructive change. If you destroyed Lab 1 after submitting (as required), the domain is simply created fresh, which takes about the same time.

> **ASCII only in AWS-facing description fields.** EC2 rejects any non-ASCII character in a security group's `description` with `InvalidParameterValue: Character sets beyond ASCII are not supported`. If you pasted an em dash (—), a curly quote, or an arrow into a `description`, `terraform apply` fails at `CreateSecurityGroup` — but `terraform validate` and LocalStack both accept it, so you will not catch this until you hit real AWS. Use plain hyphens in any `description` argument that Terraform sends to an AWS API. (Confusingly, IAM *does* accept non-ASCII in policy descriptions — so the failure looks arbitrary.)

**Changes to `environments/dev/variables.tf`:** - Add `private_subnet_cidr` (string, `"10.0.1.0/24"`)

**Apply the changes:**

```
cd infrastructure/environments/dev
terraform plan    # review carefully — you should see the SageMaker domain marked for replacement
terraform apply 2>&1 | tee ../../../docs/lab2-extend-output.txt   # creates the file
```

Tasks 2 and 3 each apply again. Those runs use `tee -a` to **append** to this file. Overwriting it loses the record of the SageMaker domain change, which Task 5 grades.

**LocalStack validation (update local environment):**

```
# environments/local/main.tf additions:
# - vpc module: enable_nat_gateway = false
# - storage module: enable_lifecycle_rules = false
# - iam module: now creates all 3 roles
make local-validate LOCAL_OUT=docs/lab2-localstack-output.txt
```

**Rubric:**

| Item | Points | Pass Criteria |
| --- | --- | --- |
| Private subnet + NAT Gateway created; SageMaker Domain moved to private subnet | 10 | `docs/lab2-verify-output.txt`: private subnet exists, NAT gateway available, domain InService in the private subnet with `VpcOnly` |
| All 3 IAM roles exist with correct trust and policies | 8 | Verify output shows all 3 roles; `iam:SimulatePrincipalPolicy` confirms DataEngineer cannot **write** `artifacts/` (read on `artifacts/glue/` is expected — Glue fetches job scripts there), ModelMonitor cannot write S3 |
| S3 lifecycle rules applied | 4 | Verify output shows 5 lifecycle rules (`modules/storage/` defines `expire-raw-data`, `expire-raw-versions`, `expire-processed-versions`, `expire-feature-versions`, `expire-datacapture`) |
| LocalStack validation updated and passing | 3 | `docs/lab2-localstack-output.txt` shows 3 IAM roles; VPC exists (NAT skipped) |

---

### Task 2 — Data Ingestion Pipeline (25 points)

Build a new `modules/glue/` module and create the Glue catalog, crawler, and transform ETL job.

**New `modules/glue/` resources:** - `aws_glue_catalog_database` — `northstar_dev` - `aws_glue_crawler` — `northstar-dev-raw-crawler`, targets `raw/customers/` prefix, role = DataEngineer ARN - `aws_glue_job` — `northstar-dev-transform`, Glue version 4.0, Python 3, script from S3 (upload `glue-scripts/transform.py` to `artifacts/glue/` prefix) - `aws_s3_object` — upload the transform script as part of `terraform apply` - `aws_glue_connection` — `northstar-dev-vpc-connection`, type `NETWORK`, in the private subnet with the security group from Task 1; attach it to the job with `connections = [...]`

> **Running Glue inside the VPC — three failures you will hit in this order.** Because Lab 2 places Glue workers in the private subnet, the job needs a Glue `NETWORK` connection, and that path has three separate prerequisites. Each one fails at *provisioning* time with a message that does not obviously name the fix, and each only appears after you have cleared the previous one:
>
>
>
> 1. `DataCatalog Connection issue ... not authorized to perform: glue:GetConnection` — the role needs `glue:GetConnection`. Glue resolves the connection before your script ever runs, so this is not a script bug.
> 2. `At least one security group must open all ingress ports.` — Glue requires a **self-referencing** all-ports ingress rule on an attached security group. An equivalent rule written as the VPC CIDR does *not* satisfy the check; the source must literally be the security group itself (`self = true` in Terraform).
> 3. `The specified role doesn't have a permission to create a tag for your elastic network interface.` — Glue tags every ENI it creates, so the role needs `ec2:CreateTags` and `ec2:DeleteTags` on `arn:aws:ec2:*:*:network-interface/*`.
>
>
>
> Also note that IAM changes take a few seconds to propagate. If you fix a policy and immediately re-run the job, you can see the *old* error once more — wait ~30 seconds before concluding your fix did not work.

**Complete the transform script** `glue-scripts/transform.py`:

The starter script defines the schema. You must implement the three transform functions:

```
def cast_types(df):
    """Cast all columns to the types defined in SCHEMA. Drop rows where customer_id is null."""
    # Your implementation here

def impute_nulls(df):
    """
    Numeric columns: impute with column median.
    String columns: impute with 'unknown'.
    """
    # Your implementation here

def deduplicate(df):
    """
    Drop duplicate transactions: keep one row per transaction_id. Duplicates
    are the same transaction landing twice from an ingestion retry. Break ties
    deterministically (e.g. purchase_date descending, then order_value
    descending) so repeated runs produce identical output.

    Deduplicate on transaction_id, NOT on customer_id. A customer is expected
    to have many transactions -- that purchase history is exactly what the
    feature engineering job in Task 3 aggregates over. Collapsing to one row
    per customer here would make total_lifetime_value and purchase_frequency_30d
    impossible to compute downstream.
    """
    # Your implementation here
```

> **Why the grain matters.** `raw/customers/` holds *transaction-level* rows: one row per purchase, many rows per customer. The transform job preserves that grain and only removes genuine duplicates — the same `transaction_id` landing twice from an ingestion retry. Task 3 is where the data collapses to one row per customer, by aggregation. Getting this backwards is the single most common way to fail Task 3 after passing Task 2.

**Apply** from `infrastructure/environments/dev`, appending to the Task 1 log:

```
terraform apply 2>&1 | tee -a ../../../docs/lab2-extend-output.txt
```

**Upload sample data and run the pipeline:**

```
# Upload sample data
aws s3 cp northstar-raw-sample.csv \
  s3://northstar-dev-data-$(aws sts get-caller-identity --query Account --output text)/raw/customers/northstar-raw-sample.csv

# Run the crawler. start-crawler returns immediately; poll until the state is READY again
aws glue start-crawler --name northstar-dev-raw-crawler
until [ "$(aws glue get-crawler --name northstar-dev-raw-crawler --query 'Crawler.State' --output text)" = "READY" ]; do sleep 15; done

# Verify the table was created
aws glue get-table --database-name northstar_dev --name customers

# Run the transform job
aws glue start-job-run --job-name northstar-dev-transform
aws glue get-job-run --job-name northstar-dev-transform \
  --run-id $(aws glue get-job-runs --job-name northstar-dev-transform \
    --query 'JobRuns[0].Id' --output text)

# Verify processed output
aws s3 ls s3://northstar-dev-data-ACCOUNT_ID/processed/customers/ --recursive
```

**Rubric:**

| Item | Points | Pass Criteria |
| --- | --- | --- |
| Glue catalog database and `customers` table exist after crawler run | 6 | `docs/lab2-verify-output.txt` shows the `northstar_dev` database and a crawler-registered table |
| Transform script correctly casts types, imputes nulls, deduplicates | 12 | Verify output, data-quality section: 0 null `customer_id`, 0 duplicate `transaction_id`, all `purchase_date` parsed, transaction-level grain preserved (many rows per customer); TA reads `glue-scripts/transform.py` |
| `modules/glue/` Terraform resources applied cleanly | 4 | Module present in repo; `docs/lab2-extend-output.txt` shows the crawler, connection, and job created with 0 errors |
| Transform job completes with SUCCEEDED status | 3 | Verify output shows `job northstar-dev-transform SUCCEEDED` |

---

### Task 3 — Feature Engineering and Labelling (20 points)

Add the feature engineering ETL job to `modules/glue/` and a new `modules/feature_store/` module.

**Add to `modules/glue/`:** - `aws_glue_job` — `northstar-dev-feature-engineer`, reads `processed/customers/`, writes to `features/customers/` and calls Feature Store

**New `modules/feature_store/`:** - `aws_sagemaker_feature_group` — `northstar-dev-customer-features` - Record identifier: `customer_id` - Event time: `event_time` - Online store: enabled - Offline store: S3 URI `s3://northstar-dev-data-{account-id}/features/offline-store/` - Execution role: DataEngineer role ARN - Feature definitions: all 16 from the Architecture Reference table (2 keys, 13 features, 1 label)

**Apply** from `infrastructure/environments/dev`, appending to the Task 1 log:

```
terraform apply 2>&1 | tee -a ../../../docs/lab2-extend-output.txt
```

> **Two Feature Store permission traps, both with misleading error messages.**
>
>
>
> 1. `ValidationException: The execution role ARN is invalid` — this does *not* mean the ARN is wrong. It means the role's trust policy is missing `sagemaker.amazonaws.com`. Add it to DataEngineer's trusted services.
> 2. `ValidationException: Invalid S3Uri provided` — the URI is fine. The role is missing `s3:GetBucketAcl` on the bucket. Feature Store checks the bucket ACL before accepting it as an offline store target. You also need `s3:PutObjectAcl` on `features/*`, because the offline store writes objects with an ACL and plain `PutObject` is not enough.
>
>
>
> Both fail at `terraform apply`, before any data moves, so a green `terraform validate` tells you nothing here.

**Anchor your time windows to `FEATURE_CUTOFF`, not to `today()` and not to the data's maximum date.** Compute recency and every frequency and spend window backwards from `FEATURE_CUTOFF` (T = 2026-04-01), the fixed constant in the starter script. Two tempting alternatives are both wrong:

- **`today()` / `current_date()`:** your features change every time the job runs, and any model Lab 3 trains on them stops being reproducible.
- **`max(purchase_date)` over the whole dataset:** that date is 2026-06-30, the end of the outcome window (`SNAPSHOT`). Measuring from it leaks the outcome window into the features: every churner has recency of at least 90 days and every active customer has less, so recency encodes the label exactly. This is the leak described in the temporal-split note above.

*(Corrected 2026-09-23. Earlier versions of this paragraph said to use the maximum `purchase_date` in the dataset. That was wrong. Use `FEATURE_CUTOFF`.)*

**Complete the feature engineering script** `glue-scripts/feature_engineer.py`:

The starter script reads from `processed/customers/`. Implement these feature computations:

```
def split_windows(df):
    """
    Split processed transactions into:
      history : purchase_date <= FEATURE_CUTOFF (T)
      holdout : FEATURE_CUTOFF < purchase_date <= SNAPSHOT
    Every feature comes from history. The label comes from holdout.
    """
    # Your implementation here

def compute_rfm_features(history):
    """
    One row per customer_id, all windows measured backwards from T:
      days_since_last_purchase, customer_tenure_days,
      purchase_frequency_30d / 90d / 180d,
      avg_order_value, total_spend_90d, total_lifetime_value,
      avg_basket_size_6m, category_diversity_score, online_to_store_ratio
    """
    # Your implementation here

def assign_loyalty_tier(df):
    """
    Bronze: total_lifetime_value < 500
    Silver: 500 <= total_lifetime_value < 2000
    Gold: 2000 <= total_lifetime_value < 5000
    Platinum: total_lifetime_value >= 5000
    """
    # Your implementation here

def compute_churn_proxy(df):
    """
    churn_risk_score: rule-based recency heuristic, NOT the label.
    High risk (0.7-1.0): days_since_last_purchase > 60
                         (which already implies purchase_frequency_30d == 0)
    Medium risk (0.4-0.7): days_since_last_purchase > 30
    Low risk (0.0-0.4): otherwise
    Scale within each band rather than emitting three constants.
    """
    # Your implementation here

def attach_churn_label(features, holdout):
    """
    churn_label = 1 if the customer made NO purchase in the holdout window,
    else 0. Derived exclusively from data after T.
    """
    # Your implementation here
```

In the starter code, `history` is the observation window and `holdout` is the outcome window (T, SNAPSHOT]. The name `holdout` is kept so your code keeps working; it is **not** a test set.

**Run and verify:**

```
# Run feature engineering job
aws glue start-job-run --job-name northstar-dev-feature-engineer

# Verify features written to S3
aws s3 ls s3://northstar-dev-data-ACCOUNT_ID/features/customers/ --recursive

# Verify a record landed in the online store (immediate; the offline store lags ~15 min)
aws sagemaker-featurestore-runtime get-record \
  --feature-group-name northstar-dev-customer-features \
  --record-identifier-value-as-string CUST-10000776

# Then capture the full rubric check before teardown
bash scripts/verify-lab2.sh 2>&1 | tee docs/lab2-verify-output.txt
```

**Rubric:**

| Item | Points | Pass Criteria |
| --- | --- | --- |
| All 5 feature functions implemented correctly | 10 | Verify output: no null feature values, all 14 columns present, all 4 tiers present, `churn_risk_score` in [0, 1] and non-degenerate, one row per customer |
| Temporal split correct — features from the observation window, label from the outcome window | 4 | Verify output: `churn_label` rate between 15% and 30%, and label not trivially separable by recency; TA reads `glue-scripts/feature_engineer.py` to confirm every window is anchored to `FEATURE_CUTOFF` |
| Feature Group created via Terraform with all 16 definitions | 3 | Verify output: feature group Created, 16 definitions, `event_time` Fractional, `churn_label` Integral, online store enabled, `GetRecord` returns a record |
| Feature engineering job completes with SUCCEEDED status | 3 | Verify output shows `job northstar-dev-feature-engineer SUCCEEDED` |

---

### Task 4 — Data Contract and Lineage (15 points)

**Data Contract** — write `docs/lab2-data-contract.md`:

A data contract is a formal agreement between the team that produces a dataset and the team that consumes it. It specifies schema, quality guarantees, and SLAs. Write one for the `processed/customers/` dataset:

```
## Data Contract: processed/customers

### Producer
Team / process: Glue ETL job `northstar-dev-transform`

### Consumers
- Feature engineering job `northstar-dev-feature-engineer`
- (Future) Direct model training in Lab 3

### Grain
One row per transaction. A customer appears on many rows.

### Schema
| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
[fill in all columns from the processed dataset]

### Quality Guarantees
- `customer_id` is never null
- No duplicate `transaction_id` rows (a `customer_id` repeating across rows is expected, not a defect)
- All numeric columns are within expected ranges (specify bounds)
- `purchase_date` is a valid ISO 8601 date

### SLA
- Data is available in `processed/customers/` within 2 hours of landing in `raw/customers/`

### Versioning
- Schema changes require a new S3 prefix (e.g., `processed/customers/v2/`)
- Breaking changes require consumer notification 5 business days in advance
```

**Data Lineage Diagram** — create `docs/lab2-data-lineage.png`:

Draw a lineage diagram showing the full flow from source to Feature Store. Include: source system → S3 `raw/` → Glue Crawler → Catalog → Transform Job → S3 `processed/` → Feature Engineer Job → S3 `features/` + Feature Store. Label each arrow with the data format (CSV, Parquet, Feature Store records) and the IAM role performing each write.

**Rubric:**

| Item | Points | Pass Criteria |
| --- | --- | --- |
| Data contract covers schema, quality guarantees, SLA, and versioning policy | 8 | All four sections present; quality guarantees include at least 3 specific, measurable assertions |
| Lineage diagram is accurate and complete | 7 | All nodes in the data flow present; formats labeled on each edge; IAM roles labeled on each write edge |

---

### Task 5 — Repository Quality (15 points)

| Item | Points | Pass Criteria |
| --- | --- | --- |
| `modules/glue/` and `modules/feature_store/` present with correct resources | 4 | All resources in correct modules; no cross-module duplication |
| All Glue and Feature Store resource names parameterized | 3 | No hardcoded strings in `.tf` files for new modules |
| `terraform fmt` and `terraform validate` pass on all modules | 3 | Clean output from both commands |
| `docs/lab2-extend-output.txt` shows a successful apply | 3 | File ends with `Apply complete!` and contains `aws_sagemaker_domain`. Either outcome is acceptable: **replacement** if you still had Lab 1 running, **creation** if you destroyed Lab 1 as instructed. Both are correct. |
| README updated to describe Lab 2 additions | 2 | README explains new modules, how to run the data pipeline end-to-end |

---

### Teardown (required — read before you submit)

> **Before you tear down:** Run `bash scripts/verify-lab2.sh 2>&1 | tee docs/lab2-verify-output.txt` while everything is still deployed. Then confirm that your five pre-teardown artifacts (`docs/lab2-extend-output.txt`, `docs/lab2-localstack-output.txt`, `docs/lab2-verify-output.txt`, `docs/lab2-data-contract.md`, and `docs/lab2-data-lineage.png`) are committed, and tag and push `lab2-submit`. The verify output cannot be regenerated after teardown, and the TA has no other way to see your running infrastructure. **No AWS console screenshots are required for Lab 2.**

**The NAT Gateway bills roughly $0.045/hour (~$32/month) whether or not you send a byte through it.** It is the single largest cost in this lab and it does not stop when you close the console. Leaving it running for three weeks will consume a meaningful share of your $200 in Free Tier credits — credits you still need for Labs 3 through 7.

After you have committed your verification output, tagged, and submitted:

```
bash scripts/teardown-lab2.sh
```

> **`terraform destroy` alone will not tear this lab down.** Six resources are created outside Terraform's state and survive it. Three of them make `destroy` hang for 10+ minutes and then fail; one of them keeps billing after you believe you are finished.
>
>
>
> | # | Orphan | Consequence |
> | --- | --- | --- |
> | 1 | Glue ENIs left in the private subnet after job runs | Subnet and security group deletion hang |
> | 2 | **SageMaker Studio EFS filesystem** | Terraform never sees it — **it keeps billing**, and its mount target blocks the subnet |
> | 3 | Two auto-created SageMaker NFS security groups | VPC deletion hangs |
> | 4 | S3 object versions | `BucketNotEmpty` — a versioned bucket will not delete while non-empty |
> | 5 | `sagemaker_featurestore` Glue database | Left behind by the offline store |
> | 6 | SageMaker **lineage contexts and artifacts** | Survive `DeleteFeatureGroup`; refuse to delete until their associations are unwound first |
>
>
>
> `scripts/teardown-lab2.sh` handles all six in the correct order and then verifies that no billable resource remains. If you insist on running `terraform destroy` by hand, expect to clean up items 1–6 manually and to wait through two failed attempts first.
>
>
>
> **Do not trust the AWS console's Resource Explorer to confirm teardown.** Its index lags by minutes to hours and will keep listing resources that are already gone — and it may equally miss ones that remain. Verify with `aws` CLI calls against the live API, which is what `scripts/teardown-lab2.sh` does in its final step.
>
>
>
> Item 4 is also why `modules/storage/` sets `force_destroy` in the dev environment. That is the right call for synthetic, regenerable lab data and **the wrong call for a bucket holding real customer records** — it deletes every version with no confirmation.

Commit `docs/lab2-destroy-output.txt` and push it to your **default branch** (`main`). Do **not** move the `lab2-submit` tag: it must still point at the commit you submitted before the deadline. The TA grades your lab at the tag and checks the destroy output on `main`, separately. Lab 3 begins by re-running `terraform apply`, which rebuilds everything from your committed code in about 15 minutes — that rebuild is itself the proof that your infrastructure is genuinely reproducible.

| Item | Points | Pass Criteria |
| --- | --- | --- |
| Infrastructure destroyed after submission | — | `docs/lab2-destroy-output.txt` on `main` (not at the tag) ends with `Destroy complete!`. The script's final check must also report "No billable Lab 2 resources remain" in your terminal; if it does not, fix and re-run before you commit. **Gate, not points:** if this evidence is missing, Task 1 is capped at half credit until you produce it. |
