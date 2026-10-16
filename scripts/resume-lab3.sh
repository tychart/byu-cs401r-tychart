#!/usr/bin/env bash
# resume-lab3.sh
# Bring the stack back after either pause mode:
#
#   scripts/pause-lab3.sh        destroyed the NAT Gateway + EIP
#   scripts/pause-lab3-deep.sh   destroyed module.vpc, module.glue, module.sagemaker
#
# A plain apply handles both: enable_nat_gateway defaults back to true, and any
# compute resources missing from state are recreated. The S3 data, the Feature
# Store and the IAM roles were never touched, so nothing is recomputed and no
# job is re-run.
#
# Usage: bash scripts/resume-lab3.sh
set -euo pipefail

TF_DIR="infrastructure/environments/dev"

if [ ! -d "${TF_DIR}/.terraform" ]; then
  echo "ERROR: ${TF_DIR} is not initialized. Run 'terraform -chdir=${TF_DIR} init' first."
  exit 1
fi

echo "==> Lab 3 resume: restoring the compute layer (data was never destroyed)"
echo

terraform -chdir="${TF_DIR}" apply -auto-approve -input=false -no-color

echo
echo "==> Back up. Useful outputs:"
echo "    bucket        : $(terraform -chdir="${TF_DIR}" output -raw s3_bucket_name)"
echo "    feature group : $(terraform -chdir="${TF_DIR}" output -raw feature_group_name)"
echo "    ml role       : $(terraform -chdir="${TF_DIR}" output -raw ml_engineer_role_arn)"
echo
echo "    The pipeline is NOT re-run by apply - it only creates definitions."
echo "    If you need to rebuild the data, see README.md 'Run it end to end'."
echo "    Remember to pause again when you stop working: bash scripts/pause-lab3.sh"
