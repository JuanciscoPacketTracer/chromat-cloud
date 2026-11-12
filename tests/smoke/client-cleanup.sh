#!/usr/bin/env bash
set -euo pipefail
source /workspace/tests/smoke/curl.sh
# shellcheck disable=SC1091
source /runtime/source.env
login_body="$(mktemp)"
cookie_file="$(mktemp)"
trap 'rm -f "$login_body" "$cookie_file"' EXIT
smoke_curl --silent --show-error --fail -c "$cookie_file" -o "$login_body" \
  -H 'content-type: application/json' \
  -d "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\"}" \
  "$BASE_URL/api/v1/admin/login" >/dev/null
csrf_token="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1])).csrf_token)' "$login_body")"
cookie_header="$(awk '$6 == "chromat_session" { print $6 "=" $7 }' "$cookie_file")"
smoke_curl --silent --show-error --fail \
  -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
  -X POST "$BASE_URL/api/v1/admin/sources/$SMOKE_SOURCE_ID/cleanup" >/dev/null
