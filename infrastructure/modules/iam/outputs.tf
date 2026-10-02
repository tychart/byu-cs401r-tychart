output "ml_engineer_role_arn" {
  description = "ARN of the MLEngineer role - later labs pass this to SageMaker"
  value       = aws_iam_role.ml_engineer.arn
}

output "ml_engineer_role_name" {
  description = "Name of the MLEngineer role"
  value       = aws_iam_role.ml_engineer.name
}

output "ml_engineer_policy_arn" {
  description = "ARN of the MLEngineer permission policy"
  value       = aws_iam_policy.ml_engineer.arn
}

output "data_engineer_role_arn" {
  description = "ARN of the DataEngineer role - the Glue crawler and ETL jobs assume this"
  value       = aws_iam_role.data_engineer.arn
}

output "data_engineer_role_name" {
  description = "Name of the DataEngineer role"
  value       = aws_iam_role.data_engineer.name
}

output "data_engineer_policy_arn" {
  description = "ARN of the DataEngineer permission policy"
  value       = aws_iam_policy.data_engineer.arn
}

output "model_monitor_role_arn" {
  description = "ARN of the ModelMonitor role - read-only drift observation"
  value       = aws_iam_role.model_monitor.arn
}

output "model_monitor_role_name" {
  description = "Name of the ModelMonitor role"
  value       = aws_iam_role.model_monitor.name
}

output "model_monitor_policy_arn" {
  description = "ARN of the ModelMonitor permission policy"
  value       = aws_iam_policy.model_monitor.arn
}
