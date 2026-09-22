#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly PROJECT_ROOT
readonly PROFILE_NAME="opsrabbit-opensandbox-bwrap"
readonly SOURCE_PROFILE="$PROJECT_ROOT/deploy/apparmor/$PROFILE_NAME"
readonly TARGET_PROFILE="/etc/apparmor.d/$PROFILE_NAME"
TARGET_DIR="$(dirname "$TARGET_PROFILE")"
readonly TARGET_DIR

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this installer as root, for example: sudo $0" >&2
  exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This AppArmor compatibility profile is only supported on Linux." >&2
  exit 1
fi

if ! command -v apparmor_parser >/dev/null 2>&1; then
  echo "apparmor_parser is required. Install the AppArmor utilities first." >&2
  exit 1
fi

if [[ ! -r "$SOURCE_PROFILE" ]]; then
  echo "Profile source not found: $SOURCE_PROFILE" >&2
  exit 1
fi

# Parse before touching the host policy directory. -Q skips the kernel load.
apparmor_parser -Q "$SOURCE_PROFILE"

staging_dir="$(mktemp -d "$TARGET_DIR/.opsrabbit-apparmor.XXXXXX")"
readonly replacement_profile="$staging_dir/replacement"
readonly backup_profile="$staging_dir/previous"
had_previous=false
rollback_required=false

cleanup_staging() {
  rm -f -- "$replacement_profile" "$backup_profile"
  if ! rmdir -- "$staging_dir"; then
    echo "Warning: could not remove AppArmor staging directory: $staging_dir" >&2
  fi
}

rollback_host_state() {
  echo "Restoring the prior AppArmor host state." >&2

  if ! apparmor_parser -R "$SOURCE_PROFILE"; then
    echo "Warning: could not remove every new profile label; inspect AppArmor state manually." >&2
  fi

  if [[ "$had_previous" == true ]]; then
    mv -f -- "$backup_profile" "$TARGET_PROFILE"
    if ! apparmor_parser -r "$TARGET_PROFILE"; then
      echo "Error: the previous profile file was restored but could not be reloaded." >&2
    fi
  else
    rm -f -- "$TARGET_PROFILE"
  fi

}

on_exit() {
  local exit_code=$?
  trap - EXIT INT TERM
  set +e

  if [[ "$rollback_required" == true ]]; then
    rollback_host_state
  fi
  cleanup_staging

  exit "$exit_code"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -e "$TARGET_PROFILE" ]]; then
  cp --preserve=mode,ownership,timestamps -- "$TARGET_PROFILE" "$backup_profile"
  had_previous=true
fi

install -o root -g root -m 0644 "$SOURCE_PROFILE" "$replacement_profile"

# Both files are on the same filesystem, so the live policy changes atomically.
rollback_required=true
mv -f -- "$replacement_profile" "$TARGET_PROFILE"

if ! apparmor_parser -r "$TARGET_PROFILE"; then
  echo "AppArmor rejected the new profile." >&2
  exit 1
fi

rollback_required=false
cleanup_staging
trap - EXIT INT TERM

echo "Installed and loaded AppArmor profile: $PROFILE_NAME"
echo "No service restart or host reboot is required."
