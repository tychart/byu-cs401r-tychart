# Lab 3 Track C: AgentCore Harness + Gateway (Lambda tools) + Policy.
#
# Most of this file is provided. Three TODOs are yours; each says what you will
# see without it. Search for "TODO (student)". Expect the first apply to fail at
# the gateway until TODO 1 is done. That is deliberate: read the error.
#
# IAM changes take up to a minute to reach AgentCore. If an apply or an agent
# call fails with AccessDenied right after you added the permission it names,
# wait a minute and run it again before you change anything else.
#
# Request path:  invoke_harness  ->  Harness (managed agent loop, Haiku 4.5)
#                -> Gateway (MCP, IAM auth, Policy engine in ENFORCE)
#                -> Lambda (handler.py -> tools.py, policy corpus bundled)

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  agent_src    = "${path.module}/../../../agent"
  lambda_src   = "${local.agent_src}/lambda"
  docs_src     = "${path.module}/../../../northstar-policy-docs"
  policy_docs  = fileset(local.docs_src, "*.md")
  tools        = jsondecode(file("${path.module}/tool_definitions.json"))
  target_name  = "northstar-tools" # Cedar actions are "<target_name>___<tool>"
  gateway_glob = "arn:aws:bedrock-agentcore:${var.region}:${local.account_id}:gateway/${var.gateway_name}-*"

  # ── Model backend ─────────────────────────────────────────────────────────
  # Default: a model on your own LiteLLM proxy, reached over public HTTPS with
  # an API key from Secrets Manager. No Anthropic, and no Bedrock model access
  # needed for the agent loop.
  #
  # Fallback: model_backend = "bedrock" uses a Bedrock-hosted open-weight model
  # (openai.gpt-oss-20b-1:0 by default). Nothing else changes -- the gateway,
  # the Cedar policies and the tools are all independent of the model.
  use_litellm = var.model_backend == "litellm"

  # Bedrock IAM resources for the fallback backend. Non-Claude Bedrock models
  # are invoked on demand by their bare model ID (the us./global. inference
  # profile requirement is Claude-4.5+-specific), so with an empty prefix there
  # is no inference-profile ARN to grant.
  bedrock_invoke_model_id = (
    var.bedrock_model_profile_prefix == ""
    ? var.bedrock_model_id
    : "${var.bedrock_model_profile_prefix}${var.bedrock_model_id}"
  )
  bedrock_model_resources = compact([
    var.bedrock_model_profile_prefix == "" ? "" : "arn:aws:bedrock:${var.region}:${local.account_id}:inference-profile/${local.bedrock_invoke_model_id}",
    "arn:aws:bedrock:*::foundation-model/${var.bedrock_model_id}",
  ])

  # The provider requires api_key_wo and api_key_wo_version to be supplied
  # TOGETHER and rejects either one alone ("Invalid Attribute Combination").
  # Deriving the version from the key keeps them in lockstep:
  #   * no key  -> both null, so `terraform destroy` works with no key present
  #   * key set -> the version changes automatically whenever the key does, so
  #                rotating the key needs no manual counter to bump
  litellm_api_key_set     = var.litellm_api_key != null && var.litellm_api_key != ""
  litellm_api_key_version = local.litellm_api_key_set ? parseint(substr(sha256(var.litellm_api_key), 0, 8), 16) : null
}

# ---------------------------------------------------------------------------
# Tools Lambda
# ---------------------------------------------------------------------------

data "archive_file" "tools" {
  type        = "zip"
  output_path = "${path.module}/build/northstar_tools.zip"

  source {
    content  = file("${local.lambda_src}/handler.py")
    filename = "handler.py"
  }
  source {
    content  = file("${local.agent_src}/tools.py")
    filename = "tools.py"
  }
  dynamic "source" {
    for_each = local.policy_docs
    content {
      content  = file("${local.docs_src}/${source.value}")
      filename = "policy_docs/${source.value}"
    }
  }
}

resource "aws_iam_role" "tools_lambda" {
  name = "${var.name_prefix}-tools-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Created here, not by Lambda, so it has a retention limit and is destroyed with the stack.
resource "aws_cloudwatch_log_group" "tools_lambda" {
  name              = "/aws/lambda/${var.name_prefix}-tools"
  retention_in_days = 14
}

resource "aws_iam_role_policy" "tools_lambda_logs" {
  name = "logs"
  role = aws_iam_role.tools_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.tools_lambda.arn}:*"
    }]
  })
}

resource "aws_lambda_function" "tools" {
  function_name    = "${var.name_prefix}-tools"
  role             = aws_iam_role.tools_lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.tools.output_path
  source_code_hash = data.archive_file.tools.output_base64sha256
  timeout          = 30
  memory_size      = 256
  depends_on       = [aws_cloudwatch_log_group.tools_lambda, aws_iam_role_policy.tools_lambda_logs]
}

# ---------------------------------------------------------------------------
# Policy engine (created before the gateway, which references it)
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_policy_engine" "this" {
  name        = "${replace(var.name_prefix, "-", "_")}_policies"
  description = "NorthStar tool authorization"
}

# ---------------------------------------------------------------------------
# Gateway and its execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "gateway" {
  name = "${var.name_prefix}-gateway"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:bedrock-agentcore:${var.region}:${local.account_id}:*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "gateway" {
  name = "invoke-tools-and-authorize"
  role = aws_iam_role.gateway.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeToolsLambda"
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.tools.arn
      },
      # TODO (student) 1: the gateway enforces Cedar policies by calling the
      # policy engine. Add a statement that lets this role do that.
      # Symptom if missing: terraform apply fails creating the gateway with
      # "Access denied while calling GetPolicyEngine". CreateGateway checks
      # this role up front and names ONE missing action per attempt, so expect
      # to iterate. Read the AgentCore developer guide page "AgentCore Gateway
      # and Policy in AgentCore IAM Permissions" (Gateway Execution Role) and
      # add them all at once instead. Scope Resource to the policy engine ARN
      # and local.gateway_glob.
    ]
  })
}

resource "aws_bedrockagentcore_gateway" "this" {
  name            = var.gateway_name
  description     = "NorthStar customer service tools"
  protocol_type   = "MCP"
  authorizer_type = "AWS_IAM"
  role_arn        = aws_iam_role.gateway.arn

  policy_engine_configuration {
    arn  = aws_bedrockagentcore_policy_engine.this.policy_engine_arn
    mode = "ENFORCE"
  }

  depends_on = [aws_iam_role_policy.gateway]
}

resource "aws_bedrockagentcore_gateway_target" "tools" {
  name               = local.target_name
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  description        = "NorthStar order, policy, return, credit, and escalation tools"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.tools.arn
        tool_schema {
          dynamic "inline_payload" {
            for_each = local.tools
            content {
              name        = inline_payload.value.name
              description = inline_payload.value.description
              input_schema {
                type = "object"
                dynamic "property" {
                  for_each = inline_payload.value.inputSchema.properties
                  content {
                    name        = property.key
                    type        = property.value.type
                    description = lookup(property.value, "description", null)
                    required    = contains(lookup(inline_payload.value.inputSchema, "required", []), property.key)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Cedar policies. depends_on the target: a policy is validated against the
# gateway's current tool schema, so the target must be updated first (F5).
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_policy" "permit_tools" {
  name             = "permit_northstar_tools"
  policy_engine_id = aws_bedrockagentcore_policy_engine.this.policy_engine_id
  validation_mode  = "FAIL_ON_ANY_FINDINGS"
  definition {
    cedar {
      statement = <<-CEDAR
        permit (
          principal,
          action in [${join(", ", [for t in local.tools : "AgentCore::Action::\"${local.target_name}___${t.name}\""])}],
          resource == AgentCore::Gateway::"${aws_bedrockagentcore_gateway.this.gateway_arn}"
        );
      CEDAR
    }
  }
  depends_on = [aws_bedrockagentcore_gateway_target.tools]
}

# TODO (student) 3: the $50 credit cap. Write a Cedar forbid policy that blocks
# northstar-tools___apply_loyalty_credit when context.input.amount exceeds
# var.credit_cap_dollars, as a resource "aws_bedrockagentcore_policy" "cap_loyalty_credit".
# Model it on permit_tools above. Two things the validator will teach you the hard way:
#   - A forbid created before the permit exists is rejected as "Overly Restrictive:
#     Policy Engine will deny every request". Make it depend on the permit.
#   - amount is an integer in tool_definitions.json. Compare it as one.
# Symptom if missing: python agent/policy_tests.py reports BAD for the $51 and
# $75 credits, which the gateway allows.

# ---------------------------------------------------------------------------
# LiteLLM backend: the proxy API key.
#
# The key goes into AgentCore Identity's token vault as an API key credential
# provider. This is NOT Secrets Manager and NOT a local file, and the distinction
# is not cosmetic -- `api_key_arn` in the harness model config must match the
# token-vault ARN pattern exactly:
#
#   arn:aws:bedrock-agentcore:<region>:<acct>:token-vault/default/apikeycredentialprovider/<name>
#
# A Secrets Manager ARN does not match that pattern and would be rejected.
#
# Why this and not something else:
#   * $0. AgentCore Identity is not charged when used through AgentCore Runtime,
#     which is where the harness runs, and the token vault has no per-secret
#     storage fee. A Secrets Manager secret would be $0.40/month.
#   * api_key_wo is a WRITE-ONLY argument: Terraform sends the value to AWS and
#     never persists it to terraform.tfstate. That is the actual fix for "secrets
#     in Terraform state" -- better than a local encrypted file, which the
#     harness could not read anyway, since it runs inside AWS.
#   * It is a normal resource, so `terraform destroy` removes it. No forgotten
#     resource and no manual teardown step.
#
# Rotating the key: change var.litellm_api_key AND bump
# var.litellm_api_key_version together, or Terraform will not resend the value.
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_api_key_credential_provider" "litellm" {
  count = local.use_litellm ? 1 : 0
  name  = var.litellm_credential_provider_name

  # Write-only: never written to state. The version is derived from the key so
  # the pair always moves together (see local.litellm_api_key_version).
  api_key_wo         = local.litellm_api_key_set ? var.litellm_api_key : null
  api_key_wo_version = local.litellm_api_key_version

  lifecycle {
    precondition {
      condition     = var.litellm_api_key != null && var.litellm_api_key != ""
      error_message = "litellm_api_key is empty. Set it out-of-band:\n  export TF_VAR_litellm_api_key=sk-...\n(or use -var model_backend=bedrock)."
    }
  }
}

# A separate role policy rather than another statement inside
# aws_iam_role_policy.harness, so the Bedrock-only path needs no change.
# The three statements are the ones the AgentCore "harness security" page
# prescribes for an API key credential provider.
resource "aws_iam_role_policy" "harness_litellm" {
  count = local.use_litellm ? 1 : 0
  name  = "harness-litellm-token-vault"
  role  = aws_iam_role.harness.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AgentCoreApiKeyTokenVaultDefault"
        Effect = "Allow"
        Action = "bedrock-agentcore:GetResourceApiKey"
        Resource = [
          "arn:aws:bedrock-agentcore:${var.region}:${local.account_id}:token-vault/default",
          "arn:aws:bedrock-agentcore:${var.region}:${local.account_id}:workload-identity-directory/default",
          "arn:aws:bedrock-agentcore:${var.region}:${local.account_id}:workload-identity-directory/default/workload-identity/harness_${var.harness_name}-*",
        ]
      },
      {
        Sid      = "AgentCoreApiKeyTokenVaultPerKey"
        Effect   = "Allow"
        Action   = "bedrock-agentcore:GetResourceApiKey"
        Resource = aws_bedrockagentcore_api_key_credential_provider.litellm[0].credential_provider_arn
      },
      {
        # AgentCore stores a MANAGED key under a service-owned secret named
        # bedrock-agentcore-identity!default/apikey/<provider-name>-*. That name
        # is service-generated, so the trailing wildcard is required.
        Sid      = "AgentCoreApiKeySecret"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = "arn:aws:secretsmanager:${var.region}:${local.account_id}:secret:bedrock-agentcore-identity!default/apikey/${var.litellm_credential_provider_name}-*"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Harness and its execution role
# ---------------------------------------------------------------------------

resource "aws_iam_role" "harness" {
  name = "${var.name_prefix}-harness"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:bedrock-agentcore:${var.region}:${local.account_id}:*" }
      }
    }]
  })
}

# Scoped-down version of the documented sample execution role policy
# (devguide/harness-security.html): model, image pull, logs, traces, metrics,
# workload identity, and the one gateway it may call. No browser, code
# interpreter, or memory statements because this harness uses none of them.
resource "aws_iam_role_policy" "harness" {
  name = "harness-execution"
  role = aws_iam_role.harness.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "BedrockModelInvocation", Effect = "Allow", Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"], Resource = local.bedrock_model_resources },
      { Sid = "EcrPublicTokenAccess", Effect = "Allow", Action = "ecr-public:GetAuthorizationToken", Resource = "*" },
      { Sid = "StsForEcrPublicPull", Effect = "Allow", Action = "sts:GetServiceBearerToken", Resource = "*" },
      { Sid = "XRayTracingAccess", Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"], Resource = "*" },
      { Sid = "CloudWatchLogsGroup", Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:DescribeLogStreams"], Resource = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*" },
      { Sid = "CloudWatchLogsDescribeGroups", Effect = "Allow", Action = "logs:DescribeLogGroups", Resource = "arn:aws:logs:${var.region}:${local.account_id}:log-group:*" },
      { Sid = "CloudWatchLogsStream", Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*" },
      { Sid = "CloudWatchMetricsPublish", Effect = "Allow", Action = "cloudwatch:PutMetricData", Resource = "*", Condition = { StringEquals = { "cloudwatch:namespace" = "bedrock-agentcore" } } },
      {
        Sid    = "AgentCoreWorkloadIdentity"
        Effect = "Allow"
        Action = ["bedrock-agentcore:GetWorkloadAccessToken", "bedrock-agentcore:GetWorkloadAccessTokenForJWT"]
        Resource = [
          "arn:aws:bedrock-agentcore:${var.region}:${local.account_id}:workload-identity-directory/default",
          "arn:aws:bedrock-agentcore:${var.region}:${local.account_id}:workload-identity-directory/default/workload-identity/harness_${var.harness_name}-*",
        ]
      },
      # TODO (student) 2: the harness calls your tools through the gateway.
      # Add the one statement that allows it, scoped to this gateway's ARN.
      # Symptom if missing: every invocation fails with "Failed to load tool
      # 'northstar_tools' ... 403 Forbidden" on the gateway URL.
    ]
  })
}

resource "aws_bedrockagentcore_harness" "this" {
  harness_name       = var.harness_name
  execution_role_arn = aws_iam_role.harness.arn
  max_iterations     = 8
  max_tokens         = 1024
  timeout_seconds    = 120

  # Exactly one of these is emitted; model_backend selects which.
  model {
    dynamic "litellm_model_config" {
      for_each = local.use_litellm ? [1] : []
      content {
        model_id    = var.litellm_model_id
        api_base    = var.litellm_api_base
        api_key_arn = aws_bedrockagentcore_api_key_credential_provider.litellm[0].credential_provider_arn
        max_tokens  = 1024
      }
    }

    dynamic "bedrock_model_config" {
      for_each = local.use_litellm ? [] : [1]
      content {
        model_id   = local.bedrock_invoke_model_id
        max_tokens = 1024
      }
    }
  }

  system_prompt {
    text = file("${path.module}/system_prompt.md")
  }

  tool {
    type = "agentcore_gateway"
    name = "northstar_tools"
    config {
      agentcore_gateway {
        gateway_arn = aws_bedrockagentcore_gateway.this.gateway_arn
        outbound_auth {
          aws_iam = true
        }
      }
    }
  }

  memory {
    disabled {}
  }

  # Runtime memory is billed for each session's lifetime, idle time included,
  # and it dominates the AgentCore bill (F13). Null = service default.
  dynamic "environment" {
    for_each = var.idle_session_timeout_seconds == null ? [] : [1]
    content {
      agentcore_runtime_environment {
        lifecycle_configuration = [{
          idle_runtime_session_timeout = var.idle_session_timeout_seconds
          max_lifetime                 = var.max_session_lifetime_seconds
        }]
        network_configuration {
          network_mode = "PUBLIC"
        }
      }
    }
  }

  depends_on = [aws_iam_role_policy.harness, aws_iam_role_policy.harness_litellm]
}
