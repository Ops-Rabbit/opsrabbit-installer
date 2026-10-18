#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/deploy"
printf '#!/usr/bin/env bash\nexit 0\n' > "$test_root/bin/docker"
bash "$repo_root/tests/release-fixture.sh" "$test_root" "$test_root/bin"
cp "$repo_root/tests/stateful-docker.sh" "$test_root/bin/docker"
chmod +x "$test_root/bin/docker"
cat > "$test_root/bin/aws" <<'AWS'
#!/usr/bin/env bash
if [[ "$*" == 'sts '* ]]; then printf '123456789012\tarn:aws:iam::123456789012:role/fixture\n'; else echo fixture-password; fi
AWS
chmod +x "$test_root/bin/aws"
cat > "$test_root/deploy/.env" <<'ENV'
AWS_REGION=us-east-1
ECR_REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com
OPSRABBIT_DAEMON_IMAGE=old-backend:latestv2
OPSRABBIT_WEB_IMAGE=old-web:latestv2
OPSRABBIT_SANDBOX_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/vg-sandbox:20261011-38113406925-1
OPSRABBIT_BACKEND_PORT=8384
WEB_HTTP_PORT=3000
OPENSANDBOX_PORT=8080
OPENSANDBOX_SERVER_API_KEY=fixture-secret
CUSTOM_SETTING=preserve-verbatim
ENV
printf 'profile\nfixture\n' > "$test_root/deploy/.aws-auth"
printf 'customer compose preserved\n' > "$test_root/deploy/docker-compose.yml"
export PATH="$test_root/bin:$PATH" TEST_RELEASE_ROOT="$test_root" OPSRABBIT_DEPLOY_DIR="$test_root/deploy"
ctl="$repo_root/bundle/opsrabbitctl"
# A declined backup confirmation on an existing install must precede host setup.
cat > "$test_root/bin/uname" <<'UNAME'
#!/bin/sh
echo x86_64
UNAME
cat > "$test_root/bin/apt-get" <<'APT'
#!/bin/sh
touch "$TEST_RELEASE_ROOT/host-setup-started"
exit 88
APT
chmod +x "$test_root/bin/uname" "$test_root/bin/apt-get"
if printf 'yes\nno\n' | OPSRABBIT_INPUT_DEVICE=/dev/stdin OPSRABBIT_INSTALL_DIR="$OPSRABBIT_DEPLOY_DIR" "$repo_root/bundle/install.sh" > "$test_root/output" 2>&1; then exit 1; fi
[[ ! -e "$test_root/host-setup-started" && ! -e "$test_root/lifecycle.log" ]]
# An independently selected application image must be rejected before setup.
for image_setting in OPSRABBIT_DAEMON_IMAGE OPSRABBIT_WEB_IMAGE; do
  if printf 'yes\n' | env OPSRABBIT_INPUT_DEVICE=/dev/stdin OPSRABBIT_INSTALL_DIR="$OPSRABBIT_DEPLOY_DIR" "$image_setting=customer.invalid/application:v9.0.0" "$repo_root/bundle/install.sh" > "$test_root/output" 2>&1; then exit 1; fi
  grep -q 'Independent backend/web image overrides are unsupported' "$test_root/output"
  [[ ! -e "$test_root/host-setup-started" && ! -e "$test_root/lifecycle.log" ]]
done
# A candidate pull failure must leave all services and config untouched.
cp "$OPSRABBIT_DEPLOY_DIR/.env" "$test_root/original.env"
if TEST_FAILURE=pull "$ctl" deploy --adopt --backup-confirmed > "$test_root/output" 2>&1; then exit 1; fi
cmp "$test_root/original.env" "$OPSRABBIT_DEPLOY_DIR/.env"
[[ ! -e "$test_root/lifecycle.log" && ! -e "$OPSRABBIT_DEPLOY_DIR/.release/pending.json" ]]
if TEST_FAILURE=metadata "$ctl" deploy --adopt --backup-confirmed > "$test_root/output" 2>&1; then exit 1; fi
[[ ! -e "$test_root/lifecycle.log" && ! -e "$OPSRABBIT_DEPLOY_DIR/.release/pending.json" ]]
cmp "$test_root/original.env" "$OPSRABBIT_DEPLOY_DIR/.env"
# A post-worker-stop failure must retain intent and prevent stale frontend serving.
if TEST_FAILURE=daemon "$ctl" deploy --adopt --backup-confirmed > "$test_root/output" 2>&1; then exit 1; fi
jq -e '.worker == null and .web == null' "$test_root/containers.json" >/dev/null
jq -e '._deployment.worker_was_running == true' "$OPSRABBIT_DEPLOY_DIR/.release/pending.json" >/dev/null
if "$ctl" start > "$test_root/output" 2>&1; then echo 'Start bypassed pending recovery'; exit 1; fi
"$ctl" deploy --adopt --backup-confirmed --version v1.1.1 > "$test_root/output" 2>&1
jq -e '.worker == .daemon and (.web | contains("vg-webapp:v1.1.1")) and (.daemon | contains("vg-backend:v1.1.1"))' "$test_root/containers.json" >/dev/null
[[ ! -f "$OPSRABBIT_DEPLOY_DIR/.release/pending.json" ]]
jq -e '.services.worker.image == .services.daemon.image' "$OPSRABBIT_DEPLOY_DIR/.release/current.compose.json" >/dev/null
grep -Fxq CUSTOM_SETTING=preserve-verbatim "$OPSRABBIT_DEPLOY_DIR/.env"
grep -Fxq OPSRABBIT_SANDBOX_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/vg-sandbox:v1.0.0 "$OPSRABBIT_DEPLOY_DIR/.env"
if grep -Fq 'vg-sandbox:20261011-38113406925-1' "$test_root/pulled-images"; then echo 'Pulled legacy sandbox instead of release default'; exit 1; fi
# Every mutator must acquire the deployment lock before inspecting or changing services.
exec {held_lock}>"$OPSRABBIT_DEPLOY_DIR/.release/lock"
flock "$held_lock"
for action in start stop restart update; do
  if "$ctl" "$action" > "$test_root/output" 2>&1; then echo "$action bypassed deployment lock"; exit 1; fi
  grep -q 'Another release or service operation' "$test_root/output"
done
flock -u "$held_lock"
# Adoption and reapplication must preserve a deliberately customized workload.
sed -i 's|^OPSRABBIT_SANDBOX_IMAGE=.*|OPSRABBIT_SANDBOX_IMAGE=customer.invalid/workload:v2.3.4|' "$OPSRABBIT_DEPLOY_DIR/.env"
# Existing callers still need confirmation; skipping it must be explicit.
cp "$test_root/lifecycle.log" "$test_root/lifecycle-before"
for backup_options in '' '--backup-confirmed --skip-backup'; do
  if "$ctl" update $backup_options --version v1.1.1 > "$test_root/output" 2>&1; then echo 'Accepted missing or conflicting backup choice'; exit 1; fi
  cmp "$test_root/lifecycle-before" "$test_root/lifecycle.log"
done
"$ctl" update --skip-backup --version v1.1.1 > "$test_root/output" 2>&1
grep -Fxq OPSRABBIT_SANDBOX_IMAGE=customer.invalid/workload:v2.3.4 "$OPSRABBIT_DEPLOY_DIR/.env"
OPSRABBIT_TEST_API_KEY=fixture-secret "$ctl" health > "$test_root/output" 2>&1
# Exercise the real root migration entrypoint in this disposable Linux container.
printf '#!/bin/sh\nexit 88\n' > /usr/local/bin/opsrabbitctl
cp "$OPSRABBIT_DEPLOY_DIR/docker-compose.yml" "$test_root/compose-before"
"$repo_root/bundle/migrate.sh" --backup-confirmed --version v1.1.1 > "$test_root/output" 2>&1
cmp "$test_root/compose-before" "$OPSRABBIT_DEPLOY_DIR/docker-compose.yml"
grep -Fxq CUSTOM_SETTING=preserve-verbatim "$OPSRABBIT_DEPLOY_DIR/.env"
echo 'PASS: pull failure isolation, interrupted worker recovery, service locks, image application and root one-time migration'
