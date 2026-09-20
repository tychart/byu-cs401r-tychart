| Component | Monthly Estimate | Key Assumptions | One Optimization |
|---|---|---|---|
| SageMaker Studio | $2.20 | 2 hrs/day, 22 days (44 hrs) at $0.05/hr | Enable idle auto-shutdown — saves ~$0.55/mo |
| S3 storage | $0.58 | 25 GB (incl. versions) at $0.023/GB | Lifecycle `raw/` to Standard-IA after 30 days — saves ~$0.13/mo |
| Internet Gateway | $0.00 | 20 GB egress/mo; $0.09/GB after first 100 GB free | Pull images from in-region ECR Public instead of Docker Hub — saves ~$1.80/mo |
| DynamoDB (state lock) | $0.00 | On-demand, near-zero reads; free tier covers it | Stay on-demand and share one lock table — avoids ~$14/mo provisioned floor |
| S3 state bucket | $0.01 | Minimal storage (~0.5 GB) | Expire noncurrent state versions after 90 days — saves ~$0.01/mo |
| Total | $2.79 | | |
