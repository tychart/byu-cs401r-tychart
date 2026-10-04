output "feature_group_name" {
  description = "Name of the customer feature group"
  value       = aws_sagemaker_feature_group.this.feature_group_name
}

output "feature_group_arn" {
  description = "ARN of the customer feature group"
  value       = aws_sagemaker_feature_group.this.arn
}

output "offline_store_uri" {
  description = "S3 URI backing the offline store"
  value       = "s3://${var.bucket_name}/${var.offline_store_prefix}"
}
