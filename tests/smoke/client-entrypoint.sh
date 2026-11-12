#!/usr/bin/env bash
set -euo pipefail

export ADMIN_PASSWORD="$(tr -d '\n' </runtime/operator_password)"
if [[ -f /runtime/source.env ]]; then
  # shellcheck disable=SC1091
  source /runtime/source.env
  export SMOKE_SOURCE_ID SMOKE_SOURCE_API_KEY FOREIGN_EVENT_ID
fi
exec "$@"
