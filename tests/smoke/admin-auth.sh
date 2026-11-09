#!/usr/bin/env bash
set -euo pipefail

base_url="${BASE_URL:-https://localhost}"
username="${ADMIN_USERNAME:?ADMIN_USERNAME is required}"
password="${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"
cookie_file="$(mktemp)"
login_body="$(mktemp)"
audit_body="$(mktemp)"
trap 'rm -f "$cookie_file" "$login_body" "$audit_body"' EXIT

login_status="$(
  curl --silent --show-error --insecure \
    -c "$cookie_file" -o "$login_body" -w '%{http_code}' \
    -H 'content-type: application/json' \
    -d "{\"username\":\"$username\",\"password\":\"$password\"}" \
    "$base_url/api/v1/admin/login"
)"
[[ "$login_status" == "200" ]] || {
  cat "$login_body" >&2
  exit 1
}

failed_login="$(
  curl --silent --show-error --insecure \
    -o /dev/null -w '%{http_code}' \
    -H 'content-type: application/json' \
    -d "{\"username\":\"$username\",\"password\":\"wrong-password\"}" \
    "$base_url/api/v1/admin/login"
)"
[[ "$failed_login" == "401" ]]

csrf_token="$(node -e 'const fs=require("fs"); const body=JSON.parse(fs.readFileSync(process.argv[1])); process.stdout.write(body.csrf_token)' "$login_body")"
cookie_header="$(awk '$6 == "chromat_session" { print $6 "=" $7 }' "$cookie_file")"

without_csrf="$(
  curl --silent --show-error --insecure \
    -o /dev/null -w '%{http_code}' \
    -H "Cookie: $cookie_header" \
    -X POST "$base_url/api/v1/admin/logout"
)"
[[ "$without_csrf" == "403" ]]

curl --silent --show-error --fail --insecure \
  -H "Cookie: $cookie_header" \
  "$base_url/api/v1/admin/audit" >"$audit_body"
grep -q 'login_failed' "$audit_body"
grep -q 'csrf_rejected' "$audit_body"
! grep -q "$password" "$audit_body"

curl --silent --show-error --fail --insecure \
  -H "Cookie: $cookie_header" \
  -H "X-CSRF-Token: $csrf_token" \
  -X POST "$base_url/api/v1/admin/logout" >/dev/null

printf 'PASS: administrative authentication and audit contract\n'
