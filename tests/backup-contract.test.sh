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
if grep -Fq 'BACKUP_AGE_IDENTITY_FILE' "$runbook" "$repo_root/docs/deployment/promotion.md"; then
  printf 'FAIL: documentation must use --identity-file instead of BACKUP_AGE_IDENTITY_FILE\n' >&2
  exit 1
fi

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
set -euo pipefail
output=
input=
while (($#)); do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -R|-i)
      shift 2
      ;;
    -d)
      shift
      ;;
    *)
      input="$1"
      shift
      ;;
  esac
done
[[ -n "$output" && -n "$input" ]]
cp -- "$input" "$output"
EOF
cat >"$fake_bin/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_MOUNT_TARGET:-/mnt/external}"
EOF
cat >"$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--" ]] && shift
printf '%s\n' "$*" >>"$SUDO_LOG"
SUDO_WRAPPER=1 exec "$@"
EOF
cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${SUDO_WRAPPER:-}" == 1 ]] || {
  printf 'FAIL: Docker was called without sudo\n' >&2
  exit 97
}
printf '%s\n' "$*" >>"$DOCKER_LOG"
case "${1:-}" in
  compose)
    if [[ " $* " == *" exec -T db "* ]]; then
      printf 'CREATE DATABASE chromat;\nUSE chromat;\n'
    fi
    ;;
  run)
    for argument in "$@"; do
      if [[ "$argument" == *:/backup ]]; then
        backup_dir="${argument%:/backup}"
      fi
    done
    if [[ " $* " == *current-raw-manifest* ]]; then
      printf '%s  ./raw-file\n' \
        'd7439bee24773bcbf2f25e9e9b5b965a2ea7f11c9c4a4b3b0f0b4d6285f2d756' \
        >"$backup_dir/current-raw-manifest.tsv"
    elif [[ " $* " == *'tar -czf /backup/raw.tar.gz'* ]]; then
      tar -czf "$backup_dir/raw.tar.gz" --files-from /dev/null
    fi
    ;;
  exec)
    if [[ "${FAKE_SQL_FAILURE:-}" == 1 &&
      " $* " == *'SELECT COUNT(*) FROM schema_migrations'* ]]; then
      exit 38
    elif [[ " $* " == *'SELECT 1'* ]]; then
      printf '1\n'
    elif [[ " $* " == *'SELECT COUNT(*) FROM schema_migrations'* ]]; then
      printf '1\n'
    elif [[ " $* " == *'SELECT storage_path, sha256 FROM raw_files'* ]]; then
      printf 'raw-file\t7499ead35ef265e107464dfc084cdbb050ef625c8c549adf3c5aa5e41772d88f\n'
    fi
    ;;
esac
EOF
chmod +x "$fake_bin/age" "$fake_bin/findmnt" "$fake_bin/sudo" "$fake_bin/docker"

mkdir -p "$work_dir/backups" "$work_dir/external" "$work_dir/state"
printf 'recipient\n' >"$work_dir/recipient"
printf 'identity\n' >"$work_dir/identity"
printf 'private-ca\n' >"$work_dir/ca.key"
printf 'db-password\n' >"$work_dir/db_password"
printf 'db-root-password\n' >"$work_dir/db_root_password"
printf 'telegram-token\n' >"$work_dir/telegram_bot_token"
chmod 0600 \
  "$work_dir/identity" "$work_dir/ca.key" "$work_dir/db_password" \
  "$work_dir/db_root_password" "$work_dir/telegram_bot_token"
config_file="$work_dir/production.env"
cat >"$config_file" <<EOF
BACKUP_ROOT=$work_dir/backups
BACKUP_EXTERNAL_DIR=$work_dir/external
BACKUP_AGE_RECIPIENT_FILE=$work_dir/recipient
BACKUP_SECRET_FILES=$work_dir/db_password $work_dir/db_root_password $work_dir/telegram_bot_token
BACKUP_MAX_SECONDS=3600
BACKUP_MODE=full
BACKUP_STATE_DIR=$work_dir/state
CHROMAT_DB_IMAGE=mariadb:11.8.2
DB_PASSWORD_HOST_FILE=$work_dir/db_password
DB_ROOT_PASSWORD_HOST_FILE=$work_dir/db_root_password
TELEGRAM_BOT_TOKEN_HOST_FILE=$work_dir/telegram_bot_token
EOF
export SUDO_LOG="$work_dir/sudo.log"
export DOCKER_LOG="$work_dir/docker.log"

if PATH="$fake_bin:$PATH" \
  FAKE_MOUNT_TARGET="$work_dir/external" \
  sudo -- bash "$repo_root/scripts/backup.sh" --config "$work_dir/missing.env" \
    >/dev/null 2>&1; then
  printf 'FAIL: backup accepted a missing production environment file\n' >&2
  exit 1
fi

if PATH="$fake_bin:$PATH" \
  FAKE_MOUNT_TARGET=/ \
  sudo -- bash "$repo_root/scripts/backup.sh" --config "$config_file" \
    >/dev/null 2>&1; then
  printf 'FAIL: backup accepted an unavailable external mount\n' >&2
  exit 1
fi

sed '/BACKUP_SECRET_FILES/d' "$config_file" >"$work_dir/missing-variable.env"
if PATH="$fake_bin:$PATH" \
  FAKE_MOUNT_TARGET="$work_dir/external" \
  sudo -- bash "$repo_root/scripts/backup.sh" --config "$work_dir/missing-variable.env" \
    >/dev/null 2>&1; then
  printf 'FAIL: backup accepted a production environment with missing variables\n' >&2
  exit 1
fi

sed "s|BACKUP_SECRET_FILES=.*|BACKUP_SECRET_FILES=$work_dir/db_password|" \
  "$config_file" >"$work_dir/incomplete-secret-list.env"
if PATH="$fake_bin:$PATH" \
  FAKE_MOUNT_TARGET="$work_dir/external" \
  sudo -- bash "$repo_root/scripts/backup.sh" --config "$work_dir/incomplete-secret-list.env" \
    >/dev/null 2>&1; then
  printf 'FAIL: backup accepted an incomplete service secret list\n' >&2
  exit 1
fi

sed "s|BACKUP_SECRET_FILES=.*|BACKUP_SECRET_FILES=$work_dir/db_password $work_dir/db_password $work_dir/db_root_password $work_dir/telegram_bot_token|" \
  "$config_file" >"$work_dir/duplicate-secret-list.env"
if PATH="$fake_bin:$PATH" \
  FAKE_MOUNT_TARGET="$work_dir/external" \
  sudo -- bash "$repo_root/scripts/backup.sh" --config "$work_dir/duplicate-secret-list.env" \
    >/dev/null 2>&1; then
  printf 'FAIL: backup accepted a duplicate service secret\n' >&2
  exit 1
fi

sed "s|BACKUP_SECRET_FILES=.*|BACKUP_SECRET_FILES=$work_dir/ca.key|" \
  "$config_file" >"$work_dir/ca-secret.env"
if PATH="$fake_bin:$PATH" \
  FAKE_MOUNT_TARGET="$work_dir/external" \
  sudo -- bash "$repo_root/scripts/backup.sh" --config "$work_dir/ca-secret.env" \
    >/dev/null 2>&1; then
  printf 'FAIL: backup accepted the CA private key\n' >&2
  exit 1
fi

PATH="$fake_bin:$PATH" \
  FAKE_MOUNT_TARGET="$work_dir/external" \
  sudo -- bash "$repo_root/scripts/backup.sh" --config "$config_file" >/dev/null
grep -Fq 'docker compose' "$SUDO_LOG"
grep -Fq 'docker run' "$SUDO_LOG"

verify_backup="$work_dir/verify-backup"
mkdir -p "$verify_backup"
printf 'CREATE DATABASE chromat;\nUSE chromat;\n' >"$verify_backup/database.sql.age"
raw_dir="$work_dir/raw"
mkdir -p "$raw_dir"
printf 'raw data\n' >"$raw_dir/raw-file"
tar -czf "$verify_backup/raw.tar.gz.age" -C "$raw_dir" raw-file
printf '%s  raw-file\n' \
  "$(sha256sum "$raw_dir/raw-file" | awk '{print $1}')" \
  >"$verify_backup/raw-manifest.tsv.age"
mkdir -p "$work_dir/configuration/db/migrations"
printf 'CREATE TABLE schema_migrations (version VARCHAR(255));\n' \
  >"$work_dir/configuration/db/migrations/001_initial.sql"
tar -czf "$verify_backup/configuration.tar.gz.age" -C "$work_dir/configuration" db
printf 'secret\n' >"$verify_backup/secrets.tar.gz.age"
printf '{"mode":"full","base_backup":""}\n' >"$verify_backup/backup-metadata.json.age"
: >"$verify_backup/raw-deletions.tsv.age"
(
  cd "$verify_backup"
  sha256sum *.age >checksums.sha256
)
PATH="$fake_bin:$PATH" \
  sudo -- bash "$repo_root/scripts/verify-backup.sh" \
    --config "$config_file" --identity-file "$work_dir/identity" "$verify_backup" \
    >/dev/null
grep -Fq 'docker run' "$SUDO_LOG"
grep -Fq 'docker exec' "$SUDO_LOG"
grep -Fq 'SELECT 1' "$DOCKER_LOG"
if grep -Eq 'restore-verification|db-password|db-root-password|telegram-token' \
  "$SUDO_LOG" "$DOCKER_LOG"; then
  printf 'FAIL: secret content appeared in a Docker process argument\n' >&2
  exit 1
fi

if grep -Eq '(^|[^[:alnum:]_])docker (run|exec|rm)' \
  "$repo_root/scripts/backup.sh" "$repo_root/scripts/verify-backup.sh" |
  grep -Ev 'sudo -- docker'; then
  printf 'FAIL: scripts invoke Docker without sudo\n' >&2
  exit 1
fi
if grep -Eq -- '-uroot[[:space:]]+-p[^[:space:]]+|MARIADB_ROOT_PASSWORD=' \
  "$repo_root/scripts/verify-backup.sh"; then
  printf 'FAIL: verifier passes a MariaDB password as a process argument\n' >&2
  exit 1
fi
if PATH="$fake_bin:$PATH" \
  FAKE_SQL_FAILURE=1 \
  sudo -- bash "$repo_root/scripts/verify-backup.sh" \
    --config "$config_file" --identity-file "$work_dir/identity" "$verify_backup" \
    >/dev/null 2>&1; then
  printf 'FAIL: verifier accepted a failed SQL migration query\n' >&2
  exit 1
fi

printf 'PASS: backup operation contract\n'
