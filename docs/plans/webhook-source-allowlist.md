# Optional webhook source allowlist

Add an opt-in Python Lambda authorizer to the HTTP API example. Disabled deployments create no Lambda or IAM resources. Enabled deployments require explicit IPv4 or IPv6 CIDRs and evaluate the API Gateway request context source IP on every request. OpsRabbit owns token and tenant authorization. Keep the webhook-only route and default port 3000.

The authorizer is an operator-managed infrastructure control. It has no application grants and only X-Ray submission permissions. CIDRs are infrastructure configuration in Terraform state and the Lambda deployment package. Requests, tokens and source IPs are transient. The handler records no request content. Active X-Ray tracing creates infrastructure diagnostics under operator IAM and AWS fixed 30-day retention, independent of inbound deletion and destroy. State history and tracing are operator infrastructure records. Trace deletion and restore follow AWS service retention. Destroy removes managed resources. Operators govern historical state and backups.

Verify default-disabled and enabled plans, invalid/empty CIDRs, route authorization and uncached source evaluation. Python tests exercise IPv4/IPv6 boundaries, missing context, spoofed forwarded headers and independent token handling. No live apply is requested.
