#!/usr/bin/env python
"""
Run the Track C scenario evaluation, repeatably, and write the rubric's evidence.

    uv run python scripts/run_agent_eval.py                  # eval-1 + eval-2
    uv run python scripts/run_agent_eval.py --runs eval-1    # just one

What it does
------------
Runs every case in `evaluation_harness.AGENT_TEST_CASES` (5 required + the
bonus prompt-injection case) through the deployed AgentCore harness, then writes
one combined CSV with a `run` column so "at least twice" is visible in a single
file:

    docs/lab3-evidence/agent_eval.csv

Each scenario gets its OWN runtime session. `HarnessAgent.invoke` appends a UUID
to whatever session id it is given, and `LocalAgentEvaluator` also passes a
per-scenario id, so a scenario can never inherit the previous one's conversation
(a shared session invalidates both scores).

Side effects, both required by the rubric and both written by
`agent/harness_client.py` as the calls happen:

    docs/lab3-evidence/agent-traces.jsonl   one JSON line per tool call
    docs/lab3-evidence/agent-cost.csv       one row per scenario-run

This script exists so the notebook is not the only way to reproduce the run,
and so the whole suite can be re-measured from a terminal.

Cost: about 4 cents per full pass (dominant term is AgentCore session runtime,
not tokens), measured at 6 scenarios x ~35 s.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd

REPO = Path(__file__).resolve().parent.parent
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import evaluation_harness as eh  # noqa: E402
from agent.harness_client import HarnessAgent  # noqa: E402

OUT = Path("docs/lab3-evidence/agent_eval.csv")


def run_once(label: str) -> pd.DataFrame:
    """One full pass over the suite. Returns one row per scenario."""
    agent = HarnessAgent(run_label=label)
    evaluator = eh.LocalAgentEvaluator(invoke_fn=agent.invoke)
    df = evaluator.run(eh.AGENT_TEST_CASES)
    df.insert(0, "run", label)
    return df


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", nargs="+", default=["eval-1", "eval-2"],
                    help="run labels, one full suite pass each (default: eval-1 eval-2)")
    ap.add_argument("--output", default=str(OUT))
    ap.add_argument("--replace", action="store_true",
                    help="overwrite the output CSV instead of appending to an existing one")
    args = ap.parse_args()

    frames = []
    for label in args.runs:
        frames.append(run_once(label))
    combined = pd.concat(frames, ignore_index=True)

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists() and not args.replace:
        # Keep earlier passes, so a re-run strengthens the record rather than
        # silently discarding the first measurement.
        previous = pd.read_csv(out)
        combined = pd.concat([previous, combined], ignore_index=True)
    combined.to_csv(out, index=False)

    print(f"\nwrote {out} ({len(combined)} rows, runs: {', '.join(map(str, combined['run'].unique()))})")
    summary = (combined.groupby("run")["passed"]
               .agg(scenarios="size", passed="sum")
               .assign(score=lambda d: d["passed"].astype(str) + "/" + d["scenarios"].astype(str)))
    print(summary.to_string())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
