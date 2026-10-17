# TODO 1 — the first apply is supposed to fail (captured 2026-10-17)

The AgentCore gateway enforces the Cedar policies, so its execution role needs
`bedrock-agentcore:GetPolicyEngine`, `AuthorizeAction` and
`PartiallyAuthorizeActions`. With that statement absent, `CreateGateway` checks
the role **before** creating anything and fails. Captured verbatim from the first
`terraform apply` in `infrastructure/environments/agent/`:

```
$ terraform -chdir=infrastructure/environments/agent apply -auto-approve

aws_bedrockagentcore_gateway.this: Creating...
aws_bedrockagentcore_gateway.this: Still creating... [02m20s elapsed]

Error: creating Bedrock AgentCore Gateway

  with aws_bedrockagentcore_gateway.this,
  on main.tf line 183, in resource "aws_bedrockagentcore_gateway" "this":
 183: resource "aws_bedrockagentcore_gateway" "this" {

ID: "northstar-tools-gw"
Cause: operation error Bedrock AgentCore Control: CreateGateway, ,
ValidationException: Access denied while calling GetPolicyEngine on Policy
Engine:
arn:aws:bedrock-agentcore:us-east-1:345594594463:policy-engine/northstar_agent_policies-r5bn3ua5af
with Gateway role: arn:aws:iam::345594594463:role/northstar-agent-gateway.
Confirm this role has bedrock-agentcore:GetPolicyEngine permissions and retry
your request
```

## What this proves

* The error names **one** missing action per attempt (`GetPolicyEngine` here),
  which is why the docs say to add all three at once rather than iterating.
* The failure is at **create time**, not first invocation, because
  `CreateGateway` validates the role against the policy engine up front.
* Everything upstream still applied: the tools Lambda, the policy engine, both
  IAM roles and their policies. Only the gateway and its dependents (target,
  policies, harness) were held back, so the retry creates them and nothing is
  orphaned.

## Fix applied

`aws_iam_role_policy.gateway` gained two statements scoped to the policy engine
ARN and `local.gateway_glob` (the gateway ARN does not exist yet at that point):

* `policy-engine:GetPolicyEngine` on the policy engine ARN
* `policy-engine:AuthorizeAction` + `PartiallyAuthorizeActions` on the policy
  engine ARN **and** the gateway ARN — both resources are required, per
  <https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/policy-permissions.html>

The second apply completed with the gateway, target, both Cedar policies and the
harness. No further IAM change was needed.
