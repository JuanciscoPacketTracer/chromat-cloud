#!/usr/bin/env bash
set -euo pipefail

base_url="${BASE_URL:-https://localhost}"
api_key="${SOURCE_API_KEY:?SOURCE_API_KEY is required}"
event_id="$(node -e 'console.log(crypto.randomUUID())')"
occurred_at="$(node -e 'console.log(new Date().toISOString())')"
image_file="$(mktemp)"
response_body="$(mktemp)"
trap 'rm -f "$image_file" "$response_body"' EXIT

printf 'fake-jpeg-data' >"$image_file"

curl --silent --show-error --fail-with-body --insecure \
  -o "$response_body" \
  -X POST "$base_url/api/v1/events" \
  -H "Authorization: Bearer $api_key" \
  -F "metadata={\"event_id\":\"$event_id\",\"occurred_at\":\"$occurred_at\"};type=application/json" \
  -F "image=@$image_file;type=image/jpeg"

for _ in $(seq 1 30); do
  status_body="$(curl --silent --show-error --fail-with-body --insecure \
    "$base_url/api/v1/events/$event_id" \
    -H "Authorization: Bearer $api_key")"
  if grep -q '"status":"completed"' <<<"$status_body"; then
    grep -q '"algorithm":"hsv"' <<<"$status_body"
    grep -q '"current_result"' <<<"$status_body"
    printf 'PASS: recoverable HSV processing contract\n'
    exit 0
  fi
  sleep 2
done

printf '%s\n' "$status_body" >&2
exit 1
