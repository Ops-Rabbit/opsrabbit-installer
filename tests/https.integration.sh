#!/usr/bin/env bash
# Opt-in local Docker check. Supply an image built with the OpsRabbit Nginx entrypoint.
set -euo pipefail
: "${OPSRABBIT_TEST_WEB_IMAGE:?Set to the locally available OpsRabbit web image}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d /tmp/opsrabbit-https-test.XXXXXX)"
export OPSRABBIT_DEPLOY_DIR="$test_root"
project="opsrabbit-https-test-$$"
export COMPOSE_PROJECT_NAME="$project"
cleanup() {
  docker compose --env-file "$test_root/.env" -f "$test_root/docker-compose.yml" \
    -f "$test_root/docker-compose.https.yml" down --volumes >/dev/null 2>&1 || true
  rm -rf "$test_root"
}
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=opsrabbit.example.com \
  -addext subjectAltName=DNS:opsrabbit.example.com \
  -keyout "$test_root/key.pem" -out "$test_root/cert.pem" >/dev/null 2>&1
cat > "$test_root/.env" <<ENV
AWS_REGION=us-east-1
ECR_REGISTRY=example.invalid
OPSRABBIT_BACKEND_PORT=18384
OPSRABBIT_SANDBOX_IMAGE=node:24.21.0-bookworm-slim
OPENSANDBOX_PORT=18384
OPENSANDBOX_SERVER_API_KEY=fixture-key
WEB_HTTP_PORT=18300
WEB_BIND_ADDRESS=127.0.0.1
OPSRABBIT_WEB_ORIGIN=http://opsrabbit.example.com:18300
OPSRABBIT_NODE_BASE_URL=http://opsrabbit.example.com:18300/api
ENV
cat > "$test_root/docker-compose.yml" <<YAML
services:
  daemon:
    image: node:24.21.0-bookworm-slim
    command: ["node", "-e", "require('http').createServer((req,res)=>{res.statusCode=req.url==='/v1/sandboxes'&&!req.headers['open-sandbox-api-key']?401:200;res.end('fixture backend')}).listen(8384,'0.0.0.0')"]
    ports: ["127.0.0.1:18384:8384"]
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:8384/health').then(r=>process.exit(r.ok?0:1))"]
      interval: 1s
      timeout: 5s
      retries: 20
  web:
    image: ${OPSRABBIT_TEST_WEB_IMAGE}
    ports: ["127.0.0.1:18300:80"]
    environment:
      WEB_TLS_MODE: http
      WEB_API_UPSTREAM: http://daemon:8384
    depends_on:
      daemon: {condition: service_healthy}
YAML
ctl=("$repo_root/bundle/opsrabbitctl")
"${ctl[@]}" https configure --hostname opsrabbit.example.com --cert "$test_root/cert.pem" \
  --key "$test_root/key.pem" --https-port 18443 --http-mode keep
curl --noproxy '*' -fsS http://127.0.0.1:18300/ >/dev/null
export CURL_CA_BUNDLE="$test_root/cert.pem"
"${ctl[@]}" health
[[ "$(curl --noproxy '*' --cacert "$test_root/cert.pem" --resolve opsrabbit.example.com:18443:127.0.0.1 -fsS https://opsrabbit.example.com:18443/webhooks/test)" == 'fixture backend' ]]
"${ctl[@]}" https configure --hostname opsrabbit.example.com --cert "$test_root/cert.pem" \
  --key "$test_root/key.pem" --https-port 18443 --http-mode disable
if curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:18300/ >/dev/null 2>&1; then
  echo 'HTTP port still reachable in HTTPS-only mode' >&2; exit 1
fi
"${ctl[@]}" health
# Rotate to a different key/certificate and verify the served fingerprint.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=opsrabbit.example.com \
  -addext subjectAltName=DNS:opsrabbit.example.com \
  -keyout "$test_root/new-key.pem" -out "$test_root/new-cert.pem" >/dev/null 2>&1
"${ctl[@]}" https reload --cert "$test_root/new-cert.pem" --key "$test_root/new-key.pem"
CURL_CA_BUNDLE="$test_root/new-cert.pem" "${ctl[@]}" health
# Redirect mode requires the standard HTTPS port; test Nginx's response on HTTP.
"${ctl[@]}" https configure --hostname opsrabbit.example.com --cert "$test_root/new-cert.pem" \
  --key "$test_root/new-key.pem" --http-mode redirect
headers="$(curl --noproxy '*' -sSI http://127.0.0.1:18300/)"
[[ "$headers" == *'301 Moved Permanently'* && "$headers" == *'Location: https://127.0.0.1/'* ]]
echo 'Real Nginx HTTPS, HTTP modes, webhook forwarding and certificate rotation passed.'
