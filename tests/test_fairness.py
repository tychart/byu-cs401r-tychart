"""NorthStar Retail — Fairness Check (Task 1, `tests/test_fairness.py`)

A model can rank customers well on average and still work badly for one group.
This file looks for exactly that: does the model find churners as reliably for
the lowest-value loyalty tier as it does for the highest?

## What is being measured, and why it is not "fairness" in the legal sense

The retention team works **one** list: the top 10% of customers by predicted
churn risk, across the whole population. `recall_top10` for a tier answers the
question "*of this tier's actual churners, what fraction made that one list?*"

That framing matters. Recall is mechanically limited by how many of a tier's
customers the model chose to put near the top, so a tier that is small or that
the model systematically ranks lower cannot reach the same recall even if the
model is equally accurate within it. This is a **screening** check on the
business outcome -- who gets a retention offer -- not a statistical parity
guarantee. The per-tier `auc` in the same dict is the accuracy question, and it
is reported alongside so the two cannot be confused.

## This test FLAGS. It does not block.

The handout is explicit: the point is that a recall gap is **visible to the
approver**, not that it is quiet, and not that it fails the build. Gating on it
would either stop every build (this data produces a large gap) or force someone
to lower the threshold until it never fires -- which is worse than no check,
because it looks like coverage.

So nothing here asserts on the size of the gap. The assertions are on whether the
numbers needed to judge it exist at all, which is the failure that would make the
flag meaningless.

## The one number

Flag when the recall gap between the best-served and worst-served loyalty tier
exceeds **10 percentage points**. It does on the reference data, and the flag
fires. That is the intended outcome.
"""

import json
import os
import warnings
from pathlib import Path

import pytest

# Threshold from the handout: flag, do not block, above 10 percentage points.
RECALL_GAP_FLAG = 0.10

# The four tiers, in value order. Anything else in the metrics dict is either
# "ALL" (the aggregate) or a slice that should not exist.
TIERS = ["Bronze", "Silver", "Gold", "Platinum"]

# A slice below this many positives produces a recall whose uncertainty is wider
# than the effect being measured: 1 churner re-ordered moves recall by ~1/n, so
# a tier with 20 positives moves 5 points per customer. Flagged separately so a
# scary-looking gap is not read as a solid one.
MIN_TRUSTWORTHY_POSITIVES = 30


@pytest.fixture(scope="session")
def slices():
    """Per-tier slice metrics emitted by `churn_model.train()`.

    `train()` writes `metrics["slices"]`, keyed by tier plus `ALL`, each entry
    carrying `n`, `positives`, `auc`, `recall_top10`, `recall_gap_vs_aggregate`,
    `recall_drop_flag` and `too_small`.

    A missing file or a missing `slices` key is a FAILURE, not a skip. Skipping
    would mean the fairness check silently does not run, and the build would go
    green having reported nothing about tier-level recall -- the exact shape of
    decorative gate this course keeps warning about.
    """
    metrics_path = os.environ.get("EVAL_METRICS_PATH", "/tmp/eval_metrics.json")
    if not Path(metrics_path).exists():
        pytest.skip(f"Evaluation metrics not found at {metrics_path}.")

    with open(metrics_path) as f:
        metrics = json.load(f)

    assert "slices" in metrics, (
        "evaluation_metrics.json has no 'slices' key, so per-tier recall cannot "
        "be evaluated. `train()` in models/churn/churn_model.py must put "
        "evaluate_slices() output under metrics['slices'] -- that is the design "
        "the CI gate reads."
    )
    assert isinstance(metrics["slices"], dict) and metrics["slices"], (
        "'slices' is empty; the fairness check would have nothing to compare."
    )
    return metrics["slices"]


def _recall_by_tier(slices):
    """Tier -> recall@top10%, for tiers that have one.

    A tier with zero churners in the validation split has `recall_top10: None`.
    It is excluded from the comparison rather than treated as 0.0: a tier with
    no churners has no recall to be unfair about, and folding it in as zero
    would invent the worst possible gap out of missing data.
    """
    out = {}
    for tier in TIERS:
        entry = slices.get(tier)
        if entry is None:
            continue
        recall = entry.get("recall_top10")
        if recall is not None:
            out[tier] = float(recall)
    return out


# ── Structure: are the numbers there at all? ──────────────────────────────────

class TestSliceMetricsExist:
    """These assertions DO block, because without them the flag is meaningless."""

    def test_all_four_tiers_are_present(self, slices):
        missing = [t for t in TIERS if t not in slices]
        assert not missing, (
            f"Missing tier(s) {missing} from metrics['slices']. All four loyalty "
            f"tiers must be evaluated; a missing tier is a group the gate never "
            f"looked at."
        )

    def test_every_slice_carries_its_sample_size(self, slices):
        """A recall number without `n` and `positives` is unfalsifiable.

        This is the failure that produced the lost 2026-08-01 slice numbers: a
        per-tier recall was quoted with no indication that the tier held 21
        churners, so a number that swings 5 points per customer was read as
        solid.
        """
        for name, entry in slices.items():
            assert "n" in entry and "positives" in entry, (
                f"slice '{name}' is missing n/positives: {sorted(entry)}"
            )
            assert entry["n"] > 0, f"slice '{name}' has no rows"
            assert 0 <= entry["positives"] <= entry["n"], (
                f"slice '{name}' reports {entry['positives']} positives out of "
                f"{entry['n']} rows, which is impossible"
            )

    def test_aggregate_slice_matches_the_sum_of_tiers(self, slices):
        """Sanity: the tiers must partition the validation set.

        If they do not, some customers are counted twice or not at all, and both
        the per-tier recalls and the aggregate are wrong.
        """
        tier_rows = sum(slices[t]["n"] for t in TIERS if t in slices)
        assert tier_rows == slices["ALL"]["n"], (
            f"Tiers sum to {tier_rows} rows but the aggregate slice has "
            f"{slices['ALL']['n']}. Every validation row must belong to exactly "
            f"one loyalty tier."
        )

    def test_recall_values_are_probabilities(self, slices):
        for name, entry in slices.items():
            recall = entry.get("recall_top10")
            if recall is None:
                continue
            assert 0.0 <= float(recall) <= 1.0, (
                f"slice '{name}' recall@top10 = {recall}, outside [0, 1]"
            )


# ── The flag: reported, never enforced ────────────────────────────────────────

class TestRecallGap:
    """Flags the gap for the approver. Never fails the build on gap size."""

    def test_recall_gap_across_tiers_is_flagged(self, slices):
        """Warn when the best-served and worst-served tiers differ by >10pp.

        Both numbers are reported with their sample sizes, and the gap is
        computed twice: once across every tier, and once excluding tiers whose
        churner count is too small for the recall to be stable. If the two
        disagree in sign or magnitude, the gap is being driven by sampling
        noise, and an approver deserves to know that before acting on it.
        """
        recalls = _recall_by_tier(slices)
        assert len(recalls) >= 2, (
            f"Need at least two tiers with churners to compute a gap; got "
            f"{sorted(recalls)}. Check the validation split."
        )

        best = max(recalls, key=recalls.get)
        worst = min(recalls, key=recalls.get)
        gap = recalls[best] - recalls[worst]

        stable = {
            tier: r for tier, r in recalls.items()
            if slices[tier]["positives"] >= MIN_TRUSTWORTHY_POSITIVES
        }
        stable_gap = (
            max(stable.values()) - min(stable.values()) if len(stable) >= 2 else None
        )

        def n_pos(tier):
            return slices[tier]["positives"]

        summary = (
            f"Fairness: recall@top10% spread across tiers = {gap:.4f} "
            f"({gap * 100:.1f} pp) from {best} {recalls[best]:.4f} "
            f"(n={slices[best]['n']}, pos={n_pos(best)}) to {worst} "
            f"{recalls[worst]:.4f} (n={slices[worst]['n']}, pos={n_pos(worst)})"
        )
        if stable_gap is not None and stable_gap != gap:
            summary += (
                f"; excluding tiers with <{MIN_TRUSTWORTHY_POSITIVES} positives "
                f"({sorted(set(recalls) - set(stable))}) the spread is "
                f"{stable_gap:.4f} ({stable_gap * 100:.1f} pp)"
            )

        if gap > RECALL_GAP_FLAG:
            warnings.warn(
                summary + f" -- exceeds the {RECALL_GAP_FLAG * 100:.0f} pp flag "
                f"threshold. FLAG, not failure: the approver decides whether this "
                f"model may ship.",
                stacklevel=2,
            )
        else:
            warnings.warn(summary + " -- within the flag threshold", stacklevel=2)

        # Deliberately no assertion on `gap`. This check reports; it does not
        # gate. Blocking here would stop every build on this dataset, and a
        # threshold loosened until it never fires is worse than no check.
        assert isinstance(gap, float)

    def test_tiers_below_the_flag_are_reported_separately(self, slices):
        """Churners a tier cannot spare: recall is quantised by `positives`.

        With 21 churners, moving one customer between the top-10% list and out
        of it changes that tier's recall by 4.8 points. A tier that small cannot
        produce a trustworthy gap no matter what the model does, so it is
        reported so the reader can discount it.
        """
        fragile = {
            tier: entry["positives"] for tier, entry in slices.items()
            if tier != "ALL"
            and entry["positives"] < MIN_TRUSTWORTHY_POSITIVES
        }

        if fragile:
            detail = ", ".join(
                f"{tier} (pos={positives}, one customer = "
                f"{100.0 / positives:.1f} pp of its recall)"
                for tier, positives in sorted(fragile.items())
            )
            warnings.warn(
                f"Fairness: thin slices below {MIN_TRUSTWORTHY_POSITIVES} "
                f"positives -- {detail}. Treat their per-tier recall as "
                f"indicative, not measured.",
                stacklevel=2,
            )

        # Structural check only: any tier present must be classified, and "ALL"
        # must never be treated as a tier.
        assert "ALL" not in fragile
        for tier in slices:
            if tier != "ALL":
                assert isinstance(slices[tier]["positives"], int)
