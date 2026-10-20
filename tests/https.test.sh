#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/deploy" "$test_root/bin"
export OPSRABBIT_DEPLOY_DIR="$test_root/deploy"
export OPSRABBIT_TEST_COMMAND_LOG="$test_root/commands"
export PATH="$test_root/bin:$PATH"
cat > "$OPSRABBIT_DEPLOY_DIR/.env" <<'ENV'
AWS_REGION=us-east-1
ECR_REGISTRY=example.invalid
OPSRABBIT_BACKEND_PORT=8384
OPSRABBIT_SANDBOX_IMAGE=example.invalid/sandbox:test
OPENSANDBOX_PORT=8080
OPENSANDBOX_SERVER_API_KEY=fixture-key
WEB_HTTP_PORT=3000
WEB_BIND_ADDRESS=0.0.0.0
OPSRABBIT_WEB_ORIGIN=http://old.example.com:3000
OPSRABBIT_NODE_BASE_URL=http://old.example.com:3000/api
BETTER_AUTH_SECRET=preserve-this-value
ENV
cp "$repo_root/bundle/docker-compose.yml" "$OPSRABBIT_DEPLOY_DIR/docker-compose.yml"
cat > "$test_root/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == 'compose version --short' ]]; then echo "${TEST_COMPOSE_VERSION:-2.30.0}"; exit; fi
printf '%s\n' "$*" >> "$OPSRABBIT_TEST_COMMAND_LOG"
if [[ "$*" == *' ps -q opensandbox-server' ]]; then echo fixture-container; fi
if [[ "$*" == *' up '* && -f "$OPSRABBIT_DEPLOY_DIR/fail-both" ]]; then exit 1; fi
if [[ "$*" == *' up '* && -f "$OPSRABBIT_DEPLOY_DIR/interrupt-once" ]]; then
  rm "$OPSRABBIT_DEPLOY_DIR/interrupt-once"
  kill -TERM "$PPID"
  exit 143
fi
if [[ "$*" == *' up '* && -f "$OPSRABBIT_DEPLOY_DIR/fail-once" ]]; then
  rm "$OPSRABBIT_DEPLOY_DIR/fail-once"
  exit 1
fi
STUB
cat > "$test_root/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OPSRABBIT_TEST_COMMAND_LOG"
if [[ "$*" == *'--write-out %{http_code}'* ]]; then printf 401; fi
if [[ "$*" == *'--header @-'* ]]; then cat >/dev/null; fi
STUB
cat > "$test_root/bin/rm" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${OPSRABBIT_TEST_FAIL_REMOVE_DIR:-}" && "$*" == "-rf $OPSRABBIT_TEST_FAIL_REMOVE_DIR" ]]; then
  # Simulate partial deletion: returning to this old version would be unsafe.
  /bin/rm -f "$OPSRABBIT_TEST_FAIL_REMOVE_DIR/privkey.pem"
  exit 1
fi
exec /bin/rm "$@"
STUB
chmod +x "$test_root/bin/"*
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -subj /CN=opsrabbit.example.com -keyout "$test_root/key.pem" -out "$test_root/cert.pem" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -subj /CN=other.example.com -keyout "$test_root/other-key.pem" -out "$test_root/other-cert.pem" >/dev/null 2>&1
ctl=("$repo_root/bundle/opsrabbitctl")
configure=(https configure --hostname opsrabbit.example.com --cert "$test_root/cert.pem" --key "$test_root/key.pem")
assert_rejected() {
  cp "$OPSRABBIT_DEPLOY_DIR/.env" "$test_root/before-env"
  if "${ctl[@]}" "$@" >"$test_root/output" 2>&1; then echo "Unexpected success: $*" >&2; exit 1; fi
  cmp "$test_root/before-env" "$OPSRABBIT_DEPLOY_DIR/.env"
  [[ ! -d "$OPSRABBIT_DEPLOY_DIR/.https-lock" ]]
}
assert_rejected https configure --hostname other.example.com --cert "$test_root/cert.pem" --key "$test_root/key.pem"
assert_rejected https configure --hostname opsrabbit.example.com --cert "$test_root/cert.pem" --key "$test_root/other-key.pem"
assert_rejected "${configure[@]}" --https-port 70000
assert_rejected "${configure[@]}" --http-mode redirect --https-port 8443
assert_rejected "${configure[@]}" --http-mode invalid
assert_rejected https configure --hostname
TEST_COMPOSE_VERSION=2.24.3 assert_rejected "${configure[@]}"
TEST_COMPOSE_VERSION=2.24.3-desktop.1 assert_rejected "${configure[@]}"
assert_rejected "${configure[@]}" --cert "$test_root/missing.pem"
openssl pkey -in "$test_root/key.pem" -aes-256-cbc -passout pass:test-fixture -out "$test_root/encrypted.pem" >/dev/null 2>&1
assert_rejected "${configure[@]}" --key "$test_root/encrypted.pem"
[[ ! -e "$OPSRABBIT_DEPLOY_DIR/docker-compose.https.yml" ]]
# Failed first activation restores the HTTP origin and removes the new override.
touch "$OPSRABBIT_DEPLOY_DIR/fail-once"
assert_rejected "${configure[@]}"
[[ ! -e "$OPSRABBIT_DEPLOY_DIR/docker-compose.https.yml" ]]
# Clear recovery logs before checking the default command path.
: > "$OPSRABBIT_TEST_COMMAND_LOG"
mkdir -p "$OPSRABBIT_DEPLOY_DIR/.release"
printf '{"version":"v1.0.0"}\n' > "$OPSRABBIT_DEPLOY_DIR/.release/current.json"
printf '{"services":{}}\n' > "$OPSRABBIT_DEPLOY_DIR/.release/current.compose.json"
# Default remains HTTP: start uses only the original Compose manifest.
"${ctl[@]}" start
! grep -q 'docker-compose.https.yml' "$OPSRABBIT_TEST_COMMAND_LOG"
TEST_COMPOSE_VERSION=2.39.4-desktop.1 "${ctl[@]}" "${configure[@]}"
override="$OPSRABBIT_DEPLOY_DIR/docker-compose.https.yml"
grep -q 'WEB_TLS_MODE: both' "$override"
grep -q 'WEB_TLS_REDIRECT: "false"' "$override"
grep -q '0.0.0.0:3000:80' "$override"
grep -q '0.0.0.0:443:443' "$override"
grep -q '^OPSRABBIT_WEB_ORIGIN=https://opsrabbit.example.com$' "$OPSRABBIT_DEPLOY_DIR/.env"
grep -q '^BETTER_AUTH_SECRET=preserve-this-value$' "$OPSRABBIT_DEPLOY_DIR/.env"
cert_dir="$(sed -n 's/^OPSRABBIT_HTTPS_CERT_DIR=//p' "$OPSRABBIT_DEPLOY_DIR/.env")"
cmp "$test_root/key.pem" "$cert_dir/privkey.pem"
"${ctl[@]}" health
grep -q -- '--resolve opsrabbit.example.com:443:127.0.0.1 https://opsrabbit.example.com:443/' "$OPSRABBIT_TEST_COMMAND_LOG"
"${ctl[@]}" start
grep -q 'docker-compose.https.yml'  "$OPSRABBIT_TEST_COMMAND_LOG"
[[ -f "$cert_dir/privkey.pem" ]]
TEST_COMPOSE_VERSION="2.40.3+ds1-0ubuntu1~24.04.1" "${ctl[@]}" "${configure[@]}" --http-mode redirect
[[ ! -e "$cert_dir" ]]
grep -q 'WEB_TLS_REDIRECT: "true"' "$override"
"${ctl[@]}" "${configure[@]}" --http-mode disable --https-port 8443
grep -q 'WEB_TLS_MODE: https' "$override"
! grep -q ':3000:80' "$override"
grep -q '^OPSRABBIT_WEB_ORIGIN=https://opsrabbit.example.com:8443$' "$OPSRABBIT_DEPLOY_DIR/.env"
"${ctl[@]}" https reload --cert "$test_root/cert.pem" --key "$test_root/key.pem"
grep -q 'WEB_TLS_MODE: https' "$override"
grep -q '0.0.0.0:8443:443' "$override"
assert_rejected https reload --cert "$test_root/other-cert.pem" --key "$test_root/other-key.pem"
assert_rejected https reload --hostname other.example.com
# Pending releases and concurrent service operations cannot be bypassed by TLS.
printf '{}' > "$OPSRABBIT_DEPLOY_DIR/.release/pending.json"
assert_rejected "${configure[@]}"
rm "$OPSRABBIT_DEPLOY_DIR/.release/pending.json"
grep -q 'current.compose.json -f .*docker-compose.https.yml up' "$OPSRABBIT_TEST_COMMAND_LOG"
# A failed activation restores both files and attempts service recovery.
cp "$OPSRABBIT_DEPLOY_DIR/.env" "$test_root/before-env"
cp "$override" "$test_root/before-override"
touch "$OPSRABBIT_DEPLOY_DIR/fail-once"
assert_rejected "${configure[@]}" --http-mode keep
cmp "$test_root/before-override" "$override"
grep -q 'HTTPS configured' "$OPSRABBIT_TEST_COMMAND_LOG" && exit 1
[[ ! -d "$OPSRABBIT_DEPLOY_DIR/.https-lock" ]]
# TERM during activation restores configuration and releases the lock.
cp "$override" "$test_root/before-interrupt"
touch "$OPSRABBIT_DEPLOY_DIR/interrupt-once"
assert_rejected "${configure[@]}" --http-mode keep
cmp "$test_root/before-interrupt" "$override"

# Once activation succeeds, cleanup failure must not revert to damaged old keys.
export OPSRABBIT_TEST_FAIL_REMOVE_DIR="$(sed -n 's/^OPSRABBIT_HTTPS_CERT_DIR=//p' "$OPSRABBIT_DEPLOY_DIR/.env")"
"${ctl[@]}" https reload --cert "$test_root/cert.pem" --key "$test_root/key.pem" > "$test_root/cleanup-output" 2>&1
grep -q 'HTTPS is active, but old certificate cleanup failed' "$test_root/cleanup-output"
current_cert_dir="$(sed -n 's/^OPSRABBIT_HTTPS_CERT_DIR=//p' "$OPSRABBIT_DEPLOY_DIR/.env")"
[[ "$current_cert_dir" != "$OPSRABBIT_TEST_FAIL_REMOVE_DIR" ]]
cmp "$test_root/key.pem" "$current_cert_dir/privkey.pem"
grep -q "$current_cert_dir/privkey.pem" "$override"
unset OPSRABBIT_TEST_FAIL_REMOVE_DIR

# Preserve recovery material if both activation and restoration fail.
touch "$OPSRABBIT_DEPLOY_DIR/fail-both"
assert_rejected "${configure[@]}" --http-mode keep
grep -q 'Recovery files retained at' "$test_root/output"
recovery_dir="$(find "$OPSRABBIT_DEPLOY_DIR" -maxdepth 1 -type d -name '.https-backup.*')"
[[ -n "$recovery_dir" ]]
cmp "$test_root/before-env" "$recovery_dir/env"
[[ -f "$recovery_dir/override" ]]
retained_candidate="$(sed -n 's/^OPSRABBIT_HTTPS_CERT_DIR=//p' "$recovery_dir/new-env")"
[[ "$retained_candidate" != "$current_cert_dir" ]]
cmp "$test_root/key.pem" "$retained_candidate/privkey.pem"
rm "$OPSRABBIT_DEPLOY_DIR/fail-both"
echo 'HTTPS CLI regression tests passed.'
