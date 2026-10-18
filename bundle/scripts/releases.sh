#!/usr/bin/env bash
# Sourced by opsrabbitctl. JSON is data, never shell input.
release_catalog_url="https://opsrabbit-releases-921870554228-us-east-1.s3.us-east-1.amazonaws.com/releases"
release_dir="${deploy_dir}/.release"
release_candidate=""

release_validate() {
  jq -e --arg registry "${ecr_registry}" '
    def pin($repo): type == "string" and startswith($registry + "/" + $repo + ":") and (ltrimstr($registry + "/" + $repo + ":") | test("^v?(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"));
    .schema_version == 1 and .protocol == 1 and .platform == "linux/amd64"
    and (.version | type == "string" and test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))
    and (.revision | type == "string" and test("^[a-f0-9]{40}$"))
    and (.images.backend | pin("vg-backend")) and (.images.frontend | pin("vg-webapp"))
    and (.images.sandbox | pin("vg-sandbox"))
    and (.images.collector == null or (.images.collector | pin("vg-otel-anomaly-collector")))
    and (.images.backend | endswith(":" + $version))
  ' --arg version "$(jq -r .version "$1")" "$1" >/dev/null || return 1
  [[ "$(jq -r .images.frontend "$1")" == *":$(jq -r .version "$1")" ]]
}

release_discover() {
  local requested="${1:-}" response versions version
  if [[ -n "${requested}" && ! "${requested}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "Expected --version vMAJOR.MINOR.PATCH." >&2; return 1
  fi
  response="$(curl --fail --silent --show-error --location --max-time 30 --proto '=https' \
    "${release_catalog_url}/catalog.json")" || return 1
  versions="$(jq -ec '
    if .schema_version == 1 and (.versions | type == "array")
      and all(.versions[]; type == "string" and test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")
        and (ltrimstr("v") | split(".") | map(tonumber) | all(.[]; . <= 9007199254740991)))
      and ((.versions | unique | length) == (.versions | length))
    then .versions else error("Invalid release catalog") end
  ' <<<"${response}")" || return 1
  if [[ -z "${requested}" ]]; then
    requested="$(jq -er 'sort_by(ltrimstr("v") | split(".") | map(tonumber)) | last // error("No complete stable product releases")' <<<"${versions}")" || return 1
  fi
  jq -en --argjson versions "${versions}" --arg version "${requested}" '$versions | index($version) != null' >/dev/null \
    || { echo "Requested version is not a published stable product release." >&2; return 1; }
  release_candidate="$(mktemp "${release_dir}/candidate.XXXXXX")" || return 1
  curl --fail --silent --show-error --location --max-time 30 --proto '=https' \
    "${release_catalog_url}/${requested}/release.json" -o "${release_candidate}" || return 1
  release_validate "${release_candidate}" || { echo "Invalid or unsupported product release manifest." >&2; return 1; }
  [[ "$(jq -r .version "${release_candidate}")" == "${requested}" ]] || return 1
  version="$(jq -r .version "${release_dir}/current.json" 2>/dev/null || true)"
  if [[ -n "${version}" ]]; then
    jq -en --arg current "${version}" --arg target "${requested}" \
      '($target | ltrimstr("v") | split(".") | map(tonumber)) >= ($current | ltrimstr("v") | split(".") | map(tonumber))' >/dev/null \
      || { echo "Downgrade requires a separate database-compatible recovery procedure." >&2; return 1; }
  fi
  echo "Selected OpsRabbit ${requested}."
}

release_verify() {
  local manifest="$1" service image container actual
  for service in daemon web; do
    if [[ "${service}" == daemon ]]; then image="$(jq -r .images.backend "${manifest}")"; else image="$(jq -r .images.frontend "${manifest}")"; fi
    container="$("${compose[@]}" ps -q "${service}")"
    [[ -n "${container}" ]] || return 1
    actual="$(docker inspect --format '{{.Image}}' "${container}")"
    [[ "${actual}" == "$(docker image inspect --format '{{.Id}}' "${image}")" ]] || return 1
  done
}

release_update_env() {
  local manifest="$1" temporary_env current_sandbox previous_sandbox managed_sandbox=false
  temporary_env="$(mktemp "${deploy_dir}/.env.XXXXXX")"
  current_sandbox="$(sed -n 's/^OPSRABBIT_SANDBOX_IMAGE=//p' "${env_file}" | tail -n 1)"
  previous_sandbox="$(jq -r '.images.sandbox // empty' "${release_dir}/current.json" 2>/dev/null || true)"
  case "${current_sandbox}" in
    opsrabbit-release:unconfigured|opsrabbit-sandbox:latest|"${ecr_registry}/vg-sandbox:latest"|"") managed_sandbox=true ;;
    *) if [[ -n "${previous_sandbox}" && "${current_sandbox}" == "${previous_sandbox}" ]]; then managed_sandbox=true; fi ;;
  esac
  # Preserve custom sandbox choices, unrelated settings and secrets verbatim.
  awk -v managed="${managed_sandbox}" '!/^(OPSRABBIT_DAEMON_IMAGE|OPSRABBIT_WEB_IMAGE)=/ && !(managed == "true" && /^OPSRABBIT_SANDBOX_IMAGE=/)' "${env_file}" > "${temporary_env}"
  jq -r '"OPSRABBIT_DAEMON_IMAGE=" + .images.backend, "OPSRABBIT_WEB_IMAGE=" + .images.frontend' "${manifest}" >> "${temporary_env}"
  if [[ "${managed_sandbox}" == true ]]; then jq -r '"OPSRABBIT_SANDBOX_IMAGE=" + .images.sandbox' "${manifest}" >> "${temporary_env}"; fi
  chmod 0600 "${temporary_env}"
  mv -- "${temporary_env}" "${env_file}"
}

release_deploy() {
  local requested="" adopt=false backup=false skip_backup=false ecr_password_stdin=false option override worker_running=false worker_defined=false pending_file worker_id image
  while [[ "$#" -gt 0 ]]; do
    option="$1"; shift
    case "${option}" in
      --version) [[ "$#" -gt 0 ]] || return 1; requested="$1"; shift ;;
      --adopt) adopt=true ;;
      --backup-confirmed) backup=true ;;
      --skip-backup) skip_backup=true ;;
      --ecr-password-stdin) ecr_password_stdin=true ;;
      *) echo "Unknown release option: ${option}" >&2; return 1 ;;
    esac
  done
  command -v jq >/dev/null || { echo "Install jq before upgrading." >&2; return 1; }
  if [[ ! -f "${release_dir}/current.json" && "${adopt}" != true ]]; then
    echo "Legacy deployment: use migrate.sh, or deploy --adopt --backup-confirmed after reviewing the upgrade requirements." >&2; return 1
  fi
  if [[ "${backup}" == true && "${skip_backup}" == true ]]; then
    echo "Choose either --backup-confirmed or --skip-backup." >&2; return 1
  fi
  [[ "${backup}" == true || "${skip_backup}" == true ]] || { echo "Back up PostgreSQL and configuration, then pass --backup-confirmed, or explicitly choose --skip-backup." >&2; return 1; }
  if [[ "${ecr_password_stdin}" == true ]]; then
    ecr_login --ecr-password-stdin || return 1
  else
    auth_load && auth_prepare && auth_identity && ecr_login || return 1
  fi
  release_discover "${requested}" || return 1
  if [[ -f "${release_dir}/pending.json" && "$(jq -r .version "${release_dir}/pending.json")" != "$(jq -r .version "${release_candidate}")" ]]; then
    echo "An interrupted release is pending. Resume that exact version before selecting another release." >&2; return 1
  fi
  while IFS= read -r image; do docker pull --platform linux/amd64 "${image}" || return 1; done < <(jq -r '.images | .backend,.frontend,.sandbox' "${release_candidate}")
  # A custom workload is preserved rather than replaced by the release default.
  if [[ "${sandbox_image}" != "$(jq -r .images.sandbox "${release_candidate}")" && "${sandbox_image}" != "$(jq -r '.images.sandbox // empty' "${release_dir}/current.json" 2>/dev/null || true)" ]]; then
    case "${sandbox_image}" in
      opsrabbit-release:unconfigured|opsrabbit-sandbox:latest|"${ecr_registry}/vg-sandbox:latest") ;;
      *) docker pull --platform linux/amd64 "${sandbox_image}" || return 1 ;;
    esac
  fi
  if [[ -f "${release_dir}/pending.json" ]]; then worker_running="$(jq -r '._deployment.worker_was_running // false' "${release_dir}/pending.json")"; fi
  if docker compose --env-file "${env_file}" -f "${compose_file}" --profile '*' config --services | grep -Fxq worker; then
    worker_defined=true
    worker_id="$(docker compose --env-file "${env_file}" -f "${compose_file}" --profile '*' ps -q worker)"
    if [[ -n "${worker_id}" && "$(docker inspect --format '{{.State.Running}}' "${worker_id}")" == true ]]; then worker_running=true; fi
  fi
  for image in "$(jq -r .images.backend "${release_candidate}")" "$(jq -r .images.frontend "${release_candidate}")"; do
    [[ "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${image}")" == "$(jq -r .version "${release_candidate}")" ]] || return 1
    [[ "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${image}")" == "$(jq -r .revision "${release_candidate}")" ]] || return 1
  done
  override="${release_candidate}.compose.json"
  jq --argjson worker "${worker_defined}" \
    '{services: ({daemon: {image: .images.backend}, web: {image: .images.frontend}} + (if $worker then {worker: {image: .images.backend}} else {} end))}' \
    "${release_candidate}" > "${override}"
  compose+=( -f "${override}" )
  "${compose[@]}" config --quiet || return 1
  # Pull non-product dependencies too, before stopping any service.
  "${compose[@]}" pull || return 1
  pending_file="$(mktemp "${release_dir}/pending.XXXXXX")"
  jq --argjson worker "${worker_running}" '._deployment={worker_was_running:$worker}' "${release_candidate}" > "${pending_file}"
  chmod 0600 "${pending_file}"
  mv -- "${pending_file}" "${release_dir}/pending.json"
  release_started=true
  "${compose[@]}" stop web
  if [[ "${worker_running}" == true ]]; then docker compose --env-file "${env_file}" -f "${compose_file}" --profile '*' stop worker; fi
  "${compose[@]}" stop daemon
  release_update_env "${release_candidate}"
  sandbox_image="$(read_env OPSRABBIT_SANDBOX_IMAGE)"
  "${compose[@]}" up -d --no-build opensandbox-server
  connect_opensandbox_runtime_bridge
  "${compose[@]}" up -d --no-build --wait daemon
  if [[ "${worker_running}" == true ]]; then
    # Worker uses exactly the daemon image; stopped optional workers remain stopped.
    docker compose --env-file "${env_file}" -f "${compose_file}" -f "${override}" --profile '*' up -d --no-build --wait worker
  fi
  "${compose[@]}" up -d --no-build --wait web
  if ! release_verify "${release_candidate}"; then
    "${compose[@]}" stop web
    echo "Release verification failed; web is stopped. Resume the pending version after investigating." >&2; return 1
  fi
  # Atomic rename keeps a partially written override from blocking recovery.
  # Keep the candidate available to cleanup through the commit. In particular,
  # a signal after the installed override rename must still be able to stop web.
  cp -- "${override}" "${override}.current"
  mv -- "${override}.current" "${release_dir}/current.compose.json"
  mv -- "${release_candidate}" "${release_dir}/current.json"
  release_candidate=""
  release_started=false
  rm -f -- "${release_dir}/pending.json" "${override}"
  echo "Installed $(jq -r .version "${release_dir}/current.json")."
}
