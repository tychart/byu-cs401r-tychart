# ── modules/feature_store ────────────────────────────────────────────────────
# Task 3: the feature group that Labs 3-6 read from.
#
#   aws_sagemaker_feature_group  northstar-dev-customer-features
#
# A feature group is a schema contract plus two stores:
#   * online store  - low-latency key/value lookups for real-time inference
#   * offline store - S3-backed Parquet + a Glue table, for training and batch
#
# Keep the two `features/` writers apart. This module points the offline store
# at features/offline-store/; the feature engineering job writes its own Parquet
# to features/customers/. Pointing them at the same prefix interleaves the
# offline store's internal layout with the job output and makes both hard to
# query.
#
# The role is DataEngineer. CreateFeatureGroup rejects an execution role whose
# trust policy omits sagemaker.amazonaws.com, and it checks the bucket ACL
# before accepting the offline store target.

locals {
  feature_group_name = "${var.project}-${var.environment}-customer-features"

  # 16 definitions: 2 keys + 13 features + 1 label. Types matter:
  #   * event_time MUST be Fractional (Unix epoch seconds). Declaring String
  #     while sending a number makes every PutRecord fail with ValidationError.
  #   * churn_label MUST be Integral: it is a 0/1 ground-truth value, not a
  #     probability. churn_risk_score is the Fractional one.
  feature_definitions = [
    { name = "customer_id", type = "String" },
    { name = "event_time", type = "Fractional" },
    { name = "days_since_last_purchase", type = "Fractional" },
    { name = "customer_tenure_days", type = "Fractional" },
    { name = "purchase_frequency_30d", type = "Fractional" },
    { name = "purchase_frequency_90d", type = "Fractional" },
    { name = "purchase_frequency_180d", type = "Fractional" },
    { name = "avg_order_value", type = "Fractional" },
    { name = "total_spend_90d", type = "Fractional" },
    { name = "total_lifetime_value", type = "Fractional" },
    { name = "avg_basket_size_6m", type = "Fractional" },
    { name = "category_diversity_score", type = "Fractional" },
    { name = "online_to_store_ratio", type = "Fractional" },
    { name = "loyalty_tier", type = "String" },
    { name = "churn_risk_score", type = "Fractional" },
    { name = "churn_label", type = "Integral" },
  ]
}

resource "aws_sagemaker_feature_group" "this" {
  feature_group_name             = local.feature_group_name
  record_identifier_feature_name = "customer_id"
  event_time_feature_name        = "event_time"
  role_arn                       = var.data_engineer_role_arn

  description = "NorthStar ${var.environment} customer churn feature group"

  online_store_config {
    enable_online_store = true
  }

  offline_store_config {
    s3_storage_config {
      s3_uri = "s3://${var.bucket_name}/${var.offline_store_prefix}"
    }
  }

  dynamic "feature_definition" {
    for_each = local.feature_definitions
    content {
      feature_name = feature_definition.value.name
      feature_type = feature_definition.value.type
    }
  }

  tags = {
    Name = local.feature_group_name
  }
}
