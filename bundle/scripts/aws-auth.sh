#!/usr/bin/env bash
# Shared authentication for the installer and opsrabbitctl. Sourced by the helper.

auth_state="${deploy_dir}/.aws-auth"
auth_dir="${HOME}/.aws/opsrabbit"
auth_method=""
auth_profile=""

auth_reset_environment() {
  local variable
  # Remove ambient credentials, web/container providers, endpoints and profile
  # overrides. Only the explicitly selected provider may supply credentials.
  for variable in ${!AWS_@}; do unset "${variable}"; done
  export AWS_EC2_METADATA_DISABLED=true AWS_PAGER="" AWS_CLI_AUTO_PROMPT=off
  # Botocore also has a legacy provider outside the AWS_* namespace.
  export BOTO_CONFIG=/dev/null
  export AWS_CONFIG_FILE="${HOME}/.aws/config"
  export AWS_SHARED_CREDENTIALS_FILE="${HOME}/.aws/credentials"
}

auth_load() {
  if [[ ! -f "${auth_state}" ]]; then
    echo "AWS authentication has not been selected. Run: opsrabbitctl auth configure" >&2
    return 1
  fi
  { IFS= read -r auth_method; IFS= read -r auth_profile; } < "${auth_state}" || return 1
  case "${auth_method}" in
    browser|profile) [[ "${auth_profile}" =~ ^[a-zA-Z0-9_.@+-]+$ ]] || return 1 ;;
    credentials|instance-role) [[ -z "${auth_profile}" ]] || return 1 ;;
    *) echo "Invalid AWS selection. Run: opsrabbitctl auth configure" >&2; return 1 ;;
  esac
}

auth_prepare() {
  auth_reset_environment
  case "${auth_method}" in
    browser)
      export AWS_PROFILE="${auth_profile}" AWS_CONFIG_FILE="${auth_browser_candidate:-${auth_dir}/config}"
      export AWS_SHARED_CREDENTIALS_FILE=/dev/null
      ;;
    profile) export AWS_PROFILE="${auth_profile}" ;;
    credentials)
      export AWS_CONFIG_FILE=/dev/null
      export AWS_SHARED_CREDENTIALS_FILE="${auth_candidate:-${auth_dir}/credentials}"
      if [[ ! -s "${AWS_SHARED_CREDENTIALS_FILE}" ]]; then
        echo "Deployment credentials are missing. Run: opsrabbitctl auth login" >&2
        return 1
      fi
      ;;
    instance-role)
      export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null
      export AWS_EC2_METADATA_DISABLED=false
      ;;
    *) return 1 ;;
  esac
}

auth_identity() {
  local identity account arn
  if ! identity="$(aws sts get-caller-identity --region "${aws_region}" --query '[Account,Arn]' --output text)"; then
    echo "Selected AWS authentication is unavailable or expired. Run: opsrabbitctl auth login" >&2
    return 1
  fi
  read -r account arn <<< "${identity}"
  if [[ ! "${account}" =~ ^[0-9]{12}$ || "${arn}" != arn:* ]]; then
    echo "AWS returned an invalid identity." >&2
    return 1
  fi
  printf 'Selected AWS identity\n  Account: %s\n  Role/user: %s\n' "${account}" "${arn}"
}

auth_open_terminal() {
  exec {auth_input}<"${OPSRABBIT_INPUT_DEVICE:-/dev/tty}"
}

auth_open_input() {
  if auth_open_terminal 2>/dev/null; then
    return 0
  fi
  echo "Authentication needs an interactive terminal. Run: opsrabbitctl auth login" >&2
  return 1
}

auth_read() {
  local variable="$1" message="$2" secret="${3:-false}" answer
  printf '%s: ' "${message}" >&2
  if [[ "${secret}" == true ]]; then
    IFS= read -r -s answer <&"${auth_input}" || return 1
    echo >&2
  else
    IFS= read -r answer <&"${auth_input}" || return 1
  fi
  printf -v "${variable}" '%s' "${answer}"
}

auth_credentials() {
  local access_key secret_key session_token
  echo "Enter deployment credentials. They are stored only in ${auth_dir}/credentials (mode 0600)."
  auth_read access_key "AWS access key ID" true || return 1
  auth_read secret_key "AWS secret access key" true || return 1
  auth_read session_token "AWS session token (required for temporary credentials; Enter for a long-lived key)" true || return 1
  if [[ -z "${access_key}" || -z "${secret_key}" || ( "${access_key}" == ASIA* && -z "${session_token}" ) ]]; then
    echo "Access key, secret key, and the session token for temporary credentials are required." >&2
    return 1
  fi
  # Reject line/control characters rather than allowing INI setting injection.
  if [[ "${access_key}${secret_key}${session_token}" =~ [[:space:][:cntrl:]] ]]; then
    echo "Credentials must not contain whitespace or control characters." >&2
    return 1
  fi
  mkdir -p "${auth_dir}" || return 1
  chmod 0700 "${auth_dir}" || return 1
  auth_candidate="$(mktemp "${auth_dir}/credentials.XXXXXX")" || return 1
  chmod 0600 "${auth_candidate}" || return 1
  printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\naws_session_token = %s\n' \
    "${access_key}" "${secret_key}" "${session_token}" > "${auth_candidate}" || return 1
}

auth_save() {
  auth_state_candidate="$(mktemp "${deploy_dir}/.aws-auth.XXXXXX")" || return 1
  chmod 0600 "${auth_state_candidate}" || return 1
  printf '%s\n%s\n' "${auth_method}" "${auth_profile}" > "${auth_state_candidate}" || return 1
  if [[ -n "${auth_candidate}" ]]; then
    if ! mv -f -- "${auth_candidate}" "${auth_dir}/credentials"; then
      return 1
    fi
    auth_candidate=""
  fi
  if [[ -n "${auth_browser_candidate}" ]]; then
    mv -f -- "${auth_browser_candidate}" "${auth_dir}/config" || return 1
    auth_browser_candidate=""
  fi
  mv -f -- "${auth_state_candidate}" "${auth_state}" || return 1
  auth_state_candidate=""
  if [[ "${auth_method}" != credentials ]]; then rm -f -- "${auth_dir}/credentials" || return 1; fi
  echo "AWS authentication saved for $(id -un). Renew it with: opsrabbitctl auth login"
}

auth_browser_login() {
  (umask 077; mkdir -p "${auth_dir}") || return 1
  chmod 0700 "${auth_dir}" || return 1
  # AWS CLI writes login_session into this candidate. Keep the previous profile
  # selected until the new identity has demonstrated access to the images.
  auth_browser_candidate="$(mktemp "${auth_dir}/config.XXXXXX")" || return 1
  chmod 0600 "${auth_browser_candidate}" || return 1
  auth_prepare || return 1
  echo "Complete AWS browser login using the URL below; enter the authorization code here."
  aws login --remote --profile "${auth_profile}" --region "${aws_region}" <&"${auth_input}"
}

auth_select() {
  local choice
  echo "Choose AWS authentication:"
  echo "  1. Sign in with AWS CLI (browser)"
  echo "  2. Enter temporary AWS credentials"
  echo "  3. Use this machine's EC2 role (explicit opt-in)"
  echo "  4. Use an existing AWS CLI profile owned by $(id -un)"
  echo "  q. Cancel"
  auth_read choice "Select [1]" || return 2
  auth_profile=""
  case "${choice:-1}" in
    1)
      auth_method=browser
      auth_profile=opsrabbit-deploy
      auth_prepare || return 1
      auth_browser_login || return 1
      ;;
    2) auth_method=credentials; auth_credentials || return 1 ;;
    3) auth_method=instance-role ;;
    4)
      auth_method=profile
      auth_read auth_profile "AWS profile name" || return 2
      if [[ ! "${auth_profile}" =~ ^[a-zA-Z0-9_.@+-]+$ ]]; then
        echo "Enter a valid profile name." >&2
        return 1
      fi
      ;;
    q|Q) return 2 ;;
    *) echo "Select 1, 2, 3, 4, or q." >&2; return 1 ;;
  esac
  auth_prepare && auth_validate && auth_save
}

auth_configure() {
  local result
  auth_open_input || return 1
  while true; do
    if auth_select; then
      exec {auth_input}>&-
      return 0
    else result=$?; fi
    if [[ -n "${auth_candidate}" ]]; then rm -f -- "${auth_candidate}"; auth_candidate=""; fi
    if [[ -n "${auth_browser_candidate}" ]]; then rm -f -- "${auth_browser_candidate}"; auth_browser_candidate=""; fi
    if [[ -n "${auth_state_candidate}" ]]; then rm -f -- "${auth_state_candidate}"; auth_state_candidate=""; fi
    if [[ "${result}" -eq 2 ]]; then
      exec {auth_input}>&-
      echo "Authentication cancelled; previous selection preserved." >&2
      return 1
    fi
    echo "Authentication or image access failed. Choose another method or q to cancel." >&2
  done
}

auth_renew() {
  if ! auth_load; then auth_configure; return; fi
  auth_prepare || { auth_configure; return; }
  auth_open_input || return 1
  case "${auth_method}" in
    browser) auth_browser_login || return 1 ;;
    credentials) auth_credentials || return 1; auth_prepare || return 1 ;;
    profile)
      if [[ -n "$(aws configure get sso_session --profile "${auth_profile}" || true)" \
        || -n "$(aws configure get sso_start_url --profile "${auth_profile}" || true)" ]]; then
        aws sso login --profile "${auth_profile}" --use-device-code --no-browser <&"${auth_input}" || return 1
      else
        echo "Renew profile ${auth_profile} with your AWS credential provider, or run: opsrabbitctl auth configure"
      fi
      ;;
    instance-role) ;;
  esac
  exec {auth_input}>&-
  auth_validate && auth_save
}
