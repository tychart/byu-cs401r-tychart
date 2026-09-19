module "bucket" {
  source = "../modules/bucket"

  bucket_name = "terraform-learning-local"
}

output "bucket_name" {
  value = module.bucket.bucket_name
}