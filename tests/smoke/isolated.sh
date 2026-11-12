#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/tests/smoke/compose.sh"
runtime_dir="" client_runtime_dir="" source_id="" stack_started=false cleanup_failed=false
cleanup() {
  local status=$?; trap - EXIT INT TERM; set +e
  if [[ "$stack_started" == true ]]; then
    if [[ -f "$client_runtime_dir/source.env" ]] &&
      ! smoke_compose run --rm --no-deps smoke-client bash /workspace/tests/smoke/client-cleanup.sh; then
      printf '%s\n' "FAIL: smoke source cleanup request failed" >&2
      cleanup_failed=true
    fi
    if [[ -n "$source_id" ]]; then
      remaining="$(smoke_compose exec -T db sh -c 'mariadb -u root -p"$(cat /run/secrets/db_root_password)" "$MARIADB_DATABASE" -N -B -e "SELECT COUNT(*) FROM monitoring_sources WHERE source_id = '\''$1'\''"' verify "$source_id")"
      if [[ "$remaining" != 0 ]]; then
        printf '%s\n' "FAIL: smoke source remains after cleanup" >&2
        cleanup_failed=true
      fi
    fi
    if ! smoke_compose down --volumes --remove-orphans; then
      printf '%s\n' "FAIL: isolated Compose teardown failed" >&2
      cleanup_failed=true
    fi
  fi
  [[ -z "$runtime_dir" ]] || rm -rf "$runtime_dir"
  [[ "$status" -ne 0 ]] && exit "$status"
  [[ "$cleanup_failed" == true ]] && exit 1
}
run_smoke_client() {
  local client_pid

  smoke_compose run --rm --no-deps \
    -e SMOKE_DEFER_SOURCE_CLEANUP=true \
    smoke-client bash /workspace/tests/smoke/run.sh &
  client_pid=$!

  while kill -0 "$client_pid" 2>/dev/null; do
    if [[ -f "$client_runtime_dir/interrupt-worker" &&
      ! -f "$client_runtime_dir/interrupt-complete" ]]; then
      smoke_compose stop worker >/dev/null
      sleep "$(( ${SMOKE_WORKER_LEASE_SECONDS:-2} + 2 ))"
      smoke_compose start worker >/dev/null
      touch "$client_runtime_dir/interrupt-complete"
    fi
    sleep 1
  done

  wait "$client_pid" || return $?
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/chromat-smoke.XXXXXX")"; chmod 700 "$runtime_dir"
client_runtime_dir="$runtime_dir/client"; mkdir -m 700 "$client_runtime_dir" "$client_runtime_dir/tmp"
run_id="$(node -e 'console.log(crypto.randomUUID())')"; project_name="chromat-smoke-${run_id//-/}"
umask 077
for secret in db_password db_root_password operator_password telegram_bot_token; do head -c 32 /dev/urandom | base64 >"$runtime_dir/$secret"; done
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$runtime_dir/server.key" -out "$runtime_dir/server.crt" -addext 'subjectAltName=DNS:nginx,DNS:localhost' -subj '/CN=nginx' >/dev/null 2>&1
cat >"$runtime_dir/compose.env" <<EOF
CHROMAT_DB_IMAGE=mariadb:11.8.2
CHROMAT_API_IMAGE=chromat-smoke-api:$run_id
CHROMAT_INFERENCE_IMAGE=chromat-smoke-inference:$run_id
DB_NAME=chromat_smoke
DB_USER=chromat_smoke
DB_PASSWORD_HOST_FILE=$runtime_dir/db_password
DB_ROOT_PASSWORD_HOST_FILE=$runtime_dir/db_root_password
OPERATOR_PASSWORD_HOST_FILE=$runtime_dir/operator_password
TELEGRAM_BOT_TOKEN_HOST_FILE=$runtime_dir/telegram_bot_token
TLS_CERT_HOST_PATH=$runtime_dir/server.crt
TLS_KEY_HOST_PATH=$runtime_dir/server.key
SMOKE_ADMIN_USERNAME=smoke-admin-$run_id
SMOKE_SOURCE_NAME=smoke-source-$run_id
SMOKE_CLIENT_RUNTIME_DIR=$client_runtime_dir
SMOKE_CLIENT_UID=$(id -u)
SMOKE_CLIENT_GID=$(id -g)
EOF
export SMOKE_COMPOSE_FILE="$repo_root/tests/smoke/compose.isolated.yaml" SMOKE_COMPOSE_PROJECT="$project_name" SMOKE_COMPOSE_ENV_FILE="$runtime_dir/compose.env"
stack_started=true
smoke_compose up --build --wait --wait-timeout 120 db api worker inference telegram-stub telegram-worker nginx
smoke_compose run --rm --no-deps operator-bootstrap >/dev/null
smoke_compose run --rm --no-deps smoke-client bash -c 'getent hosts nginx && curl --fail --cacert /runtime/server.crt https://nginx/health/ready'
smoke_compose run --rm --no-deps smoke-client bash /workspace/tests/smoke/client-bootstrap.sh
source "$client_runtime_dir/source.env"; source_id="$SMOKE_SOURCE_ID"
bash "$repo_root/tests/smoke/migrations.sh"
run_smoke_client
