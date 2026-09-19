data "aws_caller_identity" "current" {}

module "bucket" {
  source = "../modules/bucket"

  bucket_name = "terraform-learning-${data.aws_caller_identity.current.account_id}"
}

output "bucket_name" {
  value = module.bucket.bucket_name
}