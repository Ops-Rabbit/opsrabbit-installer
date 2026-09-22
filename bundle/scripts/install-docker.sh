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
candidate_version="$(apt-cache policy docker-ce | awk '/Candidate:/ { print $2; exit }')"
if [[ -z "${candidate_version}" || "${candidate_version}" == "(none)" ]]; then
  echo "Docker's official repository did not provide a docker-ce candidate for ${docker_distribution} ${docker_suite}." >&2
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
