#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-${ROOT_DIR}/backups}"
BACKUP_ROOT="$(realpath -m -- "${BACKUP_ROOT}")"
COMPOSE="${COMPOSE:-docker compose}"
RAW_VOLUME_NAME="${RAW_VOLUME_NAME:-chromat_raw_data}"
AGE_RECIPIENT_FILE="${BACKUP_AGE_RECIPIENT_FILE:-}"
EXTERNAL_DIR="${BACKUP_EXTERNAL_DIR:-}"
SECRET_FILES="${BACKUP_SECRET_FILES:-}"
MAX_SECONDS="${BACKUP_MAX_SECONDS:-3600}"
BACKUP_MODE="${BACKUP_MODE:-full}"
STATE_DIR="${BACKUP_STATE_DIR:-${BACKUP_ROOT}/.state}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK_DIR="${BACKUP_ROOT}/.tmp-${STAMP}"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"
PENDING_STATE="${STATE_DIR}/.raw-manifest-${STAMP}.pending"
MAINTENANCE_ACTIVE=0
WORKER_STOPPED=0

cleanup() {
  if (( MAINTENANCE_ACTIVE )); then
    ${COMPOSE} exec -T api node -e \
      'require("node:fs").rmSync("/app/uploads/.maintenance", { force: true })' \
      >/dev/null || true
  fi
  if (( WORKER_STOPPED )); then
    ${COMPOSE} start worker >/dev/null || true
  fi
  rm -f -- "${PENDING_STATE}"
  rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

mkdir -p -- "${WORK_DIR}" "${BACKUP_ROOT}" "${STATE_DIR}"
if [[ -z "${AGE_RECIPIENT_FILE}" || ! -r "${AGE_RECIPIENT_FILE}" ]]; then
  printf 'BACKUP_AGE_RECIPIENT_FILE must point to a readable age recipient file\n' >&2
  exit 2
fi
if [[ -z "${EXTERNAL_DIR}" ]]; then
  printf 'BACKUP_EXTERNAL_DIR must point to the mounted external backup directory\n' >&2
  exit 2
fi
if [[ -z "${SECRET_FILES}" ]]; then
  printf 'BACKUP_SECRET_FILES must list service secret files to protect\n' >&2
  exit 2
fi
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
EXTERNAL_DIR="$(realpath -m -- "${EXTERNAL_DIR}")"
command -v findmnt >/dev/null || {
  printf 'findmnt is required to validate the external backup mount\n' >&2
  exit 2
}
mount_target="$(findmnt -T "${EXTERNAL_DIR}" -n -o TARGET || true)"
if [[ -z "${mount_target}" || "${mount_target}" == "/" ]]; then
  printf 'BACKUP_EXTERNAL_DIR must be on a non-root mounted filesystem\n' >&2
  exit 2
fi
case "${EXTERNAL_DIR}/" in
  "${BACKUP_ROOT}/"*)
    printf 'BACKUP_EXTERNAL_DIR must not be inside BACKUP_ROOT\n' >&2
    exit 2
    ;;
esac
read -r -a secret_files <<<"${SECRET_FILES}"
mkdir -p -- "${WORK_DIR}/secrets"
declare -A secret_names=()
for secret_file in "${secret_files[@]}"; do
  [[ -r "${secret_file}" ]] || {
    printf 'Configured backup secret is not readable: %s\n' "${secret_file}" >&2
    exit 2
  }
  secret_name="$(basename -- "${secret_file}")"
  [[ "${secret_name}" != "ca.key" && "${secret_name}" != "ca-root.key" ]] || {
    printf 'The CA private key must remain outside the server backup\n' >&2
    exit 2
  }
  [[ -z "${secret_names[${secret_name}]+x}" ]] || {
    printf 'Duplicate backup secret basename: %s\n' "${secret_name}" >&2
    exit 2
  }
  secret_names["${secret_name}"]=1
  cp -- "${secret_file}" "${WORK_DIR}/secrets/${secret_name}"
done
start_time="$(date +%s)"
check_deadline() {
  if (( $(date +%s) - start_time >= MAX_SECONDS )); then
    printf 'Backup exceeded BACKUP_MAX_SECONDS=%s\n' "${MAX_SECONDS}" >&2
    return 1
  fi
}
${COMPOSE} exec -T api node -e \
  'require("node:fs").writeFileSync("/app/uploads/.maintenance", "backup\n")'
MAINTENANCE_ACTIVE=1
${COMPOSE} stop worker >/dev/null
WORKER_STOPPED=1

${COMPOSE} exec -T db sh -c \
  'mariadb-dump --single-transaction --routines --triggers -u root -p"$(cat /run/secrets/db_root_password)" "$MARIADB_DATABASE"' \
  >"${WORK_DIR}/database.sql"
check_deadline

docker run --rm --network none \
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
docker run --rm --network none \
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
${COMPOSE} exec -T api node -e \
  'require("node:fs").rmSync("/app/uploads/.maintenance", { force: true })'
mkdir -p -- "${EXTERNAL_DIR}"
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
${COMPOSE} start worker >/dev/null
WORKER_STOPPED=0
printf '%s\n' "${BACKUP_DIR}"
