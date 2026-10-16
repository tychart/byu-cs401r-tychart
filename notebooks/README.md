# notebooks/

`lab3-demo.ipynb` goes here (Lab 3, Task 2, Track C).

The TA cannot re-run it — they have no Bedrock access and no AWS account access —
so the notebook must be committed **with its outputs** from a single
`Kernel → Restart & Run All`. `scripts/collect_lab3_evidence.py` checks that the
execution counts are exactly `1..N`.

Run it against the repo's Python environment (`uv run jupyter lab`), not
SageMaker Studio: the lab recommends local execution, and the Studio domain is
paused (its NAT Gateway is off) between work sessions.
