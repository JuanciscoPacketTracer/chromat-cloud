#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for command in age age-keygen docker sudo; do
  if ! command -v "${command}" >/dev/null; then
    printf 'SKIP: backup integration requires %s\n' "${command}"
    exit 0
  fi
done
if ! sudo -n -- docker info >/dev/null 2>&1; then
  printf 'SKIP: backup integration requires non-interactive sudo access to Docker\n'
  exit 0
fi
if ! sudo -n -- docker image inspect mariadb:11.8.2 >/dev/null 2>&1; then
  printf 'SKIP: backup integration requires the preloaded mariadb:11.8.2 image\n'
  exit 0
fi
if ! sudo -n -- docker image inspect busybox:1.36.1 >/dev/null 2>&1; then
  printf 'SKIP: backup integration requires the preloaded busybox:1.36.1 image\n'
  exit 0
fi

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT
backup_dir="$work_dir/backup"
raw_dir="$work_dir/raw"
configuration_dir="$work_dir/configuration"
identity_file="$work_dir/identity"
recipient_file="$work_dir/recipient"
config_file="$work_dir/restore.env"
mkdir -p "$backup_dir" "$raw_dir" "$configuration_dir/db"

age-keygen -o "$identity_file" >/dev/null
chmod 0600 "$identity_file"
awk '/^# public key: / { print $4 }' "$identity_file" >"$recipient_file"
printf 'raw fixture\n' >"$raw_dir/fixture.raw"
raw_hash="$(sha256sum "$raw_dir/fixture.raw" | awk '{print $1}')"

{
  printf 'CREATE DATABASE chromat;\nUSE chromat;\n'
  printf 'CREATE TABLE schema_migrations (version VARCHAR(255) PRIMARY KEY);\n'
  while IFS= read -r migration; do
    version="${migration%%_*}"
    name="${migration%.sql}"
    printf "INSERT INTO schema_migrations (version) VALUES ('%s_%s');\n" \
      "$version" "${name#*_}"
  done < <(find "$repo_root/db/migrations" -maxdepth 1 -type f \
    -name '[0-9][0-9][0-9]_*.sql' -printf '%f\n' | sort)
  printf 'CREATE TABLE raw_files (storage_path VARCHAR(255), sha256 VARCHAR(64));\n'
  printf "INSERT INTO raw_files VALUES ('fixture.raw', '%s');\n" "$raw_hash"
} >"$work_dir/database.sql"
tar -czf "$work_dir/raw.tar.gz" -C "$raw_dir" fixture.raw
printf '%s  fixture.raw\n' "$raw_hash" >"$work_dir/raw-manifest.tsv"
cp -a "$repo_root/db/migrations" "$configuration_dir/db/"
tar -czf "$work_dir/configuration.tar.gz" -C "$configuration_dir" db
printf 'fixture secret\n' >"$work_dir/secrets.tar.gz"
printf '{"mode":"full","base_backup":""}\n' >"$work_dir/backup-metadata.json"
: >"$work_dir/raw-deletions.tsv"

for artifact in \
  database.sql raw.tar.gz raw-manifest.tsv configuration.tar.gz secrets.tar.gz \
  backup-metadata.json raw-deletions.tsv; do
  age -R "$recipient_file" -o "$backup_dir/$artifact.age" "$work_dir/$artifact"
done
(
  cd "$backup_dir"
  sha256sum *.age >checksums.sha256
)
printf 'CHROMAT_DB_IMAGE=mariadb:11.8.2\n' >"$config_file"
chmod 0600 "$config_file"

output="$(
  "$repo_root/scripts/verify-backup.sh" \
    --config "$config_file" --identity-file "$identity_file" "$backup_dir"
)"
grep -Fq "Backup verified: $backup_dir" <<<"$output"

printf 'SELECT * FROM missing_restore_table;\n' >"$work_dir/invalid.sql"
age -R "$recipient_file" -o "$backup_dir/database.sql.age" "$work_dir/invalid.sql"
(
  cd "$backup_dir"
  sha256sum *.age >checksums.sha256
)
if "$repo_root/scripts/verify-backup.sh" \
  --config "$config_file" --identity-file "$identity_file" "$backup_dir" \
  >/dev/null 2>&1; then
  printf 'FAIL: verifier accepted an SQL import error\n' >&2
  exit 1
fi

printf 'corrupt\n' >>"$backup_dir/raw.tar.gz.age"
if "$repo_root/scripts/verify-backup.sh" \
  --config "$config_file" --identity-file "$identity_file" "$backup_dir" \
  >/dev/null 2>&1; then
  printf 'FAIL: verifier accepted a corrupted encrypted artifact\n' >&2
  exit 1
fi

printf 'PASS: backup encryption and isolated MariaDB restoration integration\n'
