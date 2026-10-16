#!/usr/bin/env bash
# pause-lab3.sh
# Cheap, fully reversible pause: destroy the NAT Gateway and its Elastic IP,
# and nothing else.
#
# WHY THIS IS THE DEFAULT PAUSE
# The NAT Gateway is the only meaningful idle cost in the Lab 1-2 stack:
#   NAT Gateway   ~$0.045/hr
#   its public IPv4 ~$0.005/hr      ~= $1.20/day, ~$36/month
# Everything else is either free at rest (VPC, subnets, route tables, security
# groups, Glue catalog + job DEFINITIONS, IAM roles, SageMaker Studio domain)
# or costs cents (S3 storage, the Feature Store's online/offline store, the
# EFS home directory).
#
# So flipping this one flag takes the stack to roughly $0.01/month while
# keeping:
#   * the S3 bucket and all of raw/, processed/, features/ and artifacts/
#   * the SageMaker Feature Group and its offline-store Glue table, which is
#     what the Lab 3 Task 1 Athena query reads
#   * the Glue catalog database and job definitions, so re-running the
#     pipeline never needs a re-crawl
#   * the IAM roles, which your MLflow App is bound to
#
# Resume with scripts/resume-lab3.sh (one apply).
#
# Run the deeper scripts/pause-lab3-deep.sh instead if you want the VPC and
# Studio domain actually destroyed, not just idle.
#
# Usage: bash scripts/pause-lab3.sh
set -euo pipefail

TF_DIR="infrastructure/environments/dev"

if [ ! -d "${TF_DIR}/.terraform" ]; then
  echo "ERROR: ${TF_DIR} is not initialized. Run 'terraform -chdir=${TF_DIR} init' first."
  exit 1
fi

echo "==> Lab 3 pause (NAT off): keeping S3, Feature Store, Glue catalog and IAM"
echo "    before: NAT Gateway + EIP billing ~\$1.20/day"
echo

terraform -chdir="${TF_DIR}" apply \
  -auto-approve -input=false -no-color \
  -var enable_nat_gateway=false

echo
echo "[verify] NAT gateways and unattached EIPs still present:"
nat=$(aws ec2 describe-nat-gateways \
        --filter Name=state,Values=available,pending \
        --query 'length(NatGateways)' --output text 2>/dev/null | awk '{s+=$1} END {print s+0}')
eip=$(aws ec2 describe-addresses \
        --query 'length(Addresses)' --output text 2>/dev/null | awk '{s+=$1} END {print s+0}')
echo "    NAT gateways : ${nat}   (want 0)"
echo "    Elastic IPs  : ${eip}   (want 0)"

bucket="northstar-dev-data-$(aws sts get-caller-identity --query Account --output text)"
if aws s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1; then
  echo "    S3 bucket    : ${bucket} still present  (correct - this is the data you are keeping)"
else
  echo "    S3 bucket    : ${bucket} NOT FOUND - investigate before continuing" >&2
fi

echo
echo "==> Paused. Idle cost is now storage cents only."
echo "    NOTE: while paused, nothing in the private subnet has internet access."
echo "    That means Glue jobs and SageMaker Studio apps will NOT work until you"
echo "    run: bash scripts/resume-lab3.sh"
