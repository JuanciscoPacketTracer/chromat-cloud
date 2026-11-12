#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/curl.sh"
source "$(dirname "${BASH_SOURCE[0]}")/compose.sh"

base_url="${BASE_URL:-https://localhost}"
api_key="${SMOKE_SOURCE_API_KEY:?SMOKE_SOURCE_API_KEY is required}"
event_id="$(node -e 'console.log(crypto.randomUUID())')"
occurred_at="$(node -e 'console.log(new Date().toISOString())')"
image_file="$(mktemp)"
response_body="$(mktemp)"
trap 'rm -f "$image_file" "$response_body"' EXIT

base64 --decode >"$image_file" <<'PNG'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNo+M8AAAOCAYB04NylAAAAAElFTkSuQmCC
PNG

smoke_curl --silent --show-error --fail-with-body \
  -o "$response_body" \
  -X POST "$base_url/api/v1/events" \
  -H "Authorization: Bearer $api_key" \
  -F "metadata={\"event_id\":\"$event_id\",\"occurred_at\":\"$occurred_at\"};type=application/json" \
  -F "image=@$image_file;type=image/png"

observed_status=""
for _ in $(seq 1 30); do
  status_body="$(smoke_curl --silent --show-error --fail-with-body \
    "$base_url/api/v1/events/$event_id" \
    -H "Authorization: Bearer $api_key")"
  if grep -q '"status":"processing"' <<<"$status_body"; then
    observed_status="processing"
    if [[ "${SMOKE_INTERNAL_CLIENT:-false}" == "true" ]]; then
      : "${SMOKE_RUNTIME_DIR:?SMOKE_RUNTIME_DIR is required}"
      touch "$SMOKE_RUNTIME_DIR/interrupt-worker"
      for _ in $(seq 1 60); do
        [[ -f "$SMOKE_RUNTIME_DIR/interrupt-complete" ]] && break
        sleep 1
      done
      [[ -f "$SMOKE_RUNTIME_DIR/interrupt-complete" ]]
    else
      smoke_compose stop worker >/dev/null
      sleep "$(( ${WORKER_LEASE_SECONDS:-30} + 2 ))"
      smoke_compose start worker >/dev/null
    fi
    break
  fi
  if grep -q '"status":"completed"' <<<"$status_body"; then
    observed_status="completed"
    break
  fi
  sleep 2
done

[[ -n "$observed_status" ]] || {
  printf '%s\n' "$status_body" >&2
  exit 1
}

for _ in $(seq 1 30); do
  status_body="$(smoke_curl --silent --show-error --fail-with-body \
    "$base_url/api/v1/events/$event_id" \
    -H "Authorization: Bearer $api_key")"
  if grep -q '"status":"completed"' <<<"$status_body"; then
    node -e '
      const event = JSON.parse(require("fs").readFileSync(0, "utf8"));
      if (event.analysis_runs_count !== 2) process.exit(1);
      if (!event.analysis_runs.some((run) => run.algorithm === "hsv")) process.exit(1);
      if (!event.analysis_runs.some((run) => run.algorithm === "cnn")) process.exit(1);
      if (event.current_result?.algorithm !== "hsv") process.exit(1);
    ' <<<"$status_body"
    printf 'PASS: recoverable HSV and CNN processing contract\n'
    exit 0
  fi
  sleep 2
done

printf '%s\n' "$status_body" >&2
exit 1
