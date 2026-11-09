#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/curl.sh"

base_url="${BASE_URL:-https://localhost}"
api_key="${SMOKE_SOURCE_API_KEY:?SMOKE_SOURCE_API_KEY is required}"
username="${ADMIN_USERNAME:?ADMIN_USERNAME is required}"
password="${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"
cookie_file="$(mktemp)"
login_body="$(mktemp)"
response_headers="$(mktemp)"
response_body="$(mktemp)"
paused=false
cleanup() {
  if [[ "$paused" == true ]]; then
    smoke_curl --silent --show-error \
      -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
      -X POST "$base_url/api/v1/admin/capacity/resume" >/dev/null 2>&1 || true
  fi
  rm -f "$cookie_file" "$login_body" "$response_headers" "$response_body"
}
trap cleanup EXIT

smoke_curl --silent --show-error --fail \
  -c "$cookie_file" -o "$login_body" \
  -H 'content-type: application/json' \
  -d "{\"username\":\"$username\",\"password\":\"$password\"}" \
  "$base_url/api/v1/admin/login" >/dev/null
csrf_token="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1])).csrf_token)' "$login_body")"
cookie_header="$(awk '$6 == "chromat_session" { print $6 "=" $7 }' "$cookie_file")"
smoke_curl --silent --show-error --fail \
  -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
  -X POST "$base_url/api/v1/admin/capacity/pause" >/dev/null
paused=true

status="$(
  smoke_curl --silent --show-error \
    -D "$response_headers" -o "$response_body" -w '%{http_code}' \
    -X POST "$base_url/api/v1/events" \
    -H "Authorization: Bearer $api_key" \
    -H 'content-type: application/json' \
    -d '{}'
)"
[[ "$status" == "503" ]]
grep -qi '^retry-after: 60' "$response_headers"

smoke_curl --silent --show-error --fail \
  -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
  -X POST "$base_url/api/v1/admin/capacity/resume" >/dev/null
paused=false

printf 'PASS: capacity protection pause and resume contract\n'
