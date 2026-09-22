#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this installer as root: sudo ./install.sh" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
input_device="${OPSRABBIT_INPUT_DEVICE:-/dev/tty}"

if ! { true <"${input_device}"; } 2>/dev/null; then
  echo "An interactive terminal is required. Run the installer from an interactive SSH session." >&2
  exit 1
fi

prompt() {
  local variable_name="$1" message="$2" default_value="${3:-}" value
  if [[ -n "${default_value}" ]]; then
    read -r -p "${message} [${default_value}]: " value <"${input_device}"
    value="${value:-${default_value}}"
  else
    while [[ -z "${value:-}" ]]; do read -r -p "${message}: " value <"${input_device}"; done
  fi
  printf -v "${variable_name}" '%s' "${value}"
}

prompt_secret() {
  local variable_name="$1" message="$2" value
  while [[ -z "${value:-}" ]]; do read -r -s -p "${message}: " value <"${input_device}"; echo; done
  printf -v "${variable_name}" '%s' "${value}"
}

yes_no() {
  local message="$1" default_value="$2" value
  read -r -p "${message} [${default_value}]: " value <"${input_device}"
  value="${value:-${default_value}}"
  [[ "${value,,}" == "y" || "${value,,}" == "yes" ]]
}

read_existing_env() {
  local key="$1"
  if [[ ! -r "${env_path:-}" ]]; then return 0; fi
  sed -n "s/^${key}=//p" "${env_path}" | tail -n 1
}

ensure_env_value() {
  local key="$1" value="$2" temporary_env

  if grep -Eq "^${key}=.+$" "${env_path}"; then return; fi

  temporary_env="$(mktemp "${deploy_dir}/.env.XXXXXX")"
  if ! awk -v key="${key}" -v value="${value}" '
    BEGIN { written = 0 }
    index($0, key "=") == 1 {
      if (!written) print key "=" value
      written = 1
      next
    }
    { print }
    END { if (!written) print key "=" value }
  ' "${env_path}" > "${temporary_env}"; then
    rm -f -- "${temporary_env}"
    return 1
  fi

  chown "${deploy_user}:${deploy_user}" "${temporary_env}"
  chmod 0600 "${temporary_env}"
  mv -f -- "${temporary_env}" "${env_path}"
}

install_aws_cli() {
  local machine_arch aws_arch download_url aws_temp_dir install_args

  if command -v aws >/dev/null 2>&1; then
    echo "AWS CLI already installed: $(aws --version 2>&1)"
    return
  fi

  machine_arch="$(uname -m)"
  case "${machine_arch}" in
    x86_64|amd64) aws_arch="x86_64" ;;
    aarch64|arm64) aws_arch="aarch64" ;;
    *)
      echo "AWS CLI v2 does not provide a supported installer for architecture: ${machine_arch}" >&2
      exit 1
      ;;
  esac

  download_url="https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip"
  aws_temp_dir="$(mktemp -d)"
  echo "AWS CLI not found; downloading the official AWS CLI v2 installer for ${aws_arch}..."
  curl --fail --show-error --location --progress-bar "${download_url}" -o "${aws_temp_dir}/awscliv2.zip"
  echo "Extracting AWS CLI v2..."
  unzip -q "${aws_temp_dir}/awscliv2.zip" -d "${aws_temp_dir}"

  install_args=(--bin-dir /usr/local/bin --install-dir /usr/local/aws-cli)
  if [[ -d /usr/local/aws-cli ]]; then install_args+=(--update); fi
  "${aws_temp_dir}/aws/install" "${install_args[@]}"
  rm -rf "${aws_temp_dir}"

  if ! command -v aws >/dev/null 2>&1; then
    echo "AWS CLI installation completed but the aws command is unavailable." >&2
    exit 1
  fi
  echo "AWS CLI installed: $(aws --version 2>&1)"
}

echo "OpsRabbit image-only AWS deployment installer"
echo "This installs Docker/AWS CLI packages when missing, OpenSandbox, and a Docker-enabled deployment user."
echo
echo "[Installer 1/4] Reviewing deployment settings..."

machine_arch="$(uname -m)"
case "${machine_arch}" in
  x86_64|amd64) ;;
  *)
    echo "OpsRabbit release images currently require an x86-64 host; found ${machine_arch}." >&2
    exit 1
    ;;
esac

deploy_user="${OPSRABBIT_INSTALL_USER:-opsrabbit}"
deploy_dir="${OPSRABBIT_INSTALL_DIR:-/opt/opsrabbit}"
aws_region="${OPSRABBIT_AWS_REGION:-us-east-1}"
ecr_registry="${OPSRABBIT_ECR_REGISTRY:-921870554228.dkr.ecr.us-east-1.amazonaws.com}"
daemon_image="${OPSRABBIT_DAEMON_IMAGE:-${ecr_registry}/vg-backend:latestv2}"
web_image="${OPSRABBIT_WEB_IMAGE:-${ecr_registry}/vg-webapp:latestv2}"
web_port="${OPSRABBIT_WEB_PORT:-3000}"
env_path="${deploy_dir}/.env"
configured_registry="$(read_existing_env ECR_REGISTRY)"
configured_sandbox_image="$(read_existing_env OPSRABBIT_SANDBOX_IMAGE)"
configured_opensandbox_port="$(read_existing_env OPENSANDBOX_PORT)"
sandbox_image="${configured_sandbox_image:-${OPSRABBIT_SANDBOX_IMAGE:-${configured_registry:-${ecr_registry}}/vg-sandbox:latest}}"
opensandbox_port="${configured_opensandbox_port:-${OPENSANDBOX_PORT:-8080}}"
restricted_userns=false
if [[ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]] \
  && [[ "$(tr -d '[:space:]' < /proc/sys/kernel/apparmor_restrict_unprivileged_userns)" == "1" ]]; then
  restricted_userns=true
fi

if [[ -r "${env_path}" ]]; then
  public_origin="$(sed -n 's/^OPSRABBIT_WEB_ORIGIN=//p' "${env_path}" | tail -n 1)"
  public_origin="${public_origin:-http://$(hostname -I | awk '{print $1}'):${web_port}}"
  echo "Existing configuration found at ${env_path}; its secrets and public URL will be preserved."
else
  prompt public_origin "Public OpsRabbit URL" "http://$(hostname -I | awk '{print $1}'):${web_port}"
fi

echo
echo "Configuration summary"
echo "  User: ${deploy_user}"
echo "  Directory: ${deploy_dir}"
echo "  Registry: ${ecr_registry}"
echo "  Backend: ${daemon_image}"
echo "  Web: ${web_image}"
echo "  Sandbox: ${sandbox_image}"
echo "  OpenSandbox port: 127.0.0.1:${opensandbox_port}"
if [[ "${restricted_userns}" == true ]]; then
  echo "  AppArmor: configure Bubblewrap compatibility for restricted user namespaces"
else
  echo "  AppArmor: compatibility profile not required by this host"
fi
echo "  Origin: ${public_origin}"
echo
if ! yes_no "Continue" "yes"; then exit 0; fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This installer currently supports Debian and Ubuntu hosts with apt-get." >&2
  exit 1
fi

echo "[Installer 2/4] Installing and verifying host prerequisites..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl unzip
if [[ "${restricted_userns}" == true ]] && ! command -v apparmor_parser >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y apparmor
fi
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
install_aws_cli

echo "[Installer 3/4] Creating the deployment user and persistent configuration..."
if ! id "${deploy_user}" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "${deploy_user}"
fi
usermod -aG docker "${deploy_user}"
install -d -m 0750 -o "${deploy_user}" -g "${deploy_user}" "${deploy_dir}"
install -m 0640 -o "${deploy_user}" -g "${deploy_user}" "${script_dir}/docker-compose.yml" "${deploy_dir}/docker-compose.yml"
install -m 0640 -o "${deploy_user}" -g "${deploy_user}" "${script_dir}/opensandbox-config.toml" "${deploy_dir}/opensandbox-config.toml"
install -m 0750 -o root -g docker "${script_dir}/opsrabbitctl" /usr/local/bin/opsrabbitctl

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
OPSRABBIT_SANDBOX_IMAGE=${sandbox_image}
OPSRABBIT_POSTGRES_PASSWORD=${postgres_password}
BETTER_AUTH_SECRET=${auth_secret}
OPSRABBIT_NODE_ENCRYPTION_KEY=${encryption_key}
OPENSANDBOX_SERVER_API_KEY=$(openssl rand -hex 32)
OPENSANDBOX_PORT=${opensandbox_port}
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

ensure_env_value OPSRABBIT_SANDBOX_IMAGE "${sandbox_image}"
ensure_env_value OPENSANDBOX_SERVER_API_KEY "$(openssl rand -hex 32)"
ensure_env_value OPENSANDBOX_PORT "${opensandbox_port}"

if [[ "${restricted_userns}" == true ]]; then
  "${script_dir}/scripts/install-opensandbox-apparmor.sh"
else
  echo "The host does not enforce AppArmor's restricted unprivileged-user-namespace setting; no compatibility profile was installed."
fi

run_as_deployer() {
  local command="$1"
  runuser -u "${deploy_user}" -- env HOME="$(getent passwd "${deploy_user}" | cut -d: -f6)" bash -lc "${command}"
}

echo "[Installer 4/4] Verifying AWS access, pulling images, and starting services..."
export AWS_METADATA_SERVICE_TIMEOUT=2
export AWS_METADATA_SERVICE_NUM_ATTEMPTS=1
if run_as_deployer "aws sts get-caller-identity >/dev/null 2>&1"; then
  echo "Using the AWS identity already available to ${deploy_user} (for example, an EC2 instance role)."
else
  echo "No EC2 instance role or existing AWS CLI credentials were detected for ${deploy_user}."
  echo "Enter a least-privilege ECR pull credential. It will be stored in ${deploy_user}'s ~/.aws with mode 0600."
  aws_access_key_id=""
  aws_secret_access_key=""
  prompt aws_access_key_id "AWS access key ID"
  prompt_secret aws_secret_access_key "AWS secret access key"
  read -r -s -p "AWS session token (optional; press Enter if unused): " aws_session_token <"${input_device}"
  echo

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

  if ! run_as_deployer "aws sts get-caller-identity >/dev/null"; then
    echo "The supplied AWS credentials are not valid." >&2
    exit 1
  fi
fi

echo "AWS access verified. Authenticating to ECR and starting OpsRabbit..."
run_as_deployer "OPSRABBIT_DEPLOY_DIR='${deploy_dir}' /usr/local/bin/opsrabbitctl deploy"
run_as_deployer "OPSRABBIT_DEPLOY_DIR='${deploy_dir}' /usr/local/bin/opsrabbitctl health"

echo
echo "OpsRabbit is running at ${public_origin}"
echo "OpenSandbox endpoint for Configuration -> Sandbox: http://opensandbox-server:8080"
echo "Sandbox image: ${sandbox_image}"
echo "The OpenSandbox API key is stored in ${env_path} and was not printed."
echo "Routine commands: opsrabbitctl status | logs | health | update"
echo "The ${deploy_user} user belongs to the docker group, which is effectively root-equivalent."
