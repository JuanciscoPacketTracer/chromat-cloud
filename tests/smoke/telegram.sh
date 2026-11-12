#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/compose.sh"

endpoint="${TELEGRAM_API_URL:?TELEGRAM_API_URL must point to a deterministic Telegram test double}"
[[ "$endpoint" != "https://api.telegram.org" ]] || {
  printf 'TELEGRAM_API_URL must not use the real Telegram API during smoke tests\n' >&2
  exit 1
}

if [[ "${SMOKE_INTERNAL_CLIENT:-false}" == "true" ]]; then
  node -e 'fetch(process.env.TELEGRAM_API_URL).then(response => process.exit(response.ok ? 0 : 1))'
else
  smoke_compose exec -T telegram-worker node -e \
    'fetch(process.env.TELEGRAM_API_URL).then(response => process.exit(response.ok ? 0 : 1))'
fi

printf 'PASS: deterministic Telegram endpoint is reachable\n'
