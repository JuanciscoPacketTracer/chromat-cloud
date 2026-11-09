#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/curl.sh"

base_url="${BASE_URL:-https://localhost}"
api_key="${SMOKE_SOURCE_API_KEY:?SMOKE_SOURCE_API_KEY is required}"
event_id="$(node -e 'console.log(crypto.randomUUID())')"
occurred_at="$(node -e 'console.log(new Date().toISOString())')"
image_file="$(mktemp)"
response_body="$(mktemp)"
trap 'rm -f "$image_file" "$response_body"' EXIT

base64 --decode >"$image_file" <<'PNG'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=
PNG

smoke_curl --silent --show-error --fail-with-body \
  -X POST "$base_url/api/v1/events" \
  -H "Authorization: Bearer $api_key" \
  -F "metadata={\"event_id\":\"$event_id\",\"occurred_at\":\"$occurred_at\"};type=application/json" \
  -F "image=@$image_file;type=image/png" >/dev/null

for _ in $(seq 1 30); do
  smoke_curl --silent --show-error --fail-with-body \
    "$base_url/api/v1/events/$event_id" \
    -H "Authorization: Bearer $api_key" >"$response_body"
  if grep -q '"status":"completed"' "$response_body"; then
    grep -q '"algorithm":"cnn"' "$response_body"
    grep -q '"algorithm":"hsv"' "$response_body"
    grep -q '"comparison"' "$response_body"
    grep -q '"analysis_runs_count":2' "$response_body"
    printf 'PASS: deterministic inference comparison contract\n'
    exit 0
  fi
  sleep 2
done

cat "$response_body" >&2
exit 1
