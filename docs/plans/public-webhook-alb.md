# Public webhook ALB client reference

## Scope and finishing criteria

Keep a standalone client Terraform root at `terraform/public-webhooks`, outside `bundle/`. Create a public HTTPS ALB for an existing installer EC2 deployment with hostname, webhook-path, non-empty token-header and source-CIDR conditions. Default sources are all IPv4. Reject unmatched traffic and preserve a separate webhook rejection before future UI forwarding. Include example inputs, client guide, offline tests and local validation. Open a ready installer PR after independent reviews, autoreview and local strict Semgrep. No apply, host modification, image release or paid CI dispatch.

## Final design

User chose the existing web listener (HTTP 3000 by default) as the ALB target. Nginx forwards webhooks unchanged and `/api/health` to backend `/health`. Keep backend loopback binding and installer unchanged; the initially explored private-backend publishing feature is omitted. Existing primary-ENI instance target, same-VPC/availability-zone checks, dedicated ALB and target SG attachment, regional ACM certificate, optional public DNS alias. Existing groups are preserved and must be audited. Each forward rule includes host/path/header/source gates and at most two CIDRs (five match evaluations). Forward priorities 100–149 precede explicit path rejection at 200; future UI rules must use 300 or later and retain rejection/default rules. No UI access is enabled now.

## Authorization matrix

| Surface | Authority |
| --- | --- |
| Qualified webhook | Public network ingress; existing backend instance-token/provider authentication and tenant/resource authorization |
| Unqualified webhook | Explicit ALB 404 before any future UI fallback |
| UI/API/other hosts | Default ALB 404; existing private access unchanged |
| Target web port | New grant only from dedicated ALB SG; prior instance SG rules are outside this root |
| Infrastructure/logs | Operator AWS IAM and customer-owned state/S3 controls, no application-role changes |

The default header name is `X-OpsRabbit-Webhook-Token`, verified in the host generic provider and inbound guide. ALB `?*` checks presence only; each exposed generic instance must have its own token configured. Tokens are not Terraform inputs or state values. No plugin-facing contract or writeback change.

## Data lifecycle inventory

State contains infrastructure identifiers and configuration; operators own protected/encrypted state and backups. Access logging is disabled by default at the user’s request; supplying optional `access_log_bucket` enables delivery to an existing organization-managed bucket with prefix scoped to this ALB name. This reuses an external operational/security diagnostic store rather than creating an unclassified bucket. Logs contain IPs/URLs/metadata; no payload or token should be placed in URLs. Customer must configure same-region SSE-S3, least-privilege ALB delivery and reader permissions, retention/eligibility policy, version handling, deletion and legal holds before apply. This root does not set or claim a retention default for an existing customer bucket. IAM-authorized bucket owner manages deletion; application resource grants and retention do not govern this archive. ALB/tenant/inbound deletion does not erase logs, backup copies or held records. Disabling/destroying ingress stops future delivery; restore/reconciliation of archived logs remains with customer bucket policy. Existing application canonical/derived stores and legal-hold/deletion mechanisms are unchanged.

## Prior art

- `applied-ai-consulting/claude-code` at dfb44640ca1c2b64b882a15edf73ec0374d41d9a, `services/api/sessionIngress.ts`: explicit ingress authentication fits; session transcript retries/synchronization are rejected for this network reference.
- `openai/codex` at 9e23a4708a769e7a4ad0b0ffef933950277e05fe, `docs/sandbox.md` and `README.md`: separate runtime authority from configuration; no relevant ALB implementation identified, CLI/install architecture is not copied.
- Verified installer `bundle/docker-compose.yml`: web port 3000 and loopback-only backend publishing. Verified host `web/nginx/http.conf.template` and backend route mounting for webhooks/health. AWS documentation confirms header wildcard semantics, five match evaluations per rule, primary-IP instance targeting, and log bucket requirements.

## Verification and review

Initial independent reviews identified preservation of custom configuration and matching the primary target address in the explored backend-binding approach. Final user-approved scope removes that feature entirely and documents primary web targeting. The required strict Semgrep scan identified missing access logging; initial design enabled it through an existing governed bucket; user subsequently chose optional logging, disabled by default. Review the final Terraform/docs/CI candidate again after these scope changes. Test default and custom web ports, all forwarding gates, CIDR splitting/invalid inputs, default and explicit rejection, header-name override and log configuration with a mock provider. Local checks use the provider lockfile and mocked provider; no AWS credentials or resources. Live plan, delivery, log delivery and UI rollout checks remain unperformed/operator-owned.

## Local closeout

Terraform readonly initialization, validation and mocked plan checks pass. Final autoreview found ALB name validation accepted a trailing hyphen or reserved `internal-` prefix; checked the AWS CreateLoadBalancer contract, reproduced missing variable-level rejection in a new regression test before the fix, tightened validation and added negative checks. Independent Terraform/security and integration/docs/CI reviews reported no other P0–P2 findings. Full pinned strict Semgrep is rerun after the validation fix; no suppressions or scope exclusions are added. No backend/frontend product files change, so their line-coverage gates and Node lint scripts do not apply to this installer Terraform-only PR. No AWS apply or live reachability is claimed.

## Client documentation follow-up

Trimmed the client README to prerequisites, setup and access rules; moved operational logging, verification and future-UI details into OPERATIONS.md. Removed backend-port references from the client reference. Hosted Linux CI exposed a provider lockfile platform-checksum mismatch; regenerate signed checksums explicitly for Linux amd64/arm64 and macOS arm64, retain readonly CI initialization and verify on Linux before pushing.

User explicitly requested no `.github/workflows/validate.yml` changes. Restored that file to the PR base; no workflow changes remain in the proposed PR. Access logs are optional, with explicit default-disabled and bucket-enabled checks.

Follow-up checks: signed HashiCorp checksums recorded for Linux amd64/arm64 and macOS arm64; readonly local initialization, validation, formatting and ten mocked plan checks passed. A Linux runtime rerun and fresh Docker-based Semgrep scan were unavailable because the Docker daemon was stopped; the earlier full strict scan passed on the prior configuration. No scanner exclusions or suppressions added. Client ZIP rebuilt with minimal README, separate operating notes, optional logging and no backend-port references.
