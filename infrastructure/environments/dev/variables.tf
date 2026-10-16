variable "project" {
  description = "Project name, used as the first element of every resource name"
  type        = string
  default     = "northstar"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.100.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet that holds SageMaker and the Glue workers"
  type        = string
  default     = "10.0.1.0/24"
}

variable "availability_zone" {
  description = "Availability Zone for the public subnet"
  type        = string
  default     = "us-east-1a"
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Create the Elastic IP and NAT Gateway for private-subnet egress (Lab 2).
    Set to false to PAUSE the stack between work sessions: the NAT Gateway is
    the only meaningful idle cost in this environment (~$0.045/hr + ~$0.005/hr
    for its public IPv4, about $1.20/day). Everything else is untouched, so
    the S3 data, the Feature Store and the Glue catalog all survive and no
    data has to be recomputed.

      pause  : terraform apply -var enable_nat_gateway=false
      resume : terraform apply

    Leave it true while running Glue jobs or SageMaker Studio apps: both live
    in the private subnet and need the NAT to reach AWS APIs.
  EOT
  type        = bool
  default     = true
}

variable "sagemaker_instance_type" {
  description = "Default kernel instance type for SageMaker Studio apps"
  type        = string
  default     = "ml.t3.medium"
}
