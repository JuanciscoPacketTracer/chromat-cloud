#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_DIR="${1:-}"
if [[ -z "${BACKUP_DIR}" || ! -d "${BACKUP_DIR}" ]]; then
  printf 'Usage: %s <backup-directory>\n' "$0" >&2
  exit 2
fi

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chromat-restore-check.XXXXXX")"
RESTORE_CONTAINER="chromat-restore-check-${RANDOM}-${RANDOM}"
RESTORE_IMAGE="${RESTORE_IMAGE:-mariadb:11.8.2}"
cleanup() {
  docker rm -f "${RESTORE_CONTAINER}" >/dev/null 2>&1 || true
  rm -rf -- "${VERIFY_DIR}"
}
trap cleanup EXIT
(
  cd -- "${BACKUP_DIR}"
  sha256sum --check checksums.sha256
  gzip -t raw.tar.gz
  mkdir -p "${VERIFY_DIR}/raw"
  tar -xzf raw.tar.gz -C "${VERIFY_DIR}/raw"
  (cd "${VERIFY_DIR}/raw" && sha256sum --check "${BACKUP_DIR}/raw-manifest.tsv")
  test -s database.sql
  test -s raw-manifest.tsv
  test -s configuration.tar.gz
)

mkdir -p "${VERIFY_DIR}/configuration"
tar -xzf "${BACKUP_DIR}/configuration.tar.gz" -C "${VERIFY_DIR}/configuration"
docker run -d --network none --name "${RESTORE_CONTAINER}" \
  -e MARIADB_DATABASE=chromat_restore \
  -e MARIADB_ROOT_PASSWORD=restore-verification \
  "${RESTORE_IMAGE}" >/dev/null

for attempt in $(seq 1 60); do
  if docker exec "${RESTORE_CONTAINER}" mariadb-admin \
    -uroot -prestore-verification ping --silent >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" == 60 ]]; then
    printf 'Isolated MariaDB did not become ready\n' >&2
    exit 1
  fi
  sleep 1
done

sed -E 's/^USE .+;$/USE `chromat_restore`;/' \
  "${BACKUP_DIR}/database.sql" >"${VERIFY_DIR}/database.sql"
docker exec -i "${RESTORE_CONTAINER}" mariadb \
  -uroot -prestore-verification chromat_restore <"${VERIFY_DIR}/database.sql"

while IFS= read -r migration; do
  version="${migration%%_*}"
  name="${migration%.sql}"
  expected="${version}_${name#*_}"
  found="$(
    docker exec "${RESTORE_CONTAINER}" mariadb -N -B \
      -uroot -prestore-verification chromat_restore \
      -e "SELECT COUNT(*) FROM schema_migrations WHERE version = '${expected}'"
  )"
  if [[ "${found}" != "1" ]]; then
    printf 'Pending migration in restored database: %s\n' "${expected}" >&2
    exit 1
  fi
done < <(find "${VERIFY_DIR}/configuration/db/migrations" -maxdepth 1 -type f \
  -name '[0-9][0-9][0-9]_*.sql' -printf '%f\n' | sort)

docker exec "${RESTORE_CONTAINER}" mariadb -N -B \
  -uroot -prestore-verification chromat_restore \
  -e "SELECT storage_path, sha256 FROM raw_files WHERE storage_path IS NOT NULL ORDER BY storage_path" \
  >"${VERIFY_DIR}/raw-references.tsv"

while IFS=$'\t' read -r storage_path expected_hash; do
  [[ -n "${storage_path}" ]] || continue
  file="${VERIFY_DIR}/raw/${storage_path}"
  if [[ ! -f "${file}" ]]; then
    printf 'Missing raw file: %s\n' "${storage_path}" >&2
    exit 1
  fi
  actual_hash="$(sha256sum "${file}" | awk '{print $1}')"
  if [[ "${actual_hash}" != "${expected_hash}" ]]; then
    printf 'Raw hash mismatch: %s\n' "${storage_path}" >&2
    exit 1
  fi
done <"${VERIFY_DIR}/raw-references.tsv"

(cd "${VERIFY_DIR}/raw" && find . -type f -printf '%P\n' | sort) \
  >"${VERIFY_DIR}/actual-raw-files.txt"
cut -f1 "${VERIFY_DIR}/raw-references.tsv" | sort \
  >"${VERIFY_DIR}/referenced-raw-files.txt"
if ! cmp -s "${VERIFY_DIR}/actual-raw-files.txt" "${VERIFY_DIR}/referenced-raw-files.txt"; then
  printf 'Unreferenced raw files detected\n' >&2
  diff -u "${VERIFY_DIR}/referenced-raw-files.txt" \
    "${VERIFY_DIR}/actual-raw-files.txt" || true
  exit 1
fi

printf 'Backup verified: %s\n' "${BACKUP_DIR}"
