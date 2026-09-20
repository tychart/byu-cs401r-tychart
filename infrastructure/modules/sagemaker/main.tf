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

    # Deliberately empty, and it must stay here. DescribeDomain always returns
    # a non-nil StudioWebPortalSettings ({"ExecutionRoleSessionNameMode":
    # "USER_IDENTITY"}), and the provider's flatten only maps
    # hidden_app_types / hidden_instance_types / hidden_ml_tools — none of
    # which AWS sets. The result is an empty block written into state on every
    # refresh. Omit it from the config and Terraform plans to remove the block
    # on every plan, forever. Declaring it empty makes config and state agree.
    studio_web_portal_settings {}
  }

  # Studio's home EFS filesystem, its mount target, and a pair of NFS security
  # groups are created by SageMaker at domain creation. Terraform never sees
  # them and cannot manage them: the API has no input for an existing
  # filesystem, and home_efs_file_system_id is read-only output. "Delete" makes
  # DeleteDomain remove all of them, which is what keeps `terraform destroy`
  # clean. With the AWS default (Retain) the filesystem survives, its mount
  # target pins the subnet, the NFS security groups pin the VPC, and destroy
  # spends the provider's whole DependencyViolation retry budget before failing.
  # aws_vpc has no configurable delete timeout, so that wait cannot be bounded —
  # only avoided.
  retention_policy {
    home_efs_file_system = "Delete"
  }

  # RetentionPolicy is create-only and cannot be read back after creation, so
  # without ignore_changes every plan would show an in-place update that can
  # never converge. The configured value is still sent on create, which is the
  # part that matters: DeleteDomain honours the policy the domain was created
  # with.
  #
  # The consequence worth knowing: AWS applies that policy once, at creation,
  # and never again. A domain created before this block existed keeps "Retain"
  # for its whole life, and ignore_changes means Terraform will neither notice
  # nor correct it. The signature is `terraform destroy` hanging for many minutes
  # on the subnet or VPC and then failing with DependencyViolation. If that
  # happens, find what is actually pinning the VPC and remove it by hand:
  #
  #   aws ec2 describe-security-groups --filters Name=vpc-id,Values=<vpc-id> \
  #     --query 'SecurityGroups[?contains(GroupName,`nfs`)].GroupName'
  #   aws efs describe-file-systems
  #
  # then fix it properly by destroying and recreating the domain so it picks up
  # this policy. Recreating is the fix; deleting the leftovers only unblocks the
  # destroy in front of you.
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
