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

9,999 customers, **13 features in the feature group** of which **11 enter the
model** (`churn_risk_score` is excluded as the recency heuristic that doubles as the
baseline; `loyalty_tier` is excluded because it correlates with spend and is needed
for slicing), binary label at a **22.0%** positive rate.

Gradient boosting fits. The features are tabular, of mixed scale, and the boundary
is not additive — the same recency means different things for a customer whose
category diversity is collapsing than for one merely between orders. Boosting learns
such interactions by construction, needs no scaling, tolerates spend-column
outliers, and exposes **per-feature gain importances**. The retention team must
justify who gets contacted, so interpretability is a deliverable here.

**Not logistic regression.** A linear logit needs additivity, so the interaction
above would have to be hand-built — each term a hypothesis to defend. I did **not**
run a logistic baseline, so I make no measured claim against one; the measured
competitor is recency-only and it loses (§2). The objection is structural.

**Not a neural network.** 10k rows × 11 inputs is too little data to identify an
MLP, which also needs scaling, regularisation and more tuning to explain less.
Capacity is not the constraint: recall at a 10% contact budget is capped near 45% by
arithmetic, and the gap to close is the +0.054 lift — a features-and-budget problem.

**What would change my mind.** Orders of magnitude more rows; high-cardinality
identity or unstructured inputs; or a linear model with explicit interactions that
matched the boost inside the lift CI, which I would prefer for explainability.

## 2. What the features bought you

Full model **AUC 0.7773** against the recency-only baseline's **0.7232** on the same
3,000 held-out customers: lift **+0.0541**, paired-bootstrap 95% CI
**[0.0347, 0.0738]**, excluding zero. Precision @ top 10% **0.7233** (gate 0.50),
recall **0.3288** (gate 0.25). The feature engineering did measurable work beyond
the free rule.

**Modest, and the importances explain why.** `purchase_frequency_180d` (21.3% of
gain), `days_since_last_purchase` (20.4%) and `purchase_frequency_30d` (12.9%) carry
over half the model between them, so it leans on roughly the same information as the
baseline. Recency genuinely is the dominant signal; no feature engineering was going
to produce a dramatic lift.

**What carried signal, what was decorative.** The three features Lab 2's
diversity/channel argument rests on rank bottom: `avg_basket_size_6m` 5.3%,
`category_diversity_score` 5.0%, `online_to_store_ratio` 4.8%, with
`customer_tenure_days` lowest at 3.9%. **I am not calling them decorative.** Gain is
attribution within one fit, and correlated features split credit arbitrarily, so the
honest reading is that the feature *set* beat recency while the per-feature story is
suggestive, not established. An ablation — drop those three, re-fit, re-measure the
paired CI — would settle it; I did not run it, and it is the top follow-up in
`docs/lab3-evaluation-report.md` §7.

**Per tier** the picture is uncomfortable: one shared top-10% list reaches 44% of
Bronze churners but 15% of Gold and 14% of Platinum, because Bronze churns at 33%
against 8-11% for the top tiers. Platinum's 21 test positives make its own numbers
unmeasurable either way. Table and discussion in `slice-evaluation.csv` and report §4.

## 3. LLM system: why an agent rather than a simpler pipeline?

<!-- TODO (Phase 7). No results needed.
     Points to make:
     - Name the alternative plainly: a single-shot, deterministic flow (route the
       message to a template, fill in fields). For the five supported scenarios
       that would in fact be cheaper and easier to test.
     - The technical reason to reject it: the request is not known in advance. The
       agent has to decide *whether* a policy lookup is needed and *which* record to
       look up from an underspecified message (TC-004), then reconcile tool output
       against a policy document, then decide whether the request is inside its
       authority. That decision sequence is the product, not an implementation detail.
     - Name the primary production risk: an agent that holds authority it should not
       have. TC-005 is that risk made concrete -- a long-tenure Platinum member
       demanding a final-sale return. A single-shot template cannot fail that way,
       which is exactly why the failure mode deserves the engineering.
     - The $50 cap in three places (system prompt, tools.py, gateway Cedar policy),
       and which layer I would trust alone: the gateway, because it is evaluated
       before the tool executes and is not reachable by argument or by a persuasive
       customer. The prompt is a hint; tools.py is defence in depth; the policy is
       the only one that is actually enforced. See track-c-failures.md for the hole
       even that layer leaves (two $40 credits against a $50 cap).
     -->

## 4. What I would do differently

<!-- TODO (Phase 7). One or two specific architectural or evaluation changes --
     not "more testing". Candidates:
     - Represent the credit cap as a session-scoped ledger so the policy is
       aggregate rather than per-call (the split-credit hole).
     - Replace the bounded 5-scenario suite with a property-based or adversarial
       generator that produces policy-pressure cases, since TC-005 catches one
       instance of a general class.
     - For the churn model: replace the single random split with repeated
       stratified splits and report the interval, given the measured +/-0.03 AUC
       spread across splits.
     -->
