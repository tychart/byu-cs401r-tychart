#!/usr/bin/env bash
# pause-lab3-deep.sh
# Deep pause: a real `terraform destroy` of the ephemeral compute layer only.
#
# Keeps, deliberately:
#   module.storage      the S3 bucket - raw/, processed/, features/, artifacts/
#   module.feature_store the Feature Group + its offline-store Glue table,
#                        which is what the Lab 3 Task 1 Athena query reads.
#                        Destroying this would force a re-ingest (the exact
#                        recompute this repo is trying to avoid).
#   module.iam          the MLEngineer/DataEngineer/ModelMonitor roles. Your
#                        MLflow App is bound to the MLEngineer role ARN.
#
# Destroys:
#   module.vpc          VPC, subnets, route tables, IGW, security group,
#                       NAT Gateway + EIP
#   module.glue         catalog database (northstar_dev), raw crawler, VPC
#                       connection, transform/feature-engineer job definitions
#   module.sagemaker    Studio domain, user profile, EFS home filesystem
#
# Resume with scripts/resume-lab3.sh (a full `terraform apply` recreates the
# compute layer; the data is already there).
#
# There is no native "terraform destroy everything except X", so this uses
# -target on the complement. The plan is printed and checked FIRST: if any
# resource from the keep-set appears in it, the script aborts without
# destroying anything.
#
# Usage: bash scripts/pause-lab3-deep.sh
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
PROJECT="${PROJECT:-northstar}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
TF_DIR="infrastructure/environments/${ENVIRONMENT}"

KEEP=(module.storage module.feature_store module.iam)
TARGETS=(-target=module.vpc -target=module.glue -target=module.sagemaker)

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${PROJECT}-${ENVIRONMENT}-data-${ACCOUNT_ID}"

echo "==> Lab 3 deep pause"
echo "    Account : ${ACCOUNT_ID}"
echo "    Region  : ${REGION}"
echo "    Keeping : ${KEEP[*]}"
echo "    Destroying: module.vpc  module.glue  module.sagemaker"
echo

if [ ! -d "${TF_DIR}/.terraform" ]; then
  echo "ERROR: ${TF_DIR} is not initialized. Run 'terraform -chdir=${TF_DIR} init' first."
  exit 1
fi

# ── 0. Guardrail: plan first, abort if the keep-set is in it ──────────────────
# SEMANTICS (verified empirically 2026-10-15 on Terraform 1.16 with a local
# terraform_data fixture): `destroy -target=X` destroys X and everything that
# DEPENDS ON X, and spares everything X depends on.
#
#   -target=keep       -> keep + its dependent
#   -target=dependent  -> dependent only, keep SPARED
#
# Here the targets are module.vpc, module.glue and module.sagemaker, and the
# keep modules are dependencies of them (or unrelated), never dependents. So
# module.storage, module.feature_store and module.iam cannot be destroyed. If a
# future refactor reverses an edge, the check below catches it before anything
# is deleted.
PLAN_FILE=$(mktemp -t lab3-pause-plan.XXXXXX)
trap 'rm -f "${PLAN_FILE}"' EXIT

echo "[1/5] Reviewing the destroy plan (-target complement)"
terraform -chdir="${TF_DIR}" plan \
  -destroy -no-color -input=false "${TARGETS[@]}" 2>&1 | tee "${PLAN_FILE}"

# A destroyed resource is announced as:  # module.x.aws_y.z will be destroyed
if grep -qE '^[[:space:]]*# module\.(storage|feature_store|iam)\.' "${PLAN_FILE}"; then
  echo
  echo "ABORT: the plan would destroy a resource in a KEEP module:" >&2
  grep -E '^[[:space:]]*# module\.(storage|feature_store|iam)\.' "${PLAN_FILE}" >&2
  echo >&2
  echo "Nothing was destroyed. That means a dependency edge was reversed in" >&2
  echo "${TF_DIR}/main.tf. Check with:" >&2
  echo "    terraform -chdir=${TF_DIR} graph | grep -E 'storage|feature_store'" >&2
  echo "Safe fallback without fixing the graph: bash scripts/pause-lab3.sh" >&2
  exit 1
fi

# Nothing to do. When the targeted objects are already gone Terraform prints
# this sentence and NO "Plan:" line at all, so this check has to come first.
if grep -qE 'No changes\. No objects need to be destroyed\.' "${PLAN_FILE}"; then
  echo
  echo "Nothing to destroy - the compute layer is already paused (or never applied)."
  exit 0
fi

# The summary line reads: "Plan: 0 to add, 0 to change, 33 to destroy."
PLAN_LINE=$(grep -E '^Plan: ' "${PLAN_FILE}" | tail -1)
if [ -z "${PLAN_LINE}" ]; then
  echo "ABORT: no 'Plan:' summary line in the output above; refusing to destroy blind." >&2
  exit 1
fi

DESTROY_COUNT=$(printf '%s\n' "${PLAN_LINE}" \
  | sed -nE 's/.*,[[:space:]]*([0-9]+) to destroy\..*/\1/p')
if [ -z "${DESTROY_COUNT}" ]; then
  echo "ABORT: could not read a destroy count from: ${PLAN_LINE}" >&2
  exit 1
fi

if [ "${DESTROY_COUNT}" = "0" ]; then
  echo
  echo "Nothing to destroy - the compute layer is already paused."
  exit 0
fi

echo
echo "Plan is valid: ${DESTROY_COUNT} resource(s) to destroy, none from the keep-set."

# ── 1. Orphaned Glue ENIs, BEFORE destroy ────────────────────────────────────
# Every Glue job run inside the VPC leaves network interfaces behind in the
# "available" state. They pin the private subnet and the security group, and
# destroy then waits ~10 minutes on each before failing. They are detached, so
# they are safe to delete up front.
echo
echo "[2/5] Removing orphaned Glue network interfaces"
for eni in $(aws ec2 describe-network-interfaces \
    --filters "Name=status,Values=available" \
    --query "NetworkInterfaces[?contains(Description, 'Glue')].NetworkInterfaceId" \
    --output text 2>/dev/null); do
  aws ec2 delete-network-interface --network-interface-id "${eni}" >/dev/null 2>&1 \
    && echo "      deleted ENI ${eni}"
done

# ── 2. Destroy the compute layer ─────────────────────────────────────────────
echo
echo "[3/5] terraform destroy (compute layer only)"
mkdir -p docs
terraform -chdir="${TF_DIR}" destroy \
  -auto-approve -input=false -no-color "${TARGETS[@]}" 2>&1 \
  | tee -a docs/lab3-pause-deep-output.txt | tail -6

# ── 3. Orphaned SageMaker EFS + NFS security groups ──────────────────────────
# The module sets retention_policy home_efs_file_system = "Delete", so this
# normally finds nothing. It stays for domains created without it: an orphaned
# EFS keeps billing and its mount target blocks the subnet.
echo
echo "[4/5] Removing orphaned SageMaker Studio storage, if any"
for fs in $(aws efs describe-file-systems --query 'FileSystems[*].FileSystemId' --output text 2>/dev/null); do
  for mt in $(aws efs describe-mount-targets --file-system-id "${fs}" \
                --query 'MountTargets[*].MountTargetId' --output text 2>/dev/null); do
    aws efs delete-mount-target --mount-target-id "${mt}" >/dev/null 2>&1 \
      && echo "      deleted mount target ${mt}"
  done
  for _ in $(seq 1 30); do
    remaining=$(aws efs describe-mount-targets --file-system-id "${fs}" \
                  --query 'length(MountTargets)' --output text 2>/dev/null || echo 0)
    [ "${remaining}" = "0" ] && break
    sleep 5
  done
  aws efs delete-file-system --file-system-id "${fs}" >/dev/null 2>&1 \
    && echo "      deleted filesystem ${fs}"
done
for sg in $(aws ec2 describe-security-groups \
    --query "SecurityGroups[?contains(GroupName, 'nfs-d-')].GroupId" \
    --output text 2>/dev/null); do
  perms=$(aws ec2 describe-security-groups --group-ids "${sg}" \
            --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
  [ "${perms}" != "[]" ] && aws ec2 revoke-security-group-ingress \
    --group-id "${sg}" --ip-permissions "${perms}" >/dev/null 2>&1
  eperms=$(aws ec2 describe-security-groups --group-ids "${sg}" \
            --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)
  [ "${eperms}" != "[]" ] && aws ec2 revoke-security-group-egress \
    --group-id "${sg}" --ip-permissions "${eperms}" >/dev/null 2>&1
done
for sg in $(aws ec2 describe-security-groups \
    --query "SecurityGroups[?contains(GroupName, 'nfs-d-')].GroupId" \
    --output text 2>/dev/null); do
  aws ec2 delete-security-group --group-id "${sg}" >/dev/null 2>&1 \
    && echo "      deleted security group ${sg}"
done

# ── 4. Prove the data layer survived ─────────────────────────────────────────
echo
echo "[5/5] Verifying the keep-set survived"
keep_fail=0
for m in "${KEEP[@]}"; do
  n=$(terraform -chdir="${TF_DIR}" state list 2>/dev/null | grep -c "^${m}\." || true)
  if [ "${n}" -gt 0 ]; then
    printf "      %-24s in state (%s resources)\n" "${m}" "${n}"
  else
    printf "      %-24s MISSING FROM STATE\n" "${m}"; keep_fail=1
  fi
done
if aws s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1; then
  echo "      S3 bucket                ${BUCKET} present"
else
  echo "      S3 bucket                ${BUCKET} MISSING"; keep_fail=1
fi
if aws sagemaker describe-feature-group \
     --feature-group-name "${PROJECT}-${ENVIRONMENT}-customer-features" >/dev/null 2>&1; then
  echo "      Feature Group            ${PROJECT}-${ENVIRONMENT}-customer-features present"
else
  echo "      Feature Group            MISSING - Task 1's Athena query will fail"; keep_fail=1
fi

echo
if [ "${keep_fail}" = "0" ]; then
  echo "==> Deep pause complete. Data kept, compute destroyed."
  echo "    Resume with: bash scripts/resume-lab3.sh"
else
  echo "==> WARNING: a keep-set resource is missing. Do NOT run teardown." >&2
  exit 1
fi
