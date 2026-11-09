#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/tests/smoke/curl.sh"
base_url="${BASE_URL:-https://localhost}"
selected_tests="${SMOKE_TESTS:-admin-auth}"

usage() {
  cat <<'EOF'
Usage: tests/smoke/run.sh [--help]

Run end-to-end smoke tests against an already-running CHROMAT deployment.

Required environment:
  ADMIN_USERNAME, ADMIN_PASSWORD

Optional environment:
  BASE_URL       Public HTTPS URL (default: https://localhost)
  CA_CERT        CA certificate used to verify the public HTTPS endpoint
  ALLOW_INSECURE_TLS=true
                 Explicitly allow self-signed certificates for local-only runs
  SMOKE_TESTS    Comma-separated scenarios or "all"
                 ingestion,processing,inference,admin-auth,source-management
EOF
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || fail "unknown argument: $1"

command -v curl >/dev/null || fail "curl is required"
command -v docker >/dev/null || fail "docker is required"
command -v node >/dev/null || fail "node is required"
if [[ "${ALLOW_INSECURE_TLS:-false}" != "true" ]]; then
  [[ -f "${CA_CERT:-}" ]] || fail "CA_CERT must point to the deployment CA certificate"
fi

smoke_curl --silent --show-error --fail "$base_url/health/live" >/dev/null ||
  fail "public liveness check failed: $base_url/health/live"
smoke_curl --silent --show-error --fail "$base_url/health/ready" >/dev/null ||
  fail "public readiness check failed: $base_url/health/ready"

bash "$repo_root/tests/smoke/skeleton.sh"

if [[ "$selected_tests" == "all" ]]; then
  selected_tests="ingestion,processing,inference,admin-auth,source-management"
fi

IFS=',' read -r -a tests <<<"$selected_tests"
for test_name in "${tests[@]}"; do
  case "$test_name" in
    ingestion)
      : "${SMOKE_SOURCE_API_KEY:?SMOKE_SOURCE_API_KEY is required for ingestion}"
      : "${FOREIGN_EVENT_ID:?FOREIGN_EVENT_ID is required for ingestion}"
      ;;
    processing|inference)
      : "${SMOKE_SOURCE_API_KEY:?SMOKE_SOURCE_API_KEY is required for $test_name}"
      ;;
    admin-auth|source-management)
      : "${ADMIN_USERNAME:?ADMIN_USERNAME is required for $test_name}"
      : "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required for $test_name}"
      ;;
    "")
      fail "empty smoke test name"
      ;;
    *)
      fail "unknown smoke test: $test_name"
      ;;
  esac

  printf 'RUN: %s\n' "$test_name"
  BASE_URL="$base_url" bash "$repo_root/tests/smoke/$test_name.sh"
done

printf 'PASS: CHROMAT end-to-end smoke suite\n'
