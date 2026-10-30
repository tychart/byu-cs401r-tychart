"""Your Lab 3 churn model, packaged for the Lab 4 pipeline.

The pipeline's training job runs train_sagemaker.py (beside this file; do not
edit it), which imports this module and calls train(). Everything the job needs
from you goes through the three names below.

Contract (train_sagemaker.py checks it in the first seconds of the job):

    FEATURE_COLUMNS   list[str]   model input columns, in order
    LABEL             str         "churn_label"
    train(df, seed=42) -> (xgboost.Booster, dict)

`df` is the full labeled feature table: every column of the Lab 2 output,
including `loyalty_tier` for slice evaluation. It is already loaded. Do not
query Athena or the Feature Store from here; the training container stages the
data for you and has no business making service calls for its input.

The metrics dict includes the four numbers the CI gate in tests/test_model.py
reads, plus the per-tier slice results Task 1's fairness test needs:

    precision_top10, recall_top10      gated at 0.50 / 0.25
    lift_ci_low, lift_ci_high          paired bootstrap 95% CI on AUC lift over
                                       the recency-only baseline; lift_ci_low > 0
    slices                             per-loyalty-tier n, positives, auc,
                                       recall_top10, recall_gap_vs_aggregate

This file is a copy of the graded Lab 3 implementation
(`churn_training_skeleton.py`, run name `xgb-final`: max_depth 6, eta 0.1,
num_boost_round 200, 70/30 stratified split, seed 42), with the Athena loader,
MLflow tracking, plots and model registration removed. Only the functions the
training container needs are here: `models/churn/` is the only directory
uploaded to the job, so nothing may be imported from the repo root.

What runs in the container: the SageMaker XGBoost 1.7-1 image ships pandas,
numpy, scikit-learn, xgboost and boto3. It does NOT ship mlflow or sagemaker,
so they are deliberately not imported here. MLflow tracking stays in the Lab 3
script.

Test it locally before pushing:

    python models/churn/train_sagemaker.py \
        --train-channel <dir containing your features CSV or Parquet> \
        --model-dir /tmp/model --output-data-dir /tmp/out
"""

# Keeps Lab 3 annotations like `-> tuple[np.ndarray, np.ndarray]` from being
# evaluated, whatever Python the training container runs.
from __future__ import annotations

from datetime import datetime

import numpy as np
import pandas as pd
import xgboost as xgb
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import train_test_split

# Must match the columns your Lab 3 model was trained on, in the same order.
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

LABEL = "churn_label"
SLICE_COLUMN = "loyalty_tier"
BASELINE_FEATURE = "days_since_last_purchase"

# Lab 3 graded run (xgb-final) parameters. The recency baseline's parameters are
# fixed on purpose: it is a reference point, not a model under study, and it
# must score identically on every run for the paired lift CI to mean the same
# thing run to run.
CHURN_PARAMS = {
    # eval_metric ORDER MATTERS: XGBoost early-stops on the LAST metric. With
    # ["auc", "logloss"] the model early-stopped on reweighted logloss, ran the
    # full 200 rounds instead of ~31, and lost the gate on 28% of splits.
    "objective": "binary:logistic",
    "eval_metric": ["logloss", "auc"],
    "max_depth": 6,
    "eta": 0.1,
    "min_child_weight": 5,
    "subsample": 0.8,
    "colsample_bytree": 0.8,
    "verbosity": 1,
}
BASELINE_PARAMS = {
    "objective": "binary:logistic",
    "eval_metric": "auc",
    "max_depth": 4,
    "eta": 0.1,
    "subsample": 0.9,
    "colsample_bytree": 0.9,
}
NUM_BOOST_ROUND = 200
BASELINE_ROUNDS = 200
EARLY_STOPPING_ROUNDS = 20
TEST_SIZE = 0.30

EVAL_THRESHOLDS = {
    "precision_top10": 0.50,
    "recall_top10": 0.25,
}

BOOTSTRAP_N = 2000
BOOTSTRAP_SEED = 42

# A tier-level number is only worth acting on if enough of the minority class
# stands behind it. On this dataset the validation split holds ~22 Platinum
# positives, so Platinum trips this.
MIN_SLICE_N = 100
MIN_SLICE_POSITIVES = 25
RECALL_DROP_FLAG = 0.10


# ── Preprocessing ─────────────────────────────────────────────────────────────

def preprocess_features(df: pd.DataFrame) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Return (X, y, tiers), row-aligned, with NaNs kept for XGBoost.

    No imputation: XGBoost learns a default direction for missing values, while
    median imputation invents data and a -1 sentinel writes an impossible value
    into a continuous column. The Lab 2 job asserts zero nulls before writing,
    so this is a safety net, not a routine transform.
    """
    df = df.dropna(subset=[LABEL])

    feature_frame = df[FEATURE_COLUMNS].astype("float64")
    n_missing = int(feature_frame.isna().sum().sum())
    print(f"  Missing feature values: {n_missing} (kept as NaN for XGBoost)")

    X = feature_frame.values
    y = df[LABEL].values.astype(int)

    if SLICE_COLUMN in df.columns:
        # .to_numpy(dtype=object), not .values: under pandas 3 .values can be an
        # Arrow-backed array that train_test_split cannot index.
        tiers = df[SLICE_COLUMN].to_numpy(dtype=object)
    else:
        print(f"WARNING: '{SLICE_COLUMN}' is absent — slice evaluation will "
              f"report a single 'unknown' tier")
        tiers = np.full(len(df), "unknown", dtype=object)

    print(f"  Positive class rate: {y.mean():.1%}")
    print(f"  Feature matrix shape: {X.shape}")
    return X, y, tiers


# ── Model training ────────────────────────────────────────────────────────────

def train_model(X_train, y_train, X_val, y_val, seed: int = 42) -> xgb.Booster:
    """Train the XGBoost churn model, early-stopping on validation AUC."""
    dtrain = xgb.DMatrix(X_train, label=y_train, feature_names=FEATURE_COLUMNS)
    dval = xgb.DMatrix(X_val, label=y_val, feature_names=FEATURE_COLUMNS)

    # Class imbalance, from the TRAINING split, not hardcoded. The reference
    # dataset is 22.0% churners, giving (1 - 0.220) / 0.220 = 3.545.
    spw = float((y_train == 0).sum() / max((y_train == 1).sum(), 1))

    params = dict(CHURN_PARAMS, scale_pos_weight=spw, seed=seed)
    print(f"  Training XGBoost: depth={params['max_depth']} eta={params['eta']} "
          f"rounds={NUM_BOOST_ROUND} scale_pos_weight={spw:.3f}")

    return xgb.train(
        params=params,
        dtrain=dtrain,
        num_boost_round=NUM_BOOST_ROUND,
        evals=[(dtrain, "train"), (dval, "validation")],
        early_stopping_rounds=EARLY_STOPPING_ROUNDS,
        verbose_eval=25,
    )


def train_recency_baseline(X_train, y_train, X_val) -> np.ndarray:
    """Score the validation split with a model over recency ALONE.

    Deliberately not a constant predictor: a constant has AUC exactly 0.5, so
    "beating" it proves only that the model is better than a coin flip. The
    question is whether the features beat the rule the business already has for
    free — contact whoever has not purchased in a while.
    """
    i = FEATURE_COLUMNS.index(BASELINE_FEATURE)
    dtr = xgb.DMatrix(X_train[:, [i]], label=y_train,
                      feature_names=[BASELINE_FEATURE])
    dva = xgb.DMatrix(X_val[:, [i]], feature_names=[BASELINE_FEATURE])
    spw = float((y_train == 0).sum() / max((y_train == 1).sum(), 1))
    params = dict(BASELINE_PARAMS, scale_pos_weight=spw, seed=BOOTSTRAP_SEED)
    return xgb.train(params, dtr, num_boost_round=BASELINE_ROUNDS).predict(dva)


# ── Evaluation ────────────────────────────────────────────────────────────────

def top10_mask(proba: np.ndarray) -> np.ndarray:
    """The ONE global top-10% selection rule.

    evaluate_model() and evaluate_slices() share it so per-tier recalls
    decompose the aggregate exactly rather than measuring something adjacent.
    """
    return proba >= np.percentile(proba, 90)


def bootstrap_lift_ci(y_true, proba, baseline_proba,
                      n: int = BOOTSTRAP_N, seed: int = BOOTSTRAP_SEED,
                      alpha: float = 0.05) -> tuple[float, float]:
    """Percentile CI for (model AUC − baseline AUC), resampling the val set.

    PAIRED: each replicate resamples indices once and scores BOTH models on
    those rows, preserving the correlation between them. Resampling separately
    would inflate the interval and make a real improvement look inconclusive.
    """
    rng = np.random.default_rng(seed)
    y_true = np.asarray(y_true)
    idx = np.arange(len(y_true))
    diffs = []
    for _ in range(n):
        s = rng.choice(idx, size=len(idx), replace=True)
        ys = y_true[s]
        if len(np.unique(ys)) < 2:
            continue
        diffs.append(roc_auc_score(ys, proba[s]) - roc_auc_score(ys, baseline_proba[s]))
    if len(diffs) < n // 2:
        raise ValueError(
            "Too few usable bootstrap replicates to form a confidence interval. "
            "The validation set is too small or too imbalanced to support this gate.")
    d = np.sort(diffs)
    return float(np.quantile(d, alpha / 2)), float(np.quantile(d, 1 - alpha / 2))


def evaluate_model(model, X_val, y_val, baseline_proba) -> dict:
    """Compute metrics and RAISE if a gate fails.

    Keeping the raise is load-bearing: a model that misses a gate must fail the
    training step so it is never registered. There is no absolute AUC threshold
    — AUC is reported, not gated — because a 0.72 bar failed the reference model
    on 58% of 200 splits of the same data.
    """
    y_pred_proba = model.predict(xgb.DMatrix(X_val, feature_names=FEATURE_COLUMNS))

    auc_roc = roc_auc_score(y_val, y_pred_proba)

    selected = top10_mask(y_pred_proba)
    precision_top10 = y_val[selected].mean() if selected.sum() > 0 else 0.0
    recall_top10 = y_val[selected].sum() / y_val.sum() if y_val.sum() > 0 else 0.0

    baseline_auc = roc_auc_score(y_val, baseline_proba)
    auc_vs_baseline = auc_roc - baseline_auc
    lift_ci_low, lift_ci_high = bootstrap_lift_ci(y_val, y_pred_proba, baseline_proba)

    metrics = {
        "auc_roc": round(float(auc_roc), 4),
        "precision_top10": round(float(precision_top10), 4),
        "recall_top10": round(float(recall_top10), 4),
        "auc_vs_baseline": round(float(auc_vs_baseline), 4),
        "baseline_auc": round(float(baseline_auc), 4),
        "lift_ci_low": round(float(lift_ci_low), 4),
        "lift_ci_high": round(float(lift_ci_high), 4),
        "positive_rate_val": round(float(y_val.mean()), 4),
        "n_val_samples": int(len(y_val)),
        "eval_timestamp": datetime.utcnow().isoformat(),
    }

    print("\n── Evaluation Results ──────────────────────────────")
    failures = []
    for metric, threshold in EVAL_THRESHOLDS.items():
        value = metrics[metric]
        status = "PASS" if value >= threshold else "FAIL"
        print(f"  {metric:25s}: {value:.4f}  (threshold {threshold:.4f})  {status}")
        if value < threshold:
            failures.append(f"{metric}={value:.4f} < {threshold}")

    ci_status = "PASS" if lift_ci_low > 0 else "FAIL"
    print(f"  {'auc_lift 95% CI':25s}: [{lift_ci_low:.4f}, {lift_ci_high:.4f}]"
          f"  (must exclude 0)  {ci_status}")
    if lift_ci_low <= 0:
        failures.append(
            f"auc_lift 95% CI [{lift_ci_low:.4f}, {lift_ci_high:.4f}] includes "
            f"zero - no evidence the model beats the recency-only baseline")

    if failures:
        raise ValueError(
            f"Model failed evaluation thresholds: {'; '.join(failures)}. "
            f"Do not promote to Model Registry.")

    print("  All thresholds passed")
    return metrics


def evaluate_slices(model, X_val, y_val, slice_column) -> dict:
    """Per-loyalty-tier n, positives, AUC and recall@10%.

    Two questions, deliberately kept apart:
      * auc          — can the model rank this tier's customers on their own?
      * recall_top10 — of this tier's churners, how many land in the ONE global
                       top-10% list the retention team works?
    Every entry carries n and positives: a slice metric without them is
    unfalsifiable, and ~2 positives can swing AUC from 0.0 to 1.0.
    """
    y_pred_proba = model.predict(xgb.DMatrix(X_val, feature_names=FEATURE_COLUMNS))
    y_val = np.asarray(y_val)
    slice_column = np.asarray(slice_column)

    global_top10 = top10_mask(y_pred_proba)
    total_positives = int(y_val.sum())
    aggregate_recall = (
        float(y_val[global_top10].sum() / total_positives) if total_positives else 0.0
    )

    results = {
        "ALL": {
            "n": int(len(y_val)),
            "positives": total_positives,
            "auc": round(float(roc_auc_score(y_val, y_pred_proba)), 4),
            "recall_top10": round(aggregate_recall, 4),
            "recall_gap_vs_aggregate": 0.0,
            "recall_drop_flag": False,
            "too_small": False,
        }
    }

    for slice_value in sorted(pd.unique(slice_column), key=str):
        in_slice = slice_column == slice_value
        n = int(in_slice.sum())
        positives = int(y_val[in_slice].sum())

        auc_slice = (
            round(float(roc_auc_score(y_val[in_slice], y_pred_proba[in_slice])), 4)
            if 0 < positives < n else None
        )
        recall_slice = (
            round(float(y_val[in_slice & global_top10].sum() / positives), 4)
            if positives else None
        )

        results[str(slice_value)] = {
            "n": n,
            "positives": positives,
            "auc": auc_slice,
            "recall_top10": recall_slice,
            "recall_gap_vs_aggregate": (
                round(recall_slice - aggregate_recall, 4)
                if recall_slice is not None else None
            ),
            "recall_drop_flag": (
                recall_slice is not None
                and recall_slice < aggregate_recall - RECALL_DROP_FLAG
            ),
            "too_small": n < MIN_SLICE_N or positives < MIN_SLICE_POSITIVES,
        }

    return results


# ── The pipeline contract ─────────────────────────────────────────────────────

def train(df: pd.DataFrame, seed: int = 42):
    """Train the churn model on `df` and return (booster, metrics).

    Steps, in Lab 3's order:
      1. X, y, tiers from FEATURE_COLUMNS / LABEL (NaNs kept for XGBoost)
      2. 70/30 stratified split; tiers ride through the same indices
      3. XGBoost model, early-stopping on validation AUC
      4. recency-only baseline, scored on the same validation rows
      5. evaluate_model() — raises on a failed gate, so a model that misses it
         is never registered
      6. per-tier slice evaluation, carried in the metrics dict for the
         fairness test and the approver
    """
    print(f"Training on {len(df):,} rows")
    X, y, tiers = preprocess_features(df)

    X_train, X_val, y_train, y_val, _tier_train, tier_val = train_test_split(
        X, y, tiers, test_size=TEST_SIZE, random_state=seed, stratify=y)
    print(f"  Train: {len(X_train):,} | Validation: {len(X_val):,}")

    model = train_model(X_train, y_train, X_val, y_val, seed=seed)

    baseline_proba = train_recency_baseline(X_train, y_train, X_val)
    metrics = evaluate_model(model, X_val, y_val, baseline_proba)

    slice_results = evaluate_slices(model, X_val, y_val, tier_val)
    metrics["slices"] = slice_results
    metrics["flagging_tiers"] = sorted(
        tier for tier, m in slice_results.items()
        if tier != "ALL" and m["recall_drop_flag"])

    print("\n── Slice Evaluation ────────────────────────────────")
    for tier, m in slice_results.items():
        auc = "n/a" if m["auc"] is None else f"{m['auc']:.4f}"
        rec = "n/a" if m["recall_top10"] is None else f"{m['recall_top10']:.4f}"
        flags = []
        if m["too_small"] and tier != "ALL":
            flags.append("too small")
        if m["recall_drop_flag"]:
            flags.append(">10pp below aggregate")
        print(f"  {tier:<10} n={m['n']:>5} pos={m['positives']:>4} "
              f"auc={auc:>6} recall@10={rec:>6} {' '.join(flags)}")

    return model, metrics
