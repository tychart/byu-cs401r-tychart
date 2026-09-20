# ── modules/sagemaker ────────────────────────────────────────────────────────
# The course IDE (Lab 1).
#
#   aws_sagemaker_domain         northstar-dev-domain
#   aws_sagemaker_user_profile   MLEngineer
#
# The Domain owns the VPC placement (subnet + security group) and the default
# execution role; the user profile maps a person onto that role. Both roles
# arrive as variables — see the module call in environments/dev/main.tf.
#
# A brand-new AWS account has no service-linked role for Studio, and the Domain
# fails to create with a service-linked role error. Fix it once in the console
# (IAM -> Roles -> Create Role -> AWS Service -> SageMaker -> SageMaker Studio)
# and re-apply. See the New Account Bootstrap note in the lab.
#
# The Domain is also the slowest resource here by a wide margin — several
# minutes to create and to delete. Factor that into your apply/destroy timings
# for Task B2.

resource "aws_sagemaker_domain" "this" {
  domain_name = "${var.project}-${var.environment}-domain"
  auth_mode   = "IAM"

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # Lab 1 keeps Studio in the public subnet: apps reach the internet through
  # the internet gateway. Lab 2 moves them to VPC-only egress behind a NAT.
  app_network_access_type = "PublicInternetOnly"

  default_user_settings {
    execution_role  = var.execution_role_arn
    security_groups = var.security_group_ids

    # JupyterServer is fully managed by SageMaker: the API accepts ONLY the
    # `system` instance type for it, and CreateDomain rejects anything else
    # with "Only 'system' instance type is supported".
    jupyter_server_app_settings {
      default_resource_spec {
        instance_type = "system"
      }
    }

    # The instance type notebooks actually run on. For KernelGateway apps the
    # API translates `system` to ml.t3.medium and also accepts explicit types,
    # so this is where the "default kernel instance type" belongs.
    kernel_gateway_app_settings {
      default_resource_spec {
        instance_type = var.instance_type
      }
    }

    # Notebook output sharing: Disabled, per the component specification.
    sharing_settings {
      notebook_output_option = "Disabled"
    }
  }

  # Studio creates an EFS filesystem for home directories that Terraform never
  # sees. Without this, the default (Retain) leaves the filesystem (and its
  # mount target, which pins the subnet) behind on destroy, and `terraform
  # destroy` hangs for ten minutes before failing.
  retention_policy {
    home_efs_file_system = "Delete"
  }

  # DescribeDomain does not return RetentionPolicy (it is write-only), so the
  # provider cannot read it back into state. Without this, refreshing or
  # importing an existing Domain plans a ForceNew replacement of a healthy
  # domain. The value is still sent on create, and DeleteDomain honours the
  # policy the Domain was created with.
  lifecycle {
    ignore_changes = [retention_policy]
  }

  tags = {
    Name = "${var.project}-${var.environment}-domain"
  }
}

resource "aws_sagemaker_user_profile" "ml_engineer" {
  domain_id         = aws_sagemaker_domain.this.id
  user_profile_name = var.user_profile_name

  user_settings {
    execution_role  = var.execution_role_arn
    security_groups = var.security_group_ids
  }

  tags = {
    Name = "${var.project}-${var.environment}-${var.user_profile_name}"
  }
}
