# ── modules/glue ─────────────────────────────────────────────────────────────
# Task 2: discover the raw data's shape and clean it.
#
#   aws_glue_catalog_database  northstar_dev                  the metastore database
#   aws_glue_connection        northstar-dev-vpc-connection   NETWORK placement in the private subnet
#   aws_s3_object              artifacts/glue/transform.py    job script, uploaded by Terraform
#   aws_glue_crawler           northstar-dev-raw-crawler      scans raw/customers/, registers `customers`
#   aws_glue_job               northstar-dev-transform        Glue 4.0 Spark: raw -> processed
#
# Terraform creates *definitions*, not executions. `terraform apply` makes the
# crawler and the job exist; you still run them yourself with
# `aws glue start-crawler` and `aws glue start-job-run`. Nothing here runs on
# apply, and none of it costs money until a run starts.
#
# Every name is built from var.project and var.environment — no literal
# "northstar-dev" appears below.

locals {
  # Glue database names cannot contain a hyphen, so this one joins with an
  # underscore: northstar_dev. Everything user-facing keeps the hyphenated
  # ${project}-${environment} shape.
  database_name = "${var.project}_${var.environment}"

  crawler_name       = "${var.project}-${var.environment}-raw-crawler"
  connection_name    = "${var.project}-${var.environment}-vpc-connection"
  transform_job_name = "${var.project}-${var.environment}-transform"

  transform_script_key = "${var.artifacts_prefix}/transform.py"

  # Glue's default scratch space is a service-owned bucket the DataEngineer
  # role has no access to, so point --TempDir somewhere the role can write.
  transform_temp_dir = "s3://${var.bucket_name}/processed/_glue_temp/transform/"
}

# ── Catalog database ─────────────────────────────────────────────────────────
# The crawler writes table metadata here, and the transform job reads it back.
# Creating the database does not create any table; the first crawler run does.
resource "aws_glue_catalog_database" "this" {
  name        = local.database_name
  description = "Crawler-discovered raw tables and ETL output tables for ${var.project}-${var.environment}"
}

# ── VPC NETWORK connection ───────────────────────────────────────────────────
# A NETWORK connection carries no credentials or JDBC URL. Its entire job is
# the physical placement: attach the jobs' ENIs into this subnet and these
# security groups. Without it, Glue workers run outside your VPC and cannot
# reach the private subnet's NAT path (or the resources behind it).
resource "aws_glue_connection" "this" {
  name            = local.connection_name
  connection_type = "NETWORK"

  # AWS: NETWORK connections "do not require ConnectionParameters. Instead,
  # provide a PhysicalConnectionRequirements." So connection_properties is
  # intentionally absent.
  physical_connection_requirements {
    availability_zone      = var.availability_zone
    subnet_id              = var.private_subnet_id
    security_group_id_list = var.security_group_ids
  }

  tags = {
    Name = local.connection_name
  }
}

# ── Job script upload ────────────────────────────────────────────────────────
# The script lives in git and is pushed to S3 by `terraform apply`, so the job
# definition and the code it runs cannot drift apart. source_hash re-uploads
# whenever the local file changes.
resource "aws_s3_object" "transform_script" {
  bucket      = var.bucket_name
  key         = local.transform_script_key
  source      = var.transform_script_path
  source_hash = filemd5(var.transform_script_path)
}

# ── Raw crawler ──────────────────────────────────────────────────────────────
# Samples the CSVs under raw/customers/, infers a schema, and registers it as
# `customers` in the catalog. No table_prefix is set, so the table is named
# after the final prefix segment: `customers`, not `raw_customers`.
resource "aws_glue_crawler" "raw" {
  name          = local.crawler_name
  database_name = aws_glue_catalog_database.this.name
  role          = var.data_engineer_role_arn

  s3_target {
    path = "s3://${var.bucket_name}/${var.raw_prefix}"
  }

  # No `schedule` block: this crawler is on-demand. UPDATE_IN_DATABASE lets a
  # re-crawl pick up new columns; LOG leaves a vanished column in the catalog
  # for a human to look at instead of silently dropping it.
  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  tags = {
    Name = local.crawler_name
  }
}

# ── Transform ETL job ────────────────────────────────────────────────────────
# Glue 4.0 Spark reading the catalog table and writing Parquet. The cleaning
# logic itself lives in glue-scripts/transform.py; this resource only describes
# how to run it.
resource "aws_glue_job" "transform" {
  name              = local.transform_job_name
  role_arn          = var.data_engineer_role_arn
  glue_version      = var.glue_version
  worker_type       = var.worker_type
  number_of_workers = var.number_of_workers
  timeout           = var.job_timeout_minutes
  max_retries       = 0

  command {
    name            = "glueetl"
    script_location = "s3://${var.bucket_name}/${local.transform_script_key}"
    python_version  = "3"
  }

  # These become `--key value` pairs on the script's argv; getResolvedOptions()
  # reads them back by name. --TempDir must be writable by the job role — the
  # Glue default bucket is not.
  default_arguments = {
    "--database_name"                    = aws_glue_catalog_database.this.name
    "--table_name"                       = var.catalog_table_name
    "--output_path"                      = "s3://${var.bucket_name}/${var.processed_prefix}"
    "--TempDir"                          = local.transform_temp_dir
    "--enable-continuous-cloudwatch-log" = "true"
  }

  # Attaching the connection is what runs the workers inside the VPC.
  connections = [aws_glue_connection.this.name]

  execution_property {
    max_concurrent_runs = 1
  }

  # script_location above is just a string, so Terraform cannot see that the
  # upload has to happen first. The explicit dependency guarantees it.
  depends_on = [aws_s3_object.transform_script]

  tags = {
    Name = local.transform_job_name
  }
}
