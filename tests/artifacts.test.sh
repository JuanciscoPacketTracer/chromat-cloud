#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$repo_root/scripts/verify-artifacts.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

package_dir="$tmp_dir/package"
mkdir -p "$package_dir/images" "$package_dir/model"
printf 'model\n' >"$package_dir/model/model.bin"
printf 'image\n' >"$package_dir/images/api.tar"
sha256sum "$package_dir/model/model.bin" "$package_dir/images/api.tar" \
  | sed "s#${package_dir}/##" >"$package_dir/checksums.sha256"
model_sha256="$(sha256sum "$package_dir/model/model.bin" | cut -d' ' -f1)"
cat >"$package_dir/manifest.json" <<'EOF'
{
  "package_version": "test-1",
  "target_platform": "linux/amd64",
  "target_ubuntu_version": "26.04",
  "pull_policy": "never",
  "model_sha256": "__MODEL_SHA256__",
  "images": [
    {"name": "chromat-api:test-1", "archive": "images/api.tar"}
  ]
}
EOF
sed -i "s/__MODEL_SHA256__/$model_sha256/" "$package_dir/manifest.json"
printf 'PULL_POLICY=never\n' >"$package_dir/production.env.example"

"$verifier" "$package_dir"

printf 'tampered\n' >"$package_dir/images/api.tar"
if "$verifier" "$package_dir" >/dev/null 2>&1; then
  printf 'expected checksum verification to fail\n' >&2
  exit 1
fi

printf 'PASS: artifact package verification contract\n'
