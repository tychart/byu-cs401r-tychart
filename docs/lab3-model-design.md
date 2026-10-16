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

<!-- TODO (Phase 7). No results needed -- this section can be written now.
     Points to make, all specific to THIS dataset rather than generic ML advice:
     - ~10,000 customers x 13 tabular features + 1 label, ~22% positive rate.
     - Interpretability requirement: the retention team has to justify who gets
       contacted and why, so per-feature importances are a deliverable, not a nicety.
     - Why NOT logistic regression: the signal is not additive/monotonic. The lab's
       own framing is that ~1/3 of churners still buy right up to T, so recency alone
       misleads -- that is an interaction (healthy recency x falling category
       diversity x shifting channel mix), which a linear model cannot express without
       hand-built interaction terms.
     - Why NOT a neural network: at 10k rows x 13 features there is not enough data
       to beat a boosted ensemble, training and tuning cost more, and the result is
       harder to explain. The lab's recall ceiling (~45% at top-10%) shows the
       performance headroom is in the features and the contact budget, not in model
       capacity.
     - What would change my mind: order(s) of magnitude more rows, high-cardinality
       or unstructured features (sequences, text), or a genuinely non-tabular task.
     -->

## 2. What the features bought you

<!-- TODO (Phase 7). Needs the graded run. Fill from
     docs/lab3-evidence/evaluation_metrics.json and slice-evaluation.csv:
     - full-model AUC vs recency-only baseline AUC, the lift, and the 95% CI
     - precision@10% / recall@10%
     - feature-importance ranking: which features carried real signal and which
       were decorative -- say so plainly if the lift was small
     - per-tier slices with n and positives, and which tiers are too small to
       conclude from
     -->

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
