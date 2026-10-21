#!/usr/bin/env bash
# Shared external catalog/container fixture for CLI boundary tests.
set -euo pipefail
fixture_root="$1"
fixture_bin="$2"
fixture_registry=123456789012.dkr.ecr.us-east-1.amazonaws.com
fixture_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
jq -n --arg registry "$fixture_registry" --arg revision "$fixture_revision" \
  '{schema_version:1,protocol:1,version:"v1.1.1",revision:$revision,platform:"linux/amd64",images:{backend:($registry+"/vg-backend:v1.1.1"),frontend:($registry+"/vg-webapp:v1.1.1"),sandbox:($registry+"/vg-sandbox:v1.0.0")}}' > "$fixture_root/release.json"
printf '%s\n' '{"schema_version":1,"versions":["v1.1.1"]}' > "$fixture_root/catalog.json"
printf '%s\n' '{"services":{"opensandbox-server":{"image":"customer.invalid/lifecycle:v2.3.4"}}}' > "$fixture_root/compose.json"
cat > "$fixture_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'https://opsrabbit-releases-921870554228-us-east-1.s3.us-east-1.amazonaws.com/releases/catalog.json'* ]]; then
  [[ "${TEST_FAILURE:-}" != catalog ]] || exit 22
  cat "$TEST_RELEASE_ROOT/catalog.json"
elif [[ "$*" == *'https://opsrabbit-releases-921870554228-us-east-1.s3.us-east-1.amazonaws.com/releases/v'*'/release.json'* ]]; then
  while [[ "$1" != -o ]]; do shift; done
  cp "$TEST_RELEASE_ROOT/release.json" "$2"
else
  case "$*" in
    *'--write-out %{http_code}'*'/v1/sandboxes'*) printf '401' ;;
    *'--header @-'*) read -r header; [[ "$header" == "OPEN-SANDBOX-API-KEY: ${OPSRABBIT_TEST_API_KEY:-test-open-sandbox-key}" ]] ;;
    *) exit 0 ;;
  esac
fi
CURL
# Preserve each test's own AWS/token/denied-layer fixture; intercept only the
# Docker metadata queries introduced by release validation.
mv "$fixture_bin/docker" "$fixture_bin/docker-original"
cat > "$fixture_bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *'config --format json') cat "$TEST_RELEASE_ROOT/compose.json"; exit 0 ;;
  *'config --services') printf 'postgres\ndaemon\nweb\nopensandbox-server\n'; exit 0 ;;
  *' ps -q daemon'|*' ps -q web') echo fixture-container; exit 0 ;;
  'inspect --format {{.Image}} '*|'image inspect --format {{.Id}} '*) echo sha256:fixture-image-id; exit 0 ;;
  'image inspect --format {{index .Config.Labels "org.opencontainers.image.version"}} '*) echo v1.1.1; exit 0 ;;
  'image inspect --format {{index .Config.Labels "org.opencontainers.image.revision"}} '*) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; exit 0 ;;
esac
exec "$(dirname "$0")/docker-original" "$@"
DOCKER
chmod +x "$fixture_bin/curl" "$fixture_bin/docker"
