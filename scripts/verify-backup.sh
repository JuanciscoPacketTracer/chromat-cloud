#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/lib/backup-config.sh"

CONFIG_FILE=
AGE_IDENTITY_FILE=
BACKUP_DIR=
BASE_BACKUP_DIR=
while (($#)); do
  case "$1" in
    --config)
      CONFIG_FILE="${2:-}"
      shift 2
      ;;
    --identity-file)
      AGE_IDENTITY_FILE="${2:-}"
      shift 2
      ;;
    --base-backup-dir)
      BASE_BACKUP_DIR="${2:-}"
      shift 2
      ;;
    -*)
      printf 'Usage: %s --config <production-env-file> [--identity-file <file>] [--base-backup-dir <directory>] <backup-directory>\n' \
        "$0" >&2
      exit 2
      ;;
    *)
      [[ -z "${BACKUP_DIR}" ]] || {
        printf 'Usage: %s --config <production-env-file> [--identity-file <file>] [--base-backup-dir <directory>] <backup-directory>\n' \
          "$0" >&2
        exit 2
      }
      BACKUP_DIR="$1"
      shift
      ;;
  esac
done
if [[ -z "${CONFIG_FILE}" || -z "${BACKUP_DIR}" || ! -d "${BACKUP_DIR}" ]]; then
  printf 'Usage: %s --config <production-env-file> [--identity-file <file>] [--base-backup-dir <directory>] <backup-directory>\n' \
    "$0" >&2
  exit 2
fi
CONFIG_FILE="$(realpath -e -- "${CONFIG_FILE}")"
BACKUP_DIR="$(realpath -e -- "${BACKUP_DIR}")"
load_backup_config "${CONFIG_FILE}"

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chromat-restore-check.XXXXXX")"
RESTORE_CONTAINER="chromat-restore-check-${RANDOM}-${RANDOM}"
RESTORE_IMAGE="${CHROMAT_DB_IMAGE:-mariadb:11.8.2}"
if [[ -n "${BASE_BACKUP_DIR}" ]]; then
  BASE_BACKUP_DIR="$(realpath -e -- "${BASE_BACKUP_DIR}")"
fi
ENCRYPTED_BACKUP=0
[[ -f "${BACKUP_DIR}/raw.tar.gz.age" ]] && ENCRYPTED_BACKUP=1
RESTORE_PASSWORD_FILE="${VERIFY_DIR}/restore-root-password"
RESTORE_CLIENT_CONFIG="${VERIFY_DIR}/restore-client.cnf"
RESTORE_ENV_FILE="${VERIFY_DIR}/restore.env"
cleanup() {
  sudo -- docker rm -f "${RESTORE_CONTAINER}" >/dev/null 2>&1 || true
  rm -rf -- "${VERIFY_DIR}"
}
trap cleanup EXIT

umask 077
command -v openssl >/dev/null || {
  printf 'openssl is required to create an isolated restore credential\n' >&2
  exit 2
}
openssl rand -hex 32 >"${RESTORE_PASSWORD_FILE}"
{
  printf '[client]\nuser=root\npassword='
  tr -d '\n' <"${RESTORE_PASSWORD_FILE}"
  printf '\n'
} >"${RESTORE_CLIENT_CONFIG}"
cat >"${RESTORE_ENV_FILE}" <<'EOF'
MARIADB_DATABASE=chromat_restore
MARIADB_ROOT_PASSWORD_FILE=/run/secrets/restore_root_password
EOF
(
  cd -- "${BACKUP_DIR}"
  sha256sum --check checksums.sha256
  if [[ -f raw.tar.gz.age ]]; then
    require_private_file 'age identity file' "${AGE_IDENTITY_FILE}"
    command -v age >/dev/null || {
      printf 'age is required to verify encrypted backups\n' >&2
      exit 2
    }
    age -d -i "${AGE_IDENTITY_FILE}" -o "${VERIFY_DIR}/database.sql" database.sql.age
    age -d -i "${AGE_IDENTITY_FILE}" -o "${VERIFY_DIR}/raw.tar.gz" raw.tar.gz.age
    age -d -i "${AGE_IDENTITY_FILE}" -o "${VERIFY_DIR}/raw-manifest.tsv" raw-manifest.tsv.age
    age -d -i "${AGE_IDENTITY_FILE}" -o "${VERIFY_DIR}/configuration.tar.gz" configuration.tar.gz.age
    if [[ -f raw-deletions.tsv.age ]]; then
      age -d -i "${AGE_IDENTITY_FILE}" -o "${VERIFY_DIR}/raw-deletions.tsv" raw-deletions.tsv.age
    fi
    if [[ -f backup-metadata.json.age ]]; then
      age -d -i "${AGE_IDENTITY_FILE}" -o "${VERIFY_DIR}/backup-metadata.json" backup-metadata.json.age
    fi
    if [[ -f secrets.tar.gz.age ]]; then
      age -d -i "${AGE_IDENTITY_FILE}" -o "${VERIFY_DIR}/secrets.tar.gz" secrets.tar.gz.age
    fi
  else
    cp -- database.sql raw.tar.gz raw-manifest.tsv configuration.tar.gz "${VERIFY_DIR}/"
    [[ -f secrets.tar.gz ]] && cp -- secrets.tar.gz "${VERIFY_DIR}/"
    [[ -f raw-deletions.tsv ]] && cp -- raw-deletions.tsv "${VERIFY_DIR}/"
    [[ -f backup-metadata.json ]] && cp -- backup-metadata.json "${VERIFY_DIR}/"
  fi
  gzip -t "${VERIFY_DIR}/raw.tar.gz"
  mkdir -p "${VERIFY_DIR}/raw"
  mode="full"
  if [[ -s "${VERIFY_DIR}/backup-metadata.json" ]]; then
    mode="$(sed -n 's/.*"mode":"\([^"]*\)".*/\1/p' "${VERIFY_DIR}/backup-metadata.json")"
  fi
  if [[ "${mode}" == "incremental" ]]; then
    [[ -n "${BASE_BACKUP_DIR}" && -d "${BASE_BACKUP_DIR}" ]] || {
      printf 'BACKUP_BASE_DIR is required for incremental restore verification\n' >&2
      exit 2
    }
    if [[ -f "${BASE_BACKUP_DIR}/raw.tar.gz.age" ]]; then
      age -d -i "${AGE_IDENTITY_FILE}" -o "${VERIFY_DIR}/base-raw.tar.gz" \
        "${BASE_BACKUP_DIR}/raw.tar.gz.age"
    else
      cp -- "${BASE_BACKUP_DIR}/raw.tar.gz" "${VERIFY_DIR}/base-raw.tar.gz"
    fi
    tar -xzf "${VERIFY_DIR}/base-raw.tar.gz" -C "${VERIFY_DIR}/raw"
  fi
  tar -xzf "${VERIFY_DIR}/raw.tar.gz" -C "${VERIFY_DIR}/raw"
  if [[ "${mode}" == "incremental" ]]; then
    while IFS= read -r deleted; do
      [[ -n "${deleted}" ]] && rm -f -- "${VERIFY_DIR}/raw/${deleted}"
    done <"${VERIFY_DIR}/raw-deletions.tsv"
  fi
  (cd "${VERIFY_DIR}/raw" && sha256sum --check "${VERIFY_DIR}/raw-manifest.tsv")
  test -s "${VERIFY_DIR}/database.sql"
  test -s "${VERIFY_DIR}/raw-manifest.tsv"
  test -s "${VERIFY_DIR}/configuration.tar.gz"
  if (( ENCRYPTED_BACKUP )) && [[ -f secrets.tar.gz.age ]]; then
    test -s "${VERIFY_DIR}/secrets.tar.gz"
  fi
)

mkdir -p "${VERIFY_DIR}/configuration"
tar -xzf "${VERIFY_DIR}/configuration.tar.gz" -C "${VERIFY_DIR}/configuration"
sudo -- docker run -d --network none --name "${RESTORE_CONTAINER}" \
  --env-file "${RESTORE_ENV_FILE}" \
  -v "${RESTORE_PASSWORD_FILE}:/run/secrets/restore_root_password:ro" \
  -v "${RESTORE_CLIENT_CONFIG}:/run/secrets/restore-client.cnf:ro" \
  "${RESTORE_IMAGE}" >/dev/null

restore_sql() {
  sudo -- docker exec -i "${RESTORE_CONTAINER}" mariadb \
    --defaults-extra-file=/run/secrets/restore-client.cnf chromat_restore "$@"
}

for attempt in $(seq 1 60); do
  if restore_sql -e 'SELECT 1' \
    >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" == 60 ]]; then
    printf 'Isolated MariaDB did not become ready\n' >&2
    exit 1
  fi
  sleep 1
done

sed -E 's/^USE .+;$/USE `chromat_restore`;/' \
  "${VERIFY_DIR}/database.sql" >"${VERIFY_DIR}/database-import.sql"
if ! restore_sql <"${VERIFY_DIR}/database-import.sql"; then
  printf 'Failed to import the restored database\n' >&2
  exit 1
fi

while IFS= read -r migration; do
  version="${migration%%_*}"
  name="${migration%.sql}"
  expected="${version}_${name#*_}"
  if ! found="$(restore_sql -N -B \
    -e "SELECT COUNT(*) FROM schema_migrations WHERE version = '${expected}'")"; then
    printf 'Failed to inspect restored migration: %s\n' "${expected}" >&2
    exit 1
  fi
  if [[ "${found}" != "1" ]]; then
    printf 'Pending migration in restored database: %s\n' "${expected}" >&2
    exit 1
  fi
done < <(find "${VERIFY_DIR}/configuration/db/migrations" -maxdepth 1 -type f \
  -name '[0-9][0-9][0-9]_*.sql' -printf '%f\n' | sort)

if ! restore_sql -N -B \
  -e "SELECT storage_path, sha256 FROM raw_files WHERE storage_path IS NOT NULL ORDER BY storage_path" \
  >"${VERIFY_DIR}/raw-references.tsv"; then
  printf 'Failed to inspect restored raw-file references\n' >&2
  exit 1
fi

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
