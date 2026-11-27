#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/curl.sh"

base_url="${BASE_URL:-https://localhost}"
username="${ADMIN_USERNAME:?ADMIN_USERNAME is required}"
password="${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"
cookie_file="$(mktemp)"
login_body="$(mktemp)"
response_body="$(mktemp)"
image_file="$(mktemp)"
trap 'rm -f "$cookie_file" "$login_body" "$response_body" "$image_file"' EXIT
run_suffix="$(date +%s)-$$"

smoke_curl --silent --show-error --fail \
  -c "$cookie_file" -o "$login_body" \
  -H 'content-type: application/json' \
  -d "{\"username\":\"$username\",\"password\":\"$password\"}" \
  "$base_url/api/v1/admin/login"
csrf_token="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1])).csrf_token)' "$login_body")"
cookie_header="$(awk '$6 == "chromat_session" { print $6 "=" $7 }' "$cookie_file")"

create_source() {
  local name="$1" is_test="$2"
  smoke_curl --silent --show-error --fail \
    -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
    -H 'content-type: application/json' \
    -d "{\"name\":\"$name\",\"crop\":\"mango\",\"is_test\":$is_test,\"chat_id\":\"12345\"}" \
    "$base_url/api/v1/admin/sources"
}

source_body="$(create_source "smoke-real-$run_suffix" false)"
source_id="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(0)).source_id)' <<<"$source_body")"
old_key="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(0)).api_key)' <<<"$source_body")"
test_source_body="$(create_source "smoke-test-$run_suffix" true)"
test_source_id="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(0)).source_id)' <<<"$test_source_body")"

cleanup() {
  smoke_curl --silent --show-error --fail \
    -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
    -X POST "$base_url/api/v1/admin/sources/$test_source_id/cleanup" >/dev/null
}
trap 'cleanup; rm -f "$cookie_file" "$login_body" "$response_body" "$image_file"' EXIT

rotate_body="$(
  smoke_curl --silent --show-error --fail \
    -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
    -H 'content-type: application/json' -d '{"coexist_seconds":60}' \
    "$base_url/api/v1/admin/sources/$source_id/keys"
)"
new_key="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(0)).api_key)' <<<"$rotate_body")"

smoke_curl --silent --show-error --fail \
  -H "Authorization: Bearer $old_key" "$base_url/api/v1/events/00000000-0000-4000-8000-000000000000" >/dev/null || [[ "$?" == 22 ]]

producer_body="$(
  smoke_curl --silent --show-error --fail \
    -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
    -H 'content-type: application/json' \
    -d "{\"username\":\"smoke-producer-$run_suffix\",\"password\":\"not-returned\"}" \
    "$base_url/api/v1/admin/producers"
)"
producer_id="$(node -e 'const fs=require("fs"); process.stdout.write(JSON.parse(fs.readFileSync(0)).producer_id)' <<<"$producer_body")"
smoke_curl --silent --show-error --fail \
  -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
  -H 'content-type: application/json' \
  -d "{\"source_id\":\"$test_source_id\"}" \
  "$base_url/api/v1/admin/producers/$producer_id/sources" >/dev/null

producer_cookie="$(mktemp)"
producer_login_body="$(mktemp)"
trap 'cleanup; rm -f "$cookie_file" "$login_body" "$response_body" "$image_file" "$producer_cookie" "$producer_login_body"' EXIT
smoke_curl --silent --show-error --fail \
  -c "$producer_cookie" -o "$producer_login_body" \
  -H 'content-type: application/json' \
  -d "{\"username\":\"smoke-producer-$run_suffix\",\"password\":\"not-returned\"}" \
  "$base_url/api/v1/producer/login"
producer_cookie_header="$(awk '$6 == "chromat_producer" { print $6 "=" $7 }' "$producer_cookie")"
producer_sources="$(
  smoke_curl --silent --show-error --fail \
    -H "Cookie: $producer_cookie_header" \
    "$base_url/api/v1/producer/sources"
)"
grep -q "$test_source_id" <<<"$producer_sources"
! grep -q "$source_id" <<<"$producer_sources"

test_key="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0)).api_key)' <<<"$test_source_body")"
base64 --decode >"$image_file" <<'PNG'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNo+M8AAAOCAYB04NylAAAAAElFTkSuQmCC
PNG
measured_event="$(node -e 'console.log(crypto.randomUUID())')"
empty_event="$(node -e 'console.log(crypto.randomUUID())')"
occurred_at="$(node -e 'console.log(new Date().toISOString())')"
for metadata in \
  "{\"event_id\":\"$measured_event\",\"occurred_at\":\"$occurred_at\",\"temperature_c\":0,\"humidity_rh\":62.5}" \
  "{\"event_id\":\"$empty_event\",\"occurred_at\":\"$occurred_at\"}"; do
  smoke_curl --silent --show-error --fail -o /dev/null \
    -H "Authorization: Bearer $test_key" -F "metadata=$metadata;type=application/json" \
    -F "image=@$image_file;type=image/png" "$base_url/api/v1/events"
done
for role in admin producer; do
  role_cookie="$cookie_header"
  [[ "$role" != producer ]] || role_cookie="$producer_cookie_header"
  events_body="$(smoke_curl --silent --show-error --fail -H "Cookie: $role_cookie" \
    "$base_url/api/v1/$role/sources/$test_source_id/events")"
  node -e '
    const {events} = JSON.parse(require("fs").readFileSync(0));
    const measured = events.find((event) => event.event_id === process.argv[1]);
    const empty = events.find((event) => event.event_id === process.argv[2]);
    if (measured?.temperature_c !== 0 || measured.humidity_rh !== 62.5 ||
        empty?.temperature_c !== null || empty.humidity_rh !== null) {
      throw Error("sensor contract: numbers, zero and explicit null required for both roles");
    }
    if (events.some((event) => "raw_file" in event || "storage_path" in event || "image" in event)) {
      throw Error("raw image metadata must not be added to panel event listings");
    }
  ' "$measured_event" "$empty_event" <<<"$events_body"
done
for suffix in events state state/history; do
  smoke_curl --silent --show-error --fail -o /dev/null \
    -H "Cookie: $producer_cookie_header" \
    "$base_url/api/v1/producer/sources/$test_source_id/$suffix"
  denied_status="$(smoke_curl --silent --show-error -o /dev/null -w '%{http_code}' \
    -H "Cookie: $producer_cookie_header" \
    "$base_url/api/v1/producer/sources/$source_id/$suffix")"
  [[ "$denied_status" == "404" ]]
done
unauthorized_status="$(smoke_curl --silent --show-error -o /dev/null -w '%{http_code}' \
  "$base_url/api/v1/producer/sources/$test_source_id/events")"
[[ "$unauthorized_status" == "401" ]]
admin_status="$(smoke_curl --silent --show-error -o /dev/null -w '%{http_code}' \
  -H "Cookie: $producer_cookie_header" "$base_url/api/v1/admin/sources")"
[[ "$admin_status" == "401" ]]
write_status="$(smoke_curl --silent --show-error -o /dev/null -w '%{http_code}' \
  -H "Cookie: $producer_cookie_header" -X POST \
  "$base_url/api/v1/producer/sources/$test_source_id/events")"
[[ "$write_status" == "404" || "$write_status" == "405" ]]

smoke_curl --silent --show-error --fail \
  -H "Cookie: $cookie_header" -H "X-CSRF-Token: $csrf_token" \
  -X PATCH -H 'content-type: application/json' \
  -d '{"status":"revoked"}' "$base_url/api/v1/admin/sources/$source_id" >/dev/null

revoked_status="$(
  smoke_curl --silent --show-error -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $new_key" \
    "$base_url/api/v1/events/00000000-0000-4000-8000-000000000000"
)"
[[ "$revoked_status" == "401" ]]

printf 'PASS: monitoring source management contract\n'
