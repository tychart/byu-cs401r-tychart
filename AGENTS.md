# AGENTS.md

Guidance for AI coding agents working in this repository. Read this before your
first command. It is deliberately short on narrative and long on the things that
have actually cost time or money here.

**Last updated: 2026-10-30 (Lab 4 prerequisites complete, CI stack up).**

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
the last. **Do not create a new repo per lab.** Current position: **Lab 4 in progress** —
all six prerequisites are done and the CI stack (`northstar-cicd`) is up; the first
pipeline run stops at `pre_build` until Task 1's `data/feature_engineering.py` and
`tests/test_fairness.py` exist. Lab 3 is tagged `lab3-submit` and unchanged.

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

Tyler pays for this account **out of pocket**. There is **no $200 new-account credit
and no promotional credit at all** — verified 2026-10-16, when Cost Explorer reported
`$0.00` for `RECORD_TYPE = Credit` in both the current and previous month. Every cent
of measured spend is Tyler's own money. Do not assume a credit buffer absorbs an
overspend, and never describe a cost as "free because of credits".

**The real alarm is smaller than it looks.** The only budget configured is
`My Monthly Cost Budget` with a **$1.00** limit, and `aws cloudwatch describe-alarms`
returns **no alarms at all** — there is no $10 billing alarm in this account. Spend at
that moment was **$0.4222** MTD (~42% of the $1 budget already gone, all of it
September/early-October NAT hours). On a **paused** stack the forecast is flat, so the
budget will not fire and the steady state is ~$0.01–0.05/month. But headroom is only
~$0.58, so a single `resume-lab3.sh` left running for a day (NAT ≈ $1.20/day) breaches
it. **Cost hygiene is a first-class requirement here, not a nicety.**

Measured idle costs:

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
| CodeBuild `BUILD_GENERAL1_MEDIUM` | ~$0.005/min | a full run is ~3-5 min |
| Training job, `ml.g6.2xlarge` spot | ~$0.45/hr billed | measured 59-69 s billable ≈ $0.01/run |

**Pause tooling — use it, don't improvise:**

| Command | Effect |
| --- | --- |
| `scripts/pause-lab3.sh` | NAT off via `-var enable_nat_gateway=false`. Keeps S3, Feature Store, Glue catalog, IAM. ~$0.01/month idle |
| `scripts/pause-lab3-deep.sh` | Real `terraform destroy -target=module.vpc/glue/sagemaker`, keeps S3 + Feature Store + IAM. **Plans first and aborts if a keep module appears** |
| `scripts/resume-lab3.sh` | One `apply`; restores either pause |
| `scripts/teardown-lab2.sh` | Full destroy **including S3**. Only at the very end |

**Verify a pause from the AWS APIs, not from the script's own output.** The script's
"already gone" message reads the Terraform *state*, which is exactly what would be
wrong if a destroy had half-finished. Two checks settle it (run 2026-10-16, before a
48h absence): `aws ec2 describe-nat-gateways` shows the NAT in state **`deleted`**,
`aws ec2 describe-addresses` returns **0** addresses, and
`terraform -chdir=infrastructure/environments/dev plan -var enable_nat_gateway=false`
prints **"No changes"** — that last one is the strongest signal, because it proves the
config, the state and reality all agree.

**Cost Explorer API calls are not free: $0.01 per request.** Auditing spend eight
times on 2026-10-17 cost **$0.08** — about half a NAT-hour and the second-largest
line of that day. At a $1 budget that is not a rounding error. Use one
month-to-date `get-cost-and-usage`, or the free budget API, rather than iterating on
queries; service-level results also lag up to 24 h, so a "missing" Bedrock or
AgentCore line may simply not have posted yet.

A leftover **`blackhole`** route (`0.0.0.0/0 → nat-…` in the private route table) is
the expected residue of a NAT destroy and is **not** a cost. Do not "fix" it; the
resume re-creates the NAT route. Also expected: the SageMaker **Studio domain stays
`InService`** ($0 idle), the **MLflow App** stays `Created` ($0), and the studio
**EFS** stays mounted at ~6 KB (≈$0.000002/month). Those are all deliberately kept.

**One thing that cannot be enumerated on this account:** `aws glue list-dev-endpoints`
and `get-dev-endpoints` both fail with *"operation is currently disabled"*, so Glue dev
endpoints (which bill by the DPU-hour) cannot be positively listed. None are in
Terraform state and none have been created, but the check itself is unavailable —
confirm via Cost Explorer instead.

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

**Track C needs no NAT resume either — verified 2026-10-17.** The AgentCore stack
was created, updated five times and evaluated twice with the dev NAT destroyed. The
harness runs `network_mode = "PUBLIC"`, the tools Lambda is outside the VPC, the
LiteLLM proxy is public, and `terraform` talks to public AWS endpoints. Nothing in
Track C touches the private subnet, so the whole lab runs paused.

**Track C measured cost:** ~**$0.025 per full 6-scenario pass**, and roughly 90% of
that is AgentCore session runtime at the 60 s idle timeout, not model tokens
($0.005/run). Six passes totalled $0.1496. Raising `max_tokens` costs nothing when
unused; lowering the idle timeout is the only lever that matters.

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

**`teardown-lab3.sh` writes its own evidence file.** Its verification block is piped
to `tee docs/lab3-teardown-output.txt`, so
`bash scripts/teardown-lab3.sh > docs/lab3-teardown-output.txt` gives **two writers
on one file**: the outer redirect truncates, `tee` truncates again, and the result is
a garbled report that starts halfway through the checks (this happened 2026-10-17).
Run it with **no redirect**; the file appears on its own. Re-running it is safe and
idempotent — `terraform destroy` reports `0 destroyed` the second time.

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
- **`liteLlmModelConfig.modelId` must be provider-prefixed.** Use
  `litellm_proxy/deepseek-flash`, not the bare `deepseek-flash` from `GET /v1/models`.
  The harness calls `litellm.completion()` internally and LiteLLM refuses to guess a
  provider, so a bare ID fails on the **first invocation** with
  `litellm.BadRequestError: LLM Provider NOT provided` — apply succeeds, nothing
  catches it until a scenario runs. `openai/<model>` is the equivalent prefix for a
  plain OpenAI-compatible endpoint.
- **The gateway execution role needs three AgentCore permissions,** not one:
  `GetPolicyEngine` on the policy-engine ARN, plus `AuthorizeAction` and
  `PartiallyAuthorizeActions` on **both** the policy-engine and gateway ARNs
  (`policy-permissions.html`). `CreateGateway` validates the role before creating
  anything and names only **one** missing action per attempt, after ~2.5 min of
  waiting. Add all three at once. The harness role separately needs
  `bedrock-agentcore:InvokeGateway` on the gateway ARN or every tool load returns
  403.
- **`max_tokens = 1024` is too small for a reasoning model.** deepseek-flash emits
  its analysis as reasoning tokens; TC-003 ended the turn with `runtimeClientError:
  Model stopped generating due to maximum token limit`. That arrives as an exception
  while iterating the event stream, so an unguarded client aborts the entire
  evaluation instead of failing one scenario. `harness_client.py` now catches it and
  records `stop_reason = "error: …"`; the ceiling is 4096.
- **A required tool argument the customer never supplies blocks the tool call.**
  `escalate_to_human` required `customer_id`, so the model narrated an escalation in
  prose instead of calling it — and the harness's prose fallback still scored PASS.
  `customer_id` is now optional in `tool_definitions.json` (the handler already
  defaults to `UNKNOWN`). Check required arguments against the conversations you
  actually expect.
- **Temporal (session-aware) policies are unusable through a harness today.** They
  need a caller-generated `x-amzn-bedrock-agentcore-policy-session-id` header, and
  `InvokeHarness` / `HarnessAgentCoreGatewayConfig` expose no policy-session field
  (verified botocore 1.43.114). Adding one to the engine without that header makes
  every tool call fail validation. The gateway role would also need
  `GetWorkloadAccessToken`. That is why the split-credit hole is documented rather
  than fixed.
- **`harness_client.py` ships with Anthropic Haiku prices.** They are now
  env-overridable (`AGENT_COST_INPUT_PER_1M` / `AGENT_COST_OUTPUT_PER_1M`) and default
  to deepseek-flash's $0.14/$0.28. Reporting Haiku prices against a deepseek run
  would be a wrong number, not a rounding error.

---

## 6b. Lab 4 CI/CD pipeline (2026-10-30)

- **Applied spot training quota is 0, not 4.** `get-service-quota L-29688C85`
  returns 0 while `get-aws-default-service-quota` returns 4; every CPU training
  type is 0. The GPU families are the only ones with quota (1 spot instance
  each). A quota-increase request is `CASE_OPENED`. Do not assume the handout's
  "spot defaults to 4".
- **`scripts/run_sagemaker_pipeline.sh` is the training ladder.** It tries
  `ml.m5.large` first (so the cheap type takes over when quota lands), then GPU
  types, and falls through only on a quota/capacity failure. A 0-quota failure
  happens inside `CreateTrainingJob`, so **no training job exists** — inspect the
  *step* `FailureReason`, not a training job. Verified live: m5 quota failure →
  g6.2xlarge trained + registered (v4-v6); g5.xlarge ICE → stopped after 60 s →
  g6.2xlarge.
- **S3A writes a bucket-root `features_$folder$` marker.** Re-running the feature
  job failed with `AccessDenied` on `s3://.../features_$folder$` after computing
  every feature (old data survives; the write aborts first). The DataEngineer
  policy now grants exactly `processed_$folder$`/`features_$folder$`; the
  prefix-scoped grants still exclude everything else.
- **CodeConnections' GitHub webhook does not deliver pushes on this account.**
  V2 `Triggers` was configured and echoed by `get-pipeline`, the connection reads
  AVAILABLE, manual runs download the repo — but two pushes produced zero
  executions. Change detection is `.github/workflows/trigger-pipeline.yml` →
  `StartPipelineExecution` over GitHub OIDC (role `northstar-github-actions-trigger`
  in `pipeline.yaml`, no stored keys).
- **GitHub OIDC `sub` is immutable for repos created after 2026-07-15:**
  `repo:owner@<id>/repo@<id>:ref:refs/heads/main`. A name-only trust policy fails
  with `Not authorized to perform sts:AssumeRoleWithWebIdentity`. Accept both
  patterns.
- **The CloudFormation `Triggers` property is `ProviderType`, not `Provider`.**
  The wrong key fails changeset creation with only
  `AWS::EarlyValidation::PropertyValidation` and no detail.
- **A colon-space in an unquoted buildspec `echo` breaks the whole buildspec**
  (`YAML_FILE_ERROR` at `DOWNLOAD_SOURCE`, which looks like a source problem).
- **`pytest` is not in the repo venv** (CI installs it from `requirements.txt`):
  `uv pip install pytest` before running locally.
- **Position:** stack `northstar-cicd` is up. Runs currently fail at `pre_build`
  on `tests/test_features.py` (`ModuleNotFoundError: data.feature_engineering`) by
  design until Task 1 lands, which leaves the build-failure alarm in `ALARM` —
  get a green build before demonstrating the failure path so it can be seen
  returning to `OK`.

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
