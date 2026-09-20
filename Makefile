# NorthStar AI Platform — Lab 1
# Run from the repo root.
#
#   make local-validate   Task B5: apply vpc/storage/iam against LocalStack and
#                         save the evidence to docs/lab1b-localstack-output.txt
#   make local-destroy    tear the LocalStack stack down
#   make local-clean      also drop local state and LocalStack data

# The recipe uses `set -o pipefail`, which is a bashism.
SHELL := /bin/bash

# Prefer Docker, fall back to Podman. Either works; whichever is installed on
# the machine running `make` is the one that gets used.
COMPOSE ?= $(shell command -v docker >/dev/null 2>&1 && echo "docker compose" || echo "podman compose")

INFRA_DIR   ?= infrastructure
LOCAL_ENV    = $(INFRA_DIR)/environments/local
LOCAL_OUT    = docs/lab1b-localstack-output.txt
BUCKET       = northstar-local-data-000000000000

.PHONY: local-validate local-destroy local-clean

local-validate:
	@$(COMPOSE) up -d --wait
	@mkdir -p docs
	@set -euo pipefail; \
	export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1; \
	{ \
	  echo "== NorthStar Lab 1 — LocalStack validation =="; \
	  echo "date: $$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	  echo; \
	  echo "== terraform init =="; \
	  terraform -chdir=$(LOCAL_ENV) init -input=false -no-color; \
	  echo; \
	  echo "== terraform apply =="; \
	  terraform -chdir=$(LOCAL_ENV) apply -auto-approve -input=false -no-color; \
	  echo; \
	  echo "== awslocal sts get-caller-identity =="; \
	  awslocal sts get-caller-identity; \
	  echo; \
	  echo "== awslocal s3 ls s3://$(BUCKET)/ --recursive =="; \
	  awslocal s3 ls s3://$(BUCKET)/ --recursive; \
	  echo; \
	  echo "== awslocal iam list-roles (northstar*) =="; \
	  awslocal iam list-roles --query 'Roles[?starts_with(RoleName, `northstar`)].RoleName'; \
	  echo; \
	  echo "== awslocal ec2 describe-vpcs =="; \
	  awslocal ec2 describe-vpcs --query 'Vpcs[*].{Id:VpcId,CIDR:CidrBlock}'; \
	  echo; \
	  echo "== awslocal ec2 describe-subnets =="; \
	  awslocal ec2 describe-subnets --query 'Subnets[*].{Id:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}'; \
	} 2>&1 | tee $(LOCAL_OUT)
	@echo
	@echo "Saved to $(LOCAL_OUT) — commit it."

local-destroy:
	terraform -chdir=$(LOCAL_ENV) destroy -auto-approve -input=false

local-clean: local-destroy
	$(COMPOSE) down
	rm -rf $(LOCAL_ENV)/.terraform $(LOCAL_ENV)/terraform.tfstate* .localstack
