# AGENTS.md

Guidance for AI coding agents working in this repository. Read this before your
first command. It is deliberately short on narrative and long on the things that
have actually cost time or money here.

**Last updated: 2026-10-16 (Lab 3 kickoff).**

> ## Maintenance directive
>
> **After you finish a task here, before you end the session, update this file.**
> Add what you learned: anything that cost you more than ~10 minutes, any cost or
> billing trap, any AWS/Terraform/IAM behaviour you actually verified, and any
> correction to something this file already gets wrong. Keep entries short and
> specific, and delete anything that stops being true.
>
> A stale instruction file is worse than no instruction file. This document is
> expected to grow with every lab; treat updating it as part of finishing the work,
> not as optional cleanup. See [§10](#10-keep-this-file-current).

---

## 1. What this repo is

Coursework for **CS 401R** (BYU), a fictional retailer "NorthStar" whose ML
platform is built across seven labs. One repository for all labs; each lab extends
the last. **Do not create a new repo per lab.** Current position: **Lab 3**.

```
raw/customers/  ──crawler──▶  Glue catalog  ──transform──▶  processed/  ──features──▶  features/  ──▶  SageMaker Feature Store
   (Lab 2)                                                                                        (Labs 3–6 read this)
```

Lab 3 builds two systems: **Track A**, a churn model (XGBoost on the Feature Store,
read via Athena) and **Track C**, a customer-service agent on Amazon Bedrock
AgentCore. Track B (RAG) is **not** attempted.

Authoritative documents, in reading order:

| Document | What it is |
| --- | --- |
| `instructions/` | The lab specifications (`lab3_instructions_oct_13.md`, Lab 1/2 as HTML) |
| `docs/lab3-plan.md` | **The plan of record** for Lab 3: phases, costs, evidence map, traps |
| `docs/lab3-handoff.md` | Current position + environment facts, written to survive a session boundary |
| `docs/lab3-model-design.md` | Track declaration (already written) and Phase 7 notes |
| `README.md` | Login command at the top; per-lab run instructions |
| `docs/lab1-adr.md`, `docs/lab2-data-contract.md` | Lab 1/2 design decisions and the data contract |

---

## 2. Non-negotiables

1. **Never commit credentials.** No `.env`, no `terraform.tfvars`, no keys. The
   `.gitignore` already covers `*.tfvars`, `.env`, `*.tfstate`, `.terraform/`.
   Do not weaken it. `bash scripts/check-secrets.sh` scans git history and should
   print `CLEAN`.
2. **Never leave billable resources running.** End every work session with
   `bash scripts/pause-lab3.sh`. See [§4](#4-cost-discipline--this-is-the-biggest-recurring-risk).
3. **Never run `terraform` from the repository root.** Always `-chdir=`. Running it
   from the root creates a stray empty `terraform.tfstate` that confuses later
   sessions (this has happened).
4. **Never create an MLflow *Tracking Server*.** Only `create-mlflow-app`. The
   names differ by one word and the price differs by $0.60/hour. Details in §4.
5. **The TA grades a git tag**, not your working tree: `lab1-submit`, `lab2-submit`,
   `lab3-submit`. Work after a tag does not change that lab's grade. Anything that
   exists only in AWS is invisible to grading until exported into `docs/`.
6. **Persist what matters.** Decisions, cost facts and gotchas belong in this file,
   `docs/lab3-plan.md`, and long-term memory — not only in a chat transcript.

---

## 3. Environment and tooling

### Authentication (easy to get wrong)

`AWS_PROFILE=tf` is exported. The `tf` profile has **no** credentials of its own; it
delegates to the `[default]` login session via `credential_process`.

```bash
aws login --profile default      # correct
aws login                        # WRONG: "Profile 'tf' is already configured with
                                 # Credential Process credentials"
aws sts get-caller-identity      # expect mgt-admin / 345594594463
```

Only `[default]` ever needs re-authenticating (sessions last ~12h). Region is
**us-east-1**, account **345594594463**. Never put `credential_process` on
`[default]`, and never put a `login_session` on `[tf]` — the two conflict.

### Python

Use the repo's `uv` environment, never bare `python` (system Python is 3.14; the
project is 3.12):

```bash
uv run python <script>
uv sync                          # after editing pyproject.toml
```

Pinned and load-bearing: **`sagemaker>=2.200,<3.0.0`** (SDK 3.x *removed* the
`sagemaker.feature_store` package), `xgboost 3.4.1`, `mlflow` **plus**
`sagemaker-mlflow` (the SigV4 auth plugin), `boto3 >= 1.43.57` (needed for
`bedrock-agentcore`'s `invoke_harness`), `pandas 3.0.6`.

`import agent.lambda.handler` is a **`SyntaxError`, not a missing module** —
`lambda` is a reserved word. Lambda zips `handler.py` to the archive root, which is
correct. For local tests use `importlib.util.spec_from_file_location`.

Several repo scripts — `verify-lab2.sh` and `collect-lab3-evidence.sh` among them —
invoke bare `python3` (a system Python with no pandas/pyarrow/mlflow). Run them with
the venv on `PATH`, e.g.
`PATH="$(pwd)/.venv/bin:$PATH" bash scripts/collect-lab3-evidence.sh --track C`, or
they fail in a way that looks like a data or dependency problem rather than the
PATH problem it is.

### Terraform roots — never mix them

| Root | Provider | State key | Purpose |
| --- | --- | --- | --- |
| `infrastructure/environments/dev` | `aws ~> 5.0` | `dev/terraform.tfstate` | VPC, S3, IAM, Glue, Feature Store, SageMaker |
| `infrastructure/environments/agent` | `aws 6.67.0` (exact) | `agent/terraform.tfstate` | Lab 3 Track C: AgentCore |
| `infrastructure/environments/local` | `aws ~> 5.0` | local | LocalStack, `make local-validate` |

AgentCore needs provider 6.x; **no 5.x release has a single `aws_bedrockagentcore_*`
resource**, which is why the agent stack is a separate root. Never add AgentCore
resources to `dev/`.

Remote state: `s3://northstar-tfstate-345594594463`, lock table
`northstar-tfstate-lock` (`PAY_PER_REQUEST`). The backend's `dynamodb_table`
argument is deprecated (warns on every plan) in favour of `use_lockfile`; left
alone deliberately.

---

## 4. Cost discipline — this is the biggest recurring risk

Tyler is on a **$200 credit budget and the course alarm is $10/month.** Cost hygiene
is a first-class requirement here, not a nicety. Measured idle costs:

| Resource | Idle cost | Note |
| --- | --- | --- |
| **NAT Gateway + its public IPv4** | **~$0.05/hr ≈ $1.20/day** | **~99% of all idle cost in this repo** |
| SageMaker Studio domain | $0 | apps bill ~$0.05/hr **only while running** |
| Studio EFS home | ~$0.30/GB-month | pennies |
| S3 (all prefixes) | ~$0.023/GB-month | cents/month for this dataset |
| Feature Store (standard online store) | storage only | **no hourly idle charge** | verified in Cost Explorer — no Feature Store usage type appeared in a month the feature group was live |
| MLflow **App** | **$0** | serverless, keep it forever |
| **MLflow Tracking Server** | **$0.60/hr** | **the trap** — breaches the whole budget in 17h |
| Secrets Manager secret | $0.40/secret-month | avoided — see §6 |
| AgentCore Identity token vault | **$0** | free when used through AgentCore Runtime |
| AgentCore harness session | ~$0.003/session | memory is billed per session, so keep `idle_session_timeout_seconds = 60` |
| Glue job run | $0.44/DPU-hr (2 DPU min) | ~$0.03–0.10 per pipeline run |
| Athena | $5/TB scanned | a 10k-row query is <$0.001 |

**Pause tooling — use it, don't improvise:**

| Command | Effect |
| --- | --- |
| `scripts/pause-lab3.sh` | NAT off via `-var enable_nat_gateway=false`. Keeps S3, Feature Store, Glue catalog, IAM. ~$0.01/month idle |
| `scripts/pause-lab3-deep.sh` | Real `terraform destroy -target=module.vpc/glue/sagemaker`, keeps S3 + Feature Store + IAM. **Plans first and aborts if a keep module appears** |
| `scripts/resume-lab3.sh` | One `apply`; restores either pause |
| `scripts/teardown-lab2.sh` | Full destroy **including S3**. Only at the very end |

**`pause-lab3.sh` and the Elastic IP.** Destroying the NAT Gateway also reaps its
ENI, and the EIP `ReleaseAddress` that follows can fail with
`InvalidNetworkInterfaceID.NotFound`. The error is transient, but it aborts the
apply *after* the NAT is already gone; the old NAT-only guard then exited 0 on the
next run and stranded a detached Elastic IP billing ~$0.005/hr with no symptom. The
script now checks NAT **and** EIP in its guard and retries the apply up to 5 times.

**Track A needs no NAT resume.** Training runs locally, and Athena, the MLflow App
and Model Registry are all service APIs — verified 2026-10-16, when the graded run
queried the offline store, logged three MLflow runs and registered a model package
with the NAT destroyed. Only Glue jobs and Studio apps need private-subnet egress,
and the data is already built. Track A work therefore costs storage cents.

**Why the keep-set is what it is:** destroying `module.feature_store` deletes the
offline-store Glue table and breaks the Task 1 Athena query, forcing a re-ingest.
The S3 Parquet survives, but the catalog entry does not. Recomputing the Glue
pipeline costs ~$0.03–0.10 and 5–10 minutes; caching the data costs ~0.2¢/month. So
**keeping the data is the cheap option.**

**Verified Terraform semantics** (do not re-derive): `terraform destroy -target=X`
destroys X **plus its dependents** and **spares its dependencies**. That is what
makes the keep-set safe, and it is why the pause script can use `-target` at all.

---

## 5. Teardown traps (all of these have actually bitten)

`terraform destroy` **does not** fully tear down this stack. Six things are created
outside Terraform's state and are left behind; `scripts/teardown-lab2.sh` exists for
exactly these:

1. **Glue ENIs** — orphaned in the private subnet after job runs; they pin the subnet
   and security group and make `destroy` hang ~10 min per ENI. Removed *before* destroy.
2. **SageMaker EFS** — Studio creates a filesystem Terraform never sees. **It keeps
   billing** and its mount target blocks the subnet.
3. **SageMaker NFS security groups** — two auto-created SGs block VPC deletion.
4. **S3 object versions** — the bucket is versioned, so it cannot be deleted while
   non-empty. Empty all versions *and* delete markers first.
5. **Feature Store catalog** — the `sagemaker_featurestore` Glue database is created
   by the service, not Terraform.
6. **SageMaker lineage** — contexts and artifacts survive `DeleteFeatureGroup` and
   refuse to delete until their associations are unwound.

Also: the AgentCore harness takes ~5 minutes to delete, and AWS creates its runtime
log group itself (Terraform misses it) — it has no retention limit and holds full
customer conversations.

**A failed AWS call is a FAILED check, never "OK".** An early version of the teardown
script treated an errored AWS call as "zero resources found" and produced a
clean-looking report that had verified nothing. Keep that behaviour.

---

## 6. AWS / IAM / model gotchas

- **Least-privilege is split on purpose.** The `MLEngineer` role may read
  `features/`/`artifacts/` but **not write `raw/` or `processed/`** — writing to
  those is denied by omission, so the ingested source of truth stays auditable. The
  two S3 statements are separate because `ListBucket` is bucket-level while object
  actions are prefix-scoped; a trailing `*` on one statement would silently hand
  over the other's access.
- **IAM action names are not guessable.** `sagemaker:RegisterModel` is **not** a real
  action (the real one is `sagemaker:CreateModelPackage`) and was a silent no-op for
  a whole lab. When writing a policy, verify the action exists in the service
  authorization reference. `sagemaker:CreateModelPackageGroup` was missing from the
  MLEngineer policy and was added 2026-10-16 (with `DescribeModelPackageGroup`) —
  harmless while training runs under the student's own credentials, but it would
  have failed Lab 4's pipeline with `AccessDenied` creating the registry group.
- **Policy/role changes take up to ~60s to propagate** to AgentCore. If an apply or a
  call fails with `AccessDenied` immediately after you added the permission it names,
  wait a minute before changing anything else.
- **AgentCore harness model IDs.** Claude 4.5+ cannot be invoked by bare model ID and
  needs the `us.` cross-region inference profile; Claude 3 Haiku is `LEGACY`. The
  non-Claude Bedrock models used here (`openai.gpt-oss-20b-1:0`, `qwen.*`,
  `ministral-*`) have **no** inference profile and are invoked by bare model ID.
- **`apiKeyArn` for the harness is an AgentCore Identity *token-vault* ARN**, not a
  Secrets Manager ARN: `arn:aws:bedrock-agentcore:<region>:<acct>:token-vault/default/apikeycredentialprovider/<name>`.
  A Secrets Manager ARN is rejected. The Terraform resource is
  `aws_bedrockagentcore_api_key_credential_provider`; the provider block is
  `litellm_model_config` (**lowercase, one underscore after "litellm"**).
- **Write-only arguments are the fix for secrets in Terraform state.** `api_key_wo`
  is sent to AWS and never persisted — `terraform state show` prints
  `(write-only attribute)`. But the provider requires it on **every** operation
  including `destroy`, so it lives in the gitignored `terraform.tfvars`, not a shell
  variable.
- **Run the Athena query under your own credentials, not `MLEngineer`.** That role has
  no Athena, Glue catalog or Feature Store permissions by design.

---

## 7. Data-engineering invariants

- **The temporal split is not the train/test split.** Every feature is computed from
  purchases **≤ T** (`T = 2026-04-01`); `churn_label` comes only from the outcome
  window `(T, 2026-06-30]`. Anything derived from post-`T` data is leakage.
- **The offline store is append-only and soft-deleting.** Re-running the feature job
  writes a *second* row per customer. Always dedupe with
  `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY event_time DESC, write_time DESC)`
  and exclude `is_deleted`. Filtering on a global `MAX(write_time)` keeps only the
  customers written in the final microsecond.
- **`ORDER BY customer_id` in the Athena query is load-bearing.** Athena parallelises
  the scan and returns rows in nondeterministic order, so `train_test_split(random_state=42)`
  produces a *different split and different metrics* on identical data. Measured: AUC
  ranged 0.7276–0.7431 across four runs without it.
- **`event_time` is `Fractional` (epoch seconds), not an ISO string.** Comparing it to
  `'2026-04-01'` fails with `TYPE_MISMATCH`.
- **The offline-store Glue table needs no `MSCK REPAIR`.** It has no `PartitionKeys`
  and no partition projection (`get-partitions` returns `[]`), yet Athena reads the
  `year=/month=/day=/hour=` Parquet correctly — verified `SELECT count(*)` = 9999 on
  2026-10-16. The empty partition list is expected; do not "fix" it.
- **The training script's default date bounds are `2026-01-01`..`2027-01-01`, on
  purpose.** `event_time` is the Glue job's wall-clock time, so the offline-store
  partition is the *ingest* day, not the feature cutoff `T`. Passing the Lab 2
  window (`2026-04-01`..`2026-06-30`) as the bounds matches zero rows.
- **`churn_risk_score` is a pure recency heuristic** and doubles as the baseline to
  beat. Excluded from the feature list by default; if included, report metrics with
  and without it.
- **Every slice metric needs `n` and the positive count beside it.** A slice with ~2
  positives produces an AUC that swings 0.0→1.0 on the shuffle alone, and a
  confident conclusion drawn from it is how a careful-looking analysis ends up
  backwards.
- The XGBoost container in SageMaker is **1.7**; the reference metrics were measured
  on **3.2.0**; local training uses **3.4.1**. Metrics move with the version — always
  report which one produced the numbers.
- **XGBoost 3.x writes UBJSON when the file extension is unrecognised.**
  `save_model("model.xgb")` produces UBJSON, and reloading it prints
  `Unknown file format: 'xgb'. Using UBJSON (ubj) as a guess`. It does load (UBJSON
  is supported from XGBoost 1.6), but the extension is misleading and the load is
  untested against a real container. Lab 5 should save an explicit `model.json` or
  verify the container load before deploying from `northstar-churn-models`.

---

## 8. How Tyler wants work done here

This is the part that is easy to get wrong. These are observed preferences, not
generic advice.

- **Verify before you claim.** Tyler consistently values evidence over assertion.
  When a claim is checkable, check it: run the plan, grep the state file, make the
  API call. Empirical checks that paid off in practice: a local `terraform_data`
  fixture to settle `-target` destroy semantics, and a live tool-calling call to the
  model proxy. **Say plainly when something is unverified, and label unknowns as
  unknowns.**
- **Correct yourself openly.** Getting the AgentCore key ARN wrong twice was handled
  by saying so immediately and re-verifying. Do that rather than quietly moving on.
- **The lab instructions take precedence — but verify their AWS specifics.** Expect
  small errors in the specs and treat exact AWS operations with "a small grain of
  salt", while trusting the overall intent.
- **Ask structured questions when a decision is genuinely open.** Use the
  multi-option question tool with real trade-offs rather than guessing at a
  preference. Don't ask about things you can determine yourself.
- **Explain for someone new to classical ML.** Tyler has real LLM/agent experience
  but is new to traditional model training, so explain AUC, class imbalance, splits
  and confidence intervals plainly. Do not dumb down the agent/platform material.
- **Cost and "will I be surprised by a bill?" matter as much as correctness.** Propose
  the cheaper path, quantify it, and never leave a resource that bills.
- **Prefer open-source and cheap models; avoid Anthropic by choice.** The agent model
  is a self-hosted LiteLLM proxy (`deepseek-flash`), with `openai.gpt-oss-20b-1:0`
  (Apache-2.0) on Bedrock as a one-flag fallback. Keep the backend switchable.
  A fallback ladder should escalate to bigger **open-weight** models, never Anthropic.
- **Write documentation a beginner can follow**, with the reasoning and the rejected
  alternative included — not just the commands.
- **Commits**: descriptive subject, body explaining the *why* and the trade-offs, then
  push. Report the subject and hash back.
- **Multi-session work is normal.** Keep `AGENTS.md`, `docs/lab3-plan.md` and memory up
  to date so a fresh session can start from the repo rather than from a transcript.

---

## 9. Repo conventions

- **Scripts**: `scripts/` holds `bootstrap-state.sh`, `check-secrets.sh`,
  `verify-lab1.sh`, `verify-lab2.sh`, `teardown-lab2.sh`, the Lab 3 evidence and
  teardown scripts, and the pause/resume trio. All are `bash` and idempotent.
- **Evidence lives in the repo.** Graded artifacts go to `docs/` (e.g.
  `docs/lab3-evidence/`); logs captured with `2>&1 | tee`. If it is not committed
  under a tag, it was not done.
- **LocalStack covers `vpc`, `storage` and `iam` only** (`make local-validate`), with
  the NAT Gateway and lifecycle rules disabled. SageMaker, Glue and Feature Store are
  not emulated.
- **`verify-lab1.sh` reads all five Terraform outputs**, so those outputs must keep
  existing in `environments/dev/outputs.tf`.
- Don't reorganise `modules/` or rename outputs casually — Labs 4–6 and the Lab 1/2
  verification scripts depend on the current shape.

---

## 10. Keep this file current

**If you learn something durable, add it here before you finish the session.**

What belongs:

- Anything that cost you **more than ~10 minutes** to discover.
- **Cost facts** and billing traps, especially anything that bills while idle.
- **Verified AWS/Terraform/IAM behaviour**, with the evidence that settled it.
- **Corrections** to something this file previously said.
- **Tyler's preferences**, when he states one or when feedback implies one.

What does not: step-by-step lab instructions (those live in `docs/lab3-plan.md`),
per-session status (that is `docs/lab3-handoff.md`), or anything already documented
upstream.

Keep entries **short and specific** — one line plus the reason. Prefer a table or a
bulleted rule over a paragraph. Prune anything that stops being true; a stale
instruction file is worse than none.
