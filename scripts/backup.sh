#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-${ROOT_DIR}/backups}"
BACKUP_ROOT="$(realpath -m -- "${BACKUP_ROOT}")"
COMPOSE="${COMPOSE:-docker compose}"
RAW_VOLUME_NAME="${RAW_VOLUME_NAME:-chromat_raw_data}"
AGE_RECIPIENT_FILE="${BACKUP_AGE_RECIPIENT_FILE:-}"
EXTERNAL_DIR="${BACKUP_EXTERNAL_DIR:-}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK_DIR="${BACKUP_ROOT}/.tmp-${STAMP}"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"
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
  rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

mkdir -p -- "${WORK_DIR}" "${BACKUP_ROOT}"
if [[ -z "${AGE_RECIPIENT_FILE}" || ! -r "${AGE_RECIPIENT_FILE}" ]]; then
  printf 'BACKUP_AGE_RECIPIENT_FILE must point to a readable age recipient file\n' >&2
  exit 2
fi
if [[ -z "${EXTERNAL_DIR}" ]]; then
  printf 'BACKUP_EXTERNAL_DIR must point to the mounted external backup directory\n' >&2
  exit 2
fi
command -v age >/dev/null || {
  printf 'age is required for encrypted backups\n' >&2
  exit 2
}
EXTERNAL_DIR="$(realpath -m -- "${EXTERNAL_DIR}")"
case "${EXTERNAL_DIR}/" in
  "${BACKUP_ROOT}/"*)
    printf 'BACKUP_EXTERNAL_DIR must not be inside BACKUP_ROOT\n' >&2
    exit 2
    ;;
esac
${COMPOSE} exec -T api node -e \
  'require("node:fs").writeFileSync("/app/uploads/.maintenance", "backup\n")'
MAINTENANCE_ACTIVE=1
${COMPOSE} stop worker >/dev/null
WORKER_STOPPED=1

${COMPOSE} exec -T db sh -c \
  'mariadb-dump --single-transaction --routines --triggers -u root -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE"' \
  >"${WORK_DIR}/database.sql"

docker run --rm --network none \
  -v "${RAW_VOLUME_NAME}:/raw:ro" \
  -v "${WORK_DIR}:/backup" \
  busybox:1.36.1 sh -c '
    set -eu
    cd /raw
    find . -type f ! -name .maintenance -exec sha256sum {} + | sort > /backup/raw-manifest.tsv
    tar -czf /backup/raw.tar.gz --exclude=./.maintenance .
  '

tar -czf "${WORK_DIR}/configuration.tar.gz" \
  -C "${ROOT_DIR}" compose.yaml nginx/conf.d db/migrations
for artifact in database.sql raw.tar.gz raw-manifest.tsv configuration.tar.gz; do
  age -R "${AGE_RECIPIENT_FILE}" \
    -o "${WORK_DIR}/${artifact}.age" "${WORK_DIR}/${artifact}"
  rm -f -- "${WORK_DIR}/${artifact}"
done
(
  cd "${WORK_DIR}"
  sha256sum database.sql.age raw.tar.gz.age raw-manifest.tsv.age configuration.tar.gz.age \
    > checksums.sha256
)

mv -- "${WORK_DIR}" "${BACKUP_DIR}"
${COMPOSE} exec -T api node -e \
  'require("node:fs").rmSync("/app/uploads/.maintenance", { force: true })'
MAINTENANCE_ACTIVE=0
${COMPOSE} start worker >/dev/null
WORKER_STOPPED=0
mkdir -p -- "${EXTERNAL_DIR}"
cp -a -- "${BACKUP_DIR}" "${EXTERNAL_DIR}/"
printf '%s\n' "${BACKUP_DIR}"
