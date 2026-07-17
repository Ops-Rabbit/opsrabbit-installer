#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this installer as root: sudo ./install.sh" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

prompt() {
  local variable_name="$1" message="$2" default_value="${3:-}" value
  if [[ -n "${default_value}" ]]; then
    read -r -p "${message} [${default_value}]: " value
    value="${value:-${default_value}}"
  else
    while [[ -z "${value:-}" ]]; do read -r -p "${message}: " value; done
  fi
  printf -v "${variable_name}" '%s' "${value}"
}

prompt_secret() {
  local variable_name="$1" message="$2" value
  while [[ -z "${value:-}" ]]; do read -r -s -p "${message}: " value; echo; done
  printf -v "${variable_name}" '%s' "${value}"
}

yes_no() {
  local message="$1" default_value="$2" value
  read -r -p "${message} [${default_value}]: " value
  value="${value:-${default_value}}"
  [[ "${value,,}" == "y" || "${value,,}" == "yes" ]]
}

echo "OpsRabbit image-only AWS deployment installer"
echo "This installs Docker/AWS CLI packages when missing and creates a Docker-enabled deployment user."
echo

prompt deploy_user "Deployment user" "opsrabbit"
prompt deploy_dir "Deployment directory" "/opt/opsrabbit"
prompt aws_region "AWS region" "us-east-1"
prompt ecr_registry "ECR registry (account.dkr.ecr.region.amazonaws.com)"
prompt daemon_image "Backend image repository:tag" "${ecr_registry}/vg-backend:latest"
prompt web_image "Web image repository:tag" "${ecr_registry}/vg-web:latest"
prompt public_origin "Public OpsRabbit origin, including scheme and optional port" "http://$(hostname -I | awk '{print $1}'):3000"
prompt web_port "Public web port" "3000"

echo
echo "AWS authentication method:"
echo "  1) EC2 instance role (recommended on EC2)"
echo "  2) Store an access key for the deployment user"
echo "  3) Use AWS CLI credentials already configured for the deployment user"
prompt auth_method "Choose 1, 2, or 3" "1"

if [[ "${auth_method}" == "2" ]]; then
  echo "The access key will be stored in ${deploy_user}'s ~/.aws/credentials with mode 0600."
  prompt aws_access_key_id "AWS access key ID"
  prompt_secret aws_secret_access_key "AWS secret access key"
  read -r -s -p "AWS session token (optional; press Enter if unused): " aws_session_token
  echo
elif [[ "${auth_method}" != "1" && "${auth_method}" != "3" ]]; then
  echo "Invalid authentication method." >&2
  exit 1
fi

echo
echo "Configuration summary"
echo "  User: ${deploy_user}"
echo "  Directory: ${deploy_dir}"
echo "  Registry: ${ecr_registry}"
echo "  Backend: ${daemon_image}"
echo "  Web: ${web_image}"
echo "  Origin: ${public_origin}"
echo
if ! yes_no "Continue" "yes"; then exit 0; fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This installer currently supports Debian and Ubuntu hosts with apt-get." >&2
  exit 1
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl awscli
if ! command -v docker >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
fi
if ! docker compose version >/dev/null 2>&1; then
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
  fi
fi
systemctl enable --now docker
docker compose version >/dev/null

if ! id "${deploy_user}" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "${deploy_user}"
fi
usermod -aG docker "${deploy_user}"
install -d -m 0750 -o "${deploy_user}" -g "${deploy_user}" "${deploy_dir}"
install -m 0640 -o "${deploy_user}" -g "${deploy_user}" "${script_dir}/docker-compose.yml" "${deploy_dir}/docker-compose.yml"
install -m 0750 -o root -g docker "${script_dir}/opsrabbitctl" /usr/local/bin/opsrabbitctl

if [[ "${auth_method}" == "2" ]]; then
  user_home="$(getent passwd "${deploy_user}" | cut -d: -f6)"
  aws_dir="${user_home}/.aws"
  install -d -m 0700 -o "${deploy_user}" -g "${deploy_user}" "${aws_dir}"
  {
    echo "[default]"
    echo "aws_access_key_id = ${aws_access_key_id}"
    echo "aws_secret_access_key = ${aws_secret_access_key}"
    if [[ -n "${aws_session_token:-}" ]]; then echo "aws_session_token = ${aws_session_token}"; fi
  } > "${aws_dir}/credentials"
  printf '[default]\nregion = %s\n' "${aws_region}" > "${aws_dir}/config"
  chown "${deploy_user}:${deploy_user}" "${aws_dir}/credentials" "${aws_dir}/config"
  chmod 0600 "${aws_dir}/credentials" "${aws_dir}/config"
fi

env_path="${deploy_dir}/.env"
if [[ -e "${env_path}" ]]; then
  echo "Preserving existing ${env_path}; image and URL settings were not overwritten."
else
  postgres_password="$(openssl rand -hex 24)"
  auth_secret="$(openssl rand -hex 32)"
  encryption_key="$(openssl rand -hex 32)"
  docker_socket_gid="$(stat -c '%g' /var/run/docker.sock)"
  cat > "${env_path}" <<EOF
AWS_REGION=${aws_region}
ECR_REGISTRY=${ecr_registry}
OPSRABBIT_DAEMON_IMAGE=${daemon_image}
OPSRABBIT_WEB_IMAGE=${web_image}
OPSRABBIT_POSTGRES_PASSWORD=${postgres_password}
BETTER_AUTH_SECRET=${auth_secret}
OPSRABBIT_NODE_ENCRYPTION_KEY=${encryption_key}
OPSRABBIT_DOCKER_SOCKET_GID=${docker_socket_gid}
OPSRABBIT_WEB_ORIGIN=${public_origin}
OPSRABBIT_NODE_BASE_URL=${public_origin%/}/api
OPSRABBIT_BACKEND_PORT=8384
WEB_BIND_ADDRESS=0.0.0.0
WEB_HTTP_PORT=${web_port}
EOF
  chown "${deploy_user}:${deploy_user}" "${env_path}"
  chmod 0600 "${env_path}"
fi

run_as_deployer() {
  local command="$1"
  runuser -u "${deploy_user}" -- env HOME="$(getent passwd "${deploy_user}" | cut -d: -f6)" bash -lc "${command}"
}

if [[ "${auth_method}" == "3" ]]; then
  if ! run_as_deployer "aws sts get-caller-identity >/dev/null"; then
    echo "No working AWS credentials were found for ${deploy_user}. Configure them and run: opsrabbitctl deploy" >&2
    exit 1
  fi
fi

echo "Authenticating to ECR and starting OpsRabbit..."
run_as_deployer "OPSRABBIT_DEPLOY_DIR='${deploy_dir}' /usr/local/bin/opsrabbitctl deploy"
run_as_deployer "OPSRABBIT_DEPLOY_DIR='${deploy_dir}' /usr/local/bin/opsrabbitctl health"

echo
echo "OpsRabbit is running at ${public_origin}"
echo "Routine commands: opsrabbitctl status | logs | health | update"
echo "The ${deploy_user} user belongs to the docker group, which is effectively root-equivalent."

