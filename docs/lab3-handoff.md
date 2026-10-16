# Lab 3 Handoff — CS 401R NorthStar

Snapshot as of commit **`ba6ae22`** (main, pushed). Repo: `~/projects/byu-cs401r-tychart`
(branch `main`, remote `github.com:tychart/byu-cs401r-tychart.git`).

**Tracks: A (required) + C (chosen). Track B is NOT attempted.**
**Current position: Phase 1 complete (2026-10-16) — the platform is rebuilt and
the Lab 1-2 data is recomputed once. Phase 2 is the next action.**
Phase 1 artifacts (`docs/lab3-rebuild-output.txt`, `docs/lab2-verify-output.txt`,
`docs/lab3-pause-output.txt`) and two small infra/doc edits are **uncommitted**.

---

## 0. Read these first, in this order

1. **`docs/lab3-plan.md`** — the plan of record. Phases, cost model, evidence map, known traps. Everything below is a summary of it; this file is not a replacement.
2. **`README.md`** — the top block has the AWS login command; the "Lab 3 — train, evaluate, and where artifacts land" section has the Track A and Track C commands.
3. **`docs/lab3-model-design.md`** — the track declaration (already written) plus structured notes for Phase 7.
4. **`docs/lab3-handoff.md`** — this file.

Also useful: the agent's long-term memory has a "Lab 3 Track C — model + key storage" section and a "Lab 3 decisions" section. Search it with `memory_search "Lab 3"` if a memory tool is available.

---

## 1. Where things stand

| Phase | Status |
| --- | --- |
| 0 — Prep | ✅ **DONE** |
| 1 — Rebuild the Lab 1-2 stack + recompute the data **once** | ✅ **DONE** (2026-10-16) |
| 2 — Create the SageMaker MLflow **App** | ⬜ **NEXT** |
| 3 — Implement Track A (4 TODO areas in `churn_training_skeleton.py`) | ⬜ |
| 4 — Graded training run + `docs/lab3-evaluation-report.md` | ⬜ |
| 5 — Track C Terraform (3 `TODO (student)` items) + deploy | ⬜ |
| 6 — Track C evaluation, policy tests, failure analysis | ⬜ |
| 7 — Design doc prose + `notebooks/lab3-demo.ipynb` | ⬜ |
| 8 — Collect evidence, teardown, tag `lab3-submit` | ⬜ |

Verified in Phase 0, all against the live account:

- `aws sts get-caller-identity` → account `345594594463`, user `mgt-admin`
- AWS CLI 2.36.49, Terraform 1.16.5, uv 0.11.9; `uv sync` clean (184 pkgs)
- `docs/bedrock-access-verification.txt` present, both checks PASS (Task 4 item satisfied)
- `infrastructure/environments/dev`: initialized, **0 managed resources**, plan = **39 to add, 0 to change, 0 to destroy**
- `infrastructure/environments/agent`: plan = **15 to add, 0 change, 0 destroy**, 0 errors, model block points at `deepseek-flash`
- `docs/lab3-model-design.md` written with the track declaration
- No secrets in the repo; secret scan clean

**AWS state after Phase 1 (paused, not empty):** the 39-resource Lab 1-2 stack is
applied and then **paused** — the NAT Gateway and its EIP are gone, and the VPC,
S3 bucket, Glue catalog/jobs, Feature Store and IAM roles are live. The S3 bucket
holds `raw/`, `processed/` and `features/` (job output *and* the offline store).
The `agent/` (AgentCore) stack is **not** applied. Idle cost is storage cents.
While paused the private subnet has **no internet**: run `bash scripts/resume-lab3.sh`
before any Glue job or Studio app.

---

## 2. Environment facts a fresh session must know

These cost real time if you don't know them.

**Authentication.** `AWS_PROFILE=tf` is exported. The `tf` profile delegates to the
`[default]` login session via `credential_process`. To re-authenticate, run:

```bash
aws login --profile default      # NOT bare `aws login`
aws sts get-caller-identity      # expect mgt-admin / 345594594463
```

A bare `aws login` fails with *"Profile 'tf' is already configured with Credential
Process credentials"*. Only `[default]` ever needs refreshing. Region is `us-east-1`.

**Python.** Use the repo's uv environment; never bare `python`:

```bash
uv run python <script>       # Python 3.12, xgboost 3.4.1, sagemaker 2.257.7,
                             # mlflow 3.17.1, boto3 1.43.114, pandas 3.0.6
```

`import agent.lambda.handler` is a **SyntaxError** — `lambda` is a reserved word, not
a broken import. Lambda zips `handler.py` to the archive root, which is correct. Load
it by path with `importlib.util.spec_from_file_location` if you need it in a test.

**Terraform roots — do not mix them.**

| Root | Provider | State key | Purpose |
| --- | --- | --- | --- |
| `infrastructure/environments/dev` | `aws ~> 5.0` | `dev/terraform.tfstate` | Labs 1-2: VPC, S3, IAM, Glue, Feature Store, SageMaker |
| `infrastructure/environments/agent` | `aws 6.67.0` (exact) | `agent/terraform.tfstate` | Lab 3 Track C: AgentCore |
| `infrastructure/environments/local` | `aws ~> 5.0` | local | LocalStack only |

AgentCore needs provider 6.x, which is why `agent/` is a separate root. **Never add
AgentCore resources to `dev/`.**

**The LiteLLM API key** lives in the gitignored
`infrastructure/environments/agent/terraform.tfvars` and is already set. It is fed to
a Terraform **write-only** argument (`api_key_wo`), so it is sent to AWS and never
persisted to state.

> **Constraint that will bite you if you don't know it:** the provider requires that
> key on **every** terraform operation in `agent/`, including `terraform destroy`.
> Without it you get `No attribute specified when one (and only one) of
> [api_key,api_key_secret_config,api_key_wo] is required`. Because it is in
> `terraform.tfvars`, this is already automatic — just don't delete that file.
> If it is ever lost: `aws bedrock-agentcore-control delete-api-key-credential-provider
> --name northstar-litellm` then `terraform state rm
> aws_bedrockagentcore_api_key_credential_provider.litellm`.

**Cost-control scripts** (always pause between work sessions):

| Command | Effect |
| --- | --- |
| `bash scripts/pause-lab3.sh` | NAT Gateway off. Keeps S3 + Feature Store + Glue catalog + IAM. ~$0.01/month idle |
| `bash scripts/resume-lab3.sh` | One `terraform apply`; restores either pause |
| `bash scripts/pause-lab3-deep.sh` | Real `terraform destroy -target=module.vpc/glue/sagemaker`; keeps S3 + Feature Store + IAM. Guarded: it plans first and **aborts** if a keep module appears |
| `bash scripts/teardown-lab2.sh` | Full destroy **including S3**. Only at the very end |

Cost facts: **NAT Gateway + its public IPv4 ≈ $1.20/day is ~99% of idle cost.**
Everything else is free at rest or cents. Never create an MLflow **Tracking Server**
($0.60/hr) — the free, serverless **App** is the one to use.

---

## 3. Phase 1 — ✅ DONE (2026-10-16)

Goal: rebuild the Lab 1-2 stack and recompute the data **once**. This is the only
recompute in the lab. ~20-30 minutes, ~$0.10-0.20. Run from the repo root.

**Outcome.** `terraform apply` → **39 added, 0 changed, 0 destroyed**. Crawler,
transform job and feature-engineer job all `SUCCEEDED`. `verify-lab2.sh` →
**47 passed, 0 failed** (`docs/lab2-verify-output.txt`). `features/customers/` and
the Feature Store offline store each hold **9,999 rows / 9,999 unique customers,
22.0% churn** (IDs `CUST-10000000`..`CUST-10009999`), and the exact Track A Athena
dedup query returns the same 9,999/9,999/2,200. Stack then paused:
NAT 0, EIP 0, `terraform plan` = No changes (`docs/lab3-pause-output.txt`).

**The commands below are kept as the record of what was run.**

```bash
# 1. Deploy the platform
terraform -chdir=infrastructure/environments/dev apply \
  2>&1 | tee docs/lab3-rebuild-output.txt
#    Expect 39 to add. The SageMaker domain is the slow part (~5-10 min).

# 2. Upload the raw data
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="northstar-dev-data-${ACCOUNT}"
aws s3 cp northstar-raw-sample.csv "s3://${BUCKET}/raw/customers/northstar-raw-sample.csv"

# 3. Crawl raw/ and register the table
aws glue start-crawler --name northstar-dev-raw-crawler
aws glue get-crawler --name northstar-dev-raw-crawler   # poll until READY + SUCCEEDED

# 4. Transform: raw -> processed
aws glue start-job-run --job-name northstar-dev-transform
aws glue get-job-runs --job-name northstar-dev-transform --max-items 1   # poll for SUCCEEDED

# 5. Engineer features + write the Feature Store
aws glue start-job-run --job-name northstar-dev-feature-engineer
aws glue get-job-runs --job-name northstar-dev-feature-engineer --max-items 1

# 6. Verify (output is graded evidence)
bash scripts/verify-lab2.sh 2>&1 | tee docs/lab2-verify-output.txt

# 7. Confirm the feature group is queryable
aws sagemaker describe-feature-group \
  --feature-group-name northstar-dev-customer-features

# 8. PAUSE IMMEDIATELY -- the data is now safe and free to keep
bash scripts/pause-lab3.sh
```

**Acceptance for Phase 1:** `features/customers/` holds ~9,999 customer rows, the
Feature Store offline store is populated, `docs/lab2-verify-output.txt` shows the
checks passing, and `pause-lab3.sh` reports the NAT gone with the S3 bucket still
present.

If a Glue job is still running when you start another, wait — the jobs are
sequential (transform before feature-engineering).

Note the pipeline is **idempotent but append-only**: the offline store writes a second
record per customer if you re-run the feature job. That is exactly why the Track A
training script deduplicates with `ROW_NUMBER()` — see plan §Phase 3a.

---

## 4. Hard rules

1. **Never commit credentials.** No `.env`, no `terraform.tfvars`, no keys. The
   gitignore already covers these; do not weaken it. `bash scripts/check-secrets.sh`
   should print CLEAN.
2. **Pause when you stop working.** `bash scripts/pause-lab3.sh`. The NAT is $1.20/day.
3. **Do not create an MLflow Tracking Server.** Use `create-mlflow-app` only.
4. **Do not put `credential_process` on `[default]`** and do not put a `login_session`
   on `[tf]` — the two conflict.
5. **Stay non-Anthropic** for the agent model unless someone changes that decision:
   default is `deepseek-flash` via LiteLLM, fallback is `openai.gpt-oss-20b-1:0`
   (Apache-2.0) on Bedrock, switched with `-var model_backend=bedrock`.
6. **Don't `terraform destroy` the dev root** while you still want the data. Use the
   pause scripts. Full teardown incl. S3 is `scripts/teardown-lab2.sh`, at the end.
7. **The TA only sees the repo.** Anything living only in AWS must be exported by
   `scripts/collect-lab3-evidence.sh` **before** teardown.

---

## 5. What comes after Phase 1 (short version)

- **Phase 2** — create the MLflow **App** (free) with the `MLEngineer` role and an
  `artifacts/mlflow/` store. Poll until `Status: Created` (~5 min). Save the ARN.
- **Phase 3** — complete Track A's four TODO areas in `churn_training_skeleton.py`:
  the Athena Feature Store query (print the `Athena QueryExecutionId:` line — the
  evidence script greps for it), imputation docs, slice evaluation, MLflow logging,
  and Model Registry registration as `PendingManualApproval`.
  **The Model Registry group `northstar-churn-models` is created nowhere** — neither
  the kit nor Terraform makes it, and `create_model_package` fails without it. Create
  it idempotently inside the script. See plan §Phase 3g.
- **Phase 4** — the graded run must be the **Athena** run (never `--local-data-path`),
  teed to `docs/lab3-evidence/train-final.log`, plus
  `docs/lab3-evaluation-report.md`.
- **Phase 5** — Track C: copy `backend.tf.example` → `backend.tf`, then the three
  `TODO (student)` items in `agent/main.tf`. The first apply **is supposed to fail**
  at the gateway on TODO 1; read the error. Also run the one-scenario spike first to
  confirm the harness accepts `liteLlmModelConfig`.
- **Phase 6** — `python agent/policy_tests.py` (expect 7/7), the evaluation harness,
  traces + cost, and `track-c-failures.md` including the **split-credit hole**.
- **Phase 7** — `notebooks/lab3-demo.ipynb` committed **with outputs** from one clean
  Restart & Run All (execution counts must be `1..N`).
- **Phase 8** — `collect-lab3-evidence.sh --track C`, fix every FAIL,
  `scripts/teardown-lab3.sh`, then `git tag lab3-submit && git push origin lab3-submit`.

The full evidence map and rubric mapping are in `docs/lab3-plan.md` §7 and §1.

---

## 6. Traps already discovered (do not re-discover them)

- `apiKeyArn` for the AgentCore harness is an **AgentCore Identity token-vault ARN**,
  not Secrets Manager: `...:token-vault/default/apikeycredentialprovider/<name>`.
- The `aws` Terraform provider exposes `litellm_model_config` (lowercase, no second
  underscore) on `aws_bedrockagentcore_harness`.
- XGBoost version matters: local is **3.4.1**, the reference metrics were 3.2.0, the
  SageMaker container is 1.7. Report the version next to the metrics.
- The offline store is **append-only** and soft-deleting; dedupe with `ROW_NUMBER()`
  and exclude `is_deleted`.
- `event_time` is `Fractional` (epoch seconds), not an ISO string.
- `ORDER BY customer_id` in the Athena query is **load-bearing** — without it the row
  order varies and the train/test split changes run to run.
- `loyalty_tier` must be passed through `train_test_split` as a third array; deriving
  it afterwards will not line up.
- Slice metrics need `n` and the positive count beside them.
- `--local-data-path` is for development only; a graded-run log showing the CSV loader
  fails the 5-point Athena item.
- `scripts/pause-lab3.sh` refuses to run when the stack isn't applied, because it is a
  `terraform apply` and would otherwise **create** the stack.
- `terraform destroy -target=X` destroys X plus its **dependents** and spares its
  **dependencies** — that is what makes the S3/Feature Store keep-set safe.

### Discovered during the Phase 1 rebuild (2026-10-16)

- **`verify-lab2.sh` needs the uv venv on `PATH`.** Its embedded data-quality block
  calls bare `python3`, and system `python3` has no pandas/pyarrow, so it prints a
  `FAIL  pandas/pyarrow available` and the script exits 1. Run it as
  `PATH="$(pwd)/.venv/bin:$PATH" bash scripts/verify-lab2.sh`. Do not conclude the
  data is broken from that FAIL alone.
- **The offline store is queryable even though its Glue table has no partitions.**
  `northstar_dev_customer_features_1792134849` has `PartitionKeys: null`, empty
  `Parameters` (no partition projection) and `get-partitions` returns `[]`, yet
  Athena reads the `data/year=/month=/day=/hour=` Parquet correctly — `SELECT
  count(*)` returns 9999. **No `MSCK REPAIR TABLE` is needed**; do not "fix" this.
- **`pause-lab3.sh` can fail on the EIP after the NAT is gone.** The NAT destroys,
  then `ReleaseAddress` fails with `InvalidNetworkInterfaceID.NotFound` because the
  NAT's ENI disappears first. The script's guard then sees the NAT absent from
  state and short-circuits on re-run, so it will *not* retry for you. Finish with
  `terraform -chdir=infrastructure/environments/dev apply -var
  enable_nat_gateway=false` (it took 4 attempts); confirm
  `aws ec2 describe-addresses --query length(Addresses)` is 0.
- **The Feature Store provisioned online store has no idle charge** (this closes the
  plan's §9 throughput risk). Cost Explorer shows **no Feature Store usage type**
  during Sep 2026, when the feature group was live for Lab 2 — only
  `USE1-Studio:VolumeUsage.gp3`. Leaving `online_store_config` on its provisioned
  default is correct; do not switch it to OnDemand (that would replace the feature
  group and delete the offline-store Glue table).
- **`--training-start-date/--training-end-date` default to 2026-01-01..2027-01-01**
  and that is deliberate: Lab 2 stamps `event_time` with the Glue job's wall-clock
  `time.time()`, not the feature cutoff. The offline-store partition is therefore
  the *ingest* day. Do not pass the Lab 2 window (2026-04-01..2026-06-30) as the
  bounds or the query matches zero rows.
- **One free IAM addition was made** (plan §8 "optional"): `sagemaker:CreateModelPackageGroup`
  and `sagemaker:DescribeModelPackageGroup` on the `MLEngineer` policy, so Lab 4's
  pipeline can create the registry group. No effect on Labs 3's local run.
