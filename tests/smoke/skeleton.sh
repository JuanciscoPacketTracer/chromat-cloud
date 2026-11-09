#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -f compose.yaml ]] || fail "compose.yaml is missing"
[[ -f nginx/conf.d/default.conf ]] || fail "Nginx configuration is missing"
[[ -f api/Dockerfile ]] || fail "API Dockerfile is missing"
[[ -f api/package.json ]] || fail "API package manifest is missing"
[[ -f api/src/server.js ]] || fail "API server is missing"
[[ -f db/migrations/001_initial.sql ]] || fail "initial migration is missing"
[[ -f db/migrations/002_processing.sql ]] || fail "processing migration is missing"
[[ -f db/migrations/004_admin_auth.sql ]] || fail "admin migration is missing"
[[ -f db/migrations/006_source_access.sql ]] || fail "source access migration is missing"
[[ -f db/migrations/011_aggregated_state_history.sql ]] || fail "aggregated history migration is missing"
[[ -f db/migrations/012_alerts.sql ]] || fail "alerts migration is missing"
[[ -f api/src/worker.js ]] || fail "worker is missing"
[[ -f api/src/create-operator.js ]] || fail "operator command is missing"
[[ -f inference/server.py ]] || fail "inference service is missing"
[[ -f inference/Dockerfile ]] || fail "inference Dockerfile is missing"
[[ -f inference/models/deterministic-model.json ]] || fail "deterministic model is missing"
[[ -f tests/smoke/processing.sh ]] || fail "processing smoke test is missing"
[[ -f tests/smoke/inference.sh ]] || fail "inference smoke test is missing"
[[ -f tests/smoke/aggregation.sh ]] || fail "aggregation smoke test is missing"
[[ -f tests/smoke/migrations.sh ]] || fail "migration smoke test is missing"
[[ -f tests/smoke/admin-auth.sh ]] || fail "admin auth smoke test is missing"
[[ -f tests/smoke/source-management.sh ]] || fail "source management smoke test is missing"
[[ -x tests/smoke/run.sh ]] || fail "smoke test runner is missing or not executable"
[[ -f tests/smoke/curl.sh ]] || fail "smoke curl helper is missing"
[[ -f scripts/dev-tls.sh ]] || fail "development TLS script is missing"

compose_config="$(mktemp)"
trap 'rm -f "$compose_config"' EXIT

docker compose --env-file .env.example config >"$compose_config"

grep -q '^  nginx:' "$compose_config" || fail "nginx service is missing"
grep -q '^  api:' "$compose_config" || fail "api service is missing"
grep -q '^  worker:' "$compose_config" || fail "worker service is missing"
grep -q '^  inference:' "$compose_config" || fail "inference service is missing"
grep -q '^  db:' "$compose_config" || fail "db service is missing"
grep -q '^  edge:' "$compose_config" || fail "edge network is missing"
grep -q '^  internal:' "$compose_config" || fail "internal network is missing"
grep -q 'target: 443' "$compose_config" || fail "Nginx HTTPS port is not published"

if grep -A8 '^  api:' "$compose_config" | grep -q 'published:'; then
  fail "API must not publish a host port"
fi

if grep -A12 '^  db:' "$compose_config" | grep -q 'published:'; then
  fail "MariaDB must not publish a host port"
fi

grep -q 'healthcheck:' "$compose_config" || fail "health checks are missing"
grep -q '/etc/nginx/tls/server.crt' "$compose_config" || fail "development certificate is not mounted"
grep -q '/health/ready' "$compose_config" || fail "API readiness is not checked"
grep -q '/docker-entrypoint-initdb.d' "$compose_config" || fail "database migrations are not mounted"

printf 'PASS: CHROMAT Server skeleton contract\n'
