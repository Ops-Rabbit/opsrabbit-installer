#!/usr/bin/env bash
set -euo pipefail

repository="Ops-Rabbit/opsrabbit-installer"
default_version=""
version="${OPSRABBIT_INSTALLER_VERSION:-${default_version}}"
archive="opsrabbit-aws-image-bundle.tar.gz"
checksum="${archive}.sha256"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root, for example: curl -fsSL https://github.com/${repository}/releases/download/<installer-version>/install.sh | sudo bash" >&2
  exit 1
fi

if [[ -z "${version}" ]]; then
  if ! command -v jq >/dev/null; then
    apt-get update
    apt-get install -y jq
  fi
  versions='[]'
  page=1
  while :; do
    response="$(curl --fail --silent --show-error --location --max-time 30 --proto '=https' "https://api.github.com/repos/${repository}/releases?per_page=100&page=${page}")"
    count="$(jq -er 'if type=="array" then length else error("Invalid release catalog") end' <<<"${response}")"
    versions="$(jq -cn --argjson before "$versions" --argjson entries "$response" '$before + [$entries[] | select(.draft == false and .prerelease == false) | .tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))]')"
    [[ "$count" -eq 100 ]] || break
    page=$((page + 1))
    [[ "$page" -le 1000 ]] || { echo "Installer catalog exceeded page limit." >&2; exit 1; }
  done
  version="$(jq -er 'sort_by(ltrimstr("v") | split(".") | map(tonumber)) | last // error("No installer release")' <<<"$versions")"
fi
[[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a concrete installer version." >&2; exit 1; }
release_url="https://github.com/${repository}/releases/download/${version}"

temporary_dir="$(mktemp -d)"
cleanup() { rm -rf "${temporary_dir}"; }
trap cleanup EXIT

if ! (true </dev/tty) 2>/dev/null; then
  echo "An interactive terminal is required. Run this command from an interactive SSH session." >&2
  exit 1
fi

echo "[Bootstrap 1/3] Downloading OpsRabbit installer ${version}..."
curl --fail --silent --show-error --location "${release_url}/${archive}" -o "${temporary_dir}/${archive}"
curl --fail --silent --show-error --location "${release_url}/${checksum}" -o "${temporary_dir}/${checksum}"

echo "[Bootstrap 2/3] Verifying and extracting the release archive..."
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

echo "[Bootstrap 3/3] Archive verified. Launching the interactive installer..."
"${installer}"
