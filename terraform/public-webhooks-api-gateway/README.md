# OpsRabbit public webhooks through API Gateway

Expose `/webhooks/*` over HTTPS on a dedicated hostname. API Gateway forwards requests through VPC Link V2 to the existing private EC2 web listener on HTTP port `3000`. Cloud Map registers the instance's private IPv4 address and port. This stack requires no load balancer.

```text
Webhook sender --HTTPS--> API Gateway --VPC Link / HTTP--> Private EC2
                               |
                               +-- Look up IP and port --> Cloud Map
```

## Requirements

- An existing EC2 instance with the OpsRabbit web listener reachable on its primary private IPv4 address. Check `/api/health` from a trusted client inside the VPC.
- Subnets in the instance's VPC in [Availability Zones supported by VPC Link V2](https://docs.aws.amazon.com/apigateway/latest/developerguide/apigateway-vpc-links-v2.html). Use private subnets and ensure they have free IPs for the link's network interfaces.
- A dedicated webhook hostname and an issued ACM certificate in the same region covering that hostname. Use a separate hostname to test alongside the [ALB example](../public-webhooks/README.md).
- Terraform 1.6 or later and AWS credentials for the deployment account.

Before applying, review every inbound reachable under `/webhooks/*` and configure its token or provider authentication. API Gateway forwards these requests to OpsRabbit for validation.

## Setup

The private hop defaults to HTTP port `3000`. For an existing HTTPS listener, set `target_port` to its port and `target_tls_server_name` to a DNS name covered by its trusted certificate. API Gateway uses that name for TLS verification on the private hop.

```sh
cp terraform.tfvars.example terraform.tfvars
# Fill in your AWS IDs, hostname and certificate.
terraform init
terraform validate
terraform plan -out=webhooks.tfplan
terraform apply webhooks.tfplan
```

Set `route53_zone_id` to create a public A alias in an existing Route 53 zone. For an externally managed subdomain, point its CNAME at the `api_gateway_dns_name` output. Send requests to the existing inbound path on the new hostname, for example `https://hooks.example.com/webhooks/inbound/my-inbound`.

## Webhook access

- The gateway routes only `/webhooks/{proxy+}` and forwards the request to OpsRabbit.
- Send `X-OpsRabbit-Webhook-Token` for inbounds configured to use it. OpsRabbit validates the credential. Keep token values out of Terraform inputs and state.
- By default, the public route accepts requests from any source. Missing or invalid credentials reach OpsRabbit for validation.
- Use the custom hostname. The generated `execute-api` endpoint is disabled.

See [operating notes](OPERATIONS.md) for rollout checks, target replacement and costs.


## Optional source IP allowlist

Set both inputs to restrict callers using a Python Lambda authorizer:

```hcl
enable_source_allowlist = true
allowed_source_cidrs    = ["192.0.2.0/24", "2001:db8::/32"]
```

Replace these documentation ranges with your senders' actual public egress ranges. The feature defaults to disabled. Enabling requires at least one CIDR, with up to 50 IPv4 or IPv6 entries. Host bits in CIDRs are normalized to their network.

The authorizer checks API Gateway's request context source IP for every request, with caching disabled. Forwarded headers do not affect the decision. Requests outside the allowlist receive 403 before reaching OpsRabbit. An allowed source still needs the token or provider credentials configured in OpsRabbit.

The enabled option creates a Lambda function, execution role and invocation permission. The function uses Python's standard library and has permission only to submit X-Ray diagnostics and has no log-writing permissions. Terraform packages its source. Budget for Lambda request and compute charges. Disable and apply to remove the authorizer resources.

The enabled Lambda uses active X-Ray tracing for infrastructure diagnostics. AWS retains X-Ray traces for 30 days. Operator IAM controls access. Trace metadata follows AWS retention independently of inbound deletion or Terraform destroy. The handler does not record tokens, headers or payloads. Include tracing usage in cost estimates.
