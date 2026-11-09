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
command -v sha256sum >/dev/null || {
  printf 'sha256sum is required\n' >&2
  exit 1
}

manifest="$package_dir/manifest.json"
checksums="$package_dir/checksums.sha256"
production_env="$package_dir/production.env.example"
[[ -f "$manifest" && -f "$checksums" && -f "$production_env" ]] || {
  printf 'artifact package is missing manifest, checksums, or production.env.example\n' >&2
  exit 1
}
for required_path in \
  scripts/backup.sh \
  scripts/check-tls-expiry.sh \
  scripts/verify-artifacts.sh \
  scripts/verify-backup.sh \
  tests/smoke/run.sh \
  docs/deployment/promotion.md; do
  [[ -f "$package_dir/$required_path" ]] || {
    printf 'artifact package is missing operational file: %s\n' "$required_path" >&2
    exit 1
  }
done

python3 - "$manifest" "$package_dir" "$production_env" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
package_dir = pathlib.Path(sys.argv[2]).resolve()
production_env = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

required = (
    "package_version",
    "target_platform",
    "target_ubuntu_version",
    "pull_policy",
    "model_sha256",
)
missing = [key for key in required if not manifest.get(key)]
if missing:
    raise SystemExit(f"manifest missing required fields: {', '.join(missing)}")
if manifest["target_platform"] != "linux/amd64":
    raise SystemExit("manifest target_platform must be linux/amd64")
if manifest["pull_policy"] != "never":
    raise SystemExit("manifest pull_policy must be never")
if "PULL_POLICY=never" not in production_env.splitlines():
    raise SystemExit("production.env.example must set PULL_POLICY=never")
images = manifest.get("images")
if not isinstance(images, list) or not images:
    raise SystemExit("manifest must list exported images")
for image in images:
    archive = image.get("archive")
    if not archive:
        raise SystemExit("manifest image is missing archive")
    resolved_archive = (package_dir / archive).resolve()
    if package_dir not in resolved_archive.parents or not resolved_archive.is_file():
        raise SystemExit(f"image archive is missing: {archive}")

model_path = pathlib.Path(manifest.get("model_path", "model/model.bin"))
resolved_model = (package_dir / model_path).resolve()
if package_dir not in resolved_model.parents:
    raise SystemExit("manifest model_path escapes the package")
if not resolved_model.is_file():
    raise SystemExit(f"model artifact is missing: {model_path}")

for path in package_dir.rglob("*"):
    if path.is_file() and path.name.lower() in {
        ".env",
        "server.key",
        "ca.key",
        "telegram_bot_token",
    }:
        raise SystemExit(f"secret-like file found in package: {path.relative_to(package_dir)}")
PY

(cd "$package_dir" && sha256sum --check --strict checksums.sha256)
printf 'PASS: artifact package verified: %s\n' "$package_dir"
