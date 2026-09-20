# ── environments/local ───────────────────────────────────────────────────────
# Calls the same modules as environments/dev. The sagemaker module is omitted
# on purpose: SageMaker is not in LocalStack Community.
#
# These calls are live, not commented out, so `make local-validate` works the
# moment your vpc, storage, and iam modules are implemented. Until then,
# terraform validate still passes — an empty module is a valid module.

# ── Lookups ──────────────────────────────────────────────────────────────────
# Read at plan time, rather than values anyone chose. The bucket name has to end
# in the account ID to be globally unique — S3 names are shared across every AWS
# account. In LocalStack this answers "000000000000".

data "aws_caller_identity" "current" {}

module "vpc" {
  source      = "../../modules/vpc"
  project     = var.project
  environment = var.environment
}

module "storage" {
  source      = "../../modules/storage"
  project     = var.project
  environment = var.environment
  account_id  = data.aws_caller_identity.current.account_id
}

module "iam" {
  source      = "../../modules/iam"
  project     = var.project
  environment = var.environment
}
