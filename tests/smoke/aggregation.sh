#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/curl.sh"

base_url="${BASE_URL:-https://localhost}"
source_id="${SMOKE_SOURCE_ID:?SMOKE_SOURCE_ID is required}"
username="${ADMIN_USERNAME:?ADMIN_USERNAME is required}"
password="${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"
cookie_file="$(mktemp)"
login_body="$(mktemp)"
state_body="$(mktemp)"
history_body="$(mktemp)"
trap 'rm -f "$cookie_file" "$login_body" "$state_body" "$history_body"' EXIT

smoke_curl --silent --show-error --fail \
  -c "$cookie_file" -o "$login_body" \
  -H 'content-type: application/json' \
  -d "{\"username\":\"$username\",\"password\":\"$password\"}" \
  "$base_url/api/v1/admin/login" >/dev/null
cookie_header="$(awk '$6 == "chromat_session" { print $6 "=" $7 }' "$cookie_file")"

smoke_curl --silent --show-error --fail \
  -H "Cookie: $cookie_header" \
  "$base_url/api/v1/admin/sources/$source_id/state" >"$state_body"
grep -q '"states"' "$state_body"
grep -q '"aggregation_rule_version"' "$state_body"

smoke_curl --silent --show-error --fail \
  -H "Cookie: $cookie_header" \
  "$base_url/api/v1/admin/sources/$source_id/state/history" >"$history_body"
grep -q '"history"' "$history_body"

printf 'PASS: aggregated state and history contract\n'
