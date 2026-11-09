#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'Usage: %s CERTIFICATE [DAYS]\n' "$0" >&2
  exit 2
fi

certificate="$(realpath -e -- "$1")"
days="${2:-30}"
if ! [[ "$days" =~ ^[0-9]+$ ]]; then
  printf 'DAYS must be a non-negative integer\n' >&2
  exit 2
fi
command -v openssl >/dev/null || {
  printf 'openssl is required\n' >&2
  exit 2
}

seconds="$((days * 86400))"
expiry="$(openssl x509 -in "$certificate" -enddate -noout | cut -d= -f2-)"
if openssl x509 -in "$certificate" -checkend "$seconds" -noout >/dev/null; then
  printf 'PASS: certificate valid beyond %s days (expires %s)\n' "$days" "$expiry"
else
  printf 'FAIL: certificate expires within %s days (expires %s)\n' "$days" "$expiry" >&2
  exit 1
fi
