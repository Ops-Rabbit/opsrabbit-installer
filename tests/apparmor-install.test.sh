#!/usr/bin/env bash
set -euo pipefail

# The real installer has fixed host paths. Isolate those paths in a private
# mount namespace, without adding a test-only override to production code.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != inside ]]; then
  if [[ "$(id -u)" != 0 ]]; then echo "Run this Linux test as root." >&2; exit 1; fi
  fixture_root="$(mktemp -d)"
  trap 'rm -rf -- "$fixture_root"' EXIT
  mkdir -p "$fixture_root/policy" "$fixture_root/sys/kernel/security/apparmor" "$fixture_root/bin"
  cp -a /etc/apparmor.d/. "$fixture_root/policy/"
  touch "$fixture_root/policy/.opsrabbit-test-fixture" "$fixture_root/sys/kernel/security/apparmor/profiles"
  export fixture_root
  unshare --mount --propagation private bash -c '
    set -euo pipefail
    mount --bind "$fixture_root/policy" /etc/apparmor.d
    mount --bind "$fixture_root/sys" /sys
    exec bash "$1" inside
  ' bash "$0"
  exit 0
fi

[[ -f /etc/apparmor.d/.opsrabbit-test-fixture ]]
[[ "$(stat -c %d:%i /etc/apparmor.d)" == "$(stat -c %d:%i "$fixture_root/policy")" ]]
readonly real_parser="$(command -v apparmor_parser)"
export real_parser repo_root
readonly browser=opsrabbit-opensandbox-browser
readonly generic=opsrabbit-opensandbox-bwrap
readonly loaded=/sys/kernel/security/apparmor/profiles

# Parse real syntax; model only kernel load/unload, which tests must never send
# to the host. A failed replacement deliberately models partial kernel loading.
cat > "$fixture_root/bin/apparmor_parser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == -Q || "$1" == -N ]]; then exec "$real_parser" "$@"; fi
names="$("$real_parser" -N "$2")"
state=/sys/kernel/security/apparmor/profiles
while IFS= read -r name; do
  awk -v prefix="$name (" 'index($0, prefix) != 1' "$state" > "$fixture_root/state.next"
  if [[ "$1" == -r ]]; then printf '%s (enforce)\n' "$name" >> "$fixture_root/state.next"; fi
  cp "$fixture_root/state.next" "$state"
done <<< "$names"
if [[ "$1" == -r && "$(basename "$2")" == "${TEST_FAIL_NAME:-}" ]] \
  && cmp -s "$repo_root/bundle/deploy/apparmor/$(basename "$2")" "$2"; then
  if [[ "${TEST_INTERRUPT:-false}" == true ]]; then kill -TERM "$PPID"; fi
  exit 1
fi
EOF
chmod 0755 "$fixture_root/bin/apparmor_parser"
export PATH="$fixture_root/bin:$PATH"

reset_fixture() {
  rm -f -- "/etc/apparmor.d/$browser" "/etc/apparmor.d/$generic" /etc/apparmor.d/bwrap-userns-restrict /etc/apparmor.d/disable/bwrap-userns-restrict
  : > "$loaded"
}
assert_clean() {
  [[ -z "$(find /etc/apparmor.d -maxdepth 1 -name '.opsrabbit-apparmor*' -print)" ]]
}
install_policy() { bash "$repo_root/bundle/scripts/install-opensandbox-apparmor.sh"; }
expect_failure() {
  if install_policy; then echo "Expected installation failure." >&2; exit 1; fi
  assert_clean
}
make_distro() {
  cat > /etc/apparmor.d/bwrap-userns-restrict <<'EOF'
abi <abi/4.0>,
include <tunables/global>
profile bwrap /usr/bin/bwrap { userns, }
profile unpriv_bwrap { audit deny capability, }
EOF
}

# Fresh install: this fails on the old installer, which omits the browser policy.
reset_fixture
install_policy
for name in "$browser" "$generic"; do
  cmp "$repo_root/bundle/deploy/apparmor/$name" "/etc/apparmor.d/$name"
  [[ "$(stat -c '%u:%g:%a' "/etc/apparmor.d/$name")" == 0:0:644 ]]
  grep -q "^$name (enforce)$" "$loaded"
done
assert_clean
install_policy
assert_clean

# Both first-install and replacement failures restore all policy files/state.
for previous in absent loaded unloaded; do
  reset_fixture
  if [[ "$previous" != absent ]]; then
    for name in "$browser" "$generic"; do
      cp "$repo_root/bundle/deploy/apparmor/$name" "/etc/apparmor.d/$name"
      printf '\n# Previous administrator version\n' >> "/etc/apparmor.d/$name"
      chmod 0600 "/etc/apparmor.d/$name"
      cp "/etc/apparmor.d/$name" "$fixture_root/$name.saved"
      if [[ "$previous" == loaded ]]; then apparmor_parser -r "/etc/apparmor.d/$name"; fi
    done
  fi
  cp "$loaded" "$fixture_root/loaded.saved"
  TEST_FAIL_NAME="$generic" expect_failure
  diff -u <(sort "$loaded") <(sort "$fixture_root/loaded.saved")
  for name in "$browser" "$generic"; do
    if [[ "$previous" != absent ]]; then
      cmp "/etc/apparmor.d/$name" "$fixture_root/$name.saved"
      [[ "$(stat -c %a "/etc/apparmor.d/$name")" == 600 ]]
    else
      [[ ! -e "/etc/apparmor.d/$name" ]]
    fi
  done
done

# Prefer the packaged policy without modifying its file or losing loaded state.
reset_fixture
make_distro
cp /etc/apparmor.d/bwrap-userns-restrict "$fixture_root/distro.saved"
apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict
install_policy
cmp /etc/apparmor.d/bwrap-userns-restrict "$fixture_root/distro.saved"
[[ ! -e "/etc/apparmor.d/$generic" ]]
grep -q '^bwrap (enforce)$' "$loaded"
cmp "$repo_root/bundle/deploy/apparmor/$browser" "/etc/apparmor.d/$browser"
assert_clean

# Known legacy migration and rollback on browser failure, including signals.
for outcome in success failure interrupt; do
  reset_fixture
  make_distro
  cp "$repo_root/bundle/deploy/apparmor/$generic" "/etc/apparmor.d/$generic"
  apparmor_parser -r "/etc/apparmor.d/$generic"
  cp "$loaded" "$fixture_root/loaded.saved"
  if [[ "$outcome" == success ]]; then
    install_policy
    [[ ! -e "/etc/apparmor.d/$generic" ]]
    grep -q '^bwrap (enforce)$' "$loaded"
    if grep -q "^$generic " "$loaded"; then exit 1; fi
  else
    interrupt=false
    if [[ "$outcome" == interrupt ]]; then interrupt=true; fi
    TEST_FAIL_NAME="$browser" TEST_INTERRUPT="$interrupt" expect_failure
    cmp "$repo_root/bundle/deploy/apparmor/$generic" "/etc/apparmor.d/$generic"
    diff -u <(sort "$loaded") <(sort "$fixture_root/loaded.saved")
    [[ ! -e "/etc/apparmor.d/$browser" ]]
  fi
  cmp /etc/apparmor.d/bwrap-userns-restrict "$fixture_root/distro.saved"
  assert_clean
done

# Customized/disabled distro setups are rejected before any browser installation.
for conflict in customized disabled; do
  reset_fixture
  make_distro
  if [[ "$conflict" == customized ]]; then
    cp "$repo_root/bundle/deploy/apparmor/$generic" "/etc/apparmor.d/$generic"
    printf '\n# Customized\n' >> "/etc/apparmor.d/$generic"
    cp "/etc/apparmor.d/$generic" "$fixture_root/custom.saved"
  else
    mkdir -p /etc/apparmor.d/disable
    ln -s /etc/apparmor.d/bwrap-userns-restrict /etc/apparmor.d/disable/bwrap-userns-restrict
  fi
  expect_failure
  [[ ! -e "/etc/apparmor.d/$browser" && ! -s "$loaded" ]]
  if [[ "$conflict" == customized ]]; then cmp "/etc/apparmor.d/$generic" "$fixture_root/custom.saved"; fi
done

# A partially active distro policy cannot be restored as one atomic file.
reset_fixture
make_distro
printf 'bwrap (enforce)\n' > "$loaded"
cp "$loaded" "$fixture_root/loaded.saved"
expect_failure
cmp "$loaded" "$fixture_root/loaded.saved"
[[ ! -e "/etc/apparmor.d/$browser" ]]

# Do not overwrite a partial policy or active labels with no recoverable file.
for state in partial orphaned; do
  reset_fixture
  if [[ "$state" == partial ]]; then
    cp "$repo_root/bundle/deploy/apparmor/$browser" "/etc/apparmor.d/$browser"
    printf '%s (enforce)\n' "$browser" > "$loaded"
  else
    apparmor_parser -r "$repo_root/bundle/deploy/apparmor/$browser"
  fi
  cp "$loaded" "$fixture_root/loaded.saved"
  expect_failure
  cmp "$loaded" "$fixture_root/loaded.saved"
  [[ ! -e "/etc/apparmor.d/$generic" ]]
  if [[ "$state" == partial ]]; then
    cmp "$repo_root/bundle/deploy/apparmor/$browser" "/etc/apparmor.d/$browser"
  else
    [[ ! -e "/etc/apparmor.d/$browser" ]]
  fi
done
echo "AppArmor delivery, permissions, migration, rollback and interruption tests passed."
