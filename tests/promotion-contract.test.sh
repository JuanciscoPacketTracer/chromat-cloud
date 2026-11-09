#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runbook="$repo_root/docs/deployment/promotion.md"

test -x "$repo_root/tests/smoke/aggregation.sh"
test -x "$repo_root/tests/smoke/migrations.sh"
grep -q 'aggregation' "$repo_root/tests/smoke/run.sh"
grep -q 'migrations' "$repo_root/tests/smoke/run.sh"

for required_phrase in \
  "backup" \
  "verific" \
  "migracion" \
  "readiness" \
  "smoke" \
  "apertura" \
  "rollback" \
  "down-migration" \
  "telegram" \
  "CA_CERT" \
  "idempot" \
  "capacidad" \
  "agreg" \
  "limpieza"; do
  grep -qi "$required_phrase" "$runbook"
done

if output="$(
  env -u CA_CERT -u ALLOW_INSECURE_TLS \
    bash "$repo_root/tests/smoke/run.sh" 2>&1
)"; then
  printf 'FAIL: smoke runner accepted missing CA_CERT\n' >&2
  exit 1
fi
grep -q 'CA_CERT' <<<"$output"

printf 'PASS: promotion contract\n'
