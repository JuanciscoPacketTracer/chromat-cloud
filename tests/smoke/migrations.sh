#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/compose.sh"

expected="$(
  smoke_compose exec -T db sh -c \
    'find /docker-entrypoint-initdb.d -maxdepth 1 -type f -name "[0-9][0-9][0-9]_*.sql" | wc -l'
)"
applied="$(
  smoke_compose exec -T db sh -c \
    'mariadb -u root -p"$(cat /run/secrets/db_root_password)" "$MARIADB_DATABASE" -N -B \
      -e "SELECT COUNT(*) FROM schema_migrations"'
)"

[[ "$expected" =~ ^[0-9]+$ && "$applied" =~ ^[0-9]+$ ]]
[[ "$expected" -gt 0 && "$applied" -eq "$expected" ]] || {
  printf 'migration mismatch: expected=%s applied=%s\n' "$expected" "$applied" >&2
  exit 1
}

printf 'PASS: forward-only migrations are applied\n'
