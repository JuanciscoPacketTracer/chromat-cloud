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
[[ -f api/src/worker.js ]] || fail "worker is missing"
[[ -f tests/smoke/processing.sh ]] || fail "processing smoke test is missing"
[[ -f scripts/dev-tls.sh ]] || fail "development TLS script is missing"

compose_config="$(mktemp)"
trap 'rm -f "$compose_config"' EXIT

docker compose --env-file .env.example config >"$compose_config"

grep -q '^  nginx:' "$compose_config" || fail "nginx service is missing"
grep -q '^  api:' "$compose_config" || fail "api service is missing"
grep -q '^  worker:' "$compose_config" || fail "worker service is missing"
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
