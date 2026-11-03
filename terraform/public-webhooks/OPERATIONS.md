# Operating notes

## Adding UI access later

This reference currently exposes webhooks only. The same ALB and web target can serve the UI later. Preserve this priority order:

1. **100–149:** qualified webhook requests forward.
2. **200:** remaining `/webhooks` and `/webhooks/*` requests are explicitly rejected.
3. **300 or later:** add UI/API forwarding with the intended hostname and client network restrictions.
4. **Default:** reject unmatched requests.

Keep the explicit webhook rejection ahead of any UI catch-all rule, so a missing header or disallowed source cannot fall through to UI forwarding. UI requests should not require the webhook token. When enabling UI access, configure OpsRabbit’s public origin/base URL, trusted authentication proxy and TLS settings for the chosen hostname; review the application’s normal access controls as part of that separate rollout.

## Access logs

Access logging is disabled by default. To enable it, set `access_log_bucket` to a private same-region bucket with SSE-S3, managed by your organization. Logs use prefix `name` (default `opsrabbit-hooks`); prepare log-delivery permissions for `<prefix>/AWSLogs/<ALB-account-id>/*` using the [AWS access-log bucket requirements and policy](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html). Terraform enables delivery but does not create or modify that bucket or policy.

Access logs contain client IPs, request URLs and operational metadata. Never put tokens or customer payloads in URLs. Restrict log access and configure retention/deletion, version handling and any legal holds under your organization’s log policy before applying. Application retention does not delete S3 logs; deleting this ALB does not delete the bucket, existing logs or backups. Disable delivery or destroy the ALB before deleting/reusing its log bucket.

## Verify after deployment

Confirm target health, then check with a disposable test inbound:

- Missing/empty header → ALB 404; incorrect instance token on a POST → backend rejection.
- Correct instance token and valid payload → successful delivery; another instance’s token → backend rejection.
- `/`, `/api/health`, wrong hostname or disallowed source IP → ALB 404, even with a token.
- Private application access and access-log delivery (if enabled) still work.

GET probes do not prove token validation or event processing. Keep tokens out of shared logs, shell history and URLs. All webhook routes share this header requirement, including providers using other signature headers.

The dedicated target security group restricts the new web-port grant to the ALB; existing groups remain attached. Audit older groups and host firewall rules for direct public access. TLS terminates at the ALB and the private web hop uses HTTP. Deletion protection defaults to true; disable it and apply before destroying ingress. The instance, existing groups and log bucket are preserved.

Offline plan checks: `terraform test` (Terraform >= 1.7). [AWS listener condition behavior](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/rule-condition-types.html).
