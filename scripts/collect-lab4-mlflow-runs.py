#!/usr/bin/env python
"""Write docs/lab4-mlflow-runs.txt from the NorthStar MLflow App.

Lab 4 Task 3 asks for evidence of deliberate experiment tracking: at least three
runs with *differing hyperparameters* and the metrics they produced. The handout
is explicit that the SageMaker Experiments auto-created by the pipeline do not
count, because they record that a run happened rather than what was varied.

So this dumps Lab 3's `northstar-churn` experiment, which varied `max_depth`
across 4 / 6 / 8 and logged the full evaluation block for each.

Why a script rather than a one-liner: `search_runs` returns a DataFrame whose
`params.*` columns are truncated to `...` by pandas' default display width,
which hides exactly the thing being graded. `to_string()` is what forces the
whole table out.

The tracking URI is the MLflow App ARN, not an HTTP endpoint -- the app is
serverless and reached through SigV4 signing, which is what importing
`sagemaker_mlflow` installs.

Usage:  .venv/bin/python scripts/collect-lab4-mlflow-runs.py
"""

from __future__ import annotations

import os

import mlflow
import pandas as pd

MLFLOW_APP_ARN = os.environ.get(
    "MLFLOW_APP_ARN",
    "arn:aws:sagemaker:us-east-1:345594594463:mlflow-app/app-W4LYKOSSDJZE",
)
EXPERIMENT = os.environ.get("MLFLOW_EXPERIMENT", "northstar-churn")
OUTPUT = "docs/lab4-mlflow-runs.txt"


def main() -> int:
    # Registers the sagemaker-mlflow auth plugin so MLflow can sign requests to
    # the App. Must be imported before set_tracking_uri.
    import sagemaker_mlflow  # noqa: F401

    mlflow.set_tracking_uri(MLFLOW_APP_ARN)
    if not mlflow.get_tracking_uri().startswith("arn:aws:sagemaker"):
        raise SystemExit(
            f"tracking URI is {mlflow.get_tracking_uri()!r}, not an MLflow App "
            f"ARN. The grader checks for ':mlflow-app/'."
        )

    runs = mlflow.search_runs(experiment_names=[EXPERIMENT])
    if len(runs) < 3:
        raise SystemExit(
            f"{EXPERIMENT} has {len(runs)} run(s); Task 3 requires at least 3."
        )

    # Everything that varies, plus the scoring columns. Deliberately NOT
    # filtered down to a hand-picked pair: the point is that the reader can see
    # what changed between runs and what it did.
    columns = ["run_id", "tags.mlflow.runName", "start_time"] + [
        c for c in runs.columns if c.startswith(("params.", "metrics."))
    ]

    param_columns = [c for c in columns if c.startswith("params.")]
    varied = {
        column: sorted({str(v) for v in runs[column].dropna().unique()})
        for column in param_columns
        if runs[column].dropna().nunique() > 1
    }

    header = [
        f"tracking_uri: {mlflow.get_tracking_uri()}",
        f"experiment:   {EXPERIMENT}",
        f"runs:         {len(runs)}",
        "",
        "Hyperparameters that differ between these runs:",
        *(f"  {k}: {', '.join(v)}" for k, v in sorted(varied.items())),
        "",
        "Note: the SageMaker Experiments that the CI pipeline creates on every",
        "execution are deliberately not used as evidence here. They record that a",
        "pipeline ran, not what was varied.",
        "",
    ]

    with open(OUTPUT, "w") as f:
        f.write("\n".join(header) + "\n")
        f.write(runs[columns].to_string() + "\n")

    print(f"wrote {OUTPUT}: {len(runs)} runs, {len(varied)} varied hyperparameter(s)")
    for k, v in sorted(varied.items()):
        print(f"  {k}: {', '.join(v)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
