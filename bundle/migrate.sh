#!/usr/bin/env bash
# One-time helper migration. Does not replace customer Compose/TOML, .env, or data.
set -euo pipefail
set +x
[[ "${EUID}" -eq 0 ]] || { echo "Run sudo ./migrate.sh --backup-confirmed [--version vX.Y.Z]" >&2; exit 1; }
[[ "${1:-}" == --backup-confirmed ]] || { echo "Back up PostgreSQL and deployment configuration first; pass --backup-confirmed." >&2; exit 1; }
shift
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deploy_dir="${OPSRABBIT_DEPLOY_DIR:-/opt/opsrabbit}"
[[ -f "${deploy_dir}/.env" && -f "${deploy_dir}/docker-compose.yml" ]] || { echo "Deployment not found: ${deploy_dir}" >&2; exit 1; }
command -v jq >/dev/null && command -v flock >/dev/null || { echo "Install jq and util-linux first." >&2; exit 1; }
install -d -m 0755 /usr/local/lib/opsrabbit
install -m 0644 "${script_dir}/scripts/releases.sh" /usr/local/lib/opsrabbit/releases.sh
install -m 0644 "${script_dir}/scripts/aws-auth.sh" /usr/local/lib/opsrabbit/aws-auth.sh
install -m 0755 "${script_dir}/opsrabbitctl" /usr/local/bin/opsrabbitctl
# v1.3.4's explicit identity selection is mandatory for older installations.
if [[ ! -f "${deploy_dir}/.aws-auth" ]]; then
  OPSRABBIT_DEPLOY_DIR="${deploy_dir}" /usr/local/bin/opsrabbitctl auth configure
fi
OPSRABBIT_DEPLOY_DIR="${deploy_dir}" /usr/local/bin/opsrabbitctl deploy --adopt --backup-confirmed "$@"
