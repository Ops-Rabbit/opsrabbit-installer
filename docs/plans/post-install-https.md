# Post-install HTTPS

Scope: extend the Compose operations helper with optional Nginx TLS using user-supplied certificates. HTTP remains the default. No certificate provider, DNS automation, ACM or application dependency changes.

Finish: configure supports keep/redirect/disable HTTP modes, validated hostname/certificate/key and ports; reload supports certificate rotation; lifecycle commands retain TLS configuration; health checks work in every mode. Update both READMEs and deterministic shell regression tests. Do not deploy or modify remote infrastructure.

Design: retain the base Compose manifest and add a generated override with reset port mappings, Nginx environment, file mounts and a mode-aware health check. Require Compose 2.24.4+ for !override. Copy certificates into protected deployment directories, and back up configuration before activation. Roll back failed activation. Recreate web and daemon to apply origin changes; avoid unrelated containers.

Authorization/data: commands run with existing deployment-user Docker authority. No new application resource, grants or operational data store. Certificate private keys remain in mode-0700 host directories with readable mounted files for non-root Nginx. Existing secrets are preserved; rollback snapshots are temporary. Never print private keys or environment contents.

Verification: shell syntax, existing deploy test, real OpenSSL fixtures for valid/invalid certificates, mock Docker for command contracts and failed activation rollback. Real Docker/image/network deployment unavailable unless explicitly exercised; report separately.

## Closeout

Implemented `https configure` and `https reload --cert FILE --key FILE`; `keep`, `redirect`, and `disable` HTTP modes; optional HTTPS host port; credential-preserving origin updates; protected managed certificate copies; Compose override inclusion in regular operations; activation rollback; and verified HTTPS host health checks. Existing base Compose and installer defaults remain HTTP. Updated both READMEs and wired regression tests into the existing validation/release workflows.

Passed shell syntax and diff checks, the original deploy regression, and the new HTTPS shell regression suite using OpenSSL 3. Invalid hostname, mismatched/encrypted/missing keys or certificates, unsupported Compose, invalid options/ports, first-activation failure and reconfiguration rollback were exercised. The host's default LibreSSL lacks `x509 -checkhost`; local tests used Homebrew OpenSSL 3, matching the supported Debian/Ubuntu OpenSSL interface.

Passed the opt-in Docker integration with the current application Nginx entrypoint/templates on the pinned Nginx base and a local Node HTTP fixture (no application database or real-model calls): HTTP+HTTPS, HTTPS-only, redirect response, webhook forwarding, verified HTTPS health, and rotation to a different certificate/key. Test-owned containers/network and certificate directories were cleaned up. This validates Nginx/CLI behavior, not the deployed ECR image, EC2 installation, public certificate issuance, DNS, or EventBridge connectivity. No remote deployment or paid CI run.

PR preparation: based on current origin/main in a separate clean worktree, excluding the earlier unrelated ECS commit. Integrated with existing deployment-owner routing, release lock, pending-release guard and installed image-pin override. Existing release/authentication code remains intact. New regression fixtures include installed image pins and pending-release rejection.

## PR review follow-up

PR #25 had no submitted reviews or inline threads at the start of follow-up. The independent autoreview found a P2 transactional ordering defect: old certificates were deleted while the EXIT rollback handler could still restore their paths. Self-review also reproduced rejection of valid vendor-suffixed Compose versions and loss of recovery snapshots after both activation and restoration failed.

Changes: mark successful activation committed before destructive cleanup; explicitly handle interruption; retain protected snapshot/candidate certificate material when recovery fails; make cleanup failures preserve active HTTPS; parse supported Compose versions with vendor/build suffixes. Added production-CLI regressions for all of these failure paths. No AWS resources or live application database used.

Verification after fixes: the HTTPS CLI regression passed in Ubuntu; existing operations-helper, release-discovery, release-lifecycle and AWS-authentication suites passed sequentially. Real Docker integration against current Nginx templates passed all HTTP modes, webhook forwarding, verified HTTPS health and rotation on the updated helper. Ubuntu's actual Compose version includes `+ds1-0ubuntu1~24.04.1`; the parser and regression now cover that distro suffix as well as Docker Desktop's. Integration cleanup now handles absence of the TLS override and retains configuration if container teardown fails. These checks use disposable local fixture services, not a production database or model provider. Hosted validation on the earlier PR commit passed; validation of the follow-up commit is tracked separately.

The final HTTPS regression also passed as a non-root deployment user, and isolated real sudo/runuser routing checks passed. Independent review's accepted P2 finding was addressed by the commit boundary and cleanup regression; self-review's additional compatibility and failed-recovery defects were addressed and verified. No GitHub review findings were outstanding before the follow-up push.
