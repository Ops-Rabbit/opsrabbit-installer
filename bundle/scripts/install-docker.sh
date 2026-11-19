#!/usr/bin/env bash

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this installer as root, for example: sudo $0" >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify this operating system because /etc/os-release is unavailable." >&2
  exit 1
fi

read_os_release_value() {
  local key="$1" value
  value="$(sed -n "s/^${key}=//p" /etc/os-release | tail -n 1)"
  value="${value#\"}"
  value="${value%\"}"
  printf '%s' "${value}"
}

os_id="$(read_os_release_value ID)"
version_codename="$(read_os_release_value VERSION_CODENAME)"
ubuntu_codename="$(read_os_release_value UBUNTU_CODENAME)"

case "${os_id}" in
  amzn)
    [[ "$(read_os_release_value VERSION_ID)" == 2023 ]] || { echo "Amazon Linux 2023 is required." >&2; exit 1; }
    # Amazon Linux packages Buildx with Docker Engine. Install Compose for all users.
    compose_version=v5.8.0
    arch="$(uname -m)"
    case "${arch}" in
      x86_64) digest=b8840f5008c447f41fce0a57ae3adeab42c89b1eb6e6012524bcabbfb4ffbaf6 ;;
      aarch64) digest=1a9c918b2fb49b9c87f0018c64b5abd0d30715155e98dc939779fbaee6c414d3 ;;
      *) echo "Unsupported Amazon Linux architecture: ${arch}." >&2; exit 1 ;;
    esac
    dnf install -y docker
    plugin_dir=/usr/local/lib/docker/cli-plugins
    install -d -m 0755 "${plugin_dir}"
    plugin="${plugin_dir}/docker-compose"
    if ! printf '%s  %s\n' "${digest}" "${plugin}" | sha256sum --status --check 2>/dev/null || [[ ! -x "${plugin}" ]]; then
      staged="$(mktemp "${plugin_dir}/.compose.XXXXXX")"
      trap 'rm -f -- "${staged}"' EXIT
      curl --fail --silent --show-error --location \
        "https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-linux-${arch}" -o "${staged}"
      printf '%s  %s\n' "${digest}" "${staged}" | sha256sum --check
      chmod 0755 "${staged}"
      mv -fT -- "${staged}" "${plugin}"
    fi
    systemctl enable --now docker
    docker version >/dev/null
    docker buildx version
    docker compose version
    exit 0
    ;;
  debian)
    docker_distribution="debian"
    docker_suite="${version_codename}"
    ;;
  ubuntu)
    docker_distribution="ubuntu"
    docker_suite="${ubuntu_codename:-${version_codename}}"
    ;;
  *)
    echo "Docker's official apt repository is supported here only on Debian and Ubuntu; found: ${os_id:-unknown}." >&2
    exit 1
    ;;
esac

if [[ -z "${docker_suite}" ]]; then
  echo "Cannot determine the operating-system release codename for Docker's apt repository." >&2
  exit 1
fi

docker_architecture="$(dpkg --print-architecture)"
docker_keyring="/etc/apt/keyrings/docker.asc"
docker_source="/etc/apt/sources.list.d/docker.sources"
install -m 0755 -d /etc/apt/keyrings /etc/apt/sources.list.d
keyring_temp="$(mktemp)"
source_temp="$(mktemp /etc/apt/sources.list.d/.docker.sources.XXXXXX)"

cleanup() {
  rm -f -- "${keyring_temp}" "${source_temp}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Configuring Docker's official stable repository for ${docker_distribution} ${docker_suite}..."
curl --fail --show-error --location --silent \
  "https://download.docker.com/linux/${docker_distribution}/gpg" \
  --output "${keyring_temp}"
install -m 0644 "${keyring_temp}" "${docker_keyring}"

cat > "${source_temp}" <<EOF
Types: deb
URIs: https://download.docker.com/linux/${docker_distribution}
Suites: ${docker_suite}
Components: stable
Architectures: ${docker_architecture}
Signed-By: ${docker_keyring}
EOF
chmod 0644 "${source_temp}"
mv -f -- "${source_temp}" "${docker_source}"

apt-get update

conflicting_packages=(
  docker.io
  docker-compose
  docker-compose-v2
  docker-doc
  docker-buildx
  podman-docker
  containerd
  runc
)
installed_conflicts=()
for package in "${conflicting_packages[@]}"; do
  if dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null | grep -q '^ii '; then
    installed_conflicts+=("${package}")
  fi
done

if (( ${#installed_conflicts[@]} > 0 )); then
  echo "Replacing conflicting distribution packages with Docker's official packages: ${installed_conflicts[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get remove -y "${installed_conflicts[@]}"
fi

DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

installed_version="$(dpkg-query -W -f='${Version}' docker-ce)"
# Capture first so parsing cannot close apt-cache's stdout early (SIGPIPE/141).
# Pin the locale because policy labels are translated in other locales.
policy_output="$(LC_ALL=C apt-cache policy docker-ce)" || {
  status=$?
  echo "Unable to read Docker's candidate version from apt-cache (exit ${status})." >&2
  exit "${status}"
}
if ! candidate_version="$(LC_ALL=C awk '
  $1 == "Candidate:" {
    count++
    version = $2
    if (NF != 2) malformed = 1
  }
  END {
    if (count != 1 || malformed) exit 1
    print version
  }
' <<< "${policy_output}")"; then
  echo "Expected exactly one well-formed docker-ce candidate in apt-cache policy output." >&2
  exit 1
fi
if [[ -z "${candidate_version}" || "${candidate_version}" == "(none)" ]]; then
  echo "Docker's official repository did not provide a docker-ce candidate for ${docker_distribution} ${docker_suite}." >&2
  exit 1
fi
if ! dpkg --validate-version "${candidate_version}"; then
  echo "apt-cache returned an invalid docker-ce candidate version." >&2
  exit 1
fi
if [[ "${installed_version}" != "${candidate_version}" ]]; then
  echo "Docker Engine is not at the latest stable repository version: installed ${installed_version}, candidate ${candidate_version}." >&2
  exit 1
fi

systemctl enable --now docker
docker version >/dev/null
docker buildx version >/dev/null
docker compose version >/dev/null

echo "Docker Engine installed from Docker's official repository: $(docker --version)"
echo "Docker Compose installed from Docker's official repository: $(docker compose version --short)"
