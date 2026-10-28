#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
cleanup() { rm -rf "${test_root}"; }
trap cleanup EXIT

deploy_dir="${test_root}/deploy"
stub_bin="${test_root}/bin"
command_log="${test_root}/commands.log"
mkdir -p "${deploy_dir}" "${stub_bin}"

cat > "${deploy_dir}/.env" <<'EOF'
AWS_REGION=us-east-1
ECR_REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com
OPSRABBIT_BACKEND_PORT=8384
WEB_HTTP_PORT=3000
OPSRABBIT_DAEMON_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/vg-backend:test
OPSRABBIT_WEB_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/vg-webapp:test
OPSRABBIT_SANDBOX_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/vg-sandbox:test
OPENSANDBOX_PORT=8080
OPENSANDBOX_SERVER_API_KEY=test-open-sandbox-key
EOF
touch "${deploy_dir}/docker-compose.yml"
printf "profile\nfixture-profile\n" > "${deploy_dir}/.aws-auth"

cat > "${stub_bin}/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "sts get-caller-identity "* ]]; then
  [[ "${AWS_PROFILE:-}" == fixture-profile && "${AWS_EC2_METADATA_DISABLED:-}" == true ]]
  printf '123456789012\tarn:aws:iam::123456789012:role/fixture\n'
else
  echo temporary-password
fi
EOF

cat > "${stub_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "login" ]]; then
  cat >/dev/null
  echo "WARNING! Your credentials are stored unencrypted" >&2
  echo "Login Succeeded"
  exit 0
fi
printf '%s|%s|%s\n' "${PWD}" "${DOCKER_CONFIG:-}" "$*" >> "${OPSRABBIT_TEST_COMMAND_LOG}"
if [[ "$*" == *'exec -T daemon node /opt/opsrabbit/apps/backend/dist/scripts/initialize-opensandbox.js' ]]; then
  cat > "${OPSRABBIT_TEST_COMMAND_LOG}.stdin"
  jq -e '.endpoint == "http://opensandbox-server:8080" and .apiKey == "test-open-sandbox-key" and .image == "123456789012.dkr.ecr.us-east-1.amazonaws.com/vg-sandbox:test"' "${OPSRABBIT_TEST_COMMAND_LOG}.stdin" >/dev/null
  [[ "${OPSRABBIT_TEST_INIT_FAIL:-}" != true ]] || exit 1
  echo 'Sandbox configuration ready; execution remains disabled.'
fi
if [[ "$*" == *"compose "*" ps -q opensandbox-server" ]]; then
  echo "opensandbox-test-container"
fi
EOF
chmod +x "${stub_bin}/aws" "${stub_bin}/docker"

cat > "${stub_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
arguments="$*"
if [[ "${arguments}" == *"--write-out %{http_code}"*"/v1/sandboxes"* ]]; then
  printf '401'
  exit 0
fi
if [[ "${arguments}" == *"--header @-"*"/v1/sandboxes"* ]]; then
  read -r header
  [[ "${header}" == "OPEN-SANDBOX-API-KEY: ${OPSRABBIT_TEST_API_KEY}" ]]
  exit 0
fi
case "${arguments}" in
  *"http://127.0.0.1:8384/health"*|*"http://127.0.0.1:3000/"*|*"http://127.0.0.1:8080/health"*) exit 0 ;;
esac
echo "Unexpected curl invocation: ${arguments}" >&2
exit 1
EOF
chmod +x "${stub_bin}/curl"

bash "${repo_root}/tests/release-fixture.sh" "${test_root}" "${stub_bin}"
export TEST_RELEASE_ROOT="${test_root}"
output="$(
  cd "${test_root}"
  PATH="${stub_bin}:${PATH}" \
    OPSRABBIT_DEPLOY_DIR="${deploy_dir}" \
    OPSRABBIT_TEST_COMMAND_LOG="${command_log}" \
    "${repo_root}/bundle/opsrabbitctl" deploy --adopt --backup-confirmed
)"

sed -E -i 's/ -f [^ ]*candidate\.[^ ]*\.compose\.json//g' "${command_log}"
grep -Fq "ECR login succeeded using a temporary Docker credential file." <<<"${output}"
if grep -Fq "stored unencrypted" <<<"${output}"; then
  echo "Docker's persistent-credential warning leaked into successful output." >&2
  exit 1
fi
grep -Fq "|pull --platform linux/amd64 123456789012.dkr.ecr.us-east-1.amazonaws.com/vg-sandbox:v1.0.0" "${command_log}"
grep -Fq "|compose --env-file ${deploy_dir}/.env -f ${deploy_dir}/docker-compose.yml pull" "${command_log}"
grep -Fq "|compose --env-file ${deploy_dir}/.env -f ${deploy_dir}/docker-compose.yml stop daemon" "${command_log}"
grep -Fq "|compose --env-file ${deploy_dir}/.env -f ${deploy_dir}/docker-compose.yml up -d --no-build --wait opensandbox-server" "${command_log}"
grep -Fq "|network connect bridge opensandbox-test-container" "${command_log}"
grep -Fq "|compose --env-file ${deploy_dir}/.env -f ${deploy_dir}/docker-compose.yml up -d --no-build --wait web" "${command_log}"

pull_line="$(grep -nF "|compose --env-file ${deploy_dir}/.env -f ${deploy_dir}/docker-compose.yml pull" "${command_log}" | cut -d: -f1)"
daemon_stop_line="$(grep -nF "|compose --env-file ${deploy_dir}/.env -f ${deploy_dir}/docker-compose.yml stop daemon" "${command_log}" | cut -d: -f1)"
bridge_connect_line="$(grep -nF "|network connect bridge opensandbox-test-container" "${command_log}" | cut -d: -f1)"
up_line="$(grep -nF "|compose --env-file ${deploy_dir}/.env -f ${deploy_dir}/docker-compose.yml up -d --no-build --wait web" "${command_log}" | cut -d: -f1)"
[[ "${pull_line}" -lt "${daemon_stop_line}" && "${daemon_stop_line}" -lt "${bridge_connect_line}" && "${bridge_connect_line}" -lt "${up_line}" ]]

while IFS='|' read -r command_pwd docker_config command_args; do
  [[ "${command_pwd}" == "${deploy_dir}" ]]
  [[ "${docker_config}" == /tmp/* || "${docker_config}" == /var/* || "${docker_config}" == "${test_root}"/* ]]
  [[ ! -e "${docker_config}" ]]
  [[ "${command_args}" == manifest* || "${command_args}" == compose* || "${command_args}" == pull* || "${command_args}" == inspect* || "${command_args}" == network* ]]
done < "${command_log}"

# Routine deploy/update does not overwrite application sandbox settings. The
# explicit bootstrap command transports its credential through stdin only.
if grep -Fq initialize-opensandbox.js "${command_log}"; then
  echo "Routine deployment unexpectedly initialized sandbox settings." >&2; exit 1
fi
: > "${command_log}"
initialization_output="$(PATH="${stub_bin}:${PATH}" OPSRABBIT_DEPLOY_DIR="${deploy_dir}" \
  OPSRABBIT_TEST_COMMAND_LOG="${command_log}" "${repo_root}/bundle/opsrabbitctl" sandbox initialize)"
grep -Fq 'execution remains disabled' <<<"${initialization_output}"
if grep -Fq test-open-sandbox-key "${command_log}" || grep -Fq test-open-sandbox-key <<<"${initialization_output}"; then
  echo "Initialization exposed its credential." >&2; exit 1
fi
if PATH="${stub_bin}:${PATH}" OPSRABBIT_DEPLOY_DIR="${deploy_dir}" OPSRABBIT_TEST_COMMAND_LOG="${command_log}" \
  OPSRABBIT_TEST_INIT_FAIL=true "${repo_root}/bundle/opsrabbitctl" sandbox initialize >"${test_root}/initialization-failure.log" 2>&1; then
  echo "Initialization failure was ignored." >&2; exit 1
fi
grep -Fq 'Could not initialize OpenSandbox settings' "${test_root}/initialization-failure.log"

: > "${command_log}"
health_output="$(
  cd "${test_root}"
  PATH="${stub_bin}:${PATH}" \
    OPSRABBIT_DEPLOY_DIR="${deploy_dir}" \
    OPSRABBIT_TEST_COMMAND_LOG="${command_log}" \
    OPSRABBIT_TEST_API_KEY="test-open-sandbox-key" \
    "${repo_root}/bundle/opsrabbitctl" health
)"

grep -Fq "Web health check passed." <<<"${health_output}"
grep -Fq "OpenSandbox health, authentication, and sandbox image checks passed." <<<"${health_output}"
if grep -Fq "test-open-sandbox-key" <<<"${health_output}"; then
  echo "OpenSandbox API key leaked into health output." >&2
  exit 1
fi
grep -Fq "|image inspect 123456789012.dkr.ecr.us-east-1.amazonaws.com/vg-sandbox:test" "${command_log}"

: > "${command_log}"
(
  cd "${test_root}"
  PATH="${stub_bin}:${PATH}" \
    OPSRABBIT_DEPLOY_DIR="${deploy_dir}" \
    OPSRABBIT_TEST_COMMAND_LOG="${command_log}" \
    "${repo_root}/bundle/opsrabbitctl" stop
)
[[ "$(sed -n '1s/^[^|]*|[^|]*|//p' "${command_log}")" == "compose --env-file ${deploy_dir}/.env -f ${deploy_dir}/docker-compose.yml -f ${deploy_dir}/.release/current.compose.json stop daemon" ]]
[[ "$(sed -n '2s/^[^|]*|[^|]*|//p' "${command_log}")" == "compose --env-file ${deploy_dir}/.env -f ${deploy_dir}/docker-compose.yml -f ${deploy_dir}/.release/current.compose.json stop" ]]

: > "${command_log}"
(
  cd "${test_root}"
  PATH="${stub_bin}:${PATH}" \
    OPSRABBIT_DEPLOY_DIR="${deploy_dir}" \
    OPSRABBIT_TEST_COMMAND_LOG="${command_log}" \
    "${repo_root}/bundle/opsrabbitctl" restart
)
[[ "$(sed -n '1s/^[^|]*|[^|]*|//p' "${command_log}")" == "compose --env-file ${deploy_dir}/.env -f ${deploy_dir}/docker-compose.yml -f ${deploy_dir}/.release/current.compose.json stop daemon" ]]
[[ "$(sed -n '2s/^[^|]*|[^|]*|//p' "${command_log}")" == "compose --env-file ${deploy_dir}/.env -f ${deploy_dir}/docker-compose.yml -f ${deploy_dir}/.release/current.compose.json restart" ]]

grep -Fxq 'OPENSANDBOX_SERVER_API_KEY=test-open-sandbox-key' "${deploy_dir}/.env"
[[ "$(jq -r .version "${deploy_dir}/.release/current.json")" == v1.1.1 ]]
[[ ! -e "${deploy_dir}/.release/pending.json" ]]
! grep -Eq ':(latest|latestv2)$' "${deploy_dir}/.env"
echo "opsrabbitctl regression test passed."
