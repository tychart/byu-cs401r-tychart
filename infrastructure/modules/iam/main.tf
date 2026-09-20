# ── modules/iam ──────────────────────────────────────────────────────────────
# Identity model for the platform (Lab 1 — MLEngineer only).
#
#   aws_iam_role                   northstar-dev-MLEngineer, trusted by sagemaker.amazonaws.com
#   aws_iam_policy                 the least-privilege permission set below
#   aws_iam_role_policy_attachment attaches the policy to the role
#
# Least privilege is graded in later labs, so the S3 object actions are scoped
# to the artifacts/ and features/ prefixes only. ListBucket is intentionally a
# separate statement on the bucket ARN: a trailing `*` on an object statement
# would also match /raw/anything and silently grant the write access this role
# is supposed to lack.
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
      "sagemaker:RegisterModel", "sagemaker:DescribeModelPackage", "sagemaker:ListModelPackages",
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
