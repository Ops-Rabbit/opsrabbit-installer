#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/deploy/.release"
printf '#!/usr/bin/env bash\nexit 0\n' > "${test_root}/bin/docker"
bash "${repo_root}/tests/release-fixture.sh" "${test_root}" "${test_root}/bin"
export TEST_RELEASE_ROOT="${test_root}"
export PATH="${test_root}/bin:${PATH}"
deploy_dir="${test_root}/deploy"
ecr_registry=123456789012.dkr.ecr.us-east-1.amazonaws.com
# The validator/resolver is the production manifest boundary; jq and SemVer
# selection run unchanged. Only the external catalog transport is replaced.
source "${repo_root}/bundle/scripts/releases.sh"
release_validate "${test_root}/release.json"
for image_key in backend frontend sandbox; do
  jq --arg key "${image_key}" '.images[$key] = "123456789012.dkr.ecr.us-east-1.amazonaws.com/vg-backend:latest"' "${test_root}/release.json" > "${test_root}/bad.json"
  if release_validate "${test_root}/bad.json"; then echo "Accepted floating ${image_key}" >&2; exit 1; fi
done
jq '.images.frontend |= sub(":v1.1.1"; ":v1.1.2")' "${test_root}/release.json" > "${test_root}/bad.json"
if release_validate "${test_root}/bad.json"; then echo "Accepted a mixed pair" >&2; exit 1; fi
release_discover
[[ "$(jq -r .version "${release_candidate}")" == v1.1.1 ]]
cp "${test_root}/release.json" "${test_root}/release.original.json"
jq '.version="v1.10.0" | .images.backend |= sub(":v1.1.1"; ":v1.10.0") | .images.frontend |= sub(":v1.1.1"; ":v1.10.0")' "${test_root}/release.original.json" > "${test_root}/release.json"
printf '%s\n' '{"schema_version":1,"versions":["v1.9.0","v1.10.0","v1.1.1"]}' > "${test_root}/catalog.json"
release_discover
[[ "$(jq -r .version "${release_candidate}")" == v1.10.0 ]]
cp "${test_root}/release.original.json" "${test_root}/release.json"
printf '%s\n' '{"schema_version":1,"versions":["v1.1.2"]}' > "${test_root}/catalog.json"
# Exact selection must agree with the downloaded manifest.
if release_discover v1.1.2; then echo "Accepted wrong exact version" >&2; exit 1; fi
printf '%s\n' '{"schema_version":1,"versions":["v1.1.1"]}' > "${test_root}/catalog.original.json"
printf '%s\n' '{"schema_version":1,"versions":[]}' > "${test_root}/catalog.json"
if release_discover v1.1.1; then echo "Accepted an unpublished release" >&2; exit 1; fi
if release_discover; then echo "Accepted an empty catalog" >&2; exit 1; fi
for catalog in '{"schema_version":2,"versions":["v1.1.1"]}' '{"schema_version":1,"versions":["latest"]}' '{"schema_version":1,"versions":["v1.1.1-beta"]}' '{"schema_version":1,"versions":["v9007199254740992.0.0"]}' '{"schema_version":1,"versions":["v1.1.1","v1.1.1"]}'; do
  printf '%s\n' "$catalog" > "${test_root}/catalog.json"
  if release_discover; then echo "Accepted a malformed catalog" >&2; exit 1; fi
done
cp "${test_root}/catalog.original.json" "${test_root}/catalog.json"
if TEST_FAILURE=catalog release_discover; then echo "Accepted catalog failure" >&2; exit 1; fi
jq '.version="v2.0.0"' "${test_root}/release.json" > "${release_dir}/current.json"
if release_discover v1.1.1; then echo "Accepted an unsafe downgrade" >&2; exit 1; fi
[[ ! -e "${release_dir}/pending.json" ]]
echo 'PASS: complete manifests, floating-tag rejection, stable discovery, exact selection, outage and downgrade safety'
