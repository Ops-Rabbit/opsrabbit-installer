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
EOF
touch "${deploy_dir}/docker-compose.yml"

cat > "${stub_bin}/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo temporary-password
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
EOF
chmod +x "${stub_bin}/aws" "${stub_bin}/docker"

output="$(
  cd "${test_root}"
  PATH="${stub_bin}:${PATH}" \
    OPSRABBIT_DEPLOY_DIR="${deploy_dir}" \
    OPSRABBIT_TEST_COMMAND_LOG="${command_log}" \
    "${repo_root}/bundle/opsrabbitctl" deploy
)"

grep -Fq "ECR login succeeded using a temporary Docker credential file." <<<"${output}"
if grep -Fq "stored unencrypted" <<<"${output}"; then
  echo "Docker's persistent-credential warning leaked into successful output." >&2
  exit 1
fi

while IFS='|' read -r command_pwd docker_config command_args; do
  [[ "${command_pwd}" == "${deploy_dir}" ]]
  [[ "${docker_config}" == /tmp/* || "${docker_config}" == /var/* || "${docker_config}" == "${test_root}"/* ]]
  [[ ! -e "${docker_config}" ]]
  [[ "${command_args}" == compose* ]]
done < "${command_log}"

echo "opsrabbitctl regression test passed."
