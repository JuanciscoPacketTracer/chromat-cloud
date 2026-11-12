#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

runbook="$repo_root/docs/deployment/backups.md"
canonical_secret_dir="/etc/chromat/secrets"
expected_backup_secrets=(
  db_password
  db_root_password
  telegram_bot_token
)

expected_backup_secret_files=""
for secret in "${expected_backup_secrets[@]}"; do
  expected_backup_secret_files+="${expected_backup_secret_files:+ }$canonical_secret_dir/$secret"
done
grep -Fx "BACKUP_SECRET_FILES=$expected_backup_secret_files" "$repo_root/.env.example"
for secret in "${expected_backup_secrets[@]}"; do
  grep -Fq "$canonical_secret_dir/$secret" "$runbook"
done
grep -Fq '${TELEGRAM_BOT_TOKEN_HOST_FILE}:/run/secrets/telegram_bot_token:ro' \
  "$repo_root/compose.yaml"

for required_phrase in \
  "diari" \
  "siete" \
  "America/Mazatlan" \
  "copia externa" \
  "age" \
  "clave" \
  "migraciones" \
  "hash" \
  "faltantes" \
  "custodio" \
  "pérdida"; do
  grep -qi "$required_phrase" "$runbook"
done

fake_bin="$work_dir/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/age" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '/mnt/external\n'
EOF
chmod +x "$fake_bin/age" "$fake_bin/findmnt"

mkdir -p "$work_dir/backups" "$work_dir/external"
printf 'recipient\n' >"$work_dir/recipient"
printf 'private-ca\n' >"$work_dir/ca.key"

if PATH="$fake_bin:$PATH" \
  BACKUP_ROOT="$work_dir/backups" \
  BACKUP_EXTERNAL_DIR="$work_dir/external" \
  BACKUP_AGE_RECIPIENT_FILE="$work_dir/recipient" \
  BACKUP_SECRET_FILES="$work_dir/ca.key" \
  COMPOSE="false" \
  bash "$repo_root/scripts/backup.sh" >/dev/null 2>&1; then
  printf 'FAIL: backup accepted the CA private key\n' >&2
  exit 1
fi

mkdir -p "$work_dir/invalid-backup"
if bash "$repo_root/scripts/verify-backup.sh" "$work_dir/invalid-backup" >/dev/null 2>&1; then
  printf 'FAIL: verifier accepted a backup without checksums\n' >&2
  exit 1
fi

printf 'PASS: backup operation contract\n'
