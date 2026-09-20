output "domain_id" {
  description = "ID of the SageMaker Domain"
  value       = aws_sagemaker_domain.this.id
}

output "domain_arn" {
  description = "ARN of the SageMaker Domain"
  value       = aws_sagemaker_domain.this.arn
}

output "domain_url" {
  description = "Studio URL for the SageMaker Domain"
  value       = aws_sagemaker_domain.this.url
}

output "user_profile_name" {
  description = "Name of the Studio user profile created in the Domain"
  value       = aws_sagemaker_user_profile.ml_engineer.user_profile_name
}
