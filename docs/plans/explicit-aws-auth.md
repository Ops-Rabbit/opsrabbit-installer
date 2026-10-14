# Explicit deployment AWS authentication

## Scope and finishing criteria

The installer and operations helper must use an explicitly selected AWS identity.
An available client EC2 role must never be selected implicitly. Installation offers
browser login, temporary credentials, explicit instance role, or an existing CLI
profile. Login, deployment and updates share the same verification and renewal
path. Normal sudo-capable users can invoke the helper without switching accounts.

## Design

- Store only method/profile selection in the deployment directory. Store temporary
  credentials separately in the deployment user's private AWS directory (0700/0600).
  Renew them with `opsrabbitctl auth login`; never put them in application `.env`,
  command arguments, logs or shell history. Keep the last working selection until
  replacement credentials pass identity and image-manifest checks.
- Clear inherited AWS provider/endpoint settings. Explicit profile/login methods
  disable EC2 metadata; temporary credentials use an isolated credentials file and
  empty CLI config. Only the instance-role choice enables metadata and it ignores
  local AWS profiles and credentials.
- Route root invocations to the owner of the deployment directory. Ordinary users
  invoke sudo when needed; the deployment user reads its own AWS profiles/cache.
  Keep auth library installation root-owned. No new sudoers privileges.
- Show AWS account/role, authenticate to ECR using an ephemeral Docker config, and
  verify all three configured image manifests before changing running services.
  Actual pulls still finish before daemon shutdown and can fail on layer access.
- Missing/expired selection fails closed with a specific renewal command. Legacy
  installations need an explicit selection on their next authenticated command.
- Preserve unrelated documentation. Prepare a new version only after verification;
  never modify published v1.3.3 assets.

## Authorization and data lifecycle

Resources: local deployment configuration, selected user's AWS login/cache, ECR
read access, Docker service lifecycle. Existing sudo/Docker privileges remain the
authorization boundary. No product tenant resources or database schema change.
Identity and selected profile are persisted; temporary credentials are secrets
owned by the deployment user. Successful replacement removes the old managed
credential file when switching away from temporary credentials; failed attempts
and cancellation remove candidate files. ECR tokens are removed on exit. Browser login cache stays in the deployment user's standard AWS directory; AWS CLI owns its expiry and logout. Unrelated AWS profiles are preserved.

## Prior art

- `openai/codex`, `docs/authentication.md` (GitHub contents API, 2026-10-14): points
  to dedicated authentication documentation. Adopt a discoverable auth command;
  do not introduce a second credential broker or copy unrelated provider behavior.
- `applied-ai-consulting/claude-code`, `README.md` (GitHub contents API, 2026-10-14):
  contains only the project title, so it provides no applicable auth implementation.
  Use the locally installed AWS CLI `aws login help` contract for `--remote` and
  named profiles; no speculative browser automation or credentials forwarding.

## Verification and review

- Extend production-entrypoint tests with an available unauthorized EC2 identity,
  profile selection, temporary credentials, role opt-in, expired/missing profiles,
  denied images, retry/cancellation, credential cleanup, renewal and inherited AWS
  environment isolation. No real credentials, private pulls or cloud writes.
- Exercise root/ordinary-user handoff and installer integration in disposable Linux
  containers. Run existing helper, Docker-install and AppArmor tests serially.
- Validate shell syntax, archive contents, workflows and targeted documentation.
  Independent code/security and tests/documentation reviews, then autoreview before PR.

## Closeout

Target release: v1.3.4; README quick-install references updated. Published v1.3.3
assets are unchanged.

- `bash tests/aws-auth.test.sh` passed in disposable Ubuntu 24.04 amd64 containers;
  the same regression rejects `origin/main:bundle/opsrabbitctl`. Coverage includes
  inherited providers, explicit role opt-in, failed/cancelled distinct credential
  and browser replacements, token-directory failures, private storage and renewal.
- `python3 tests/auth-user-routing.test.py` passed in a disposable container with
  real sudo, runuser and a PTY. It verifies ordinary-user elevation, root installer
  handoff, hidden input, deployment HOME and later deploy/update reuse.
- `bash tests/opsrabbitctl.test.sh` and `bash tests/docker-install.test.sh` passed.
- `bash tests/apparmor-install.test.sh` passed in a privileged disposable container
  because its mount-namespace fixtures require unshare. It models kernel changes;
  native host AppArmor enforcement was not exercised. Real profile syntax passed
  `apparmor_parser -Q`; the container reports unavailable kernel cache support.
- Each shell file passed `bash -n`. `shellcheck -x -P SCRIPTDIR bundle/opsrabbitctl
  bundle/install.sh tests/aws-auth.test.sh tests/opsrabbitctl.test.sh` passed.
- Installed AWS CLI 2.36.27 `aws configure list`, with an isolated temporary HOME,
  an empty selected profile, fixture default/Boto credentials, metadata disabled
  and `BOTO_CONFIG=/dev/null`, reported no credentials. No AWS request was needed.
  Source inspection of its botocore credential resolver confirmed the legacy Boto
  provider; the helper now explicitly disables it as well as ambient AWS providers.
- Candidate archive includes the new authentication library, helper and installer.
  `git diff --check` and Python AST parsing passed. This shell-only repository has
  no package.json, lint:quality command or pinned Semgrep workflow to execute.
- Independent code/security and tests/docs reviewers found temporary-directory
  error handling, browser replacement staging and test assertion gaps; all were
  fixed and both reviewers cleared the follow-up review.
- AWS/ECR/Docker responses in authentication tests are deterministic fixtures.
  Real AWS browser sign-in, private image pulls and the client host were not used.
  Final autoreview completed with `scoped-clean` at P0–P2. Its initial release-pin
  concern was disproved by the unchanged workflow's tag-stamping step and the
  generated v1.3.4 bootstrap; source-context review confirmed no defect.
  PR validation remains pending.
