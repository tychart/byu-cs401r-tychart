"""Pure-pandas port of the Lab 2 feature engineering job.

`glue-scripts/feature_engineer.py` is the PySpark implementation that writes
`features/customers/` and feeds the SageMaker Feature Store. This module is the
*same computation* expressed on DataFrames, for three reasons:

1. **It can be unit tested in isolation.** PySpark cannot be installed in
   CodeBuild in under a few minutes, and a test suite that needs a Glue cluster
   is a test suite that does not run on every commit. Lab 4 Task 1 asks for the
   feature logic out of the Spark job and behind a function boundary.
2. **It can prove the temporal split held.** `tests/test_data.py` recomputes
   the time-sensitive columns here from `processed/` and asserts they equal what
   `features/` actually contains. That is a real leakage check rather than a
   proxy.
3. **It documents the definition of each feature in one place.**

## Parity is the point

Every function below must compute exactly what the Glue job computes, including
the awkward details:

* Windows are `purchase_date > T - N days`, **strictly greater**, where `T` is
  the feature cutoff -- never `today()` and never `max(purchase_date)`. A
  purchase dated exactly `T - 30` is outside the 30-day window, matching
  `F.date_sub(cutoff, 30)` + `>` in the Spark job.
* Comparisons are on **dates**, not timestamps. The Glue job uses `to_date`, so
  a purchase at 23:00 on `T` counts as `T`.
* `avg_basket_size_6m` is **items per order** over 180 days, not dollars, with
  a guarded denominator.
* `category_diversity_score` divides distinct real categories by
  `N_CATEGORIES = 8` and **excludes `unknown`**, which the transform imputes for
  missing values. Counting `unknown` pushes the score above 1.0 on real data.
* `churn_label` comes only from the outcome window `(T, SNAPSHOT]`, never from
  a feature.

If the Spark job and this module drift apart, the unit tests keep passing while
the pipeline trains on something else. `tests/test_data.py::TestLeakage` is the
check that catches that drift on the real dataset.

## Why the Glue job still has its own copy of the logic

The starter kit suggests "having the Glue job and these tests share that logic".
This module deliberately does **not** import into `glue-scripts/feature_engineer.py`,
and the reason is risk: the Glue job is a Spark program operating on 158k rows in
partitions, and running it via pandas would mean either a `mapInPandas`/
`applyInPandas` rewrite of every aggregation or pulling the whole table onto the
driver. Both are large changes to the one component whose output the model, the
Feature Store and Labs 5-6 all depend on, made to serve a testability goal that is
already met.

Sharing is achieved a different way, with a stronger guarantee than a shared
import: `tests/test_data.py::TestTemporalSplit` recomputes these functions from
`processed/` and asserts the result **equals what the Glue job actually wrote** to
`features/`, for all 9,999 customers, on every CI run. A shared import only
proves the two sides call the same code; the cross-check proves the same numbers
came out. If the definitions ever diverge, that test fails rather than the model
silently training on different features.
"""

from __future__ import annotations

from typing import Iterable, Optional

import numpy as np
import pandas as pd

# ── Constants, mirrored from glue-scripts/feature_engineer.py ─────────────────
#
# These MUST match the job that produced features/. Changing one here without
# changing the Glue job makes the tests disagree with the data.

FEATURE_CUTOFF = "2026-04-01"   # T: features use purchases on or before this date
SNAPSHOT = "2026-06-30"         # end of the outcome window, used only for the label

N_CATEGORIES = 8.0              # denominator for category_diversity_score

TIER_BRONZE_MAX = 500.0
TIER_SILVER_MAX = 2000.0
TIER_GOLD_MAX = 5000.0

RISK_HIGH_LO, RISK_HIGH_HI = 0.7, 1.0
RISK_MED_LO, RISK_MED_HI = 0.4, 0.7
RISK_LOW_LO, RISK_LOW_HI = 0.0, 0.4

# Sentinel recency for a customer with no purchases at all. A customer who never
# bought anything is maximally lapsed, and 0 would encode them as the *most*
# engaged customer -- the worst possible default. 999 is outside any window the
# job computes (the longest is 180 days), so it is distinguishable from real data.
NO_PURCHASE_SENTINEL = 999.0

# The six columns the Glue job rounds to 4 decimals before writing.
ROUNDED_COLUMNS = [
    "avg_order_value",
    "total_lifetime_value",
    "total_spend_90d",
    "avg_basket_size_6m",
    "category_diversity_score",
    "online_to_store_ratio",
]

# The model's input features, in the order churn_model.FEATURE_COLUMNS expects.
FEATURE_COLUMNS = [
    "days_since_last_purchase",
    "customer_tenure_days",
    "purchase_frequency_30d",
    "purchase_frequency_90d",
    "purchase_frequency_180d",
    "avg_order_value",
    "total_spend_90d",
    "total_lifetime_value",
    "avg_basket_size_6m",
    "category_diversity_score",
    "online_to_store_ratio",
]


# ── Helpers ───────────────────────────────────────────────────────────────────

def _as_date(value) -> pd.Timestamp:
    """Coerce anything date-like to a tz-naive midnight Timestamp.

    Mirrors Spark's `to_date`: any time component is dropped, so a purchase
    stamped 23:00 on the cutoff belongs to the cutoff day.
    """
    ts = pd.Timestamp(value)
    if ts.tzinfo is not None:
        ts = ts.tz_localize(None)
    return ts.normalize()


def _purchase_dates(transactions: pd.DataFrame) -> pd.Series:
    """`purchase_date` as tz-naive dates.

    Processed Parquet stores this column as `datetime.date` objects, which
    pandas keeps as `object` dtype -- `pd.to_datetime` is required before any
    comparison. Anything unparseable becomes NaT and is dropped by callers,
    because a row whose date is unknown cannot be placed on either side of the
    temporal split.
    """
    return pd.to_datetime(transactions["purchase_date"], errors="coerce").dt.normalize()


def _observed(transactions: pd.DataFrame, snapshot_date) -> pd.DataFrame:
    """Return only the observation window: purchases on or before `T`.

    This single filter is the whole leakage defence. Every feature is computed
    from what it returns; nothing upstream of this is allowed to see the
    outcome window.
    """
    cutoff = _as_date(snapshot_date)
    df = transactions.copy()
    df["_purchase_date"] = _purchase_dates(df)
    df = df[df["_purchase_date"].notna() & (df["_purchase_date"] <= cutoff)]
    return df


def _spark_round(values, decimals: int = 4):
    """Round HALF-UP, matching Spark's `F.round` more closely than numpy does.

    pandas/numpy round half-to-even (banker's rounding). On this dataset plain
    `.round(4)` disagreed with the pipeline output for 327 of 9,999 customers
    in avg_order_value and 15 in online_to_store_ratio; HALF-UP cuts that to
    126 and leaves the ratio exact.

    It cannot be exact, and that is expected. Where the underlying double sits
    on a 4-decimal tie (45.13875 exactly), Spark's sum order and pandas' differ
    in the last bit, so one rounds up and the other down. The residual
    difference is exactly 1e-4 -- the smallest representable step at this
    precision -- on 1.3% of rows. The cross-check in tests/test_data.py
    therefore allows 1e-4 on these columns and asserts exactness on the
    integer-valued ones, rather than pretending the tie can be settled.

    All rounded columns are non-negative (order values, ratios, diversities), so
    the `floor(x * 10^d + 0.5)` form is correct here; it is not a general
    replacement for `round` on signed values.
    """
    scale = 10.0 ** decimals
    return np.floor(np.asarray(values, dtype="float64") * scale + 0.5) / scale
    scale = 10.0 ** decimals
    return np.floor(np.asarray(values, dtype="float64") * scale + 0.5) / scale


def _empty_featured_frame(columns: Iterable[str]) -> pd.DataFrame:
    """An empty result with the right columns, so callers never KeyError."""
    return pd.DataFrame({c: pd.Series(dtype="float64") for c in columns})


def _apply_roster(features: pd.DataFrame, customer_ids, fill: dict) -> pd.DataFrame:
    """Left-join `features` onto a customer roster and fill the gaps.

    `customer_ids` may be a DataFrame with a `customer_id` column or any
    iterable of ids. Customers present in the roster but absent from
    `features` have never bought anything, so they get the sentinel values in
    `fill` rather than NaN. That is the documented null strategy: a
    zero-purchase customer is a valid row, not a missing one.
    """
    if customer_ids is None:
        return features

    if isinstance(customer_ids, pd.DataFrame):
        roster = customer_ids[["customer_id"]].drop_duplicates()
    else:
        roster = pd.DataFrame({"customer_id": list(customer_ids)}).drop_duplicates()

    merged = roster.merge(features, on="customer_id", how="left")
    for column, value in fill.items():
        if column in merged.columns:
            merged[column] = merged[column].fillna(value)
    return merged


# ── Recency ───────────────────────────────────────────────────────────────────

def compute_recency_features(transactions, snapshot_date=FEATURE_CUTOFF,
                             customer_ids=None):
    """How long ago each customer last bought, and how long they have been one.

    Columns produced (one row per customer):

      days_since_last_purchase   T minus the customer's most recent purchase
      customer_tenure_days       T minus the customer's first purchase

    Both are measured back from `T`, not from today, so the values are stable
    across re-runs and identical to the Spark job's.

    `customer_ids` is an optional roster. Customers with no purchases cannot
    appear in a `groupby` of transactions, so without a roster they silently
    vanish from the feature set -- and a customer who never bought anything is
    precisely the one you most want to score. When a roster is supplied they
    appear with `days_since_last_purchase = 999` and `customer_tenure_days = 0`.
    """
    cutoff = _as_date(snapshot_date)
    columns = ["customer_id", "days_since_last_purchase", "customer_tenure_days"]

    if transactions is None or len(transactions) == 0:
        return _apply_roster(
            _empty_featured_frame(columns), customer_ids,
            {"days_since_last_purchase": NO_PURCHASE_SENTINEL,
             "customer_tenure_days": 0.0},
        )

    history = _observed(transactions, snapshot_date)
    if history.empty:
        return _apply_roster(
            _empty_featured_frame(columns), customer_ids,
            {"days_since_last_purchase": NO_PURCHASE_SENTINEL,
             "customer_tenure_days": 0.0},
        )

    grouped = history.groupby("customer_id")["_purchase_date"]
    features = pd.DataFrame({
        "customer_id": grouped.max().index,
        "days_since_last_purchase": (cutoff - grouped.max()).dt.days.to_numpy(),
        "customer_tenure_days": (cutoff - grouped.min()).dt.days.to_numpy(),
    })

    # A negative recency means a purchase dated after T reached the observation
    # window, which the filter above already prevents. Assert rather than clamp:
    # clamping would hide exactly the bug this module exists to catch.
    if (features["days_since_last_purchase"] < 0).any():
        raise ValueError(
            "days_since_last_purchase is negative -- a purchase after the "
            f"feature cutoff {cutoff.date()} reached the observation window"
        )

    return _apply_roster(
        features, customer_ids,
        {"days_since_last_purchase": NO_PURCHASE_SENTINEL,
         "customer_tenure_days": 0.0},
    )


# ── Frequency ─────────────────────────────────────────────────────────────────

def compute_frequency_features(transactions, snapshot_date=FEATURE_CUTOFF):
    """Order counts in the 30, 90 and 180 days before `T`.

    Windows are nested, so `180d >= 90d >= 30d` holds by construction. A test
    asserts it anyway: the invariant survives any future refactor that computes
    the windows independently.
    """
    columns = ["customer_id", "purchase_frequency_30d",
               "purchase_frequency_90d", "purchase_frequency_180d"]

    if transactions is None or len(transactions) == 0:
        return _empty_featured_frame(columns)

    history = _observed(transactions, snapshot_date)
    if history.empty:
        return _empty_featured_frame(columns)

    cutoff = _as_date(snapshot_date)
    windows = {
        "purchase_frequency_30d": cutoff - pd.Timedelta(days=30),
        "purchase_frequency_90d": cutoff - pd.Timedelta(days=90),
        "purchase_frequency_180d": cutoff - pd.Timedelta(days=180),
    }

    out = history.groupby("customer_id").size().rename("_n").reset_index()
    for column, start in windows.items():
        # Strictly greater, matching Spark's `purchase_date > date_sub(T, N)`.
        in_window = history[history["_purchase_date"] > start]
        counts = in_window.groupby("customer_id").size().rename(column)
        out = out.merge(counts.reset_index(), on="customer_id", how="left")
        out[column] = out[column].fillna(0).astype("float64")

    return out[columns]


# ── Monetary ──────────────────────────────────────────────────────────────────

def compute_monetary_features(transactions, snapshot_date=FEATURE_CUTOFF):
    """Value features: order size, 90-day spend, lifetime value, basket size.

    Columns produced:

      avg_order_value        mean order_value across all observation history
      total_spend_90d        sum of order_value in the 90 days before T
      total_lifetime_value   sum of order_value across all observation history
      avg_basket_size_6m     mean num_items per order in the 180 days before T

    Watch the two easy mistakes:

    * `total_spend_90d` is a **sum**, not a mean. Averaging it makes the
      highest-spending customer indistinguishable from an occasional one.
    * `avg_basket_size_6m` is **items per order**, not dollars (Lab 2 schema).
      Its denominator is guarded, so a customer with no orders in the last 180
      days gets 0.0 instead of dividing by zero.
    """
    columns = ["customer_id", "avg_order_value", "total_spend_90d",
               "total_lifetime_value", "avg_basket_size_6m"]

    if transactions is None or len(transactions) == 0:
        return _empty_featured_frame(columns)

    history = _observed(transactions, snapshot_date)
    if history.empty:
        return _empty_featured_frame(columns)

    cutoff = _as_date(snapshot_date)
    window_90 = cutoff - pd.Timedelta(days=90)
    window_180 = cutoff - pd.Timedelta(days=180)

    values = pd.to_numeric(history["order_value"], errors="coerce")
    items = pd.to_numeric(history.get("num_items"), errors="coerce")

    history = history.assign(_value=values, _items=items)
    grouped = history.groupby("customer_id")

    spend_90 = (
        history[history["_purchase_date"] > window_90]
        .groupby("customer_id")["_value"].sum()
    )
    in_180 = history[history["_purchase_date"] > window_180]
    items_180 = in_180.groupby("customer_id")["_items"].sum()
    orders_180 = in_180.groupby("customer_id").size()

    features = pd.DataFrame({
        "customer_id": grouped["_value"].mean().index,
        "avg_order_value": grouped["_value"].mean().to_numpy(),
        "total_lifetime_value": grouped["_value"].sum().to_numpy(),
    })
    features["total_spend_90d"] = (
        features["customer_id"].map(spend_90).fillna(0.0).astype("float64")
    )

    # Guarded denominator: no orders in 180 days -> 0.0, not NaN or inf.
    basket = items_180 / orders_180
    features["avg_basket_size_6m"] = (
        features["customer_id"].map(basket).fillna(0.0).astype("float64")
    )

    return features[columns]


# ── Behavioral ────────────────────────────────────────────────────────────────

def compute_behavioral_features(transactions, snapshot_date=FEATURE_CUTOFF):
    """How broadly and through which channel a customer shops.

    Columns produced:

      category_diversity_score   distinct real categories / 8
      online_to_store_ratio      fraction of orders placed online

    `unknown` is the imputed placeholder the Lab 2 transform writes for a
    missing category. It is excluded from the distinct count: counting it as a
    real category inflates the score, and on a customer with all eight real
    categories present it pushes the ratio above 1.0 -- which the [0, 1] gate in
    tests/test_data.py then fails on production data.
    """
    columns = ["customer_id", "category_diversity_score", "online_to_store_ratio"]

    if transactions is None or len(transactions) == 0:
        return _empty_featured_frame(columns)

    history = _observed(transactions, snapshot_date)
    if history.empty:
        return _empty_featured_frame(columns)

    categories = history.get("product_category")
    if categories is None:
        real_categories = pd.Series("", index=history.index)
    else:
        real_categories = categories.where(categories != "unknown", other=pd.NA)

    distinct_real = (
        history.assign(_category=real_categories)
        .groupby("customer_id")["_category"].nunique(dropna=True)
    )

    if "channel" in history.columns:
        is_online = (history["channel"] == "online").astype("float64")
        ratio = is_online.groupby(history["customer_id"]).mean()
    else:
        ratio = pd.Series(dtype="float64")

    features = pd.DataFrame({
        "customer_id": distinct_real.index,
        "category_diversity_score": (distinct_real / N_CATEGORIES).to_numpy(),
    })
    features["online_to_store_ratio"] = (
        features["customer_id"].map(ratio).fillna(0.0).astype("float64")
    )

    # Clamp for numerical safety only. A value above 1.0 here means the
    # 'unknown' exclusion broke; the tests assert the range, so clamping would
    # hide it. Keep the raw value and let the gate fail loudly.
    return features[columns]


# ── Derived columns ───────────────────────────────────────────────────────────

def assign_loyalty_tier(df: pd.DataFrame) -> pd.DataFrame:
    """Bucket `total_lifetime_value` into Bronze / Silver / Gold / Platinum.

    Bounds are half-open on the upper end, so 500 lands in Silver rather than
    Bronze. All four tiers must exist in the pipeline output; an empty tier
    means these thresholds or the lifetime-value aggregation is wrong.
    """
    ltv = pd.to_numeric(df["total_lifetime_value"], errors="coerce")

    tier = pd.Series("Platinum", index=df.index, dtype="object")
    tier = tier.mask(ltv < TIER_GOLD_MAX, "Gold")
    tier = tier.mask(ltv < TIER_SILVER_MAX, "Silver")
    tier = tier.mask(ltv < TIER_BRONZE_MAX, "Bronze")

    return df.assign(loyalty_tier=tier)


def compute_churn_risk_score(df: pd.DataFrame) -> pd.DataFrame:
    """Rule-based `churn_risk_score` in [0, 1]. This is NOT the label.

      High   (0.7-1.0): days_since_last_purchase > 60 and purchase_frequency_30d == 0
      Medium (0.4-0.7): days_since_last_purchase > 30
      Low    (0.0-0.4): otherwise

    Scaled within each band so the score does not collapse to three constants,
    then clamped to [0, 1]. Kept as the baseline the trained model has to beat:
    a model that cannot outperform three lines of rules has not earned its
    deployment.
    """
    recency = pd.to_numeric(df["days_since_last_purchase"], errors="coerce")
    freq_30d = pd.to_numeric(df["purchase_frequency_30d"], errors="coerce").fillna(0)

    high = 0.7 + 0.3 * np.minimum(1.0, (recency - 60) / 120.0)
    medium = 0.4 + 0.3 * ((recency - 30) / 30.0)
    low = 0.4 * (recency / 30.0)

    score = np.where(
        (recency > 60) & (freq_30d == 0),
        high,
        np.where(recency > 30, medium, low),
    )
    score = np.clip(np.asarray(score, dtype="float64"), 0.0, 1.0)

    return df.assign(churn_risk_score=score)


def attach_churn_label(features: pd.DataFrame, transactions,
                       snapshot_date=FEATURE_CUTOFF,
                       snapshot= SNAPSHOT) -> pd.DataFrame:
    """`churn_label = 1` if the customer bought nothing in `(T, SNAPSHOT]`.

    The label is derived only from the outcome window. It must never be
    computed from a feature: deriving it from recency would make the target a
    deterministic function of the input, the model would post a near-perfect
    AUC, and it would collapse in production. That failure mode is what
    `test_label_not_trivially_separable` exists to catch.
    """
    cutoff = _as_date(snapshot_date)
    end = _as_date(snapshot)

    if transactions is None or len(transactions) == 0:
        return features.assign(churn_label=1)

    dates = _purchase_dates(transactions)
    in_holdout = (dates > cutoff) & (dates <= end)
    buyers = set(transactions.loc[in_holdout, "customer_id"].dropna().unique())

    label = (
        ~features["customer_id"].isin(buyers)
    ).astype("int64")

    return features.assign(churn_label=label)


# ── The whole feature set ─────────────────────────────────────────────────────

def build_churn_feature_set(customers, transactions,
                            snapshot_date=FEATURE_CUTOFF,
                            snapshot=SNAPSHOT) -> pd.DataFrame:
    """Build the complete customer-level feature table.

    This is the pandas equivalent of the Glue job's `main()`: recency,
    frequency, monetary and behavioral features are computed from the
    observation window, joined onto the customer roster, then the derived
    columns (`loyalty_tier`, `churn_risk_score`, `churn_label`) are added.

    Parameters
    ----------
    customers
        Roster with at least `customer_id`. If it also carries `loyalty_tier`
        or `churn_label` those are treated as authoritative and kept, because
        the Lab 2 job already computed them (its label uses the same outcome
        window). Rows absent from the roster are not invented.
    transactions
        Processed-grain purchases. Anything dated after `snapshot_date` is
        ignored for features and used only to derive the label when the roster
        does not supply one.
    snapshot_date
        `T`, the feature cutoff. Defaults to the module constant, matching the
        Glue job. Never `today()`: features must not change between runs.
    snapshot
        End of the outcome window, used only for the label.

    Returns
    -------
    One row per customer in the roster, with no nulls in the feature columns.
    Customers with no purchases get recency 999 and zeros elsewhere, which is
    the documented null strategy -- see `compute_recency_features`.
    """
    if customers is None:
        roster = None
    else:
        roster = customers

    recency = compute_recency_features(transactions, snapshot_date, roster)
    frequency = compute_frequency_features(transactions, snapshot_date)
    monetary = compute_monetary_features(transactions, snapshot_date)
    behavioral = compute_behavioral_features(transactions, snapshot_date)

    # Outer joins, so a column that exists for some customers but not others
    # keeps its rows. Recency carries the roster when one was supplied.
    features = recency
    for part in (frequency, monetary, behavioral):
        if part.empty:
            continue
        features = part if features.empty else features.merge(
            part, on="customer_id", how="outer")

    # Fill anything the aggregates could not produce. With no transactions at
    # all every feature is legitimately zero except recency, which is maximally
    # lapsed.
    features["days_since_last_purchase"] = features[
        "days_since_last_purchase"].fillna(NO_PURCHASE_SENTINEL)
    for column in FEATURE_COLUMNS:
        if column not in features.columns:
            features[column] = 0.0
        features[column] = pd.to_numeric(features[column], errors="coerce").fillna(0.0)

    if roster is not None:
        keep = ["customer_id"]
        for extra in ("loyalty_tier", "churn_label"):
            if extra in roster.columns:
                keep.append(extra)
        features = roster[keep].merge(features, on="customer_id", how="left")
        features["days_since_last_purchase"] = features[
            "days_since_last_purchase"].fillna(NO_PURCHASE_SENTINEL)
        for column in FEATURE_COLUMNS:
            features[column] = pd.to_numeric(
                features[column], errors="coerce").fillna(0.0)

    # The roster's tier is authoritative when it has one: the Lab 2 job already
    # bucketed it, and re-deriving it here could disagree at a threshold.
    if "loyalty_tier" not in features.columns:
        features = assign_loyalty_tier(features)

    features = compute_churn_risk_score(features)

    if "churn_label" not in features.columns:
        features = attach_churn_label(features, transactions, snapshot_date, snapshot)
    features["churn_label"] = features["churn_label"].astype("int64")

    # Round exactly the columns the Glue job rounds, and with the same
    # HALF-UP semantics, so a comparison against the pipeline output is an
    # equality check rather than a tolerance game.
    for column in ROUNDED_COLUMNS:
        if column in features.columns:
            features[column] = _spark_round(features[column])

    ordered = ["customer_id"] + FEATURE_COLUMNS + [
        "loyalty_tier", "churn_risk_score", "churn_label"]
    ordered = [c for c in ordered if c in features.columns]
    return features[ordered].reset_index(drop=True)
