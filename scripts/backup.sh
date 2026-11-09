#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-${ROOT_DIR}/backups}"
COMPOSE="${COMPOSE:-docker compose}"
RAW_VOLUME_NAME="${RAW_VOLUME_NAME:-chromat_raw_data}"
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
(
  cd "${WORK_DIR}"
  sha256sum database.sql raw.tar.gz raw-manifest.tsv configuration.tar.gz > checksums.sha256
)

mv -- "${WORK_DIR}" "${BACKUP_DIR}"
${COMPOSE} exec -T api node -e \
  'require("node:fs").rmSync("/app/uploads/.maintenance", { force: true })'
MAINTENANCE_ACTIVE=0
${COMPOSE} start worker >/dev/null
WORKER_STOPPED=0
printf '%s\n' "${BACKUP_DIR}"
