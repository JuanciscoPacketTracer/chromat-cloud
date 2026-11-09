#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

source_dir="$work_dir/source"
installed_dir="$work_dir/installed"
mkdir -p "$source_dir"
umask 077

openssl ecparam -name prime256v1 -genkey -noout -out "$work_dir/ca.key"
openssl req -x509 -new -sha256 -days 3650 \
  -key "$work_dir/ca.key" \
  -out "$source_dir/ca.crt" \
  -subj "/CN=CHROMAT Test CA"
openssl ecparam -name prime256v1 -genkey -noout -out "$source_dir/server.key"
openssl req -new -sha256 \
  -key "$source_dir/server.key" \
  -out "$work_dir/server.csr" \
  -subj "/CN=chromat.lan"
cat >"$work_dir/server.ext" <<'EOF'
subjectAltName=DNS:chromat.lan,IP:192.0.2.10
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -sha256 -days 365 \
  -in "$work_dir/server.csr" \
  -CA "$source_dir/ca.crt" \
  -CAkey "$work_dir/ca.key" \
  -CAcreateserial -CAserial "$work_dir/ca.srl" \
  -out "$source_dir/server.crt" \
  -extfile "$work_dir/server.ext" >/dev/null 2>&1

if bash "$repo_root/scripts/install-production-tls.sh" \
  "$source_dir" "$installed_dir" 192.0.2.10; then
  :
else
  printf 'FAIL: valid production TLS materials were rejected\n' >&2
  exit 1
fi

test -f "$installed_dir/server.crt"
test -f "$installed_dir/server.key"
test -f "$installed_dir/ca.crt"
test "$(stat -c '%a' "$installed_dir/server.key")" = 600
test "$(stat -c '%a' "$installed_dir/server.crt")" = 644
test "$(stat -c '%a' "$installed_dir/ca.crt")" = 644
openssl verify -CAfile "$installed_dir/ca.crt" "$installed_dir/server.crt" >/dev/null
server_inode="$(stat -c '%i' "$installed_dir/server.crt")"
bash "$repo_root/scripts/install-production-tls.sh" \
  "$source_dir" "$installed_dir" 192.0.2.10 >/dev/null
test "$(stat -c '%i' "$installed_dir/server.crt")" = "$server_inode"

if bash "$repo_root/scripts/check-tls-expiry.sh" "$installed_dir/server.crt" 30; then
  :
else
  printf 'FAIL: certificate with sufficient lifetime was rejected\n' >&2
  exit 1
fi
if bash "$repo_root/scripts/check-tls-expiry.sh" "$installed_dir/server.crt" 400; then
  printf 'FAIL: expiry check accepted a certificate inside the threshold\n' >&2
  exit 1
fi

if bash "$repo_root/scripts/install-production-tls.sh" \
  "$source_dir" "$work_dir/invalid-san" 192.0.2.11; then
  printf 'FAIL: certificate with missing expected IP SAN was accepted\n' >&2
  exit 1
fi

cp "$work_dir/ca.key" "$source_dir/ca.key"
if bash "$repo_root/scripts/install-production-tls.sh" \
  "$source_dir" "$work_dir/secret-material" 192.0.2.10; then
  printf 'FAIL: CA private key was accepted as an installation material\n' >&2
  exit 1
fi

printf 'PASS: production TLS installation and expiry contract\n'
