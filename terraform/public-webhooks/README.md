# OpsRabbit public webhook ALB

Terraform reference for an existing private EC2 instance installed with OpsRabbit. It creates a public HTTPS ALB and uses the existing web proxy:

```text
Webhook sender → ALB HTTPS :443 → EC2 HTTP :3000 → nginx → backend :8384
```

No installer or backend binding changes are required. The backend stays on loopback; nginx already forwards `/webhooks/*` to it. Keep the application’s private DNS unchanged.

A request forwards only when these conditions match:

| Condition | Setting |
| --- | --- |
| Hostname | `opsrabbit_hostname` |
| Path | `/webhooks/*` |
| Header | Non-empty `X-OpsRabbit-Webhook-Token` (name can be overridden) |
| Source IP | `allowed_webhook_cidrs`, default `["0.0.0.0/0"]` |

Other requests receive **404**. Port 80 is closed. Configure a **Webhook Token on each exposed inbound in OpsRabbit** and send that instance’s token in the header. The ALB checks non-empty presence (`?*`); OpsRabbit validates each instance’s token. Generic webhook instances without a configured token accept unauthenticated intake. Tokens are not Terraform inputs.

## Requirements

- Existing VPC and EC2 instance; public ALB subnets in at least two availability zones, including the instance’s zone. Subnets need Internet Gateway routes, free addresses and working network ACLs. The instance needs no public IP for ALB ingress.
- The installer’s web HTTP listener on the primary EC2 private IP, normally port `3000`. Set `target_port` if `WEB_HTTP_PORT` differs. `/api/health` must return 200; nginx forwards that to backend `/health`. If the web listener was made loopback-only or HTTP was disabled, restore private-network HTTP reachability through the deployment’s supported web configuration first.
- Issued ACM certificate in the ALB’s region covering `opsrabbit_hostname`.
- Existing private S3 access-log bucket in the same region, with SSE-S3 encryption, ALB log-delivery permissions and your retention policy. See logging below.
- Terraform >= 1.6, AWS credentials for the intended account and protected state. Allow one additional security group on the primary ENI; coordinate ownership with any stack managing its complete group list.

## Use

Open `terraform/public-webhooks` in the installer repository (or copy this directory), then fill in the example:

```sh
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform validate
terraform plan -out=webhooks.tfplan
# Review account, target, security groups and DNS before applying.
terraform apply webhooks.tfplan
```

Optional `route53_zone_id` creates an A alias in an existing public hosted zone. Otherwise create a CNAME from a non-apex hostname to the `alb_dns_name` output. `instance_private_ip` identifies the address used by the ALB target.

To restrict senders, replace these documentation ranges with actual provider egress CIDRs:

```hcl
allowed_webhook_cidrs = ["192.0.2.0/24", "198.51.100.10/32"]
```

Source matching uses the connection IP, not `X-Forwarded-For`; a proxy in front means its egress address. This reference is IPv4-only. Each pair of CIDRs creates one rule to respect ALB match limits; check account rule quotas for large lists.

## Adding UI access later

This reference currently exposes webhooks only. The same ALB and web target can serve the UI later, without exposing backend `8384`. Preserve this priority order:

1. **100–149:** qualified webhook requests forward.
2. **200:** remaining `/webhooks` and `/webhooks/*` requests are explicitly rejected.
3. **300 or later:** add UI/API forwarding with the intended hostname and client network restrictions.
4. **Default:** reject unmatched requests.

Keep the explicit webhook rejection ahead of any UI catch-all rule, so a missing header or disallowed source cannot fall through to UI forwarding. UI requests should not require the webhook token. When enabling UI access, configure OpsRabbit’s public origin/base URL, trusted authentication proxy and TLS settings for the chosen hostname; review the application’s normal access controls as part of that separate rollout.

## Access logs

Set `access_log_bucket` to a bucket already managed by your organization. Logs use prefix `name` (default `opsrabbit-hooks`); prepare log-delivery permissions for `<prefix>/AWSLogs/<ALB-account-id>/*` using the [AWS access-log bucket requirements and policy](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html). Terraform enables delivery but does not create or modify that bucket or policy.

Access logs contain client IPs, request URLs and operational metadata. Never put tokens or customer payloads in URLs. Restrict log access and configure retention/deletion, version handling and any legal holds under your organization’s log policy before applying. Application retention does not delete S3 logs; deleting this ALB does not delete the bucket, existing logs or backups. Disable delivery or destroy the ALB before deleting/reusing its log bucket.

## Verify after deployment

Confirm target health, then check with a disposable test inbound:

- Missing/empty header → ALB 404; incorrect instance token on a POST → backend rejection.
- Correct instance token and valid payload → successful delivery; another instance’s token → backend rejection.
- `/`, `/api/health`, wrong hostname or disallowed source IP → ALB 404, even with a token.
- Private application access and access-log delivery still work.

GET probes do not prove token validation or event processing. Keep tokens out of shared logs, shell history and URLs. All webhook routes share this header requirement, including providers using other signature headers.

The dedicated target security group restricts the new web-port grant to the ALB; existing groups remain attached. Audit older groups and host firewall rules for direct public access. TLS terminates at the ALB and the private web hop uses HTTP. Deletion protection defaults to true; disable it and apply before destroying ingress. The instance, existing groups and log bucket are preserved.

Offline plan checks: `terraform test` (Terraform >= 1.7). [AWS listener condition behavior](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/rule-condition-types.html).
