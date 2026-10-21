#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/deploy" "${test_root}/home"
deploy="${test_root}/deploy"
log="${test_root}/commands"
output="${test_root}/output"
input="${test_root}/input"
state="${deploy}/.aws-auth"
credentials="${test_root}/home/.aws/opsrabbit/credentials"
touch "${deploy}/docker-compose.yml"
cat > "${deploy}/.env" <<'EOF'
AWS_REGION=us-east-1
ECR_REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com
OPSRABBIT_DAEMON_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/backend:test
OPSRABBIT_WEB_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/web:test
OPSRABBIT_SANDBOX_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox:test
OPSRABBIT_BACKEND_PORT=8384
WEB_HTTP_PORT=3000
OPENSANDBOX_PORT=8080
OPENSANDBOX_SERVER_API_KEY=fixture-api-key
EOF

cat > "${test_root}/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws %s\n' "$*" >> "$TEST_LOG"
[[ "${BOTO_CONFIG:-}" == /dev/null ]]
# Every AWS entrypoint must ignore inherited credentials and redirected providers.
for key in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE \
  AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
  AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_ENDPOINT_URL AWS_ENDPOINT_URL_STS \
  AWS_EC2_METADATA_SERVICE_ENDPOINT; do
  [[ -z "${!key:-}" ]] || { echo "Unexpected ambient AWS setting: $key" >&2; exit 90; }
done
case "${TEST_PROVIDER}" in
  profile)
    [[ "${AWS_EC2_METADATA_DISABLED}" == true && "${AWS_PROFILE}" == fixture-profile ]]
    [[ "${AWS_CONFIG_FILE}" == "$HOME/.aws/config" && "${AWS_SHARED_CREDENTIALS_FILE}" == "$HOME/.aws/credentials" ]]
    ;;
  browser)
    [[ "${AWS_EC2_METADATA_DISABLED}" == true && "${AWS_PROFILE}" == opsrabbit-deploy ]]
    ;;
  credentials)
    [[ "${AWS_EC2_METADATA_DISABLED}" == true && -z "${AWS_PROFILE:-}" && "${AWS_CONFIG_FILE}" == /dev/null ]]
    [[ -r "${AWS_SHARED_CREDENTIALS_FILE}" ]]
    grep -Fq 'aws_access_key_id = ASIAFIXTUREONLY' "${AWS_SHARED_CREDENTIALS_FILE}"
    grep -Fq "aws_secret_access_key = fixture-secret-never-log${TEST_REPLACEMENT:+-replacement}" "${AWS_SHARED_CREDENTIALS_FILE}"
    grep -Fq "aws_session_token = fixture-token-never-log${TEST_REPLACEMENT:+-replacement}" "${AWS_SHARED_CREDENTIALS_FILE}"
    [[ "$(stat -c %a "${AWS_SHARED_CREDENTIALS_FILE}")" == 600 ]]
    ;;
  role)
    [[ "${AWS_EC2_METADATA_DISABLED}" == false && -z "${AWS_PROFILE:-}" ]]
    [[ "${AWS_CONFIG_FILE}" == /dev/null && "${AWS_SHARED_CREDENTIALS_FILE}" == /dev/null ]]
    ;;
esac
case "$*" in
  'sts get-caller-identity '*)
    if [[ "${TEST_FAILURE:-}" == identity ]]; then echo 'Expired or missing selected credentials' >&2; exit 1; fi
    printf '123456789012\tarn:aws:iam::123456789012:role/selected-deployment-role\n'
    ;;
  'ecr get-login-password '*)
    if [[ "${TEST_FAILURE:-}" == ecr ]]; then echo 'ECR token denied' >&2; exit 1; fi
    echo fixture-ecr-token
    ;;
  'login --remote '*)
    [[ "${TEST_PROVIDER}" == browser || "${TEST_RENEW:-}" == browser ]]
    [[ "${AWS_SHARED_CREDENTIALS_FILE}" == /dev/null ]]
    printf '[profile opsrabbit-deploy]\nlogin_session = fixture-%s\n' "${TEST_BROWSER_SESSION}" > "${AWS_CONFIG_FILE}"
    echo 'Browser login completed'
    ;;
  'configure get sso_session '*) [[ "${TEST_RENEW:-}" == sso ]] && echo fixture-sso ;;
  'configure get sso_start_url '*) exit 1 ;;
  'configure get login_session '*) [[ "${TEST_RENEW:-}" == browser ]] && echo fixture-login ;;
  'sso login '*) [[ "${TEST_RENEW:-}" == sso ]] ;;
  *) echo "Unexpected AWS command" >&2; exit 1 ;;
esac
EOF

cat > "${test_root}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "$TEST_LOG"
printf '%s\n' "${DOCKER_CONFIG:-}" >> "${TEST_LOG}.docker-configs"
case "$*" in
  'login '*)
    token="$(cat)"
    [[ "$token" == fixture-ecr-token ]] || exit 1
    if [[ "${TEST_FAILURE:-}" == token ]]; then echo "Rejected $token" >&2; exit 1; fi
    ;;
  'manifest inspect '*)
    if [[ "${TEST_FAILURE:-}" == provider-manifest && "$*" == *'customer.invalid/lifecycle:v2.3.4' ]]; then
      echo 'Access denied to lifecycle image' >&2; exit 1
    fi
    if [[ "${TEST_FAILURE:-}" == manifest && ( "$*" == *'/web:test' || "$*" == *'/vg-webapp:v'* ) ]]; then
      echo 'Access denied to web image' >&2; exit 1
    fi
    echo '{"schemaVersion":2}'
    ;;
  'pull '*)
    if [[ "${TEST_FAILURE:-}" == interrupted ]]; then kill -TERM "$PPID"; exit 143; fi
    [[ "${TEST_FAILURE:-}" != layer ]]
    if [[ "${TEST_FAILURE:-}" == manifest && "$*" == *'/vg-webapp:v'* ]]; then
      echo 'Access denied to web image' >&2; exit 1
    fi
    ;;
  *' ps -q opensandbox-server') echo fixture-opensandbox ;;
  'inspect '*) echo connected ;;
esac
EOF
cat > "${test_root}/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
if [[ "${TEST_FAILURE:-}" == tmpdir && "$*" == -d ]]; then exit 1; fi
exec /usr/bin/mktemp "$@"
EOF
cat > "${test_root}/bin/chmod" <<'EOF'
#!/usr/bin/env bash
if [[ "${TEST_FAILURE:-}" == permissions && "${1:-}" == 0700 ]]; then exit 1; fi
exec /usr/bin/chmod "$@"
EOF
chmod +x "${test_root}/bin/"*

provider=profile
failure=""
renew=""
replacement=""
browser_session=original
bash "${repo_root}/tests/release-fixture.sh" "${test_root}" "${test_root}/bin"
export TEST_RELEASE_ROOT="${test_root}"
run_ctl() {
  if [[ "${1:-}" == deploy || "${1:-}" == update ]]; then set -- "$@" --adopt --backup-confirmed; fi
  : > "${log}"
  : > "${log}.docker-configs"
  HOME="${test_root}/home" PATH="${test_root}/bin:${PATH}" \
    OPSRABBIT_DEPLOY_DIR="${deploy}" OPSRABBIT_INPUT_DEVICE="${input}" \
    TEST_LOG="${log}" TEST_PROVIDER="${provider}" TEST_FAILURE="${failure}" TEST_RENEW="${renew}" TEST_REPLACEMENT="${replacement}" TEST_BROWSER_SESSION="${browser_session}" \
    AWS_ACCESS_KEY_ID=client-key AWS_SECRET_ACCESS_KEY=client-secret AWS_SESSION_TOKEN=client-token \
    AWS_PROFILE=client-profile AWS_DEFAULT_PROFILE=client-default BOTO_CONFIG=/client-boto \
    AWS_CONFIG_FILE=/client-config AWS_SHARED_CREDENTIALS_FILE=/client-credentials \
    AWS_CONTAINER_CREDENTIALS_FULL_URI=http://client.invalid/credentials \
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI=/client \
    AWS_WEB_IDENTITY_TOKEN_FILE=/client-token AWS_ROLE_ARN=client-role \
    AWS_ENDPOINT_URL=http://client.invalid AWS_ENDPOINT_URL_STS=http://client.invalid \
    AWS_EC2_METADATA_SERVICE_ENDPOINT=http://client.invalid AWS_EC2_METADATA_DISABLED=false \
    "${repo_root}/bundle/opsrabbitctl" "$@" > "${output}" 2>&1
}
assert_no_service_changes() {
  if grep -Eq '^docker (pull |compose )' "${log}"; then
    echo 'Failed authentication changed services or started pulling.' >&2; cat "${log}"; exit 1
  fi
}
assert_ephemeral_cleanup() {
  while IFS= read -r dir; do [[ -z "$dir" || ! -e "$dir" ]]; done < "${log}.docker-configs"
  [[ -z "$(find "${test_root}/home" \( -name 'credentials.*' -o -name 'config.*' \) -print)" ]]
}
assert_no_secrets() {
  local files=("${output}" "${log}" "${deploy}/.env")
  if [[ -e "${state}" ]]; then files+=("${state}"); fi
  if grep -Eq 'fixture-secret-never-log|fixture-token-never-log|fixture-ecr-token|client-secret|client-token' "${files[@]}"; then
    echo 'Authentication secret appeared in output or persistent configuration.' >&2; exit 1
  fi
}
assert_no_aws_calls() {
  if grep -q '^aws ' "${log}"; then
    echo 'Supplied-token authentication invoked AWS CLI.' >&2; exit 1
  fi
}
assert_no_compose_calls() {
  if grep -q '^docker compose ' "${log}"; then
    echo 'Changed services after a failed preflight.' >&2; exit 1
  fi
}

touch "${input}"
if run_ctl deploy; then echo 'Missing selection accepted ambient role'; exit 1; fi
[[ ! -s "${log}" ]]
grep -q 'auth configure' "${output}"
echo 'PASS: legacy/missing selection fails before any AWS or Docker call'

if ! printf 'fixture-ecr-token\n' | run_ctl deploy --ecr-password-stdin; then
  cat "${output}"; exit 1
fi
[[ ! -e "${state}" && ! -e "${credentials}" ]]
assert_no_aws_calls
grep -q '^docker pull ' "${log}"
assert_ephemeral_cleanup
assert_no_secrets
echo 'PASS: supplied ECR token deploys without selecting or persisting AWS credentials'

for failure in empty token layer interrupted; do
  token_input=fixture-ecr-token
  if [[ "${failure}" == empty ]]; then token_input=""; fi
  if printf '%s\n' "${token_input}" | run_ctl update --ecr-password-stdin; then
    echo "Accepted ${failure} token deployment"; exit 1
  fi
  assert_no_aws_calls
  assert_no_compose_calls
  if [[ "${failure}" == empty ]]; then [[ ! -s "${log}" ]]; fi
  [[ ! -e "${state}" && ! -e "${credentials}" ]]
  assert_no_secrets
  assert_ephemeral_cleanup
done
failure=""
echo 'PASS: empty/rejected tokens, denied pulls and interruption leave services untouched and remove temporary Docker auth'

for action in login restart; do
  if printf 'fixture-ecr-token\n' | run_ctl "${action}" --ecr-password-stdin; then
    echo "Accepted token option for ${action}"; exit 1
  fi
  grep -q 'supported only by deploy and update' "${output}"
  [[ ! -s "${log}" ]]
done

printf '4\nfixture-profile\n' > "${input}"
run_ctl auth configure
[[ "$(cat "${state}")" == $'profile\nfixture-profile' ]]
[[ "$(stat -c %a "${state}")" == 600 ]]
[[ "$(grep -c '^docker manifest inspect ' "${log}")" == 4 ]]
grep -Fxq 'docker manifest inspect customer.invalid/lifecycle:v2.3.4' "${log}"
assert_no_service_changes
assert_ephemeral_cleanup
echo 'PASS: explicit profile verifies all images and ignores every ambient provider'

cp "${state}" "${test_root}/selected-state"
failure=identity
printf 'fixture-ecr-token' | run_ctl update --ecr-password-stdin
cmp "${state}" "${test_root}/selected-state"
assert_no_aws_calls
assert_ephemeral_cleanup
assert_no_secrets
failure=""
echo 'PASS: supplied token updates without renewing or replacing the selected AWS identity'

for action in login deploy update; do
  run_ctl "${action}"
  if [[ "${action}" == login ]]; then
    [[ "$(grep -c '^docker manifest inspect ' "${log}")" == 4 ]]
  else
    grep -q '^docker pull ' "${log}"
  fi
  assert_ephemeral_cleanup
done
echo 'PASS: login, deploy and update share selected authentication and preflight'

failure="provider-manifest"
if run_ctl login; then echo 'Accepted inaccessible configured lifecycle image'; exit 1; fi
grep -q 'Cannot read image customer.invalid/lifecycle:v2.3.4' "${output}"
assert_no_service_changes
assert_ephemeral_cleanup

for failure in identity ecr manifest tmpdir permissions; do
  if run_ctl deploy; then echo "Accepted failed ${failure}"; exit 1; fi
  if [[ "${failure}" == manifest ]]; then
    assert_no_compose_calls
  else
    assert_no_service_changes
  fi
  if [[ "${failure}" == tmpdir || "${failure}" == permissions ]]; then
    if grep -q '^docker ' "${log}"; then echo 'Docker ran without a private config'; exit 1; fi
    if grep -q '^aws ecr ' "${log}"; then echo 'Requested token without a private config'; exit 1; fi
  fi
  assert_ephemeral_cleanup
done
failure=layer
if run_ctl deploy; then echo 'Accepted denied layer'; exit 1; fi
if grep -q '^docker compose ' "${log}"; then echo 'Changed services after a failed pull'; exit 1; fi
failure=""
echo 'PASS: missing/expired identity, denied ECR, manifest and layer access stop deployment'

provider=credentials
printf '2\nASIAFIXTUREONLY\nfixture-secret-never-log\nfixture-token-never-log\n' > "${input}"
run_ctl auth configure
[[ "$(stat -c %a "${credentials}")" == 600 ]]
[[ "$(stat -c %a "$(dirname "${credentials}")")" == 700 ]]
[[ "$(cat "${state}")" == credentials ]]
assert_no_secrets
assert_ephemeral_cleanup
run_ctl deploy
assert_no_secrets
echo 'PASS: temporary credentials persist privately and are reused without exports'

cp "${credentials}" "${test_root}/previous-credentials"
cp "${state}" "${test_root}/previous-state"
failure=identity
replacement=yes
printf '2\nASIAFIXTUREONLY\nfixture-secret-never-log-replacement\nfixture-token-never-log-replacement\nq\n' > "${input}"
if run_ctl auth configure; then echo 'Saved invalid replacement'; exit 1; fi
cmp "${credentials}" "${test_root}/previous-credentials"
cmp "${state}" "${test_root}/previous-state"
assert_no_service_changes
assert_ephemeral_cleanup
failure=""
replacement=""
printf '2\nASIAFIXTUREONLY\nfixture-secret-never-log\n\nq\n' > "${input}"
if run_ctl auth configure; then echo 'Accepted missing session token'; exit 1; fi
[[ ! -s "${log}" ]]
cmp "${credentials}" "${test_root}/previous-credentials"
echo 'PASS: failed replacement and cancellation preserve working selection and remove candidates'

printf 'ASIAFIXTUREONLY\nfixture-secret-never-log\nfixture-token-never-log\n' > "${input}"
run_ctl auth login
assert_no_secrets
assert_ephemeral_cleanup
echo 'PASS: temporary credential renewal uses the same verification'

provider=browser
printf '1\n' > "${input}"
run_ctl auth configure
grep -q '^aws login --remote --profile opsrabbit-deploy --region us-east-1$' "${log}"
[[ ! -e "${credentials}" ]]
run_ctl auth login
grep -q '^aws login --remote ' "${log}"
echo 'PASS: browser selection and renewal use a named deployment profile'
cp "${test_root}/home/.aws/opsrabbit/config" "${test_root}/previous-browser-config"
cp "${state}" "${test_root}/previous-state"
browser_session=rejected
failure=manifest
printf '1\nq\n' > "${input}"
if run_ctl auth configure; then echo 'Accepted inaccessible browser identity'; exit 1; fi
cmp "${test_root}/home/.aws/opsrabbit/config" "${test_root}/previous-browser-config"
cmp "${state}" "${test_root}/previous-state"
assert_ephemeral_cleanup
failure=""
echo 'PASS: rejected browser replacement preserves the previous profile and selection'

provider=profile
printf '4\nfixture-profile\n' > "${input}"
run_ctl auth configure
renew=sso
run_ctl auth login
grep -q '^aws sso login --profile fixture-profile --use-device-code --no-browser$' "${log}"
renew=""
echo 'PASS: existing SSO profiles renew through device login'

provider=role
printf '3\n' > "${input}"
run_ctl auth configure
[[ "$(cat "${state}")" == instance-role ]]
run_ctl deploy
assert_ephemeral_cleanup
echo 'PASS: instance metadata is enabled only after explicit role selection'

printf 'invalid\n\n' > "${state}"
if run_ctl deploy; then echo 'Accepted corrupt selection'; exit 1; fi
[[ ! -s "${log}" ]]
echo 'PASS: invalid persisted selection fails closed'

echo 'AWS authentication regression tests passed.'
