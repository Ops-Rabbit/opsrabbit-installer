#!/usr/bin/env bash
set -euo pipefail

repository="Ops-Rabbit/opsrabbit-installer"
version="${OPSRABBIT_INSTALLER_VERSION:-latest}"
archive="opsrabbit-aws-image-bundle.tar.gz"
checksum="${archive}.sha256"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root, for example: curl -fsSL https://raw.githubusercontent.com/${repository}/main/install.sh | sudo bash" >&2
  exit 1
fi

if [[ "${version}" == "latest" ]]; then
  release_url="https://github.com/${repository}/releases/latest/download"
else
  release_url="https://github.com/${repository}/releases/download/${version}"
fi

temporary_dir="$(mktemp -d)"
cleanup() { rm -rf "${temporary_dir}"; }
trap cleanup EXIT

echo "Downloading OpsRabbit installer ${version}..."
curl --fail --silent --show-error --location "${release_url}/${archive}" -o "${temporary_dir}/${archive}"
curl --fail --silent --show-error --location "${release_url}/${checksum}" -o "${temporary_dir}/${checksum}"

(
  cd "${temporary_dir}"
  sha256sum --check "${checksum}"
  tar -xzf "${archive}"
)

installer="${temporary_dir}/opsrabbit-aws-image-bundle/install.sh"
if [[ ! -x "${installer}" ]]; then
  echo "The release archive does not contain an executable installer." >&2
  exit 1
fi

echo "Archive verified. Starting the interactive installer..."
exec </dev/tty
"${installer}"
