# Upgrade image cleanup

## Scope and finishing criteria

Prevent tagged OpsRabbit release images filling the host disk. Clean older unused
product images before pulls and after successful release verification. Preserve
current/pending/candidate pins, configured sandbox, all container image identities
(including stopped containers), unrelated repositories, custom tags and newer releases.
No forced removal, volume/container deletion, database changes or live deployment.
Prove selection and failure behavior through deterministic Docker CLI fixtures.

## Design, authorization and lifecycle

Run within the existing host-administrator CLI and release lock. No API, tenant
resource, grant or authorization change. Images are host operational artifacts;
only SemVer-tagged backend/web/sandbox images in the configured ECR registry are
eligible when older than that repository’s installed release pin (sandbox versions
are independent of product versions). No new store or retention setting.
Customer volumes, backups and logs remain untouched. Older images are re-pullable;
database-compatible recovery still requires the documented backup procedure.
Pre-pull cleanup preserves the installed release even if the upgrade fails;
post-commit cleanup makes its old unused images eligible. Cleanup failures are
reported as errors, without undoing an already verified/committed release.

## Prior art reviewed

- applied-ai-consulting/claude-code, `Tool.ts`, commit
  `dfb44640ca1c2b64b882a15edf73ec0374d41d9a`: reviewed centralized permission/result
  types. Adopt explicit destructive-operation boundaries; reject adding agent
  permission infrastructure to an existing administrator CLI.
- openai/codex, `codex-rs/core/src/tools/handlers/apply_patch.rs`, commit
  `2c502d8b3d382dd609179164f31396d95deee55c`: reviewed structured patch operations
  and error propagation. Adopt explicit bounded targets and surfaced errors;
  reject importing sandbox/orchestrator architecture for Docker maintenance.

## Verification and closeout

Completed locally:
- The extended production CLI lifecycle suite passes in an owned disposable Ubuntu
  24.04 container with deterministic Docker/catalog fixtures. The same suite with
  the original release library fails as expected because cleanup never executes.
- Release discovery, operations-helper, AWS-authentication and HTTPS suites pass.
- Bash syntax checks for every checked-in shell entrypoint/test and diff whitespace
  checks pass. Native macOS Bash 3 cannot parse existing Bash 4 constructs; final
  syntax validation used the supported Linux Bash environment.
- Two independent read-only reviews completed. Fixed both findings: per-repository
  sandbox cutoff and non-vacuous status/restart preservation assertions. Added
  digest/alias coverage. Follow-up review found no remaining issues.
- Autoreview of the complete local changes against ac91868 reported scoped-clean
  through P2, with no accepted findings. Report is outside the repository at
  `/Users/aaic/work/installer-image-cleanup-review.md`.
- Full pinned Semgrep 1.179.0 strict scan completed with all parsed lines and no
  parsing/timeouts reported, but exits 1 for the pre-existing
  `terraform.aws.security.aws-elb-access-logs-not-enabled.aws-elb-access-logs-not-enabled`
  finding at `terraform/public-webhooks/main.tf:55`. Logging is optional through
  `access_log_bucket`; that unrelated configuration was preserved. The first
  attempt lacked linked-worktree Git mounts; rerunning with read-only Git mounts
  removed that warning and reproduced the sole finding. This blocks PR creation
  under the supplied repository instructions. No exclusions or suppressions added.
- This installer repository has no package.json, pnpm lint:quality script or
  backend/frontend product files; those workspace-specific checks and V8 coverage
  do not apply to this shell-only change.

At initial closeout, no PR was opened and no paid CI, production helper update or
upgrade was started. The user subsequently explicitly requested PR publication;
PR #31 was opened with the unrelated full-scan finding disclosed.


## Patch release follow-up

The user requested publishing a patch installer release and correcting README
links. Latest published installer was v1.5.1; select v1.5.2. Update both README
fresh-install instructions and root existing-host migration links to that immutable
release. Keep the bootstrap source unpinned: the existing tag-triggered release
workflow stamps default_version into the published install.sh asset. Publish all
three assets (bootstrap, bundle, SHA-256), verify their checksum and version pin,
and verify the bundled cleanup code matches the released commit. No customer host
upgrade is included. PR #31 validation passed for 774e886; review/validation of the
follow-up and release verification are pending. The user explicitly requested the
PR after disclosure of the existing Semgrep finding; that finding remains recorded.


Follow-up review: independent documentation review found no issues. Full-scope
release autoreview reported two findings, both adjudicated against source:
- P1 historical sandbox cutoff: invalid for installer-produced release state.
  `release_validate` requires a SemVer sandbox pin before `current.json` is written,
  including the initial implementation at 3bbdc5d and published v1.5.1. Historical
  build tags occur in `.env`, which is separately preserved/adopted; cleanup does
  not use that value as its version cutoff. No validation weakening or fallback
  was added for externally corrupted manifests.
- P2 index-only old README links: addressed by staging and committing the complete
  reviewed README delta. Working-tree links already used v1.5.2 during review.

The follow-up changes only documentation; prior product-code verification remains
applicable. Release workflow and published asset checks will verify v1.5.2 after
publication; no customer-host deployment is part of this request.
