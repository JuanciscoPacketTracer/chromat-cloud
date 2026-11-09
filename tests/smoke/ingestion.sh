#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/curl.sh"

base_url="${BASE_URL:-https://localhost}"
api_key="${SMOKE_SOURCE_API_KEY:?SMOKE_SOURCE_API_KEY is required}"
foreign_event_id="${FOREIGN_EVENT_ID:?FOREIGN_EVENT_ID is required}"
event_id="$(node -e 'console.log(crypto.randomUUID())')"
occurred_at="$(node -e 'console.log(new Date().toISOString())')"
image_file="$(mktemp)"
trap 'rm -f "$image_file"' EXIT

printf 'fake-jpeg-data' >"$image_file"

response_headers="$(mktemp)"
response_body="$(mktemp)"
trap 'rm -f "$image_file" "$response_headers" "$response_body"' EXIT

smoke_curl --silent --show-error --fail-with-body \
  -D "$response_headers" -o "$response_body" \
  -X POST "$base_url/api/v1/events" \
  -H "Authorization: Bearer $api_key" \
  -F "metadata={\"event_id\":\"$event_id\",\"occurred_at\":\"$occurred_at\"};type=application/json" \
  -F "image=@$image_file;type=image/jpeg"

grep -q '202' "$response_headers" || {
  cat "$response_body" >&2
  exit 1
}
grep -q "\"event_id\":\"$event_id\"" "$response_body"

smoke_curl --silent --show-error --fail-with-body \
  -X POST "$base_url/api/v1/events" \
  -H "Authorization: Bearer $api_key" \
  -F "metadata={\"event_id\":\"$event_id\",\"occurred_at\":\"$occurred_at\"};type=application/json" \
  -F "image=@$image_file;type=image/jpeg" >/dev/null

printf 'different-image-data' >"$image_file"
conflict_status="$(
  smoke_curl --silent --show-error \
    -o /dev/null -w '%{http_code}' \
    -X POST "$base_url/api/v1/events" \
    -H "Authorization: Bearer $api_key" \
    -F "metadata={\"event_id\":\"$event_id\",\"occurred_at\":\"$occurred_at\"};type=application/json" \
    -F "image=@$image_file;type=image/jpeg"
)"
[[ "$conflict_status" == "409" ]]

smoke_curl --silent --show-error --fail-with-body \
  "$base_url/api/v1/events/$event_id" \
  -H "Authorization: Bearer $api_key" >/dev/null

if smoke_curl --silent --show-error --fail \
  "$base_url/api/v1/events/$foreign_event_id" \
  -H "Authorization: Bearer $api_key" >/dev/null; then
  echo "foreign event unexpectedly visible" >&2
  exit 1
fi

printf 'PASS: monitoring event ingestion contract\n'
