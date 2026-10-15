#!/usr/bin/env bash
# External Docker contract fixture. Running image identity comes from the actual
# last Compose override supplied by the CLI, rather than from expected pins.
set -euo pipefail
state="$TEST_RELEASE_ROOT/containers.json"
log="$TEST_RELEASE_ROOT/lifecycle.log"
if [[ ! -f "$state" ]]; then echo '{"daemon":"old-backend","web":"old-web","worker":"old-backend"}' > "$state"; fi
image_id() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
case "$*" in
  'login '*) cat >/dev/null; exit 0 ;;
  'manifest inspect '*) exit 0 ;;
  'pull '*) [[ "${TEST_FAILURE:-}" != pull ]] || exit 1; printf '%s\n' "${*: -1}" >> "$TEST_RELEASE_ROOT/pulled-images"; exit 0 ;;
  'inspect --format {{.State.Running}} fixture-worker') jq -er '.worker != null' "$state"; exit 0 ;;
  'inspect --format {{.Image}} fixture-'*) service="${*: -1}"; image="$(jq -er --arg service "${service#fixture-}" '.[$service]' "$state")"; image_id "$image"; exit 0 ;;
  'image inspect --format {{.Id}} '*) image_id "${*: -1}"; exit 0 ;;
  'image inspect --format {{index .Config.Labels "org.opencontainers.image.version"}} '*) [[ "${TEST_FAILURE:-}" == metadata ]] && echo v0.0.0 || echo v1.1.1; exit 0 ;;
  'image inspect --format {{index .Config.Labels "org.opencontainers.image.revision"}} '*) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; exit 0 ;;
  'image inspect '*) grep -Fxq "${*: -1}" "$TEST_RELEASE_ROOT/pulled-images"; exit 0 ;;
  'inspect '*) echo connected; exit 0 ;;
  'network '*) exit 0 ;;
  'compose '*) ;;
  *) echo "Unsupported Docker fixture operation: $*" >&2; exit 1 ;;
esac
args="$*"
case "$args" in
  *'config --services')
    printf 'daemon\nweb\nopensandbox-server\n'
    # This customer's worker belongs to the background profile.
    if [[ "$args" == *'--profile *'* || "$args" == *'--profile background'* ]]; then echo worker; fi
    exit 0 ;;
  *'config --quiet'|*' pull'*|*' ps') exit 0 ;;
  *' ps -q opensandbox-server') echo fixture-provider; exit 0 ;;
  *' ps -q '*) service="${*: -1}"; if jq -e --arg service "$service" '.[$service] != null' "$state" >/dev/null; then echo "fixture-$service"; fi; exit 0 ;;
esac
service="${*: -1}"
if [[ "$args" == *' stop '* ]]; then
  printf 'stop %s\n' "$service" >> "$log"
  jq --arg service "$service" '.[$service]=null' "$state" > "$state.next"; mv "$state.next" "$state"
  exit 0
fi
if [[ "$args" == *' up '* ]]; then
  [[ "${TEST_FAILURE:-}" != "$service" ]] || { echo "Fixture $service startup failed" >&2; exit 1; }
  if [[ "$service" == opensandbox-server ]]; then exit 0; fi
  override=""
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == -f ]]; then override="$2"; shift; fi
    shift
  done
  image="$(jq -er --arg service "$service" '.services[$service].image' "$override")"
  printf 'up %s %s\n' "$service" "$image" >> "$log"
  jq --arg service "$service" --arg image "$image" '.[$service]=$image' "$state" > "$state.next"; mv "$state.next" "$state"
  exit 0
fi
echo "Unsupported Compose fixture operation: $args" >&2; exit 1
