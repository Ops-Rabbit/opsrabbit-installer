#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly PROJECT_ROOT
readonly TARGET_DIR="/etc/apparmor.d"
readonly LEGACY_NAME="opsrabbit-opensandbox-bwrap"
readonly LEGACY_SOURCE="$PROJECT_ROOT/deploy/apparmor/$LEGACY_NAME"
readonly SYSTEM_PROFILE="$TARGET_DIR/bwrap-userns-restrict"
readonly LOADED_PROFILES="/sys/kernel/security/apparmor/profiles"
profile_names=(opsrabbit-opensandbox-browser)
legacy_loaded=false
system_loaded=false
system_changed=false
legacy_moved=false
changed_profiles=()
previous_loaded_profiles=()

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
if [[ ! -r "$LOADED_PROFILES" ]]; then
  echo "Cannot inspect loaded AppArmor profiles at $LOADED_PROFILES; host policy was not changed." >&2
  exit 1
fi

policy_is_loaded() {
  local names profile_name total=0 active=0
  names="$(apparmor_parser -N "$1")" || return 1
  while IFS= read -r profile_name; do
    [[ -n "$profile_name" ]] || continue
    total=$((total + 1))
    if awk -v prefix="$profile_name (" 'index($0, prefix) == 1 { found = 1 } END { exit !found }' "$LOADED_PROFILES"; then
      active=$((active + 1))
    fi
  done <<< "$names"
  if [[ "$active" != 0 && "$active" != "$total" ]]; then
    echo "Policy $1 is only partially loaded; resolve its host state before installing." >&2
    return 1
  fi
  if [[ "$active" == 0 ]]; then printf 'false'; else printf 'true'; fi
}

if [[ -r "$SYSTEM_PROFILE" ]]; then
  # Preserve the packaged policy; migrate only our unchanged known fallback.
  if [[ -e "$TARGET_DIR/disable/bwrap-userns-restrict" || -L "$TARGET_DIR/disable/bwrap-userns-restrict" ]]; then
    echo "The operating system Bubblewrap AppArmor profile is disabled; host policy was not changed." >&2
    exit 1
  fi
  apparmor_parser -Q "$SYSTEM_PROFILE"
  if [[ -e "$TARGET_DIR/$LEGACY_NAME" ]] && ! cmp -s "$LEGACY_SOURCE" "$TARGET_DIR/$LEGACY_NAME"; then
    echo "Existing $TARGET_DIR/$LEGACY_NAME differs from the OpsRabbit fallback; remove the conflicting profile manually." >&2
    exit 1
  fi
  legacy_loaded="$(policy_is_loaded "$LEGACY_SOURCE")"
  system_loaded="$(policy_is_loaded "$SYSTEM_PROFILE")"
else
  profile_names+=("$LEGACY_NAME")
fi

# Parse every proposed policy before any file or loaded state changes.
for profile_name in "${profile_names[@]}"; do
  source_profile="$PROJECT_ROOT/deploy/apparmor/$profile_name"
  if [[ ! -r "$source_profile" ]]; then
    echo "Profile source not found: $source_profile" >&2
    exit 1
  fi
  apparmor_parser -Q "$source_profile"
  previous_profile="$TARGET_DIR/$profile_name"
  if [[ ! -e "$previous_profile" ]]; then previous_profile="$source_profile"; fi
  previous_loaded="$(policy_is_loaded "$previous_profile")"
  if [[ "$previous_loaded" == true ]]; then
    if [[ ! -e "$TARGET_DIR/$profile_name" ]]; then
      echo "Loaded $profile_name has no policy file to back up; resolve its host state before installing." >&2
      exit 1
    fi
    previous_loaded_profiles+=("$profile_name")
  fi
done

staging_dir="$(mktemp -d "$TARGET_DIR/.opsrabbit-apparmor.XXXXXX")"
cleanup_staging() {
  for profile_name in "${profile_names[@]}" "$LEGACY_NAME"; do
    rm -f -- "$staging_dir/$profile_name.replacement" "$staging_dir/$profile_name.previous"
  done
  if ! rmdir -- "$staging_dir"; then
    echo "Warning: could not remove AppArmor staging directory: $staging_dir" >&2
  fi
}

rollback_host_state() {
  echo "Restoring the prior AppArmor host state." >&2
  local index profile_name target_profile backup_profile
  for ((index=${#changed_profiles[@]}-1; index>=0; index--)); do
    profile_name="${changed_profiles[index]}"
    target_profile="$TARGET_DIR/$profile_name"
    backup_profile="$staging_dir/$profile_name.previous"
    if ! apparmor_parser -R "$PROJECT_ROOT/deploy/apparmor/$profile_name"; then
      echo "Warning: could not remove new labels for $profile_name; inspect AppArmor state manually." >&2
    fi
    if [[ -e "$backup_profile" ]]; then
      mv -f -- "$backup_profile" "$target_profile"
      if [[ " ${previous_loaded_profiles[*]} " == *" $profile_name "* ]] && ! apparmor_parser -r "$target_profile"; then
        echo "Error: the previous $profile_name file was restored but could not be reloaded." >&2
      fi
    else
      rm -f -- "$target_profile"
    fi
  done
  if [[ "$system_changed" == true && "$system_loaded" == false ]]; then
    if ! apparmor_parser -R "$SYSTEM_PROFILE"; then
      echo "Warning: could not unload the newly loaded distribution policy." >&2
    fi
  fi
  if [[ "$legacy_moved" == true && -e "$staging_dir/$LEGACY_NAME.previous" ]]; then
    mv -f -- "$staging_dir/$LEGACY_NAME.previous" "$TARGET_DIR/$LEGACY_NAME"
  fi
  if [[ "$legacy_loaded" == true && "$system_changed" == true ]]; then
    source_profile="$LEGACY_SOURCE"
    if [[ -r "$TARGET_DIR/$LEGACY_NAME" ]]; then source_profile="$TARGET_DIR/$LEGACY_NAME"; fi
    if ! apparmor_parser -r "$source_profile"; then
      echo "Error: could not restore the previous Bubblewrap AppArmor profile." >&2
    fi
  fi
}

on_exit() {
  local exit_code=$?
  trap - EXIT INT TERM
  set +e
  rollback_host_state
  cleanup_staging
  exit "$exit_code"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -r "$SYSTEM_PROFILE" ]]; then
  if [[ -e "$TARGET_DIR/$LEGACY_NAME" ]]; then
    legacy_moved=true
    mv -- "$TARGET_DIR/$LEGACY_NAME" "$staging_dir/$LEGACY_NAME.previous"
  fi
  system_changed=true
  if [[ "$legacy_loaded" == true ]]; then
    removal_profile="$LEGACY_SOURCE"
    if [[ "$legacy_moved" == true ]]; then removal_profile="$staging_dir/$LEGACY_NAME.previous"; fi
    apparmor_parser -R "$removal_profile"
  fi
  apparmor_parser -r "$SYSTEM_PROFILE"
fi

for profile_name in "${profile_names[@]}"; do
  target_profile="$TARGET_DIR/$profile_name"
  if [[ -e "$target_profile" ]]; then
    cp --preserve=mode,ownership,timestamps -- "$target_profile" "$staging_dir/$profile_name.previous"
  fi
  install -o root -g root -m 0644 "$PROJECT_ROOT/deploy/apparmor/$profile_name" "$staging_dir/$profile_name.replacement"
  # Record before the same-filesystem atomic rename, including interruption.
  changed_profiles+=("$profile_name")
  mv -f -- "$staging_dir/$profile_name.replacement" "$target_profile"
  apparmor_parser -r "$target_profile"
done

trap - EXIT INT TERM
cleanup_staging
if [[ -r "$SYSTEM_PROFILE" ]]; then echo "Using the operating system Bubblewrap AppArmor profile: $SYSTEM_PROFILE"; fi
printf 'Installed and loaded AppArmor profile: %s\n' "${profile_names[@]}"
echo "No service restart or host reboot is required."
