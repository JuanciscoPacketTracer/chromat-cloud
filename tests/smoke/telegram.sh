#!/usr/bin/env bash
set -euo pipefail

endpoint="${TELEGRAM_API_URL:?TELEGRAM_API_URL must point to a deterministic Telegram test double}"
[[ "$endpoint" != "https://api.telegram.org" ]] || {
  printf 'TELEGRAM_API_URL must not use the real Telegram API during smoke tests\n' >&2
  exit 1
}

docker compose exec -T telegram-worker node -e \
  'fetch(process.env.TELEGRAM_API_URL).then(response => process.exit(response.ok ? 0 : 1))'

printf 'PASS: deterministic Telegram endpoint is reachable\n'
