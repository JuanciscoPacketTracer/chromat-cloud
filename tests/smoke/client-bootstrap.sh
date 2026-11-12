#!/usr/bin/env bash
set -euo pipefail
source /workspace/tests/smoke/curl.sh

login_body="$(mktemp)"
cookie_file="$(mktemp)"
trap 'rm -f "$login_body" "$cookie_file"' EXIT
smoke_curl --silent --show-error --fail -c "$cookie_file" -o "$login_body" \
  -H 'content-type: application/json' \
  -d "{\"username\":\"$ADMIN_USERNAME\",\"password\":\"$ADMIN_PASSWORD\"}" \
  "$BASE_URL/api/v1/admin/login" >/dev/null
csrf_token="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1])).csrf_token)' "$login_body")"
cookie_header="$(awk '$6 == "chromat_session" { print $6 "=" $7 }' "$cookie_file")"
source_body="$(
  smoke_curl --silent --show-error --fail \
    -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
    -H 'content-type: application/json' \
    -d "{\"name\":\"$SMOKE_SOURCE_NAME\",\"crop\":\"mango\",\"is_test\":true}" \
    "$BASE_URL/api/v1/admin/sources"
)"
node -e '
const fs = require("fs");
const source = JSON.parse(fs.readFileSync(0, "utf8"));
fs.writeFileSync("/runtime/source.env",
  `SMOKE_SOURCE_ID=${JSON.stringify(source.source_id)}\nSMOKE_SOURCE_API_KEY=${JSON.stringify(source.api_key)}\nFOREIGN_EVENT_ID=${JSON.stringify(crypto.randomUUID())}\n`,
  { mode: 0o600 });
' <<<"$source_body"
