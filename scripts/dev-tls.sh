#!/usr/bin/env bash
set -euo pipefail

output_dir="${1:-certs/dev}"
vm_ip="${CHROMAT_VM_IP:-127.0.0.1}"
mkdir -p "$output_dir"
umask 077

openssl ecparam -name prime256v1 -genkey -noout \
  -out "$output_dir/ca.key"
openssl req -x509 -new -sha256 -days 3650 \
  -key "$output_dir/ca.key" \
  -out "$output_dir/ca.crt" \
  -subj "/CN=CHROMAT Development CA"

openssl ecparam -name prime256v1 -genkey -noout \
  -out "$output_dir/server.key"
openssl req -new -sha256 \
  -key "$output_dir/server.key" \
  -out "$output_dir/server.csr" \
  -subj "/CN=chromat.lan"

san_file="$(mktemp)"
trap 'rm -f "$san_file"' EXIT
cat >"$san_file" <<'EOF'
subjectAltName=DNS:chromat.lan,DNS:localhost,IP:__VM_IP__
extendedKeyUsage=serverAuth
EOF
sed -i "s/__VM_IP__/$vm_ip/" "$san_file"

openssl x509 -req -sha256 -days 365 \
  -in "$output_dir/server.csr" \
  -CA "$output_dir/ca.crt" \
  -CAkey "$output_dir/ca.key" \
  -CAcreateserial \
  -out "$output_dir/server.crt" \
  -extfile "$san_file"

rm -f "$output_dir/server.csr" "$output_dir/ca.srl"
chmod 600 "$output_dir/ca.key" "$output_dir/server.key"
chmod 644 "$output_dir/ca.crt" "$output_dir/server.crt"
printf 'Development certificates written to %s\n' "$output_dir"
