"""
NorthStar Retail — Churn Prediction Training Script (Skeleton)
CS 401R Lab 3 Starter Kit

This script is the SageMaker XGBoost training entry point for the NorthStar
churn prediction model. It reads features from the SageMaker Feature Store,
trains an XGBoost classifier, tracks the run in a SageMaker MLflow App, and
registers the model in the Model Registry.

Experiment tracking needs two packages that are NOT in the training container:

    pip install mlflow sagemaker-mlflow

`sagemaker-mlflow` is the SigV4 auth plugin for arn:aws:sagemaker:... tracking
URIs. Install `mlflow` alone and you get a connection error that never mentions
credentials. See track_run() for the cost warning about the OTHER MLflow
product -- read it before you create anything.

Usage (local testing):
    python churn_training_skeleton.py \
        --feature-group-name northstar-dev-customer-features \
        --artifacts-bucket northstar-dev-data-<account> \
        --max-depth 6 --eta 0.1 --num-round 200 \
        --mlflow-arn arn:aws:sagemaker:us-east-1:<account>:mlflow-app/app-XXXX \
        --run-name xgb-depth6-eta0.1

Usage (SageMaker training job — parameters passed via hyperparameter dict):
    Configured via the SageMaker Python SDK Estimator.
"""

import argparse
import json
import os
import pickle
import tarfile
from datetime import datetime, timezone

import boto3
import numpy as np
import pandas as pd

# SageMaker imports — available in SageMaker training containers.
#
# The two failure modes below are different problems and used to produce the
# same message. sagemaker 3.x REMOVED the feature_store package, so on a 3.x
# install the SDK imports fine and only the second line fails. Reporting that
# as "sagemaker not available" sends you looking for a missing install that is
# not missing. Pin sagemaker<3.0.0 (see requirements.txt, defect 55).
try:
    import sagemaker
except ImportError:
    sagemaker = None
    SAGEMAKER_AVAILABLE = False
    print("WARNING: sagemaker not installed — running in local test mode")
else:
    try:
        from sagemaker.feature_store.feature_group import FeatureGroup
        from sagemaker.session import Session
        SAGEMAKER_AVAILABLE = True
    except ImportError:
        SAGEMAKER_AVAILABLE = False
        print("WARNING: sagemaker is installed but has no feature_store module. "
              "This is sagemaker 3.x, which dropped it. Run "
              "`pip install 'sagemaker>=2.200.0,<3.0.0'` — the Feature Store "
              "path in this script cannot work on 3.x.")

try:
    import xgboost as xgb
    XGBOOST_AVAILABLE = True
except ImportError:
    raise ImportError("xgboost is required: pip install xgboost")

from sklearn.metrics import (auc, classification_report, confusion_matrix,
                              precision_recall_curve, roc_auc_score)
from sklearn.model_selection import train_test_split

# ── Argument Parsing ───────────────────────────────────────────────────────────
# SageMaker passes hyperparameters as CLI arguments.

def parse_args():
    parser = argparse.ArgumentParser(description="NorthStar churn prediction training")

    # Data configuration
    # Names come from Lab 2's Terraform: `terraform output -raw feature_group_name`
    # and `terraform output -raw s3_bucket_name`. Do not invent new ones.
    parser.add_argument("--feature-group-name", type=str,
                        default="northstar-dev-customer-features",
                        help="SageMaker Feature Store feature group name (Lab 2 output)")
    # These dates bound the INGEST batch, not the feature window. Lab 2 stamps
    # event_time with the wall-clock time its Glue job ran (time.time()), not
    # with the feature cutoff T = 2026-04-01 -- T was already enforced when the
    # features were computed. A window that ends before your Lab 2 run (the old
    # default here was 2026-06-01) matches zero rows. These defaults match the
    # reference implementation and cover any Lab 2 run during the semester.
    parser.add_argument("--training-start-date", type=str, default="2026-01-01",
                        help="Earliest Lab 2 ingest date to include (YYYY-MM-DD)")
    parser.add_argument("--training-end-date", type=str, default="2027-01-01",
                        help="Latest Lab 2 ingest date to include (YYYY-MM-DD)")
    parser.add_argument("--artifacts-bucket", type=str, required=True,
                        help="Your Lab 1 data bucket, northstar-dev-data-<account>. "
                             "Athena results and model artifacts go under its artifacts/ "
                             "prefix, the only prefix your MLEngineer role can write")
    parser.add_argument("--local-data-path", type=str, default=None,
                        help="Path to local feature CSV for development testing (bypasses Feature Store)")

    # XGBoost hyperparameters
    parser.add_argument("--max-depth", type=int, default=6)
    parser.add_argument("--eta", type=float, default=0.1)
    parser.add_argument("--num-round", type=int, default=200)
    parser.add_argument("--min-child-weight", type=int, default=5)
    parser.add_argument("--subsample", type=float, default=0.8)
    parser.add_argument("--colsample-bytree", type=float, default=0.8)
    parser.add_argument("--scale-pos-weight", type=float, default=None,
                        help=(
                            "XGBoost positive-class weight. Leave unset and it is computed "
                            "from YOUR training split as negatives/positives, which is what "
                            "you want. The reference 10,000-customer dataset is 22.0%% "
                            "churners, giving (1 - 0.220) / 0.220 = 3.545. Passing a value "
                            "tuned for a different class balance will quietly skew your "
                            "precision/recall trade-off, so only override this deliberately."
                        ))
    # Experiment tracking (Task 1, 5 points)
    parser.add_argument("--mlflow-arn", type=str,
                        default=os.environ.get("MLFLOW_APP_ARN"),
                        help=(
                            "ARN of your SageMaker MLflow APP, e.g. "
                            "arn:aws:sagemaker:us-east-1:<account>:mlflow-app/app-XXXX. "
                            "Create it once with `aws sagemaker create-mlflow-app`. "
                            "This is NOT an MLflow Tracking Server -- see the warning "
                            "on track_run() below. Omit to skip tracking."
                        ))
    parser.add_argument("--mlflow-experiment", type=str, default="northstar-churn",
                        help="MLflow experiment name; runs group under this")
    parser.add_argument("--run-name", type=str, default=None,
                        help="Name for this run. Make it descriptive -- 'run3' tells "
                             "you nothing three weeks later.")

    parser.add_argument("--model-dir", type=str,
                        default=os.environ.get("SM_MODEL_DIR", "./model"))
    parser.add_argument("--output-data-dir", type=str,
                        default=os.environ.get("SM_OUTPUT_DATA_DIR", "./output"))

    return parser.parse_args()


# ── Feature Store Loading ──────────────────────────────────────────────────────

# These are exactly the features your Lab 2 pipeline wrote to the Feature
# Group. If a name here does not match your feature group, the Athena query
# below will fail - check `aws sagemaker describe-feature-group` first.
#
# Note what is NOT in this list: churn_label (the target) and customer_id
# (an identifier, not a signal). Including either as an input is leakage.
FEATURE_COLUMNS = [
    # Recency and tenure
    "days_since_last_purchase",
    "customer_tenure_days",
    # Frequency
    "purchase_frequency_30d",
    "purchase_frequency_90d",
    "purchase_frequency_180d",
    # Monetary
    "avg_order_value",
    "total_spend_90d",
    "total_lifetime_value",
    "avg_basket_size_6m",
    # Behavioural - these are the features that catch churners who still
    # look active on recency alone. Drop them and your model collapses
    # toward the recency-only baseline.
    "category_diversity_score",
    "online_to_store_ratio",
]

# churn_risk_score is available in the feature group but deliberately excluded
# here: it is a pure recency heuristic and doubles as the baseline you must
# beat. If you add it, report your metrics both with and without it.
BASELINE_COLUMN = "churn_risk_score"

# The recency-only baseline model uses just this one feature. Task 1 requires
# you to train it and show your full model beats it by a margin whose 95%
# confidence interval excludes zero. There is no fixed AUC-lift threshold: a
# ">= 0.03 lift" gate lived here until 2026-08-02 and was removed because 0.03
# is smaller than the metric's own run-to-run standard deviation, so it failed
# on 21% of splits regardless of model quality. See EVAL_THRESHOLDS below.
BASELINE_FEATURE = "days_since_last_purchase"

LABEL_COLUMN = "churn_label"

# Not a feature. This is the column Task 1's slice evaluation groups by, so it
# has to come back from the query even though it never enters the model. Keep it
# out of FEATURE_COLUMNS: loyalty_tier correlates with spend, and feeding it in
# both leaks and makes the per-tier fairness check circular.
SLICE_COLUMN = "loyalty_tier"


def load_features_from_feature_store(feature_group_name: str,
                                     start_date: str,
                                     end_date: str,
                                     artifacts_bucket: str) -> pd.DataFrame:
    """
    Load features from the SageMaker Feature Store offline store using Athena.

    Args:
        feature_group_name: your Lab 2 feature group
        start_date, end_date: ISO dates (YYYY-MM-DD) bounding the event_time range
        artifacts_bucket: S3 bucket that Athena writes its result set to. Athena
            will not run a query without an output location, so this has to be
            threaded in from --artifacts-bucket rather than assumed.

    Reads the Feature Store offline store through Athena. Reference:
    https://docs.aws.amazon.com/sagemaker/latest/dg/feature-store-use-with-studio.html
    """
    if not SAGEMAKER_AVAILABLE:
        raise RuntimeError("SageMaker SDK not available - use --local-data-path for local testing")

    # event_time was written as Fractional (epoch seconds) by the Lab 2 job, so
    # the date bounds must be converted before comparison. Passing ISO strings
    # straight into the query fails with TYPE_MISMATCH rather than returning
    # rows, so at least the failure is loud.
    start_epoch = datetime.strptime(start_date, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp()
    end_epoch = datetime.strptime(end_date, "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp()

    session = Session()
    feature_group = FeatureGroup(name=feature_group_name, sagemaker_session=session)

    # Three things in the query below are easy to get wrong, so read them:
    #
    # 1. event_time is Fractional - Unix epoch SECONDS, not an ISO string.
    #    Comparing it to '2026-04-01' fails the query outright with:
    #      TYPE_MISMATCH: Cannot check if double is BETWEEN varchar(10)...
    #    Convert your date bounds to epoch seconds before substituting them.
    #
    # 2. The offline store is append-only. Re-running the Lab 2 feature job
    #    writes a SECOND record for every customer, and a naive SELECT then
    #    returns duplicate customers with stale feature values. Deduplicate
    #    with a window function keyed on customer_id, keeping the most recent
    #    event_time. Filtering on a global MAX(write_time) does NOT work -
    #    it keeps only the customers written in the final microsecond.
    #
    #    The offline store also soft-deletes: rows carry is_deleted, and
    #    deleted records must be excluded.
    #
    # 3. The outer SELECT must ORDER BY customer_id, and this is the one people
    #    skip because it looks cosmetic. It is not. Athena parallelises the scan
    #    across the offline store's Parquet objects and returns rows in whatever
    #    order the splits happen to finish, which varies from run to run.
    #    train_test_split(random_state=42) is deterministic only for a GIVEN row
    #    order -- so without ORDER BY, the identical data produces a different
    #    train/test split, and therefore different metrics, on every single run.
    #
    #    This was measured, not theorised: four runs on byte-identical data
    #    produced AUC between 0.7276 and 0.7431, and a Platinum-slice AUC
    #    between 0.430 and 0.700. An entire "the model is worse than random on
    #    your best customers" finding turned out to be an artefact of row order.
    #
    #    The rn = 1 filter guarantees customer_id is unique here, so ordering on
    #    it is a TOTAL order and the pipeline becomes reproducible.
    #
    #    If your metrics move between runs and your data did not, this is why.

    #    loyalty_tier is selected but is NOT in FEATURE_COLUMNS, and that is
    #    deliberate. It is not an input to the model - it is the column Task 1's
    #    slice evaluation groups by. Keep it out of the feature matrix (see
    #    preprocess_features, which selects FEATURE_COLUMNS explicitly) and
    #    carry it alongside X and y through the split so each row's prediction
    #    can still be attributed to a tier:
    #
    #        X_train, X_val, y_train, y_val, tier_train, tier_val = \
    #            train_test_split(X, y, df[SLICE_COLUMN], test_size=0.30,
    #                             random_state=42, stratify=y)
    #
    #    Split X and y without it and you cannot line the tiers back up.

    query = feature_group.athena_query()
    query_string = f"""
        WITH ranked AS (
            SELECT
                customer_id,
                {", ".join(FEATURE_COLUMNS)},
                {LABEL_COLUMN},
                {SLICE_COLUMN},
                event_time,
                ROW_NUMBER() OVER (
                    PARTITION BY customer_id
                    ORDER BY event_time DESC, write_time DESC
                ) AS rn
            FROM "{query.table_name}"
            WHERE event_time BETWEEN {start_epoch} AND {end_epoch}
              AND NOT is_deleted
        )
        SELECT
            customer_id,
            {", ".join(FEATURE_COLUMNS)},
            {LABEL_COLUMN},
            {SLICE_COLUMN}
        FROM ranked
        WHERE rn = 1
        ORDER BY customer_id
    """

    # query.run() starts the query and returns immediately; the id is available
    # straight away, and the result only after wait().
    output_location = f"s3://{artifacts_bucket}/artifacts/athena-results/"
    query.run(query_string=query_string, output_location=output_location)

    # This line is printed BEFORE wait(), and in exactly this shape: the Lab 3
    # evidence script regex-matches `Athena QueryExecutionId:` and then looks the
    # id up in Athena to prove the graded run read the Feature Store offline
    # store rather than a local CSV. No line, no 5 points.
    query_execution_id = query.get_query_execution()["QueryExecution"]["QueryExecutionId"]
    print(f"Athena QueryExecutionId: {query_execution_id}")
    print(f"  {query.database}.{query.table_name} | event_time {start_date}..{end_date} "
          f"| results -> {output_location}")

    query.wait()
    df = query.as_dataframe()

    print(f"  Loaded {len(df):,} rows / {df['customer_id'].nunique():,} unique customers")
    return df


def load_features_local(path: str) -> pd.DataFrame:
    """Load features from a local CSV file (development mode)."""
    print(f"Loading features from local file: {path}")
    df = pd.read_csv(path)
    missing = [c for c in FEATURE_COLUMNS + [LABEL_COLUMN] if c not in df.columns]
    if missing:
        raise ValueError(f"Local data missing required columns: {missing}")
    # Not fatal - the model trains fine without it - but Task 1's slice
    # evaluation cannot be done at all, so fail the task rather than the run.
    if SLICE_COLUMN not in df.columns:
        print(f"WARNING: '{SLICE_COLUMN}' not in local data — Task 1 slice "
              f"evaluation will not be possible with this file")
    return df


# ── Feature Preprocessing ──────────────────────────────────────────────────────

def preprocess_features(df: pd.DataFrame) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """
    Clean and prepare features for XGBoost training.

    Returns (X, y, slices): the feature matrix, the 0/1 label vector, and the
    loyalty_tier of each row. The slice column is returned from here rather than
    re-read from df in main() so that it stays row-aligned with X after the
    label dropna below.
    """
    print(f"Preprocessing {len(df):,} samples...")

    # Drop rows where label is missing
    df = df.dropna(subset=[LABEL_COLUMN])

    # ── Imputation strategy: NONE. Missing values stay NaN. ───────────────────
    # XGBoost is sparsity-aware: at every split it learns a default direction for
    # missing values, so a NaN is information the model can use rather than a
    # hole to paper over. The alternatives are worse for these features:
    #
    #   * median imputation assumes the value is missing at random and pulls
    #     every imputed row toward the centre of the distribution, inventing
    #     data that was never observed.
    #   * a -1 sentinel (the starter kit's default) writes a value no real record
    #     can hold into a column the model treats as continuous, so a missing
    #     online_to_store_ratio becomes "even less online than 0.0".
    #
    # In practice this path never fires: the Lab 2 feature job asserts zero nulls
    # before it writes, verify-lab2.sh re-checks it, and the offline store holds
    # 0 nulls across all 14 features. It is a safety net against an upstream
    # regression, not a routine transform -- so the count is printed, to make a
    # surprise visible in the log rather than silent.
    feature_frame = df[FEATURE_COLUMNS].astype("float64")
    n_missing = int(feature_frame.isna().sum().sum())
    print(f"  Missing feature values: {n_missing} (kept as NaN for XGBoost)")

    X = feature_frame.values
    y = df[LABEL_COLUMN].values.astype(int)

    # loyalty_tier is carried beside X, never inside it: it correlates with spend,
    # so feeding it in would both leak and make the per-tier fairness check
    # circular. It is split alongside X and y so each validation row's prediction
    # can still be attributed to a tier.
    if SLICE_COLUMN in df.columns:
        slices = df[SLICE_COLUMN].to_numpy()
    else:
        print(f"WARNING: '{SLICE_COLUMN}' is absent -- slice evaluation will "
              f"report a single 'unknown' tier")
        slices = np.full(len(df), "unknown", dtype=object)

    print(f"  Positive class rate: {y.mean():.1%}")
    print(f"  Feature matrix shape: {X.shape}")

    return X, y, slices


# ── Model Training ─────────────────────────────────────────────────────────────

def train_model(X_train: np.ndarray,
                y_train: np.ndarray,
                X_val: np.ndarray,
                y_val: np.ndarray,
                args) -> xgb.Booster:
    """Train the XGBoost churn model."""

    dtrain = xgb.DMatrix(X_train, label=y_train, feature_names=FEATURE_COLUMNS)
    dval = xgb.DMatrix(X_val, label=y_val, feature_names=FEATURE_COLUMNS)

    # Class imbalance, computed from the training split rather than hardcoded.
    # On the reference dataset this lands at 3.545.
    spw = (args.scale_pos_weight if args.scale_pos_weight is not None
           else float((y_train == 0).sum() / max((y_train == 1).sum(), 1)))

    # Record the RESOLVED value so track_run() can log what was actually used.
    # Logging args.scale_pos_weight instead would log None on every run that
    # let it compute itself -- which is most of them -- and your MLflow
    # comparison would be missing the one parameter most likely to explain a
    # precision/recall difference between runs.
    args.resolved_scale_pos_weight = spw

    params = {
        # eval_metric ORDER MATTERS. XGBoost early-stops on the LAST metric in
        # this list, not the first. This used to read ["auc", "logloss"], which
        # silently made logloss the early-stopping criterion: under
        # scale_pos_weight the reweighted logloss keeps improving long after
        # ranking quality peaks, so training ran the full 200 rounds instead of
        # stopping near round 31 and validation AUC came out 0.7603 instead of
        # 0.7822. Measured across 50 splits, that cost the model the promotion
        # gate on 28% of them -- a student doing everything right was told their
        # features did not beat recency. Keep "auc" last (defect 49).
        "objective": "binary:logistic",
        "eval_metric": ["logloss", "auc"],
        "max_depth": args.max_depth,
        "eta": args.eta,
        "min_child_weight": args.min_child_weight,
        "subsample": args.subsample,
        "colsample_bytree": args.colsample_bytree,
        "scale_pos_weight": spw,
        "seed": 42,
        "verbosity": 1,
    }

    print(f"\nTraining XGBoost with params: {json.dumps(params, indent=2)}")

    model = xgb.train(
        params=params,
        dtrain=dtrain,
        num_boost_round=args.num_round,
        evals=[(dtrain, "train"), (dval, "validation")],
        early_stopping_rounds=20,
        verbose_eval=25,
    )

    return model


# ── Evaluation ─────────────────────────────────────────────────────────────────

EVAL_THRESHOLDS = {
    "precision_top10":   0.50,   # Minimum precision @ top 10% scored customers
    "recall_top10":      0.25,   # Minimum recall @ top 10% scored customers
    # Note the recall ceiling: with ~22% positives, targeting the top 10% of
    # customers caps achievable recall near 0.45. Hitting 0.25 means capturing
    # roughly half of what is reachable within that contact budget.
}

# There is deliberately NO absolute AUC threshold. One used to live here
# (auc_roc >= 0.72) and it was removed on 2026-08-02: measured across 200
# random train/test splits of the same data, the reference model fell below
# 0.72 on 58% of them. A gate the reference clears by luck of the shuffle
# grades your random seed, not your model. Report AUC; do not gate on it.
#
# The baseline gate is an INTERVAL, not a threshold: the 95% CI on
# (your AUC - recency-only baseline AUC) must exclude zero.
# BASELINE_FEATURE is defined once, near FEATURE_COLUMNS above.
BOOTSTRAP_N = 2000
BOOTSTRAP_SEED = 42


def top10_mask(proba: np.ndarray) -> np.ndarray:
    """The ONE global top-10% selection rule, shared by every caller.

    evaluate_model() scores precision/recall on it, and evaluate_slices() reuses
    it per tier. That sharing is deliberate: it makes the per-tier recalls
    decompose the aggregate exactly. If the two drifted apart, the slice numbers
    would stop summing to the headline and the "10pp below aggregate" flag would
    be comparing two different contact policies.
    """
    return proba >= np.percentile(proba, 90)


def train_recency_baseline(X_train: np.ndarray,
                           y_train: np.ndarray,
                           X_val: np.ndarray) -> np.ndarray:
    """Train the recency-only baseline and score the validation split.

    The baseline is a model over `days_since_last_purchase` ALONE, trained on
    the same training rows and scored on the same validation rows as the full
    model. That is what makes the comparison fair.

    It is deliberately NOT a constant predictor. A constant prediction has an
    AUC of exactly 0.5 by construction, so "beating" it proves only that your
    model is better than a coin flip. The question Lab 3 asks is whether your
    feature engineering beats the rule the business already has for free:
    "contact whoever has not purchased in a while."
    """
    i = FEATURE_COLUMNS.index(BASELINE_FEATURE)
    dtr = xgb.DMatrix(X_train[:, [i]], label=y_train, feature_names=[BASELINE_FEATURE])
    dva = xgb.DMatrix(X_val[:, [i]], feature_names=[BASELINE_FEATURE])
    spw = float((y_train == 0).sum() / max((y_train == 1).sum(), 1))
    # The baseline's own hyperparameters are deliberately FIXED rather than exposed
    # as arguments: it is a reference point, not a model under study, and it must
    # score identically on every run for the paired lift CI to mean the same thing
    # run to run. The churn model's parameters are all arguments (parse_args /
    # train_model); Task 4's "no literals in the training call" is about that call.
    params = {
        "objective": "binary:logistic", "eval_metric": "auc",
        "max_depth": 4, "eta": 0.1, "subsample": 0.9,
        "colsample_bytree": 0.9, "scale_pos_weight": spw, "seed": 42,
    }
    return xgb.train(params, dtr, num_boost_round=200).predict(dva)


def bootstrap_lift_ci(y_true: np.ndarray,
                      proba: np.ndarray,
                      baseline_proba: np.ndarray,
                      n: int = BOOTSTRAP_N,
                      seed: int = BOOTSTRAP_SEED,
                      alpha: float = 0.05) -> tuple[float, float]:
    """Percentile CI for (model AUC - baseline AUC), by resampling the val set.

    PAIRED: each replicate resamples row indices once and scores BOTH models on
    those same rows, so the interval is on the difference and the correlation
    between the two models is preserved. Resampling them independently breaks
    the pairing and inflates the interval, which would make a real improvement
    look inconclusive.

    Replicates whose resample happens to be single-class are skipped, because
    AUC is undefined there.

    The seed is fixed so the gate is reproducible: the same split must always
    produce the same verdict.
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
            "Your validation set is too small or too imbalanced to support this gate."
        )
    d = np.sort(diffs)
    return float(np.quantile(d, alpha / 2)), float(np.quantile(d, 1 - alpha / 2))


def evaluate_model(model: xgb.Booster,
                   X_val: np.ndarray,
                   y_val: np.ndarray,
                   baseline_proba: np.ndarray) -> dict:
    """
    Evaluate the trained model against required thresholds.
    Returns a metrics dict. Raises ValueError if thresholds are not met.
    """
    dval = xgb.DMatrix(X_val, feature_names=FEATURE_COLUMNS)
    y_pred_proba = model.predict(dval)
    y_pred_binary = (y_pred_proba > 0.5).astype(int)

    auc_roc = roc_auc_score(y_val, y_pred_proba)

    # Precision and recall @ top 10%, through the shared selection rule (see
    # top10_mask) so the slice evaluation under "Slice Evaluation" decomposes
    # this aggregate rather than measuring something adjacent to it.
    selected = top10_mask(y_pred_proba)
    precision_top10 = y_val[selected].mean() if selected.sum() > 0 else 0.0
    recall_top10 = y_val[selected].sum() / y_val.sum() if y_val.sum() > 0 else 0.0

    # Baseline: a model trained on days_since_last_purchase ALONE.
    #
    # This used to be `np.full_like(y_pred_proba, y_val.mean())` - a constant
    # prediction, whose AUC is exactly 0.5 by definition. Beating a coin flip
    # is not evidence that your feature engineering did anything, and it is not
    # what Lab 3 asks for. The comparison that matters is against recency,
    # because recency is the rule the business already has for free.
    #
    baseline_auc = roc_auc_score(y_val, baseline_proba)
    auc_vs_baseline = auc_roc - baseline_auc

    lift_ci_low, lift_ci_high = bootstrap_lift_ci(
        y_val, y_pred_proba, baseline_proba)

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
        status = "✓ PASS" if value >= threshold else "✗ FAIL"
        print(f"  {metric:25s}: {value:.4f}  (threshold: {threshold:.4f})  {status}")
        if value < threshold:
            failures.append(f"{metric}={value:.4f} < {threshold}")

    # The baseline gate: the interval must exclude zero.
    ci_status = "\u2713 PASS" if lift_ci_low > 0 else "\u2717 FAIL"
    print(f"  {'auc_lift 95% CI':25s}: [{lift_ci_low:.4f}, {lift_ci_high:.4f}]"
          f"  (must exclude 0)  {ci_status}")
    if lift_ci_low <= 0:
        failures.append(
            f"auc_lift 95% CI [{lift_ci_low:.4f}, {lift_ci_high:.4f}] includes "
            f"zero - no evidence the model beats the recency-only baseline")

    if failures:
        raise ValueError(
            f"Model failed evaluation thresholds: {'; '.join(failures)}. "
            f"Do not promote to Model Registry."
        )

    print("  All thresholds passed ✓")

    # Per-tier slice evaluation lives in evaluate_slices(), which main() calls
    # immediately after this. It is kept out of here because it needs the tier of
    # each validation row, which this function is not given.

    return metrics


# ── Slice Evaluation ───────────────────────────────────────────────────────────

# A tier-level AUC or recall is only worth reporting if enough of the minority
# class stands behind it. AUC's standard error is driven by the positive count,
# and at ~25 positives it is already wider than most of the tier gaps we are
# trying to compare. Below either floor the number is still printed -- the report
# should show it -- but it is flagged as too small to support a claim.
#
# On this dataset the validation split holds only ~22 Platinum positives, so
# Platinum is the tier that trips it. That is precisely the slice the starter kit
# warns about: "Platinum once measured AUC 0.0 on ~2 positives".
MIN_SLICE_N = 100
MIN_SLICE_POSITIVES = 25

# The lab's flag: recall more than 10 percentage points below the aggregate.
RECALL_DROP_FLAG = 0.10


def evaluate_slices(model: xgb.Booster,
                    X_val: np.ndarray,
                    y_val: np.ndarray,
                    slice_column) -> dict:
    """
    Per-loyalty-tier evaluation, with the sample size beside every number.

    Two different questions are answered here, and conflating them is the mistake
    this rubric exists to catch:

      * ``auc``          -- does the model rank this tier's customers correctly
                            when the tier is considered on its own? It is a
                            within-tier ranking measure, so it is comparable
                            across tiers, but it is only meaningful when
                            ``positives`` is large enough to estimate it.
      * ``recall_top10`` -- of this tier's churners, how many land in the ONE
                            global top-10% list the retention team actually
                            works? This is the fairness question: given a single
                            shared contact list, does it under-serve a tier?

    Recall is measured against the same global selection as the aggregate (see
    top10_mask), so the per-tier recalls decompose the aggregate and the "10pp
    below aggregate" flag is a real gap rather than an artefact of ranking each
    tier against itself.

    Every entry carries ``n`` and ``positives``, because a slice metric without
    them is unfalsifiable -- and an "ALL" row carries the aggregate for
    comparison.
    """
    y_pred_proba = model.predict(xgb.DMatrix(X_val, feature_names=FEATURE_COLUMNS))
    y_val = np.asarray(y_val)
    slice_column = np.asarray(slice_column)

    global_top10 = top10_mask(y_pred_proba)
    total_positives = int(y_val.sum())
    aggregate_recall = (
        float(y_val[global_top10].sum() / total_positives) if total_positives else 0.0
    )

    slice_results = {
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

        # AUC is undefined when a slice is single-class.
        auc_slice = (
            round(float(roc_auc_score(y_val[in_slice], y_pred_proba[in_slice])), 4)
            if 0 < positives < n else None
        )
        recall_slice = (
            round(float(y_val[in_slice & global_top10].sum() / positives), 4)
            if positives else None
        )

        slice_results[str(slice_value)] = {
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

    return slice_results


def print_slice_summary(slice_results: dict) -> None:
    """Human-readable slice table for the training log."""
    print("\n── Slice Evaluation ────────────────────────────────")
    print(f"  {'tier':<10}{'n':>7}{'pos':>6}{'auc':>10}{'recall@10':>11}{'gap':>9}  flags")
    for tier, m in slice_results.items():
        if tier == "ALL":
            continue
        flags = []
        if m["too_small"]:
            flags.append("TOO SMALL - do not conclude from this tier")
        if m["recall_drop_flag"]:
            flags.append(">10pp below aggregate")
        auc = "n/a" if m["auc"] is None else f"{m['auc']:.4f}"
        rec = "n/a" if m["recall_top10"] is None else f"{m['recall_top10']:.4f}"
        gap = ("" if m["recall_gap_vs_aggregate"] is None
               else f"{m['recall_gap_vs_aggregate']:+.4f}")
        print(f"  {tier:<10}{m['n']:>7}{m['positives']:>6}{auc:>10}{rec:>11}{gap:>9}  "
              f"{', '.join(flags)}")
    agg = slice_results["ALL"]
    print(f"  {'ALL':<10}{agg['n']:>7}{agg['positives']:>6}{agg['auc']:>10.4f}"
          f"{agg['recall_top10']:>11.4f}")
    print(f"  (flag: recall > {RECALL_DROP_FLAG:.0%} below aggregate "
          f"{agg['recall_top10']:.4f}; too_small if n < {MIN_SLICE_N} "
          f"or positives < {MIN_SLICE_POSITIVES})")


def write_slice_evaluation(slice_results: dict, output_dir: str) -> str:
    """Write slice-evaluation.csv (tier, n, positives, auc, recall_top10, ...)."""
    path = os.path.join(output_dir, "slice-evaluation.csv")
    frame = pd.DataFrame([{"tier": tier, **m} for tier, m in slice_results.items()])
    frame.to_csv(path, index=False)
    print(f"✓ Slice evaluation written to {path} ({len(frame) - 1} tiers + aggregate)")
    return path


# ── Evidence Plots ─────────────────────────────────────────────────

DECISION_THRESHOLD = 0.5


def _pyplot():
    """Import matplotlib lazily, on a headless backend.

    Kept out of module scope so the training container does not need matplotlib
    just to train, and so this never tries to open a window on a machine with no
    display.
    """
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    return plt


def write_confusion_matrix_plot(model: xgb.Booster,
                                X_val: np.ndarray,
                                y_val: np.ndarray,
                                output_dir: str,
                                threshold: float = DECISION_THRESHOLD) -> str:
    """2x2 table at the operating threshold, so the trade-off chosen is visible."""
    plt = _pyplot()
    y_proba = model.predict(xgb.DMatrix(X_val, feature_names=FEATURE_COLUMNS))
    y_pred = (y_proba >= threshold).astype(int)
    cm = confusion_matrix(np.asarray(y_val), y_pred, labels=[0, 1])

    fig, ax = plt.subplots(figsize=(5.5, 4.5))
    im = ax.imshow(cm, cmap="Blues")
    for (row, col), value in np.ndenumerate(cm):
        ax.text(col, row, f"{value:,}", ha="center", va="center", fontsize=12,
                color="white" if value > cm.max() / 2 else "black")
    ax.set_xticks([0, 1], ["p = active", "p = churn"])
    ax.set_yticks([0, 1], ["Actually active", "Actually churned"])
    ax.set_title(f"Confusion matrix @ threshold {threshold:.2f}\n"
                 f"validation n={len(y_val):,}, positives={int(np.asarray(y_val).sum()):,}")
    fig.colorbar(im, ax=ax, shrink=0.8)
    fig.tight_layout()
    path = os.path.join(output_dir, "confusion-matrix.png")
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"✓ Confusion matrix written to {path}")
    return path


def write_feature_importance_plot(model: xgb.Booster, output_dir: str) -> str:
    """Gain-based importance over EVERY feature, not just the ones that split.

    XGBoost omits never-split features from get_score(), and "this feature earned
    nothing" is exactly the finding Task 3 asks you to report, so absent features
    are drawn as zero rather than dropped.
    """
    plt = _pyplot()
    gain = model.get_score(importance_type="gain")
    ranked = sorted(((name, float(gain.get(name, 0.0))) for name in FEATURE_COLUMNS),
                    key=lambda pair: pair[1])
    names = [name for name, _ in ranked]
    scores = [score for _, score in ranked]

    fig, ax = plt.subplots(figsize=(7.5, 6))
    ax.barh(names, scores, color="#2b6cb0")
    ax.set_xlabel("Total gain")
    ax.set_title("XGBoost feature importance (gain)")
    for index, score in enumerate(scores):
        ax.text(score, index, f" {score:,.0f}", va="center", fontsize=8)
    fig.tight_layout()
    path = os.path.join(output_dir, "feature-importance.png")
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"✓ Feature importance written to {path}")
    return path


# ── Experiment Tracking (MLflow App) ───────────────────────────────────────────

def track_run(args, metrics: dict, scale_pos_weight: float) -> str | None:
    """
    Log this training run to your SageMaker MLflow App.

    Worth 5 points in Task 1: >=3 runs, each with logged params AND metrics,
    retrievable via mlflow.search_runs.

    ###########################################################################
    #  THERE ARE TWO MLflow PRODUCTS ON SAGEMAKER. USE THE APP.               #
    #                                                                         #
    #    CreateMlflowApp            serverless   NO ADDITIONAL CHARGE   <-- ok #
    #    CreateMlflowTrackingServer $0.60/hour   until you delete it    <-- NO #
    #                                                                         #
    #  $0.60/hr breaches the entire $10 course budget in 16.7 hours and costs #
    #  about $43 over a weekend -- more per hour than any endpoint in this    #
    #  course. It is not an endpoint, so "did I delete my endpoints?" will    #
    #  not find it. Most tutorials describe the Tracking Server because it    #
    #  shipped first. If anything asks you to choose a size (Small/Medium),   #
    #  you are on the wrong product.                                          #
    ###########################################################################

    Two things that fail in ways the error does not explain:

      1. `create-mlflow-app` postdates many installed AWS CLIs. An old CLI
         says "Invalid choice: 'create-mlflow-app'", which reads like a typo
         rather than a version problem. Check `aws --version` and upgrade.

      2. You need BOTH `mlflow` and `sagemaker-mlflow` installed. The second
         is the SigV4 auth plugin for arn:aws:sagemaker:... tracking URIs.
         Without it you get a connection error that never mentions credentials.
    """
    if not args.mlflow_arn:
        print("\n(no --mlflow-arn given; skipping experiment tracking)")
        return

    import mlflow

    # The App ARN goes in verbatim: the sagemaker-mlflow plugin recognises the
    # arn:aws:sagemaker:... scheme and signs every request with SigV4. Both
    # `mlflow` and `sagemaker-mlflow` must be installed; with mlflow alone you get
    # a connection error that never mentions credentials.
    mlflow.set_tracking_uri(args.mlflow_arn)
    mlflow.set_experiment(args.mlflow_experiment)

    params = {
        "max_depth": args.max_depth,
        "eta": args.eta,
        "num_round": args.num_round,
        "min_child_weight": args.min_child_weight,
        "subsample": args.subsample,
        "colsample_bytree": args.colsample_bytree,
        # The RESOLVED value computed from the training split, not the possibly
        # None CLI argument. Logging None would hide the one parameter most
        # likely to explain a precision/recall difference between runs.
        "scale_pos_weight": scale_pos_weight,
        # Lab 3 documents that identical data and an identical split produce
        # different metrics on XGBoost 3.2.0 vs 1.7 (the SageMaker container).
        # Record the version or you will compare incomparable runs unknowingly.
        "xgboost_version": xgb.__version__,
        "feature_group_name": args.feature_group_name,
        "training_start_date": args.training_start_date,
        "training_end_date": args.training_end_date,
    }
    params = {key: value for key, value in params.items() if value is not None}

    # MLflow metrics must be numeric. The metrics dict also carries a timestamp
    # string, so filter rather than passing it through wholesale.
    numeric_metrics = {
        key: float(value) for key, value in metrics.items()
        if isinstance(value, (int, float)) and not isinstance(value, bool)
    }

    with mlflow.start_run(run_name=args.run_name) as run:
        mlflow.log_params(params)
        mlflow.log_metrics(numeric_metrics)
        mlflow.set_tags({
            "track": "A",
            "model_family": "xgboost",
            # Makes the provenance of a run explicit: a run over a local CSV is
            # not the graded Athena run, however good its numbers look.
            "data_source": "local-csv" if args.local_data_path else "feature-store-athena",
        })
        # Log the evidence this run produced, so the numbers in MLflow and the
        # numbers under docs/lab3-evidence/ cannot drift apart.
        for name in ("evaluation_metrics.json", "slice-evaluation.csv",
                     "confusion-matrix.png", "feature-importance.png"):
            candidate = os.path.join(args.output_data_dir, name)
            if os.path.exists(candidate):
                mlflow.log_artifact(candidate)

    print(f"\n✓ MLflow run '{args.run_name}' logged to '{args.mlflow_experiment}' "
          f"(run_id={run.info.run_id})")
    return run.info.run_id


# ── Model Saving & Registry ────────────────────────────────────────────────────

def _xgboost_container_image() -> str:
    """The first-party SageMaker XGBoost container, for the inference spec.

    Registration needs a container even though Lab 3 never deploys: Lab 5 builds
    its endpoint from this group, so the entry must name a real image and a real
    artifact. Resolved through the SDK so the region-specific ECR account is not
    hardcoded; the fallback is us-east-1's stable first-party account.
    """
    region = boto3.session.Session().region_name or "us-east-1"
    if SAGEMAKER_AVAILABLE:
        try:
            return sagemaker.image_uris.retrieve("xgboost", region, version="1.7-1")
        except Exception as exc:  # offline, or a region without this image
            print(f"  (image_uris lookup failed: {exc}; using the us-east-1 URI)")
    return f"683313688378.dkr.ecr.{region}.amazonaws.com/sagemaker-xgboost:1.7-1"


def save_and_register_model(model: xgb.Booster,
                             metrics: dict,
                             args,
                             mlflow_run_id: str | None = None) -> None:
    """
    Save the model artifact and register it in SageMaker Model Registry.
    Status is set to PendingManualApproval — human approval required before deployment.
    """
    os.makedirs(args.model_dir, exist_ok=True)

    # Save model
    model_path = os.path.join(args.model_dir, "model.xgb")
    model.save_model(model_path)
    print(f"\n✓ Model saved to {model_path}")

    # Save feature metadata alongside model
    metadata = {
        "feature_columns": FEATURE_COLUMNS,
        "label_column": LABEL_COLUMN,
        "hyperparameters": {
            "max_depth": args.max_depth,
            "eta": args.eta,
            "num_round": args.num_round,
        },
        "evaluation_metrics": metrics,
        "training_date": datetime.utcnow().isoformat(),
        # Ties the artifact to the MLflow run, so the report, the metrics json,
        # the MLflow run and the registry entry all trace to one training event
        # instead of four look-alike sets of numbers.
        "mlflow_run_id": mlflow_run_id,
    }
    with open(os.path.join(args.model_dir, "model_metadata.json"), "w") as f:
        json.dump(metadata, f, indent=2)

    # ── Package the artifact the way a SageMaker container expects ───────────
    # Not bookkeeping: the registry entry has to point at a real tarball or the
    # model package is a metadata row that cannot be deployed. Lab 5 deploys from
    # this group, so the model file sits at the root of the archive.
    model_tar = os.path.join(args.model_dir, "model.tar.gz")
    with tarfile.open(model_tar, "w:gz") as archive:
        archive.add(model_path, arcname="model.xgb")
        archive.add(os.path.join(args.model_dir, "model_metadata.json"),
                    arcname="model_metadata.json")

    run_slug = "".join(
        c if (c.isalnum() or c in "-._") else "-"
        for c in (args.run_name or datetime.utcnow().strftime("%Y%m%d-%H%M%S"))
    )
    model_key = f"artifacts/models/{run_slug}/model.tar.gz"
    boto3.client("s3").upload_file(model_tar, args.artifacts_bucket, model_key)
    model_data_url = f"s3://{args.artifacts_bucket}/{model_key}"
    print(f"✓ Model artifact uploaded to {model_data_url}")

    sm_client = boto3.client("sagemaker")

    # The group is created HERE, idempotently, and deliberately NOT in Terraform.
    # Nothing in the Lab 1-2 root creates it, and that root is destroyed by the
    # pause/teardown scripts -- while registry entries are meant to survive, so
    # Labs 4-6 can still read them. Putting the group in Terraform would tie its
    # lifetime to a root that is routinely torn down.
    group_name = "northstar-churn-models"
    try:
        sm_client.create_model_package_group(
            ModelPackageGroupName=group_name,
            ModelPackageGroupDescription="NorthStar customer churn models",
        )
        print(f"✓ Created model package group {group_name}")
    except sm_client.exceptions.ClientError as exc:
        if "already exists" not in str(exc).lower():
            raise
        print(f"  model package group {group_name} already exists")

    # These three keys are the ones the Lab 3 evidence script cross-checks
    # against evaluation_metrics.json and an MLflow run, so they must be strings
    # and must match those numbers exactly.
    metadata_properties = {
        "auc_roc": str(metrics["auc_roc"]),
        "precision_top10": str(metrics["precision_top10"]),
        "recall_top10": str(metrics["recall_top10"]),
        "baseline_auc": str(metrics["baseline_auc"]),
        "lift_ci_low": str(metrics["lift_ci_low"]),
        "lift_ci_high": str(metrics["lift_ci_high"]),
        "xgboost_version": xgb.__version__,
    }
    if mlflow_run_id:
        metadata_properties["mlflow_run_id"] = mlflow_run_id

    response = sm_client.create_model_package(
        ModelPackageGroupName=group_name,
        ModelPackageDescription=(
            f"NorthStar churn XGBoost. AUC={metrics['auc_roc']}, "
            f"precision@top10={metrics['precision_top10']}, "
            f"recall@top10={metrics['recall_top10']}, "
            f"lift 95% CI [{metrics['lift_ci_low']}, {metrics['lift_ci_high']}]. "
            f"Trained {datetime.utcnow().date()}."
        ),
        InferenceSpecification={
            "Containers": [{
                "Image": _xgboost_container_image(),
                "ModelDataUrl": model_data_url,
                "Framework": "XGBOOST",
            }],
            "SupportedContentTypes": ["text/csv"],
            "SupportedResponseMIMETypes": ["text/csv"],
        },
        # Never Approved from code: a human reviews the metrics and promotes it.
        # The evidence script asserts this status, and an auto-approved model
        # would silently remove the review step the rubric is asking about.
        ModelApprovalStatus="PendingManualApproval",
        CustomerMetadataProperties=metadata_properties,
    )
    print(f"✓ Registered {response['ModelPackageArn']} as PendingManualApproval")


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    args = parse_args()
    os.makedirs(args.model_dir, exist_ok=True)
    os.makedirs(args.output_data_dir, exist_ok=True)

    print("=" * 60)
    print("NorthStar Churn Prediction — Training Script")
    print("=" * 60)

    # 1. Load features
    if args.local_data_path:
        df = load_features_local(args.local_data_path)
    else:
        df = load_features_from_feature_store(
            args.feature_group_name,
            args.training_start_date,
            args.training_end_date,
            args.artifacts_bucket,
        )

    # 2. Preprocess (also returns the loyalty_tier of each row)
    X, y, tiers = preprocess_features(df)

    # 3. Train/validation split
    # test_size=0.30 matches the reference run and every published figure in
    # Lab 3 (6,999 train / 3,000 test on the 10k dataset). The bootstrap lift CI
    # is calibrated on a test set that size; a 0.20 split leaves 2,000 rows and
    # widens the interval enough to matter.
    #
    # loyalty_tier rides through as a THIRD array so it is split on the identical
    # indices as X and y, and stratified so the ~22% churn rate holds on both
    # sides. Re-reading the tiers from df afterwards would NOT line up once any
    # row had been dropped -- that is the trap this rubric sets.
    X_train, X_val, y_train, y_val, _tier_train, tier_val = train_test_split(
        X, y, tiers, test_size=0.30, random_state=42, stratify=y
    )
    print(f"\nTrain: {len(X_train):,} | Validation: {len(X_val):,}")

    # 4. Train
    model = train_model(X_train, y_train, X_val, y_val, args)

    # 5. Evaluate: the precision/recall gates plus the paired bootstrap CI on the
    #    lift over the recency-only baseline. Raises if a gate fails, so a model
    #    that does not beat recency is never registered.
    baseline_proba = train_recency_baseline(X_train, y_train, X_val)
    metrics = evaluate_model(model, X_val, y_val, baseline_proba)

    # 6. Slice evaluation (Task 1): per-tier AUC and recall@10%, each beside its
    #    n and positive count, written to slice-evaluation.csv.
    slice_results = evaluate_slices(model, X_val, y_val, tier_val)
    print_slice_summary(slice_results)
    write_slice_evaluation(slice_results, args.output_data_dir)

    # 7. Evidence plots for the evaluation report.
    write_confusion_matrix_plot(model, X_val, y_val, args.output_data_dir)
    write_feature_importance_plot(model, args.output_data_dir)

    # 8. Write metrics to output. SageMaker also collects these as job output;
    #    that is job lineage, NOT experiment tracking. It records that a job
    #    ran, not what you varied or why. Step 9 is the graded one.
    metrics_path = os.path.join(args.output_data_dir, "evaluation_metrics.json")
    with open(metrics_path, "w") as f:
        json.dump(metrics, f, indent=2)

    # 9. Track this run in the MLflow App (Task 1, 5 pts). Done BEFORE
    #    registration so the model package can carry the run id -- that is what
    #    welds the report, this json, the MLflow run and the model card into one
    #    chain instead of four look-alike sets of numbers.
    run_id = track_run(args, metrics, getattr(args, "resolved_scale_pos_weight", None))

    # 10. Save the artifact and register it, pending human approval.
    save_and_register_model(model, metrics, args, mlflow_run_id=run_id)

    print("\n" + "=" * 60)
    print(f"Training complete. AUC-ROC: {metrics['auc_roc']:.4f}")
    print("=" * 60)


if __name__ == "__main__":
    main()
