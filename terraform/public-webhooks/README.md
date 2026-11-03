# OpsRabbit public webhook ALB

Expose `/webhooks/*` through a public HTTPS ALB targeting the EC2 web listener on HTTP port `3000`.

## Requirements

- Existing EC2 instance, VPC and public subnets across at least two availability zones.
- Web listener reachable on the instance’s primary private IP; `/api/health` returns 200.
- ACM certificate covering `opsrabbit_hostname`, in the ALB’s region.
- Terraform >= 1.6 and AWS credentials for the target account.

## Setup

```sh
cp terraform.tfvars.example terraform.tfvars
# Fill in your AWS resource IDs, hostname and certificate.
terraform init
terraform validate
terraform plan -out=webhooks.tfplan
terraform apply webhooks.tfplan
```

Set `route53_zone_id` for a public A alias, or point your hostname’s CNAME at the `alb_dns_name` output. Set `target_port` if the web listener uses a different port.

Set `access_log_bucket` to enable access logging to an existing S3 bucket.

## Webhook access

- Header: non-empty `X-OpsRabbit-Webhook-Token`; configure its value separately on each inbound in OpsRabbit.
- IP ranges: `allowed_webhook_cidrs` defaults to `["0.0.0.0/0"]`. Set provider egress CIDRs to restrict access.
- Unmatched requests return **404**. OpsRabbit validates each inbound’s token.

[Logging, verification and future UI access](OPERATIONS.md).
