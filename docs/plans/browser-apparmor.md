# Browser/AppArmor installer companion

## Scope and completion

Start from installer main `d12523f`. Deliver a ready PR under the configured
`ghaaic` identity; do not release, deploy, edit Compose/TOML, or change image tags.
Carry the exact browser policy from OpsRabbit PR #916, commit `687536e151624c3b98b3603640d8627c7d1d1f42`.
Finish with shell/operations regressions, real AppArmor parsing, disposable
installation/rollback checks, Compose and release archive validation, a strict
scan, independent reviews and autoreview.

## Design and boundaries

- Restricted-userns hosts install the image-only browser policy in addition to
  the existing generic policy selection. Keep Ubuntu's distribution policy;
  migrate only the byte-identical known legacy fallback and reject customized
  or disabled policy. Preflight every source before changing the host.
- One installation transaction backs up replaced policies, loads selected
  profiles, and restores files and prior loaded legacy policy on failure.
  Preserve distro files and remove a newly loaded distro policy on rollback
  only when it was not previously loaded.
- Snapshot exact previously loaded policy labels before mutation; leave old
  unloaded files unloaded on rollback. Reject partial policy state or active
  selected labels with no recoverable file rather than guessing their prior state.
- Keep the browser policy identical to #916, not a second design. Its executable
  exists only in the rebuilt sandbox image; do not install a host browser launcher.
  Normal commands retain capability-denying profiles, Chromium retains its own
  namespace/seccomp sandbox, and standard containers retain Docker confinement.
- Release and validation jobs parse every bundled policy and inspect the archive
  for both required files. Keep validation generic, not Ubuntu-version-specific.
- Document targeted host-policy upgrade plus matching backend/workload image.
  `opsrabbitctl update` does not install host profiles or refresh bundle files.

## Authorization and lifecycle

The root administrator owns host policy installation. No tenant grant, API,
customer data store, application setting, or secret changes. Transaction backups
are temporary host-local control-plane files, deleted after success or rollback.
Tests run inside disposable Linux containers; they do not load host kernel policy
or touch customer volumes. The application PR separately owns live browser proof.

## Prior art and regression ownership

Reuse the application design verified in #916 rather than duplicate its runtime.
That design reviewed `openai/codex` commit
`cc7ba33601286a751477832b01de7b6f8de0dd9c`,
`codex-rs/linux-sandbox/src/bwrap.rs`, and
`applied-ai-consulting/claude-code` commit
`dfb44640ca1c2b64b882a15edf73ec0374d41d9a`,
`utils/sandbox/sandbox-adapter.ts`: explicit mounts and authoritative paths fit;
unsandboxed fallbacks and unrelated proxy architecture do not. No new runtime
architecture is introduced here.

The new installer regression owns delivery and transactional host state, which
the application's live browser test cannot cover. Execute the real installer in
a disposable Linux filesystem, with the real AppArmor parser for syntax and only
kernel load/unload mocked. Verify file contents/permissions and modeled loaded
state on fresh install, replacement, distro migration and failure. No production
test path override, exported hook or source-grep assertion is needed.

## Verification and review closeout

- Shell syntax and the existing operations-helper regression passed.
- Real AppArmor parsing and installation-state regressions passed in disposable
  Ubuntu 24.04/ARM64 and Ubuntu 26.04/amd64 Linux containers. A private mount
  namespace isolates policy files and the loaded-state receipt. Only kernel
  load/unload is mocked; no host profile or sysctl was changed. Expected parser
  cache diagnostics reflect the deliberately absent kernel interface.
- The same delivery test fails on main because the browser policy is missing.
  The present-but-unloaded regression also failed against the first candidate,
  showing five newly active profiles after a failed replacement; it passes after
  the root-cause loaded-state fix. No assertion was weakened to make it pass.
- Tests cover new install, repeat install, loaded/unloaded replacement rollback,
  known legacy migration, browser-load failure, TERM interruption, distro file
  preservation, customized/disabled policy rejection, partial policy and orphaned
  label rejection, permissions and staging cleanup.
- Compose validation and release-layout archive inspection passed. Both policies
  and the executable installer are present; the browser profile is byte-identical
  to application commit `687536e`. Compose/TOML and image references are unchanged.
- Independent policy/runtime-state and delivery/tests/docs reviewers found the
  unloaded rollback gap; it is fixed and both final reviews have no findings.
- Final strict scan and autoreview outcomes are recorded in the PR closeout.

This is local policy-delivery qualification, not a fresh cloud deployment,
Ubuntu ARM64 live-browser qualification, or hosted CI result. #916 owns the live
browser proof. Release publishing and deployment remain separately authorized.
