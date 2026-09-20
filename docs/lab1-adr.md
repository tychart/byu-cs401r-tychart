## ADR-001: NorthStar Platform Foundation

### Status
Accepted

### Context

NorthStar loses about 18% of its 2.1M active customers a year, roughly $128.5M in lifetime value at $340 each, which is why Maya Chen funded three AI systems. The churn model scores every active customer weekly so retention offers can go out Monday at 6 AM ET. The offer generator is an LLM/RAG service that must personalize an offer in under 2 seconds. The customer service agent must absorb 50% of the 14,000 daily contacts while holding 99.5% availability between 8 AM and 10 PM.

The three systems serve differently - weekly batch scoring, real-time inference, LLM serving, agentic - but share almost everything underneath: the same 250,000 customer records, 4.2M transactions, 12,000-SKU catalog, features, and small team. They also share one compliance problem: customer PII falls under GDPR, CCPA, and NorthStar's 24-month raw retention rule, so "who can read which data" needs one answer, not three.

Lab 1 therefore builds the layer all three systems sit on, not a model.

### Decision

**Network.** One VPC, `northstar-dev-vpc`, on 10.0.0.0/16 with DNS hostnames and resolution enabled, and one public subnet, `northstar-dev-public-1`, on 10.0.100.0/24 in us-east-1a, routed 0.0.0.0/0 to `northstar-dev-igw`. Studio must pull training images from ECR and reach S3, and Lab 1 has no NAT gateway, so a public subnet is the only thing that works. Inbound is limited to the VPC CIDR by `northstar-dev-sagemaker-sg`: nothing on the internet reaches a notebook, but a notebook can reach out. The VPC makes "inside NorthStar" a CIDR in a security group rule rather than a list of IPs.

**Storage.** One bucket, `northstar-dev-data-{account-id}`, with versioning, SSE-S3, all four public access blocks on, and four prefixes: `raw/`, `processed/`, `features/`, `artifacts/`. Prefixes instead of separate buckets because the boundary that matters is the access boundary, and a prefix is something an IAM policy can name. Versioning is on because a bad retraining run has to be recoverable, and an auditable 24-month retention story is easier when nothing is destroyed in place.

**Identity.** One role, `northstar-dev-MLEngineer`, trusted by `sagemaker.amazonaws.com`, with six policy statements: SageMaker training jobs, endpoints, MLflow App, and model registry; Studio self-service; object read/write on `artifacts/` and `features/`; `ListBucket` on the bucket ARN; CloudWatch Logs write; and ECR pulls. The two S3 statements are split on purpose: `ListBucket` is bucket-level and goes on the bucket ARN, while the object actions go only on those prefixes. A trailing `*` on the object statement would also match `raw/anything` and hand this role the write access it is supposed to lack. Writing to `raw/` or `processed/` is denied by omission: a training job that can overwrite the ingested source of truth makes every downstream result unauditable.

### Consequences

#### What this makes easy

Adding a fourth system is a new prefix and a policy statement, not a new stack, bucket, and network review. Privacy questions have one place to be answered: the CPO's office can read one bucket policy and one role and know what ML code can see. The DataEngineer role Lab 2 adds for `raw/` and `processed/` slots in without editing the ML role. Studio and training jobs share one execution role, so a notebook cannot reach data a deployed model could not.

#### What this makes harder

The shared role is the cost. A careless notebook has the same reach as a training job, so one bad cell can touch every feature set NorthStar owns. Everything is single-region in us-east-1, so a regional outage takes the Monday 6 AM churn score with it and there is no copy to fail over to. The public subnet means egress is wide open on 0.0.0.0/0 with no NAT gateway, so a notebook with a bad dependency could push 25 GB of features out before anyone notices, with no egress log to reconstruct it. And `ml.t3.medium` is fine for three engineers but not for a 4.2M-row training run, so the first real job will be launched from here, not run on it.

#### What would cause you to revisit this decision

If NorthStar adds a system with a different regulator or retention schedule, prefix-level IAM stops being enough and this splits into separate buckets. If weekly churn scoring moves to intraday, or the 2-second offer SLA starts driving GPU spend the $85,000/month budget cannot absorb, the single-region layout gets revisited. And if the ML role ever genuinely needs to write `raw/`, the stage boundaries are wrong, not the policy.

### Alternative Considered

The real alternative is three independent point solutions: each system gets its own bucket, execution role, and Studio domain, with no coordination between them. It is attractive because each team ships without waiting and a broken policy in one stack cannot affect another. I rejected it because the churn model's engineered features are exactly what the offer generator needs to personalize a discount for a high-risk customer, so that design copies the same 250,000-row feature set across three boundaries and three retention policies. One customer table under one IAM model is one thing to audit and one storage line item, worth more than the isolation.

### AWS Service Selection

- **Networking isolation model:** VPC with a public subnet and an internet gateway. Deciding reason: Studio must pull external images and Lab 1 has no NAT gateway, so a private subnet would add ~$32/month of NAT for isolation the VPC CIDR already gives.
- **Storage design:** one S3 bucket with four stage prefixes and SSE-S3. Deciding reason: prefix-scoped IAM is the only mechanism that lets the MLEngineer role read `features/` while denying it `raw/`.
- **Identity model:** an IAM role trusted by `sagemaker.amazonaws.com` with an inline least-privilege policy. Deciding reason: Studio and training jobs both need credentials, and a role issues short-lived ones with no keys to leak.
- **ML development environment:** SageMaker Studio pinned to `ml.t3.medium` with notebook output sharing disabled. Deciding reason: it runs inside the VPC under the same execution role as training jobs, and idles at $0.05/hour inside the $200 credit budget.
