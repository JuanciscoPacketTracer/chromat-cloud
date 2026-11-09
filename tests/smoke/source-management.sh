#!/usr/bin/env bash
set -euo pipefail

base_url="${BASE_URL:-https://localhost}"
username="${ADMIN_USERNAME:?ADMIN_USERNAME is required}"
password="${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"
cookie_file="$(mktemp)"
login_body="$(mktemp)"
response_body="$(mktemp)"
trap 'rm -f "$cookie_file" "$login_body" "$response_body"' EXIT

curl --silent --show-error --fail --insecure \
  -c "$cookie_file" -o "$login_body" \
  -H 'content-type: application/json' \
  -d "{\"username\":\"$username\",\"password\":\"$password\"}" \
  "$base_url/api/v1/admin/login"
csrf_token="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1])).csrf_token)' "$login_body")"
cookie_header="$(awk '$6 == "chromat_session" { print $6 "=" $7 }' "$cookie_file")"

create_source() {
  local name="$1" is_test="$2"
  curl --silent --show-error --fail --insecure \
    -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
    -H 'content-type: application/json' \
    -d "{\"name\":\"$name\",\"crop\":\"mango\",\"is_test\":$is_test,\"chat_id\":\"12345\"}" \
    "$base_url/api/v1/admin/sources"
}

source_body="$(create_source "smoke-real" false)"
source_id="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(0)).source_id)' <<<"$source_body")"
old_key="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(0)).api_key)' <<<"$source_body")"
test_source_body="$(create_source "smoke-test" true)"
test_source_id="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(0)).source_id)' <<<"$test_source_body")"

rotate_body="$(
  curl --silent --show-error --fail --insecure \
    -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
    -H 'content-type: application/json' -d '{"coexist_seconds":60}' \
    "$base_url/api/v1/admin/sources/$source_id/keys"
)"
new_key="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(0)).api_key)' <<<"$rotate_body")"

curl --silent --show-error --fail --insecure \
  -H "Authorization: Bearer $old_key" "$base_url/api/v1/events/00000000-0000-4000-8000-000000000000" >/dev/null || [[ "$?" == 22 ]]

curl --silent --show-error --fail --insecure \
  -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
  -X PATCH -H 'content-type: application/json' \
  -d '{"status":"revoked"}' "$base_url/api/v1/admin/sources/$source_id" >/dev/null

revoked_status="$(
  curl --silent --show-error --insecure -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $new_key" \
    "$base_url/api/v1/events/00000000-0000-4000-8000-000000000000"
)"
[[ "$revoked_status" == "401" ]]

producer_body="$(
  curl --silent --show-error --fail --insecure \
    -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
    -H 'content-type: application/json' \
    -d '{"username":"smoke-producer","password":"not-returned"}' \
    "$base_url/api/v1/admin/producers"
)"
producer_id="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(0)).producer_id)' <<<"$producer_body")"
curl --silent --show-error --fail --insecure \
  -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
  -H 'content-type: application/json' \
  -d "{\"source_id\":\"$test_source_id\"}" \
  "$base_url/api/v1/admin/producers/$producer_id/sources" >/dev/null

producer_cookie="$(mktemp)"
producer_login_body="$(mktemp)"
trap 'rm -f "$cookie_file" "$login_body" "$response_body" "$producer_cookie" "$producer_login_body"' EXIT
curl --silent --show-error --fail --insecure \
  -c "$producer_cookie" -o "$producer_login_body" \
  -H 'content-type: application/json' \
  -d '{"username":"smoke-producer","password":"not-returned"}' \
  "$base_url/api/v1/producer/login"
producer_cookie_header="$(awk '$6 == "chromat_producer" { print $6 "=" $7 }' "$producer_cookie")"
producer_sources="$(
  curl --silent --show-error --fail --insecure \
    -H "Cookie: $producer_cookie_header" \
    "$base_url/api/v1/producer/sources"
)"
grep -q "$test_source_id" <<<"$producer_sources"
! grep -q "$source_id" <<<"$producer_sources"

printf 'PASS: monitoring source management contract\n'
