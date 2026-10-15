# Versioned OpsRabbit releases

Status: implementation authorized; three PRs only. No deployment, release publication or paid CI. First product release is v1.1.1; every product build reserves the next patch by default, with operator-selected minor/major. Failed reservations are skipped.

## Scope and finishing criteria

- Backend/frontend build from one commit with one SemVer, publish version tags directly, and enter the public catalog only after both build jobs succeed. Require immutable ECR version tags.
- Product manifests live in public Ops-Rabbit/opsrabbit-installer releases named opsrabbit-vX.Y.Z, separately from installer versions. Resolve the highest complete stable SemVer once per install/update; allow an explicit version. No latest/latestv2 aliases and no image digest-reference support.
- Existing deployments use the bundle's root migrate.sh once with backup confirmation. Install only the new helper/libraries; preserve customer Compose/TOML, secrets, URLs and data. Subsequent updates use opsrabbitctl update --backup-confirmed.
- Pull before maintenance, stop frontend and active worker before daemon migrations, restore the worker after daemon readiness, then start frontend. Persist worker intent and pending version before maintenance. Resume interrupted updates explicitly; reject database-unsafe downgrade. All service/auth mutators share one host lock.
- Persist Compose overrides for daemon/web and any defined worker so hardcoded customer image settings cannot split a release. Verify build metadata and actual running images within the existing deployment steps. Preserve custom sandbox workload choices.
- Replace only known historical sandbox aliases with a release-default sentinel through an additive ordered SQL migration. CI bakes the selected versioned sandbox default into backend metadata; frontend reset follows server defaults. Existing sandbox containers are retired separately.
- Remove moving Collector alias publication in the third PR; keep the user-approved pnpm/security-policy update. Exclude unrelated plugin parser, redaction and TLS-fixture cleanup as requested.

The user's final scope correction selects plain version tags, removes the separate verification script, and keeps checks in existing build/deploy steps. Existing provider configuration and host policy remain separately operated prerequisites; this change does not add a privileged host-policy probe or infrastructure updater. Source fallback is a local development workload image, not a release alias.

## Authorization and lifecycle

Release publication uses protected operator credentials plus a scoped public-catalog publishing token. Host upgrades use existing SSH/sudo/deployment-owner authority and explicitly selected AWS identity. Product admin, tenant and resource grants are unchanged. No public plugin-platform capability or new runtime environment configuration is introduced.

Public manifests contain distribution metadata only. Host .release state is private administrative configuration: current, one previous and an active pending manifest, removed with installation configuration. Candidate downloads are cleaned. Customer database/volume retention, tenant deletion, legal holds and audit behavior remain unchanged. Custom sandbox DB settings and activation remain intact. Backups and supported registry versions must be retained for database-compatible recovery.

## Prior art reviewed

- [applied-ai-consulting/claude-code cli/update.ts](https://github.com/applied-ai-consulting/claude-code/blob/dfb44640ca1c2b64b882a15edf73ec0374d41d9a/cli/update.ts) and [utils/autoUpdater.ts](https://github.com/applied-ai-consulting/claude-code/blob/dfb44640ca1c2b64b882a15edf73ec0374d41d9a/utils/autoUpdater.ts): reuse explicit current/target diagnostics and SemVer ordering; reject mutable latest channels, unattended policy and package-manager architecture.
- [openai/codex rust-release.yml](https://github.com/openai/codex/blob/3ee47c10513f1bb57d869ea650aba28638e3d11c/.github/workflows/rust-release.yml) and [updates.rs](https://github.com/openai/codex/blob/3ee47c10513f1bb57d869ea650aba28638e3d11c/codex-rs/tui/src/updates.rs): reuse publication after dependent builds, staged assets, serialization and stable/prerelease separation; reject latest-channel promotion and unrelated multi-platform packaging.

## Verification and delivery

Run allocator/catalog/manifest and actual SSH/CLI lifecycle fixtures, including pull failure, mismatch, pending recovery, worker intent, locking and migration preservation. Use actual sudo/runuser/TTY in disposable Linux containers. Run focused backend/schema/real PostgreSQL migration tests against a disposable database, frontend helper tests, fresh per-file coverage, type checks and lint:quality. Run exact pinned full strict Semgrep, independent bounded reviews and autoreview before PRs. Distinguish local checks from hosted CI or host qualification.

Review fixes cover pre-maintenance pulls, durable worker intent, shared locking, pagination, sandbox-default continuity, paired service selection, pre-start metadata checks and persistent worker overrides. The final version-only design removes digest qualification and its extra verification helper.

Publish ready PRs as gau1991 for the app and ghaaic for installer/plugins. Attach all three, inspect current-head Codex feedback and fix valid findings. Do not add ci:run-full or dispatch/rerun paid workflows. Catalog token provisioning, registry immutability configuration, installer/product publication and customer migration execution remain later operational actions.
