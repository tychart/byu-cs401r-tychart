# Lab 3 Track C: the AgentCore stack's own state key.
#
# Same bucket and lock table as Labs 1-2, but a DIFFERENT key, so the two roots
# never share state. Kept in its own root because AgentCore needs provider 6.x
# and environments/dev is pinned to 5.x.
terraform {
  backend "s3" {
    bucket         = "northstar-tfstate-345594594463"
    key            = "agent/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "northstar-tfstate-lock" # same lock table as Labs 1-2
    encrypt        = true
  }
}
