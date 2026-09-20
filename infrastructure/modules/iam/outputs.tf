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
