#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  printf 'Usage: %s <artifact-package-directory>\n' "${0##*/}" >&2
}

package_dir="${1:-}"
if [[ -z "$package_dir" || "${1:-}" == "--help" ]]; then
  usage
  [[ "${1:-}" == "--help" ]] && exit 0
  exit 2
fi
[[ -d "$package_dir" ]] || {
  printf 'artifact package directory does not exist: %s\n' "$package_dir" >&2
  exit 1
}
command -v python3 >/dev/null || {
  printf 'python3 is required\n' >&2
  exit 1
}
command -v docker >/dev/null || {
  printf 'docker is required\n' >&2
  exit 1
}

manifest="$package_dir/manifest.json"
[[ -f "$manifest" ]] || {
  printf 'artifact package is missing manifest.json\n' >&2
  exit 1
}

image_records="$(
  python3 - "$manifest" <<'PY'
import json
import sys

manifest = json.loads(open(sys.argv[1], encoding="utf-8").read())
images = manifest.get("images")
auxiliary_images = manifest.get("auxiliary_images")
if not isinstance(images, list) or not isinstance(auxiliary_images, list):
    raise SystemExit("manifest must contain images and auxiliary_images lists")
records = images + auxiliary_images
if not records:
    raise SystemExit("manifest must contain image records")
for image in records:
    if not isinstance(image, dict):
        raise SystemExit("manifest image entries must be objects")
    fields = (image.get("name"), image.get("archive"),
              image.get("id"), image.get("architecture"),
              image.get("config_digest", image.get("id")))
    if not all(isinstance(field, str) and field for field in fields):
        raise SystemExit("manifest image entries must include name, archive, id, architecture, and config_digest")
    print("\t".join(fields))
PY
)"
[[ -n "$image_records" ]] || {
  printf 'manifest contains no image records\n' >&2
  exit 1
}

while IFS=$'\t' read -r name archive expected_id expected_architecture expected_config_digest; do
  [[ -n "$name" ]] || continue
  archive_path="$package_dir/$archive"
  [[ -f "$archive_path" ]] || {
    printf 'image archive is missing: %s\n' "$archive" >&2
    exit 1
  }
  docker load --input "$archive_path" >/dev/null
  read -r actual_id actual_architecture < <(
    docker image inspect --format '{{.Id}} {{.Architecture}}' "$name"
  ) || {
    printf 'loaded image is unavailable: %s\n' "$name" >&2
    exit 1
  }
  if [[ "$actual_id" != "$expected_id" ]]; then
    printf 'image ID does not match manifest for %s: %s != %s\n' \
      "$name" "$actual_id" "$expected_id" >&2
    exit 1
  fi
  if [[ "$name" == "busybox:1.36.1" && "$actual_id" != "$expected_config_digest" ]]; then
    printf 'BusyBox image ID does not match manifest config digest: %s != %s\n' \
      "$actual_id" "$expected_config_digest" >&2
    exit 1
  fi
  if [[ "$actual_architecture" != "$expected_architecture" ]]; then
    printf 'image architecture does not match manifest for %s: %s != %s\n' \
      "$name" "$actual_architecture" "$expected_architecture" >&2
    exit 1
  fi
done <<<"$image_records"

printf 'PASS: image archives match manifest: %s\n' "$package_dir"
