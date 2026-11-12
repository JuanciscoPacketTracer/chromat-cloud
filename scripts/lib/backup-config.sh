#!/usr/bin/env bash

load_backup_config() {
  local config_file="$1"
  local line key value mode
  local -A seen=()

  [[ -f "${config_file}" && -r "${config_file}" ]] || {
    printf 'Production environment file is unreadable: %s\n' "${config_file}" >&2
    return 2
  }
  mode="$(stat -c '%a' -- "${config_file}")"
  (( ((8#${mode}) & 0022) == 0 )) || {
    printf 'Production environment file must not be group or world writable: %s\n' \
      "${config_file}" >&2
    return 2
  }

  BACKUP_ROOT=
  BACKUP_EXTERNAL_DIR=
  BACKUP_AGE_RECIPIENT_FILE=
  BACKUP_SECRET_FILES=
  BACKUP_MAX_SECONDS=
  BACKUP_MODE=
  BACKUP_STATE_DIR=
  CHROMAT_DB_IMAGE=
  DB_PASSWORD_HOST_FILE=
  DB_ROOT_PASSWORD_HOST_FILE=
  TELEGRAM_BOT_TOKEN_HOST_FILE=

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" == *=* ]] || {
      printf 'Invalid production environment line in %s\n' "${config_file}" >&2
      return 2
    }
    key="${line%%=*}"
    value="${line#*=}"
    case "${key}" in
      BACKUP_ROOT|BACKUP_EXTERNAL_DIR|BACKUP_AGE_RECIPIENT_FILE|\
      BACKUP_SECRET_FILES|BACKUP_MAX_SECONDS|BACKUP_MODE|BACKUP_STATE_DIR|\
      CHROMAT_DB_IMAGE|DB_PASSWORD_HOST_FILE|DB_ROOT_PASSWORD_HOST_FILE|\
      TELEGRAM_BOT_TOKEN_HOST_FILE)
        [[ -z "${seen[${key}]+x}" ]] || {
          printf 'Duplicate production environment key: %s\n' "${key}" >&2
          return 2
        }
        seen["${key}"]=1
        printf -v "${key}" '%s' "${value}"
        ;;
    esac
  done <"${config_file}"
}

require_backup_variable() {
  local name="$1"
  [[ -n "${!name:-}" ]] || {
    printf '%s is required in the production environment file\n' "${name}" >&2
    return 2
  }
}

require_secure_file() {
  local label="$1"
  local path="$2"
  local mode

  [[ -f "${path}" && -r "${path}" ]] || {
    printf '%s must point to a readable regular file\n' "${label}" >&2
    return 2
  }
  mode="$(stat -c '%a' -- "${path}")"
  (( ((8#${mode}) & 0022) == 0 )) || {
    printf '%s must not be group or world writable: %s\n' "${label}" "${path}" >&2
    return 2
  }
}

require_private_file() {
  local label="$1"
  local path="$2"
  local mode

  require_secure_file "${label}" "${path}"
  mode="$(stat -c '%a' -- "${path}")"
  (( ((8#${mode}) & 0077) == 0 )) || {
    printf '%s must not be readable by group or other users: %s\n' \
      "${label}" "${path}" >&2
    return 2
  }
}

require_secure_directory() {
  local label="$1"
  local path="$2"
  local mode

  [[ -d "${path}" && -w "${path}" ]] || {
    printf '%s must be an existing writable directory\n' "${label}" >&2
    return 2
  }
  mode="$(stat -c '%a' -- "${path}")"
  (( ((8#${mode}) & 0022) == 0 )) || {
    printf '%s must not be group or world writable: %s\n' \
      "${label}" "${path}" >&2
    return 2
  }
}
