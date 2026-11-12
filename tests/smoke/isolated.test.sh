#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
compose_helper="$repo_root/tests/smoke/compose.sh"
isolated_compose="$repo_root/tests/smoke/compose.isolated.yaml"
isolated_runner="$repo_root/tests/smoke/isolated.sh"

[[ -x "$isolated_runner" ]]
bash -n "$compose_helper" "$isolated_runner" "$repo_root/tests/smoke/client-bootstrap.sh" \
  "$repo_root/tests/smoke/client-cleanup.sh" "$repo_root/tests/smoke/client-entrypoint.sh" \
  "$repo_root/tests/smoke/run.sh"
grep -q 'docker compose "$@"' "$compose_helper"
grep -q -- '--project-name "$SMOKE_COMPOSE_PROJECT"' "$compose_helper"
grep -q 'TELEGRAM_API_URL: http://telegram-stub:8080' "$isolated_compose"
! grep -q 'api.telegram.org' "$isolated_compose"
! grep -q 'ports:' "$isolated_compose"
! grep -q 'network_mode: host' "$isolated_compose"
! grep -q '/var/run/docker.sock' "$isolated_compose"
grep -q 'smoke-client:' "$isolated_compose"
grep -q 'BASE_URL: https://nginx' "$isolated_compose"
grep -q 'SMOKE_TESTS: ${SMOKE_TESTS:-all}' "$isolated_compose"
grep -q 'user: "${SMOKE_CLIENT_UID}:${SMOKE_CLIENT_GID}"' "$isolated_compose"
grep -q './:/workspace/tests/smoke:ro' "$isolated_compose"
grep -q ':/runtime/server.crt:ro' "$isolated_compose"
grep -q ':/runtime/operator_password:ro' "$isolated_compose"
! grep -q '${SMOKE_RUNTIME_DIR}:/runtime' "$isolated_compose"
! grep -q -- '--no-check-certificate' "$isolated_compose"
grep -q 'trap cleanup EXIT' "$isolated_runner"
grep -q "trap 'exit 130' INT" "$isolated_runner"
grep -q "trap 'exit 143' TERM" "$isolated_runner"
grep -q 'down --volumes --remove-orphans' "$isolated_runner"
grep -q 'client-cleanup.sh' "$isolated_runner"
grep -q 'smoke_compose stop worker' "$isolated_runner"
grep -q -- '-e SMOKE_DEFER_SOURCE_CLEANUP=true' "$isolated_runner"

printf 'PASS: isolated smoke harness contract\n'
