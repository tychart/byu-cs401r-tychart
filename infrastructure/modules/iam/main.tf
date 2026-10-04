# ── modules/iam ──────────────────────────────────────────────────────────────
# Identity model for the platform.
#
#   aws_iam_role                   northstar-dev-MLEngineer     Lab 1, trusted by sagemaker.amazonaws.com
#   aws_iam_role                   northstar-dev-DataEngineer   Lab 2, trusted by glue/lambda/sagemaker
#   aws_iam_role                   northstar-dev-ModelMonitor   Lab 2, trusted by sagemaker.amazonaws.com
#   aws_iam_policy                 one least-privilege permission set per role
#   aws_iam_role_policy_attachment attaches each policy to its role
#
# Least privilege is graded in later labs, so the S3 object actions are scoped
# to prefixes rather than the whole bucket. ListBucket is intentionally a
# separate statement on the bucket ARN: a trailing `*` on an object statement
# would also match /raw/anything and silently grant the write access a role is
# supposed to lack.
#
# The bucket name is derived from the same
# ${project}-${environment}-data-${account_id} shape the storage module builds,
# which is why these ARNs use a wildcard in place of the account ID.

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "SageMakerAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ml_engineer" {
  statement {
    sid    = "SageMakerCore"
    effect = "Allow"
    actions = [
      "sagemaker:CreateTrainingJob", "sagemaker:DescribeTrainingJob", "sagemaker:StopTrainingJob",
      "sagemaker:CreateEndpoint", "sagemaker:DescribeEndpoint", "sagemaker:DeleteEndpoint",
      "sagemaker:CreateEndpointConfig", "sagemaker:DeleteEndpointConfig",
      "sagemaker:CreateMlflowApp", "sagemaker:DescribeMlflowApp", "sagemaker:ListMlflowApps",
      "sagemaker:CreatePresignedMlflowAppUrl",
      # Model registry. The IAM action is CreateModelPackage; "RegisterModel" is
      # the Pipelines step name, not an IAM action, and silently matched nothing.
      "sagemaker:CreateModelPackage", "sagemaker:DescribeModelPackage", "sagemaker:ListModelPackages",
    ]
    resources = ["*"]
  }

  # Studio runs as this role. Opening Studio calls DescribeDomain, ListApps and
  # friends, and launching or stopping JupyterLab is CreateApp/DeleteApp plus
  # CreatePresignedDomainUrl. Without this statement the Studio UI loads a blank
  # "Permissions not configured correctly" page.
  statement {
    sid    = "StudioSelfService"
    effect = "Allow"
    actions = [
      "sagemaker:DescribeDomain", "sagemaker:ListDomains",
      "sagemaker:DescribeUserProfile", "sagemaker:ListUserProfiles",
      "sagemaker:DescribeSpace", "sagemaker:ListSpaces", "sagemaker:CreateSpace",
      "sagemaker:UpdateSpace", "sagemaker:DeleteSpace",
      "sagemaker:DescribeApp", "sagemaker:ListApps", "sagemaker:CreateApp", "sagemaker:DeleteApp",
      "sagemaker:CreatePresignedDomainUrl",
    ]
    resources = [
      "arn:aws:sagemaker:*:*:domain/*",
      "arn:aws:sagemaker:*:*:user-profile/*",
      "arn:aws:sagemaker:*:*:space/*",
      "arn:aws:sagemaker:*:*:app/*",
    ]
  }

  statement {
    sid     = "S3ArtifactsAndFeatures"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "arn:aws:s3:::${var.project}-${var.environment}-data-*/artifacts/*",
      "arn:aws:s3:::${var.project}-${var.environment}-data-*/features/*",
    ]
  }

  statement {
    sid       = "S3BucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.project}-${var.environment}-data-*"]
  }

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:log-group:/aws/sagemaker/*"]
  }

  statement {
    sid    = "ECRRead"
    effect = "Allow"
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "ml_engineer" {
  name               = "${var.project}-${var.environment}-MLEngineer"
  description        = "SageMaker execution role for ${var.project}-${var.environment} ML work"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = {
    Name = "${var.project}-${var.environment}-MLEngineer"
  }
}

resource "aws_iam_policy" "ml_engineer" {
  name        = "${var.project}-${var.environment}-MLEngineerPolicy"
  description = "Least-privilege policy for ${var.project}-${var.environment} SageMaker work"
  policy      = data.aws_iam_policy_document.ml_engineer.json

  tags = {
    Name = "${var.project}-${var.environment}-MLEngineerPolicy"
  }
}

resource "aws_iam_role_policy_attachment" "ml_engineer" {
  role       = aws_iam_role.ml_engineer.name
  policy_arn = aws_iam_policy.ml_engineer.arn
}

# ══ Lab 2: DataEngineer ══════════════════════════════════════════════════════
# The data-plane identity: Glue crawler and ETL jobs, and the Feature Store
# writer. It reads raw/, writes processed/ and features/, and reads its own job
# scripts from artifacts/glue/ — but it can never write artifacts/.

data "aws_iam_policy_document" "assume_role_data_engineer" {
  statement {
    sid     = "DataServicesAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "glue.amazonaws.com",
        "lambda.amazonaws.com",
        # Required in Task 3: CreateFeatureGroup rejects an execution role that
        # does not trust SageMaker, even though this is otherwise a pure
        # data-plane identity.
        "sagemaker.amazonaws.com",
      ]
    }
  }
}

data "aws_iam_policy_document" "data_engineer" {
  # Glue full access over databases, tables, crawlers, jobs, and runs. This
  # also covers glue:GetConnection, the Task 2 failure that appears before the
  # script ever runs: Glue resolves the NETWORK connection first, and a role
  # missing that action sees "not authorized to perform: glue:GetConnection".
  statement {
    sid       = "GlueFullAccess"
    effect    = "Allow"
    actions   = ["glue:*"]
    resources = ["*"]
  }

  # Glue creates one ENI per worker in the private subnet. The Describe* set is
  # what it uses to place those ENIs.
  statement {
    sid    = "GlueNetworkInterfaceLifecycle"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:Describe*",
    ]
    resources = ["*"]
  }

  # Task 2 failure #3: Glue tags every ENI it creates. Without these two the
  # job dies with "The specified role doesn't have a permission to create a tag
  # for your elastic network interface."
  statement {
    sid       = "GlueNetworkInterfaceTags"
    effect    = "Allow"
    actions   = ["ec2:CreateTags", "ec2:DeleteTags"]
    resources = ["arn:aws:ec2:*:*:network-interface/*"]
  }

  # Read/write the three data prefixes. artifacts/ is deliberately absent here,
  # so a write to artifacts/ stays implicitly denied.
  statement {
    sid    = "S3DataPrefixes"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = [
      "arn:aws:s3:::${var.project}-${var.environment}-data-*/raw/*",
      "arn:aws:s3:::${var.project}-${var.environment}-data-*/processed/*",
      "arn:aws:s3:::${var.project}-${var.environment}-data-*/features/*",
    ]
  }

  # Read-only on artifacts/glue/: Glue must fetch its own job scripts from S3.
  # GetObject only — adding PutObject here would hand this role write access to
  # the prefix it is supposed to be excluded from.
  statement {
    sid       = "S3GlueScriptsRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.project}-${var.environment}-data-*/artifacts/glue/*"]
  }

  # Feature Store checks the bucket ACL before it accepts the offline store
  # target, and writes offline-store objects WITH an ACL, so plain PutObject is
  # not enough. Without these two, CreateFeatureGroup fails at apply time with
  # "Invalid S3Uri provided" — even though the URI is correct.
  statement {
    sid       = "S3BucketAcl"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = ["arn:aws:s3:::${var.project}-${var.environment}-data-*"]
  }

  statement {
    sid       = "S3FeatureOfflineStoreAcl"
    effect    = "Allow"
    actions   = ["s3:PutObjectAcl"]
    resources = ["arn:aws:s3:::${var.project}-${var.environment}-data-*/features/*"]
  }

  statement {
    sid       = "S3BucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.project}-${var.environment}-data-*"]
  }

  statement {
    sid    = "FeatureStoreWrite"
    effect = "Allow"
    actions = [
      "sagemaker:CreateFeatureGroup",
      "sagemaker:DescribeFeatureGroup",
      "sagemaker:PutRecord",
    ]
    resources = ["arn:aws:sagemaker:*:*:feature-group/*"]
  }

  # Scoped to the Glue log groups rather than Resource "*" (IAM guidance:
  # logs actions belong on a log-group ARN). Glue writes crawler and job output
  # under /aws-glue/*; the trailing :* covers the log streams inside them.
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:log-group:/aws-glue/*:*"]
  }
}

resource "aws_iam_role" "data_engineer" {
  name               = "${var.project}-${var.environment}-DataEngineer"
  description        = "Glue, crawler, and Feature Store writer role for ${var.project}-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.assume_role_data_engineer.json

  tags = {
    Name = "${var.project}-${var.environment}-DataEngineer"
  }
}

resource "aws_iam_policy" "data_engineer" {
  name        = "${var.project}-${var.environment}-DataEngineerPolicy"
  description = "Data pipeline permissions for ${var.project}-${var.environment}: raw/processed/features in, artifacts/ read-only"
  policy      = data.aws_iam_policy_document.data_engineer.json

  tags = {
    Name = "${var.project}-${var.environment}-DataEngineerPolicy"
  }
}

resource "aws_iam_role_policy_attachment" "data_engineer" {
  role       = aws_iam_role.data_engineer.name
  policy_arn = aws_iam_policy.data_engineer.arn
}

# ══ Lab 2: ModelMonitor ══════════════════════════════════════════════════════
# This role observes; it does not act. It reads artifacts/ and publishes
# CloudWatch metrics and alarms, and cannot write to S3 or launch work. The
# distinction matters in Lab 6, where a separate *Execution role runs the drift
# analysis while this one only watches.

data "aws_iam_policy_document" "assume_role_model_monitor" {
  statement {
    sid     = "SageMakerAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "model_monitor" {
  statement {
    sid    = "CloudWatchMetricsAndAlarms"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DescribeAlarms",
    ]
    resources = ["*"]
  }

  # Read-only visibility into drift runs. Starting one is a job for
  # ModelMonitorExecution, not for this role.
  statement {
    sid    = "ProcessingJobVisibility"
    effect = "Allow"
    actions = [
      "sagemaker:ListProcessingJobs",
      "sagemaker:DescribeProcessingJob",
    ]
    resources = ["*"]
  }

  # Read-only on artifacts/. No s3:PutObject appears anywhere in this policy,
  # which is what makes a write to S3 an implicit deny.
  statement {
    sid       = "S3ArtifactsRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.project}-${var.environment}-data-*/artifacts/*"]
  }

  statement {
    sid       = "S3BucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.project}-${var.environment}-data-*"]
  }

  # Scoped to the SageMaker log groups rather than Resource "*" (IAM guidance:
  # logs actions belong on a log-group ARN). Processing jobs log under
  # /aws/sagemaker/ProcessingJobs.
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:log-group:/aws/sagemaker/*:*"]
  }
}

resource "aws_iam_role" "model_monitor" {
  name               = "${var.project}-${var.environment}-ModelMonitor"
  description        = "Read-only drift observation role for ${var.project}-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.assume_role_model_monitor.json

  tags = {
    Name = "${var.project}-${var.environment}-ModelMonitor"
  }
}

resource "aws_iam_policy" "model_monitor" {
  name        = "${var.project}-${var.environment}-ModelMonitorPolicy"
  description = "Drift observation permissions for ${var.project}-${var.environment}: CloudWatch metrics, artifacts/ read-only"
  policy      = data.aws_iam_policy_document.model_monitor.json

  tags = {
    Name = "${var.project}-${var.environment}-ModelMonitorPolicy"
  }
}

resource "aws_iam_role_policy_attachment" "model_monitor" {
  role       = aws_iam_role.model_monitor.name
  policy_arn = aws_iam_policy.model_monitor.arn
}
