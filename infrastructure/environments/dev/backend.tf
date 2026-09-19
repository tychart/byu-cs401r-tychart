# Task B3 - Remote State.
#
# Copy this file to backend.tf. scripts/bootstrap-state.sh creates the state
# bucket and lock table and replaces 345594594463 below with your real
# account ID (it also copies this file to backend.tf for you if you have not).
# The bucket must exist BEFORE terraform init: a backend cannot bootstrap the
# bucket that stores its own state.

terraform {
  backend "s3" {
    bucket         = "northstar-tfstate-345594594463"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "northstar-tfstate-lock"
  }
}
