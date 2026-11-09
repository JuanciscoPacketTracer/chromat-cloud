#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_DIR="${1:-}"
if [[ -z "${BACKUP_DIR}" || ! -d "${BACKUP_DIR}" ]]; then
  printf 'Usage: %s <backup-directory>\n' "$0" >&2
  exit 2
fi

(
  cd -- "${BACKUP_DIR}"
  sha256sum --check checksums.sha256
  gzip -t raw.tar.gz
  tar -tzf raw.tar.gz >/dev/null
  test -s database.sql
  test -s raw-manifest.tsv
  test -s configuration.tar.gz
)
printf 'Backup verified: %s\n' "${BACKUP_DIR}"
