#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s SOURCE_DIR DEST_DIR EXPECTED_IP [EXPECTED_IP...]\n' "$0" >&2
}

if [[ $# -lt 3 ]]; then
  usage
  exit 2
fi

source_dir="$(realpath -e -- "$1")"
destination_dir="$(realpath -m -- "$2")"
shift 2

[[ -d "$source_dir" ]] || {
  printf 'TLS source directory does not exist: %s\n' "$source_dir" >&2
  exit 2
}
command -v openssl >/dev/null || {
  printf 'openssl is required\n' >&2
  exit 2
}

required_files=(ca.crt server.crt server.key)
for file in "${required_files[@]}"; do
  [[ -f "$source_dir/$file" ]] || {
    printf 'missing TLS material: %s\n' "$file" >&2
    exit 2
  }
done

while IFS= read -r entry; do
  case "$entry" in
    ca.crt|server.crt|server.key) ;;
    *)
      printf 'unexpected TLS material: %s\n' "$entry" >&2
      exit 2
      ;;
  esac
done < <(find "$source_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)

if find "$source_dir" -mindepth 1 -maxdepth 1 ! -type f -print -quit | grep -q .; then
  printf 'TLS source directory may contain only regular certificate files\n' >&2
  exit 2
fi

openssl x509 -in "$source_dir/server.crt" -noout >/dev/null
openssl x509 -in "$source_dir/ca.crt" -noout >/dev/null
openssl pkey -in "$source_dir/server.key" -noout >/dev/null
openssl verify -CAfile "$source_dir/ca.crt" "$source_dir/server.crt" >/dev/null

openssl x509 -in "$source_dir/server.crt" -checkhost chromat.lan -noout >/dev/null || {
  printf 'server.crt must contain DNS SAN chromat.lan\n' >&2
  exit 2
}
for expected_ip in "$@"; do
  openssl x509 -in "$source_dir/server.crt" -checkip "$expected_ip" -noout >/dev/null || {
    printf 'server.crt is missing expected IP SAN: %s\n' "$expected_ip" >&2
    exit 2
  }
done

cert_public_key="$(
  openssl x509 -in "$source_dir/server.crt" -pubkey -noout |
    openssl pkey -pubin -outform DER |
    sha256sum
)"
key_public_key="$(
  openssl pkey -in "$source_dir/server.key" -pubout -outform DER |
    sha256sum
)"
[[ "$cert_public_key" == "$key_public_key" ]] || {
  printf 'server.key does not match server.crt\n' >&2
  exit 2
}

umask 077
mkdir -p -- "$destination_dir"
for file in "${required_files[@]}"; do
  install_mode=0644
  [[ "$file" == server.key ]] && install_mode=0600
  if [[ -f "$destination_dir/$file" ]]; then
    cat "$source_dir/$file" >"$destination_dir/$file"
    chmod "$install_mode" "$destination_dir/$file"
  else
    install -m "$install_mode" "$source_dir/$file" "$destination_dir/$file"
  fi
done

printf 'Production TLS materials installed in %s\n' "$destination_dir"
