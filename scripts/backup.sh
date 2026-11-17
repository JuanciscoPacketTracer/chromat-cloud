#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/lib/backup-config.sh"

CONFIG_FILE=
MODE_OVERRIDE=
while (($#)); do
  case "$1" in
    --config)
      CONFIG_FILE="${2:-}"
      shift 2
      ;;
    --mode)
      MODE_OVERRIDE="${2:-}"
      shift 2
      ;;
    *)
      printf 'Usage: %s --config <production-env-file> [--mode full|incremental]\n' "$0" >&2
      exit 2
      ;;
  esac
done
[[ -n "${CONFIG_FILE}" ]] || {
  printf 'Usage: %s --config <production-env-file> [--mode full|incremental]\n' "$0" >&2
  exit 2
}
CONFIG_FILE="$(realpath -e -- "${CONFIG_FILE}")"
load_backup_config "${CONFIG_FILE}"
for required in \
  BACKUP_ROOT BACKUP_EXTERNAL_DIR BACKUP_AGE_RECIPIENT_FILE \
  BACKUP_SECRET_FILES BACKUP_MAX_SECONDS BACKUP_MODE BACKUP_STATE_DIR \
  DB_PASSWORD_HOST_FILE DB_ROOT_PASSWORD_HOST_FILE \
  TELEGRAM_BOT_TOKEN_HOST_FILE; do
  require_backup_variable "${required}"
done

BACKUP_ROOT="$(realpath -e -- "${BACKUP_ROOT}")"
EXTERNAL_DIR="$(realpath -e -- "${BACKUP_EXTERNAL_DIR}")"
STATE_DIR="$(realpath -e -- "${BACKUP_STATE_DIR}")"
AGE_RECIPIENT_FILE="${BACKUP_AGE_RECIPIENT_FILE}"
SECRET_FILES="${BACKUP_SECRET_FILES}"
MAX_SECONDS="${BACKUP_MAX_SECONDS}"
BACKUP_MODE="${MODE_OVERRIDE:-${BACKUP_MODE}}"
RAW_VOLUME_NAME="chromat_raw_data"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK_DIR="${BACKUP_ROOT}/.tmp-${STAMP}"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"
PENDING_STATE="${STATE_DIR}/.raw-manifest-${STAMP}.pending"
MAINTENANCE_ACTIVE=0
WORKER_STOPPED=0

docker_compose() {
  sudo -- docker compose --project-directory "${ROOT_DIR}" -f "${ROOT_DIR}/compose.yaml" \
    --env-file "${CONFIG_FILE}" "$@"
}

cleanup() {
  if (( MAINTENANCE_ACTIVE )); then
    docker_compose exec -T api node -e \
      'require("node:fs").rmSync("/app/uploads/.maintenance", { force: true })' \
      >/dev/null || true
  fi
  if (( WORKER_STOPPED )); then
    docker_compose start worker >/dev/null || true
  fi
  rm -f -- "${PENDING_STATE}"
  rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

require_secure_directory BACKUP_ROOT "${BACKUP_ROOT}"
require_secure_directory BACKUP_STATE_DIR "${STATE_DIR}"
require_secure_file BACKUP_AGE_RECIPIENT_FILE "${AGE_RECIPIENT_FILE}"
require_secure_directory BACKUP_EXTERNAL_DIR "${EXTERNAL_DIR}"
if ! [[ "${MAX_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'BACKUP_MAX_SECONDS must be a positive integer\n' >&2
  exit 2
fi
if [[ "${BACKUP_MODE}" != "full" && "${BACKUP_MODE}" != "incremental" ]]; then
  printf 'BACKUP_MODE must be full or incremental\n' >&2
  exit 2
fi
command -v age >/dev/null || {
  printf 'age is required for encrypted backups\n' >&2
  exit 2
}
require_independent_external_mount "${EXTERNAL_DIR}"
case "${EXTERNAL_DIR}/" in
  "${BACKUP_ROOT}/"*)
    printf 'BACKUP_EXTERNAL_DIR must not be inside BACKUP_ROOT\n' >&2
    exit 2
    ;;
esac
MANIFEST_FILE="${ROOT_DIR}/manifest.json"
[[ -r "${MANIFEST_FILE}" ]] || {
  printf 'Release manifest is unreadable: %s\n' "${MANIFEST_FILE}" >&2
  exit 2
}
auxiliary_image_data="$(
  python3 - "${MANIFEST_FILE}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    manifest = json.load(stream)
auxiliary_images = manifest.get("auxiliary_images")
if not isinstance(auxiliary_images, list) or len(auxiliary_images) != 1:
    raise SystemExit("release manifest must list exactly one auxiliary image")
image = auxiliary_images[0]
if not isinstance(image, dict):
    raise SystemExit("release manifest auxiliary image entry must be an object")
if image.get("name") != "busybox:1.36.1":
    raise SystemExit("release manifest auxiliary image must be busybox:1.36.1")
if image.get("archive") != "images/busybox.tar":
    raise SystemExit("release manifest auxiliary image archive is invalid")
image_id = image.get("id")
if not isinstance(image_id, str) or not image_id:
    raise SystemExit("release manifest auxiliary image is missing an ID")
if image.get("architecture") != "amd64":
    raise SystemExit("release manifest auxiliary image architecture must be amd64")
print(f"{image['name']}\t{image_id}\t{image['architecture']}")
PY
)" || {
  printf 'Release manifest auxiliary image validation failed\n' >&2
  exit 2
}
IFS=$'\t' read -r AUXILIARY_IMAGE_NAME AUXILIARY_IMAGE_ID AUXILIARY_IMAGE_ARCHITECTURE \
  <<<"${auxiliary_image_data}"
loaded_auxiliary_image_data="$(
  sudo -- docker image inspect \
    --format '{{.Id}} {{.Architecture}}' "${AUXILIARY_IMAGE_NAME}"
)" || {
  printf 'Required auxiliary image is not loaded locally: %s\n' \
    "${AUXILIARY_IMAGE_NAME}" >&2
  exit 2
}
read -r loaded_auxiliary_image_id loaded_auxiliary_image_architecture \
  <<<"${loaded_auxiliary_image_data}"
if [[ "${loaded_auxiliary_image_id}" != "${AUXILIARY_IMAGE_ID}" ||
  "${loaded_auxiliary_image_architecture}" != "${AUXILIARY_IMAGE_ARCHITECTURE}" ]]; then
  printf 'Loaded auxiliary image does not match the release manifest: %s\n' \
    "${AUXILIARY_IMAGE_NAME}" >&2
  exit 2
fi
read -r -a secret_files <<<"${SECRET_FILES}"
required_service_secrets=(
  "${DB_PASSWORD_HOST_FILE}"
  "${DB_ROOT_PASSWORD_HOST_FILE}"
  "${TELEGRAM_BOT_TOKEN_HOST_FILE}"
)
declare -A required_service_secret_paths=()
for required_secret in "${required_service_secrets[@]}"; do
  require_private_file configured-service-secret "${required_secret}"
  required_service_secret_paths["$(realpath -e -- "${required_secret}")"]=1
done
mkdir -p -- "${WORK_DIR}/secrets"
declare -A secret_names=()
declare -A configured_secret_paths=()
for secret_file in "${secret_files[@]}"; do
  secret_file="$(realpath -e -- "${secret_file}")"
  require_private_file BACKUP_SECRET_FILES "${secret_file}"
  secret_name="$(basename -- "${secret_file}")"
  [[ "${secret_name}" != "ca.key" && "${secret_name}" != "ca-root.key" ]] || {
    printf 'The CA private key must remain outside the server backup\n' >&2
    exit 2
  }
  [[ -z "${secret_names[${secret_name}]+x}" ]] || {
    printf 'Duplicate backup secret basename: %s\n' "${secret_name}" >&2
    exit 2
  }
  [[ -z "${configured_secret_paths[${secret_file}]+x}" ]] || {
    printf 'Duplicate backup secret path: %s\n' "${secret_file}" >&2
    exit 2
  }
  secret_names["${secret_name}"]=1
  configured_secret_paths["${secret_file}"]=1
  cp -- "${secret_file}" "${WORK_DIR}/secrets/${secret_name}"
done
for required_secret in "${!required_service_secret_paths[@]}"; do
  [[ -n "${configured_secret_paths[${required_secret}]+x}" ]] || {
    printf 'BACKUP_SECRET_FILES must include configured service secret: %s\n' \
      "${required_secret}" >&2
    exit 2
  }
done
start_time="$(date +%s)"
check_deadline() {
  if (( $(date +%s) - start_time >= MAX_SECONDS )); then
    printf 'Backup exceeded BACKUP_MAX_SECONDS=%s\n' "${MAX_SECONDS}" >&2
    return 1
  fi
}
docker_compose exec -T api node -e \
  'require("node:fs").writeFileSync("/app/uploads/.maintenance", "backup\n")'
MAINTENANCE_ACTIVE=1
docker_compose stop worker >/dev/null
WORKER_STOPPED=1

docker_compose exec -T db sh -ceu "$(cat <<'EOF'
  defaults_file="$(mktemp /tmp/chromat-mariadb.XXXXXX)"
  cleanup_defaults() {
    rm -f -- "$defaults_file"
  }
  trap cleanup_defaults EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  password="$(cat /run/secrets/db_root_password)"
  case "$password" in
    *"
"*)
      printf "MariaDB passwords containing newlines are not supported\n" >&2
      exit 2
      ;;
  esac
  escaped_password="$(printf "%s" "$password" | sed "s/[\"\\\\]/\\\\&/g")"
  printf "[client]\npassword=\"%s\"\n" "$escaped_password" >"$defaults_file"
  chmod 0600 "$defaults_file"
  unset MYSQL_PWD
  mariadb-dump --defaults-extra-file="$defaults_file" --single-transaction --routines --triggers -u root "$MARIADB_DATABASE"
EOF
)" \
  >"${WORK_DIR}/database.sql"
check_deadline

sudo -- docker run --rm --network none \
  -v "${RAW_VOLUME_NAME}:/raw:ro" \
  -v "${WORK_DIR}:/backup" \
  busybox:1.36.1 sh -c '
    set -eu
    cd /raw
    find . -type f ! -name .maintenance -exec sha256sum {} + | sort > /backup/current-raw-manifest.tsv
  '
check_deadline

state_manifest="${STATE_DIR}/raw-manifest.tsv"
base_backup=""
if [[ "${BACKUP_MODE}" == "incremental" ]]; then
  [[ -s "${state_manifest}" ]] || {
    printf 'An earlier full backup is required before an incremental backup\n' >&2
    exit 2
  }
  base_backup="$(cat "${STATE_DIR}/last-full")"
  [[ -n "${base_backup}" ]] || {
    printf 'State does not identify a full backup base\n' >&2
    exit 2
  }
  [[ -d "${base_backup}" ]] || {
    printf 'Incremental backup base is missing: %s\n' "${base_backup}" >&2
    exit 2
  }
  awk 'NR == FNR { previous[$2] = $1; next }
       { if (!( $2 in previous) || previous[$2] != $1) print $2 }' \
    "${state_manifest}" "${WORK_DIR}/current-raw-manifest.tsv" \
    >"${WORK_DIR}/raw-selection.txt"
  awk 'NR == FNR { current[$2] = 1; next }
       { if (!($2 in current)) print $2 }' \
    "${WORK_DIR}/current-raw-manifest.tsv" "${state_manifest}" \
    >"${WORK_DIR}/raw-deletions.tsv"
else
  cut -d' ' -f3- "${WORK_DIR}/current-raw-manifest.tsv" \
    >"${WORK_DIR}/raw-selection.txt"
  : >"${WORK_DIR}/raw-deletions.tsv"
fi
cp -- "${WORK_DIR}/current-raw-manifest.tsv" "${WORK_DIR}/raw-manifest.tsv"
sudo -- docker run --rm --network none \
  -v "${RAW_VOLUME_NAME}:/raw:ro" \
  -v "${WORK_DIR}:/backup" \
  busybox:1.36.1 sh -c '
    set -eu
    cd /raw
    tar -czf /backup/raw.tar.gz -T /backup/raw-selection.txt
  '
printf '{"mode":"%s","base_backup":"%s"}\n' \
  "${BACKUP_MODE}" "${base_backup}" >"${WORK_DIR}/backup-metadata.json"
check_deadline

tar -czf "${WORK_DIR}/configuration.tar.gz" \
  -C "${ROOT_DIR}" compose.yaml nginx/conf.d db/migrations
tar -czf "${WORK_DIR}/secrets.tar.gz" -C "${WORK_DIR}" secrets
for artifact in database.sql raw.tar.gz raw-manifest.tsv configuration.tar.gz; do
  age -R "${AGE_RECIPIENT_FILE}" \
    -o "${WORK_DIR}/${artifact}.age" "${WORK_DIR}/${artifact}"
  rm -f -- "${WORK_DIR}/${artifact}"
done
age -R "${AGE_RECIPIENT_FILE}" \
  -o "${WORK_DIR}/raw-deletions.tsv.age" "${WORK_DIR}/raw-deletions.tsv"
age -R "${AGE_RECIPIENT_FILE}" \
  -o "${WORK_DIR}/backup-metadata.json.age" "${WORK_DIR}/backup-metadata.json"
rm -f -- "${WORK_DIR}/raw-deletions.tsv" "${WORK_DIR}/backup-metadata.json"
age -R "${AGE_RECIPIENT_FILE}" \
  -o "${WORK_DIR}/secrets.tar.gz.age" "${WORK_DIR}/secrets.tar.gz"
rm -rf -- "${WORK_DIR}/secrets" "${WORK_DIR}/secrets.tar.gz"
check_deadline
(
  cd "${WORK_DIR}"
  sha256sum database.sql.age raw.tar.gz.age raw-manifest.tsv.age \
    configuration.tar.gz.age secrets.tar.gz.age raw-deletions.tsv.age \
    backup-metadata.json.age \
    > checksums.sha256
)
cp -- "${WORK_DIR}/current-raw-manifest.tsv" "${PENDING_STATE}"
rm -f -- "${WORK_DIR}/current-raw-manifest.tsv" "${WORK_DIR}/raw-selection.txt"

mv -- "${WORK_DIR}" "${BACKUP_DIR}"
docker_compose exec -T api node -e \
  'require("node:fs").rmSync("/app/uploads/.maintenance", { force: true })'
cp -a -- "${BACKUP_DIR}" "${EXTERNAL_DIR}/"
check_deadline
printf '%s\n' "${BACKUP_DIR}" >"${BACKUP_ROOT}/last-successful"
cp -- "${BACKUP_ROOT}/last-successful" "${EXTERNAL_DIR}/"
if [[ "${BACKUP_MODE}" == "full" ]]; then
  mv -- "${PENDING_STATE}" "${STATE_DIR}/raw-manifest.tsv"
  printf '%s\n' "${BACKUP_DIR}" >"${STATE_DIR}/last-full"
else
  rm -f -- "${PENDING_STATE}"
fi
MAINTENANCE_ACTIVE=0
docker_compose start worker >/dev/null
WORKER_STOPPED=0
printf '%s\n' "${BACKUP_DIR}"
