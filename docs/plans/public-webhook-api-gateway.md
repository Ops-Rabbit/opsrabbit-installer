# Public webhook ingress through API Gateway

Add a standalone Terraform example for a public Regional HTTP API forwarding webhook requests to an existing private EC2 instance through VPC Link V2 and Cloud Map. Finish with example inputs, setup and operating notes, mocked Terraform plans. AWS deployment is an operator step.

Use a root custom-domain mapping with the default execute-api endpoint disabled. Expose only `ANY /webhooks/{proxy+}` with gateway authorization set to NONE. The public gateway forwards requests from any source and preserves the webhook path. OpsRabbit retains per-inbound authentication and tenant authorization. The gateway does not grant any application role, ownership, resource grants or writeback capability. Operator AWS IAM controls infrastructure and state. The only new network grant permits the VPC Link security group to reach the existing web port. Existing groups require operator review.

Cloud Map and Terraform state hold infrastructure configuration and target metadata under operator IAM. The HTTP namespace uses API discovery. API access logging is disabled. Terraform destroy deregisters the target and removes managed ingress resources. Operators govern state history, backups and holds. OpsRabbit remains responsible for webhook payload lifecycle. Operators monitor private target health and reconcile the registration after EC2 replacement.

Prior art reviewed:

- `applied-ai-consulting/claude-code` at `dfb44640ca1c2b64b882a15edf73ec0374d41d9a`, `services/api/sessionIngress.ts`. Explicit token checks at the application boundary fit. Session persistence and synchronization do not apply.
- [OpenAI Codex network proxy README](https://github.com/openai/codex/blob/main/codex-rs/network-proxy/README.md). Scoped network allowances fit. The local proxy implementation and process sandbox do not apply.

Verify the Terraform plan with a mocked AWS provider. Live verification requires a disposable authenticated inbound and a customer AWS environment.

## Local verification

Terraform 1.14.7 initialized with the readonly provider lockfile and validated the configuration. Three mocked plans passed for the webhook route and private integration, custom port and optional DNS, and rejection of a mismatched VPC. Live testing verified HTTPS on private port 443 with certificate name verification, 404 responses for unrelated public paths, and a sample POST that created an inbound event and started an investigation. The test inbound had no token configured. Token rejection and live delivery on the default HTTP port 3000 were not tested.
