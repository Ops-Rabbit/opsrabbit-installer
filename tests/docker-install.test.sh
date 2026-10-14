#!/usr/bin/env bash
set -euo pipefail

# Run the real Linux entrypoint with host mutations and package operations stubbed.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(id -u)" != 0 || ! -r /etc/os-release ]]; then
  echo "Run this test as root on Linux (a disposable container is sufficient)." >&2
  exit 1
fi
fixture_root="$(mktemp -d)"
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir -p "$fixture_root/bin" "$fixture_root/etc/apt/sources.list.d"
export fixture_root

cat > "$fixture_root/bin/stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command_name="${0##*/}"
case "$command_name" in
  install|mv|mktemp)
    args=()
    for arg in "$@"; do
      if [[ "$arg" == /etc/* ]]; then arg="$fixture_root$arg"; fi
      args+=("$arg")
    done
    exec "/usr/bin/$command_name" "${args[@]}"
    ;;
  curl)
    while [[ "$1" != --output ]]; do shift; done
    printf 'fixture-key\n' > "$2"
    ;;
  dpkg)
    if [[ "$1" == --validate-version ]]; then exec /usr/bin/dpkg "$@"; fi
    [[ "$1" == --print-architecture ]]
    echo amd64
    ;;
  dpkg-query)
    if [[ "$*" == *'${Version}'* ]]; then echo 5:29.9.0-1; else exit 1; fi
    ;;
  apt-get) printf '%s\n' "$*" >> "$fixture_root/apt.log" ;;
  apt-cache)
    [[ "$LC_ALL" == C ]]
    case "$TEST_APT_MODE" in
      error) exit 42 ;;
      partial-error) echo '  Candidate: 5:29.9.0-1'; exit 42 ;;
      missing) echo 'docker-ce:' ;;
      none) echo '  Candidate: (none)' ;;
      duplicate) printf '  Candidate: 5:29.9.0-1\n  Candidate: 5:29.9.0-1\n' ;;
      malformed) echo '  Candidate: 5:29.9.0-1 unexpected-field' ;;
      invalid) echo '  Candidate: not-a-version' ;;
      noisy)
        printf 'Description mentions Candidate: 5:30.0.0-1\n  Candidate: 5:29.9.0-1\n'
        ;;
      mismatch) echo '  Candidate: 5:30.0.0-1' ;;
      large)
        # Stream many writes beyond the pipe buffer. A single large write can
        # finish before the consumer exits on some kernels/emulation runtimes.
        echo '  Candidate: 5:29.9.0-1'
        for ((row=0; row<1024; row++)); do printf '%08192d\n' 0; done
        ;;
    esac
    ;;
  systemctl|docker) printf '%s %s\n' "$command_name" "$*" >> "$fixture_root/verified.log" ;;
  *) echo "Unexpected stub: $command_name" >&2; exit 1 ;;
esac
EOF
chmod +x "$fixture_root/bin/stub"
for command_name in install mv mktemp curl dpkg dpkg-query apt-get apt-cache systemctl docker; do
  ln -s stub "$fixture_root/bin/$command_name"
done

for mode in large noisy mismatch missing none duplicate malformed invalid error partial-error; do
  rm -f "$fixture_root/verified.log"
  status=0
  PATH="$fixture_root/bin:$PATH" TEST_APT_MODE="$mode" LANG=fr_FR.UTF-8 \
    timeout 120 bash "$repo_root/bundle/scripts/install-docker.sh" > "$fixture_root/output" 2>&1 || status=$?
  if [[ "$mode" == large || "$mode" == noisy ]]; then
    if [[ "$status" != 0 ]]; then
      cat "$fixture_root/output"
      echo "Docker installation unexpectedly stopped with exit $status." >&2
      exit 1
    fi
    grep -Fq 'Docker Engine installed from' "$fixture_root/output"
    grep -Fxq 'systemctl enable --now docker' "$fixture_root/verified.log"
    grep -Fxq 'docker compose version' "$fixture_root/verified.log"
  else
    [[ "$status" != 0 && ! -e "$fixture_root/verified.log" ]]
    case "$mode" in
      mismatch) grep -Fq 'not at the latest stable repository version' "$fixture_root/output" ;;
      none) grep -Fq 'did not provide a docker-ce candidate' "$fixture_root/output" ;;
      missing|duplicate|malformed) grep -Fq 'Expected exactly one well-formed docker-ce candidate' "$fixture_root/output" ;;
      invalid) grep -Fq 'invalid docker-ce candidate version' "$fixture_root/output" ;;
      error|partial-error)
        [[ "$status" == 42 ]]
        grep -Fq 'Unable to read' "$fixture_root/output"
        ;;
    esac
  fi
done
echo "Docker installer regression tests passed (10 scenarios, including pipe pressure, locale, invalid/ambiguous policy, and command failures)."
