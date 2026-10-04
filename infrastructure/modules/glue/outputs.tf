# Downstream modules and environments/dev consume these; the verification
# script also looks up the same names through the AWS API.

output "database_name" {
  description = "Glue catalog database holding the raw and processed tables"
  value       = aws_glue_catalog_database.this.name
}

output "crawler_name" {
  description = "Name of the on-demand raw crawler"
  value       = aws_glue_crawler.raw.name
}

output "connection_name" {
  description = "Name of the VPC NETWORK connection the jobs attach"
  value       = aws_glue_connection.this.name
}

output "transform_job_name" {
  description = "Name of the raw -> processed Glue job"
  value       = aws_glue_job.transform.name
}

output "transform_script_s3_uri" {
  description = "S3 URI of the uploaded transform script"
  value       = "s3://${aws_s3_object.transform_script.bucket}/${aws_s3_object.transform_script.key}"
}
