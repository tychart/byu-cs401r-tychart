terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "hello" {
  bucket = "terraform-learning-${data.aws_caller_identity.current.account_id}"

  tags = {
    Purpose = "Terraform learning exercise test"
    Course  = "CS401R"
  }
}

output "bucket_name" {
  value = aws_s3_bucket.hello.bucket
}