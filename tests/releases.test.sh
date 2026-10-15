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
# Exact selection must agree with the downloaded manifest.
if release_discover v1.1.2; then echo "Accepted wrong exact version" >&2; exit 1; fi
if TEST_FAILURE=catalog release_discover; then echo "Accepted catalog failure" >&2; exit 1; fi
jq '.version="v2.0.0"' "${test_root}/release.json" > "${release_dir}/current.json"
if release_discover v1.1.1; then echo "Accepted an unsafe downgrade" >&2; exit 1; fi
[[ ! -e "${release_dir}/pending.json" ]]
echo 'PASS: complete manifests, floating-tag rejection, stable discovery, exact selection, outage and downgrade safety'
