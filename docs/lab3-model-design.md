# Lab 3 — Model Design Justification

## Track declaration

**Tracks completed: A (required) and C (chosen). Track B is not attempted.**

| Track | System | Approach |
| --- | --- | --- |
| **A** (required) | Churn prediction | XGBoost on the Lab 2 Feature Store features, read from the offline store via Athena |
| **C** (chosen) | Customer service agent | Amazon Bedrock AgentCore — Harness + Gateway + Policy (Cedar), deployed with Terraform |
| B | Offer generation (RAG) | Not attempted |

Declared here before any Lab 3 model code was written, as the lab requires.

**Model choices, deliberately non-Anthropic:**

| | |
| --- | --- |
| Agent (generation) | `deepseek-flash` on a self-hosted **LiteLLM proxy**, via `liteLlmModelConfig` |
| Agent (fallback) | `openai.gpt-oss-20b-1:0` (Apache-2.0) on Bedrock, via `bedrockModelConfig` |
| Agent (key storage) | AgentCore Identity token vault, written through a Terraform write-only argument |
| Churn model | XGBoost 3.4.1, trained locally (not the SageMaker container, which is XGBoost 1.7) |

Both agent backends are switchable with a single Terraform variable
(`model_backend`). The gateway, the Cedar `$50` credit cap, the tools Lambda and
the trace/cost evidence are all independent of which model is selected.

---

## 1. Churn model: why gradient boosting?

9,999 customers, **13 features**, of which **11 enter the model** (`churn_risk_score`
is excluded — the recency heuristic that doubles as the baseline; `loyalty_tier` is
excluded because it correlates with spend and is needed for slicing). Binary label at
a **22.0%** positive rate.

Gradient boosting fits: the features are tabular and mixed-scale, the boundary is
not additive (the same recency means something different when category diversity is
collapsing than when a customer is merely between orders), boosting learns those
interactions by construction, needs no scaling, tolerates spend outliers, and exposes
**per-feature gain importances**. The retention team must justify who gets contacted,
so interpretability is a deliverable.

**Not logistic regression.** A linear logit needs additivity, so each interaction
becomes a hypothesis to defend. I did **not** run a logistic baseline, so I claim
nothing measured against one; the measured competitor is recency-only, and it loses
(§2).

**Not a neural network.** 10k rows × 11 inputs cannot identify an MLP, which needs
more tuning to explain less. Capacity is not the constraint — recall at a 10% budget
is capped near 45% by arithmetic, and the gap is the +0.054 lift.

**What would change my mind:** orders of magnitude more rows; high-cardinality or
unstructured inputs; or an explicit-interaction linear model that matched the boost
inside the lift CI.

## 2. What the features bought you

Full model **AUC 0.7773** against the recency-only baseline's **0.7232** on the same
3,000 held-out customers: lift **+0.0541**, paired-bootstrap 95% CI
**[0.0347, 0.0738]**, excluding zero. Precision @ top 10% **0.7233** (gate 0.50),
recall **0.3288** (gate 0.25). The feature engineering did measurable work beyond
the free rule.

**Modest, and the importances explain why.** `purchase_frequency_180d` (21.3% of
gain), `days_since_last_purchase` (20.4%) and `purchase_frequency_30d` (12.9%) carry
over half the model, so it leans on roughly the same information as the baseline.
Recency dominates; no feature engineering was going to produce a dramatic lift.

**What carried signal, what was decorative.** The three features Lab 2's
diversity/channel argument rests on rank bottom: `avg_basket_size_6m` 5.3%,
`category_diversity_score` 5.0%, `online_to_store_ratio` 4.8%, with
`customer_tenure_days` lowest at 3.9%. **I am not calling them decorative.** Gain is
attribution within one fit, and correlated features split credit arbitrarily, so the
honest reading is that the feature *set* beat recency while the per-feature story is
suggestive, not established. An ablation — drop those three, re-fit, re-measure the
paired CI — would settle it; it is the top follow-up in the report, and I did not run
it.

**Per tier** one shared top-10% list reaches 44% of Bronze churners but 15% of Gold
and 14% of Platinum, because Bronze churns at 33% against 8-11% for the top tiers.
Platinum's 21 test positives make its own numbers unmeasurable.

## 3. LLM system: why an agent rather than a simpler pipeline?

**The alternative I rejected:** a single-shot deterministic flow — classify the
intent, fill a template, call one lookup. For these six scenarios it would be cheaper,
faster and easier to test.

**Why it does not fit: the request is not known in advance.** TC-004 ("my order never
showed up") does not say which order, and the correct path depends on tracking — no
carrier scan for 7 business days is lost; marked-delivered opens a trace. The agent
must decide whether to look up policy, which record to request, reconcile the result
against a policy document, and decide whether the request is inside its authority.
That sequence *is* the product; a template answers only anticipated questions.

**Primary production risk: an agent holding authority it should not have.** TC-005 is
that risk made concrete — a six-year Platinum member demanding a final-sale return with
an account-closure threat. Final sale is non-returnable at every tier (POL-RET-004 §4
overrides tier benefits), so the only correct answer is a clear refusal plus
escalation. Measured: 6/6 in both final runs, with `escalate_to_human` as a tool call.

**Why the $50 cap appears three times.** The prompt is a hint a customer can argue with
and a model can be talked out of; `tools.py` is real code, but the model reaches it only
if it calls the tool; the gateway Cedar policy runs on every request, before the tool,
and cannot be persuaded. Prompt for behaviour, tool for defence in depth, policy for
enforcement.

**Which I would trust alone: the gateway — with one caveat.** It is the only layer the
model cannot skip, but its predicate is per call: two $40 credits pass a $50 cap ($80
total), so alone it bounds one transaction, not one session. That needs the ledger in
§4. The prompt alone earns no trust.

## 4. What I would do differently

**1. Make the cap aggregate, not per-call.** Replace the Cedar predicate with a
Dogwood temporal policy that sums prior `apply_loyalty_credit` responses within a
session and denies when the total exceeds $50. It needs a caller-generated policy
session id (`x-amzn-bedrock-agentcore-policy-session-id` header) and
`GetWorkloadAccessToken` on the gateway role. **A harness cannot do this today** —
`InvokeHarness` and its `agentCoreGateway` tool config expose no policy-session field
(verified against botocore 1.43.114) — so it needs a gateway client we control, or
that API. Details in `docs/lab3-evidence/track-c-failures.md` §1.

**2. Turn escalation into a contract, not a phrase.** The evaluator accepts a tool
call *or* prose such as "a human agent will follow up", which let a run score PASS
with no ticket created (failure 3 in the same file). I would assert on the trace —
every `should_escalate` scenario must contain an `escalate_to_human` call — and
replace six fixed scenarios with generated policy-pressure variants, since TC-005 is
one instance of a general class, not the class itself.
