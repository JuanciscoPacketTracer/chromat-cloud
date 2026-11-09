#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="$repo_root/tests/smoke/run.sh"

[[ -x "$runner" ]]
grep -q -- "--help" "$runner"
"$runner" --help >/dev/null
