#!/usr/bin/env bash
set -Eeuo pipefail

BACKUP_DIR="${1:-}"
if [[ -z "${BACKUP_DIR}" || ! -d "${BACKUP_DIR}" ]]; then
  printf 'Usage: %s <backup-directory>\n' "$0" >&2
  exit 2
fi

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chromat-restore-check.XXXXXX")"
trap 'rm -rf -- "${VERIFY_DIR}"' EXIT
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
printf 'Backup verified: %s\n' "${BACKUP_DIR}"
