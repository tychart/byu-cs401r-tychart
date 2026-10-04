# ── environments/dev ─────────────────────────────────────────────────────────
# Wire the four modules together here. Each module call passes var.project and
# var.environment down; nothing in modules/ hardcodes a name.

# ── Lookups ──────────────────────────────────────────────────────────────────
# Read at plan time, rather than values anyone chose. The bucket name has to end
# in the account ID to be globally unique — S3 names are shared across every AWS
# account. In LocalStack this answers "000000000000".

data "aws_caller_identity" "current" {}


module "vpc" {
  source              = "../../modules/vpc"
  project             = var.project
  environment         = var.environment
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
  availability_zone   = var.availability_zone
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

module "glue" {
  source      = "../../modules/glue"
  project     = var.project
  environment = var.environment

  bucket_name            = module.storage.bucket_name
  data_engineer_role_arn = module.iam.data_engineer_role_arn

  # The Glue NETWORK connection places job workers in the private subnet, using
  # the SageMaker SG (which carries the self-referencing all-ports rule Glue
  # requires). Both must be passed through so the connection can be created.
  private_subnet_id  = module.vpc.private_subnet_id
  security_group_ids = [module.vpc.security_group_id]
  availability_zone  = var.availability_zone

  # path.root is infrastructure/environments/dev, so three levels up is the
  # repo root that holds glue-scripts/. Terraform uploads the file and hashes it.
  transform_script_path        = "${path.root}/../../../glue-scripts/transform.py"
  feature_engineer_script_path = "${path.root}/../../../glue-scripts/feature_engineer.py"

  # The feature job PutRecords into this group; the name comes from the
  # feature_store module so the two can never drift apart.
  feature_group_name = module.feature_store.feature_group_name
  aws_region         = var.aws_region
}

module "feature_store" {
  source      = "../../modules/feature_store"
  project     = var.project
  environment = var.environment

  bucket_name            = module.storage.bucket_name
  data_engineer_role_arn = module.iam.data_engineer_role_arn
}

module "sagemaker" {
  source             = "../../modules/sagemaker"
  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = [module.vpc.private_subnet_id]
  security_group_ids = [module.vpc.security_group_id]
  execution_role_arn = module.iam.ml_engineer_role_arn
  instance_type      = var.sagemaker_instance_type
}
