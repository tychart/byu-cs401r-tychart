variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for IAM roles and the tools Lambda"
  type        = string
  default     = "northstar-agent"
}

variable "gateway_name" {
  type    = string
  default = "northstar-tools-gw"
}

variable "harness_name" {
  description = "Letters, digits, underscores; max 40 chars"
  type        = string
  default     = "northstar_agent"
}

variable "credit_cap_dollars" {
  description = "Largest loyalty credit the gateway will let the agent apply in one call"
  type        = number
  default     = 50
}

variable "idle_session_timeout_seconds" {
  description = <<-EOT
    Seconds an idle harness session keeps running. Memory is billed for that
    whole time. The AWS default is 900 s; measured on the same six calls,
    900 s cost $0.106 of runtime and 60 s cost $0.020. Do not raise it.
  EOT
  type        = number
  default     = 60
}

variable "max_session_lifetime_seconds" {
  type    = number
  default = 3600
}

# ── Model backend ────────────────────────────────────────────────────────────
# The harness ships configured for Anthropic Claude Haiku 4.5 on Bedrock. This
# stack defaults to a model on your own LiteLLM proxy instead, and keeps the
# Bedrock path behind a switch. Neither choice touches the gateway, the Cedar
# policies or the tools, so the rest of Track C is unaffected.

variable "model_backend" {
  description = <<-EOT
    Which model backend the harness uses.

      "litellm" (default) - a model on your own LiteLLM proxy. Cheap, no
                            Anthropic, and no Bedrock model access needed for
                            the agent loop. Requires litellm_api_key.
      "bedrock"           - a Bedrock-hosted model (bedrock_model_id). No
                            external dependency; the fallback if the proxy is
                            unreachable during grading.
  EOT
  type        = string
  default     = "litellm"

  validation {
    condition     = contains(["litellm", "bedrock"], var.model_backend)
    error_message = "model_backend must be \"litellm\" or \"bedrock\"."
  }
}

variable "bedrock_model_id" {
  description = <<-EOT
    Bedrock model ID used when model_backend = "bedrock". Deliberately a small
    open-weight model rather than Anthropic:
      openai.gpt-oss-20b-1:0   Apache-2.0, $0.07/$0.30 per 1M tokens
    Other cheap options in us-east-1: qwen.qwen3-32b-v1:0 (Apache-2.0),
    mistral.ministral-3-8b-instruct (Apache-2.0), zai.glm-4.7-flash.
  EOT
  type        = string
  default     = "openai.gpt-oss-20b-1:0"
}

variable "bedrock_model_profile_prefix" {
  description = <<-EOT
    Cross-region inference profile prefix for the Bedrock backend: "us.",
    "global.", or "" for plain on-demand invocation by the bare model ID.
    Defaults to "" because the model above has no inference profile and the
    us./global. requirement is specific to Claude 4.5+.
  EOT
  type        = string
  default     = ""
}

variable "litellm_model_id" {
  description = <<-EOT
    Model name exactly as your LiteLLM proxy knows it -- the "id" field from
    GET <litellm_api_base>/models. The harness sends it verbatim as the
    "model" field, so an alias mismatch is a 400 from the proxy.
  EOT
  type        = string
  default     = "deepseek-flash"
}

variable "litellm_api_base" {
  description = <<-EOT
    OpenAI-compatible root of the LiteLLM proxy INCLUDING the /v1 suffix (the
    harness appends /chat/completions). Must be reachable from the public
    internet: the harness runtime runs with network_mode = "PUBLIC".
  EOT
  type        = string
  default     = "https://litellm.tychart.com/v1"
}

variable "litellm_credential_provider_name" {
  description = <<-EOT
    Name of the AgentCore Identity API key credential provider that holds the
    LiteLLM proxy key. Becomes the last segment of the ARN the harness uses:
      arn:aws:bedrock-agentcore:<region>:<acct>:token-vault/default/apikeycredentialprovider/<this>
    Allowed characters: letters, digits, dot, dash.

    The key lives in AgentCore's token vault, not in Secrets Manager and not in
    a local file. AgentCore Identity is not charged when it is used through
    AgentCore Runtime, so this costs nothing, and the default token vault
    already exists in the account.
  EOT
  type        = string
  default     = "northstar-litellm"
}

variable "litellm_api_key" {
  description = <<-EOT
    LiteLLM proxy API key. Create a DEDICATED key for this lab rather than
    reusing your personal one, so it can be revoked on its own.

    Supply it out-of-band so it never reaches the repository:

      read -rs KEY
      export TF_VAR_litellm_api_key="$KEY"
      unset KEY

    This is consumed by a Terraform WRITE-ONLY argument (api_key_wo), so the value
    is sent to AWS and is never persisted to terraform.tfstate. "read -rs" keeps
    it out of your shell history as well.

    Rotation is automatic: the write-only version counter is derived from the key
    itself, so a new key is detected and resent without you bumping anything.
  EOT
  type        = string
  sensitive   = true
  default     = null
}
