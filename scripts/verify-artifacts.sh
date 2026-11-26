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
  .env.example \
  compose.yaml \
  model/deterministic-model.json \
  nginx/conf.d/default.conf \
  web/public/app.js \
  web/public/index.html \
  web/public/styles.css \
  db/migrations/001_initial.sql \
  db/migrations/002_processing.sql \
  db/migrations/003_processing_constraints.sql \
  db/migrations/004_admin_auth.sql \
  db/migrations/005_source_management.sql \
  db/migrations/006_source_access.sql \
  db/migrations/007_retention.sql \
  db/migrations/008_raw_tombstones.sql \
  db/migrations/009_aggregated_state.sql \
  db/migrations/010_aggregation_rule_audit.sql \
  db/migrations/011_aggregated_state_history.sql \
  db/migrations/012_alerts.sql \
  db/migrations/013_alert_interval.sql \
  db/migrations/014_manual_reprocessing.sql \
  db/migrations/015_raw_file_finalization.sql \
  db/migrations/016_job_event_uniqueness.sql \
  scripts/backup.sh \
  scripts/check-tls-expiry.sh \
  scripts/install-production-tls.sh \
  scripts/prepare-ubuntu-production-host.sh \
  scripts/recover-release-links.sh \
  scripts/retention.sh \
  scripts/verify-artifacts.sh \
  scripts/verify-image-artifacts.sh \
  scripts/lib/image-identity.py \
  scripts/lib/source-provenance.py \
  scripts/verify-production-environment.sh \
  scripts/verify-backup.sh \
  tests/smoke/admin-auth.sh \
  tests/smoke/aggregation.sh \
  tests/smoke/capacity.sh \
  tests/smoke/client-bootstrap.sh \
  tests/smoke/client-cleanup.sh \
  tests/smoke/client-entrypoint.sh \
  tests/smoke/compose.isolated.yaml \
  tests/smoke/compose.sh \
  tests/smoke/curl.sh \
  tests/smoke/Dockerfile \
  tests/smoke/inference.sh \
  tests/smoke/ingestion.sh \
  tests/smoke/isolated.sh \
  tests/smoke/isolated.test.sh \
  tests/smoke/migrations.sh \
  tests/smoke/processing.sh \
  tests/smoke/runner.test.sh \
  tests/smoke/run.sh \
  tests/smoke/skeleton.sh \
  tests/smoke/source-management.sh \
  tests/smoke/telegram.sh \
  tests/smoke/telegram-stub.conf \
  docs/deployment/artifacts.md \
  docs/deployment/backups.md \
  docs/deployment/promotion.md \
  docs/deployment/tls.md \
  docs/installation/requisitos.md \
  docs/installation/ubuntu-server-26.04.md; do
  [[ -f "$package_dir/$required_path" ]] || {
    printf 'artifact package is missing operational file: %s\n' "$required_path" >&2
    exit 1
  }
  if [[ "$required_path" == scripts/*.sh && ! -x "$package_dir/$required_path" ]]; then
    printf 'artifact package operational script is not executable: %s\n' "$required_path" >&2
    exit 1
  fi
done
backup_config="$package_dir/scripts/lib/backup-config.sh"
[[ -f "$backup_config" && ! -L "$backup_config" && -r "$backup_config" ]] || {
  printf 'artifact package is missing readable backup configuration library\n' >&2
  exit 1
}
[[ "$(stat -c %a -- "$backup_config")" == 644 ]] || {
  printf 'artifact package backup configuration library must have mode 0644\n' >&2
  exit 1
}
for required_image in \
  images/api.tar images/inference.tar images/db.tar images/nginx.tar \
  images/busybox.tar; do
  [[ -f "$package_dir/$required_image" ]] || {
    printf 'artifact package is missing image archive: %s\n' "$required_image" >&2
    exit 1
  }
done

python3 - "$manifest" "$package_dir" "$production_env" <<'PY'
import json
import hashlib
import pathlib
import re
import sys

manifest_path = pathlib.Path(sys.argv[1])
package_dir = pathlib.Path(sys.argv[2]).resolve()
production_env = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit(f"manifest is not valid JSON: {error}")
if not isinstance(manifest, dict):
    raise SystemExit("manifest root must be an object")

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
if not isinstance(images, list) or len(images) != 4:
    raise SystemExit("manifest must list exactly four exported images")
required_archives = {
    "images/api.tar",
    "images/inference.tar",
    "images/db.tar",
    "images/nginx.tar",
}
archives = set()
for image in images:
    if not isinstance(image, dict):
        raise SystemExit("manifest image entries must be objects")
    archive = image.get("archive")
    if not isinstance(archive, str) or not archive:
        raise SystemExit("manifest image is missing archive")
    if archive in archives:
        raise SystemExit(f"manifest lists image archive more than once: {archive}")
    archives.add(archive)
if archives != required_archives:
    raise SystemExit("manifest must list every required image archive")
for image in images:
    archive = image.get("archive")
    resolved_archive = (package_dir / archive).resolve()
    if package_dir not in resolved_archive.parents or not resolved_archive.is_file():
        raise SystemExit(f"image archive is missing: {archive}")

auxiliary_images = manifest.get("auxiliary_images")
if not isinstance(auxiliary_images, list) or len(auxiliary_images) != 1:
    raise SystemExit("manifest must list exactly one auxiliary image")
auxiliary = auxiliary_images[0]
if not isinstance(auxiliary, dict):
    raise SystemExit("manifest auxiliary image entry must be an object")
if auxiliary.get("name") != "busybox:1.36.1":
    raise SystemExit("manifest auxiliary image must be busybox:1.36.1")
if auxiliary.get("archive") != "images/busybox.tar":
    raise SystemExit("manifest auxiliary image must use images/busybox.tar")
auxiliary_id = auxiliary.get("id")
if not isinstance(auxiliary_id, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", auxiliary_id):
    raise SystemExit("manifest auxiliary image id must be a SHA-256 image ID")
expected_busybox_index_digest = (
    "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662"
)
expected_busybox_platform_digest = (
    "sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f"
)
expected_busybox_config_digest = (
    "sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d"
)
source_reference = auxiliary.get("source_reference")
if source_reference != (
    "docker.io/library/busybox@"
    + expected_busybox_platform_digest
):
    raise SystemExit("manifest auxiliary image must use the pinned BusyBox platform reference")
if auxiliary.get("index_digest") != expected_busybox_index_digest:
    raise SystemExit("manifest auxiliary image index digest is not pinned")
if auxiliary.get("platform_digest") != expected_busybox_platform_digest:
    raise SystemExit("manifest auxiliary image platform digest is not pinned")
if auxiliary.get("config_digest") != expected_busybox_config_digest:
    raise SystemExit("manifest auxiliary image config digest is not pinned")
if auxiliary.get("architecture") != "amd64":
    raise SystemExit("manifest auxiliary image architecture must be amd64")
repo_digests = auxiliary.get("repo_digests")
if not isinstance(repo_digests, list) or not repo_digests or not all(
    isinstance(digest, str)
    and digest.rsplit("@", 1)[0]
    in {"busybox", "docker.io/library/busybox", "index.docker.io/library/busybox"}
    and digest.rsplit("@", 1)[-1].startswith("sha256:")
    for digest in repo_digests
):
    raise SystemExit("manifest auxiliary image must include a busybox repository digest")
resolved_auxiliary_archive = (
    package_dir / auxiliary["archive"]
).resolve()
if (
    package_dir not in resolved_auxiliary_archive.parents
    or not resolved_auxiliary_archive.is_file()
):
    raise SystemExit("auxiliary image archive is missing: images/busybox.tar")

model_path_value = manifest.get("model_path", "model/deterministic-model.json")
if not isinstance(model_path_value, str) or not model_path_value:
    raise SystemExit("manifest model_path must be a non-empty string")
model_path = pathlib.Path(model_path_value)
resolved_model = (package_dir / model_path).resolve()
if package_dir not in resolved_model.parents:
    raise SystemExit("manifest model_path escapes the package")
if not resolved_model.is_file():
    raise SystemExit(f"model artifact is missing: {model_path}")
model_sha256 = manifest["model_sha256"]
if not isinstance(model_sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", model_sha256):
    raise SystemExit("manifest model_sha256 must be a lowercase SHA-256 digest")
digest = hashlib.sha256()
with resolved_model.open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
if digest.hexdigest() != model_sha256:
    raise SystemExit(f"model SHA-256 does not match manifest: {model_path}")

for path in package_dir.rglob("*"):
    if path.is_file() and path.name.lower() in {
        ".env",
        "server.key",
        "ca.key",
        "telegram_bot_token",
    }:
        raise SystemExit(f"secret-like file found in package: {path.relative_to(package_dir)}")
PY

python3 "$(dirname "${BASH_SOURCE[0]}")/lib/source-provenance.py" verify-package "$package_dir"
python3 "$(dirname "${BASH_SOURCE[0]}")/lib/image-identity.py" \
  "$package_dir/images/busybox.tar" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["auxiliary_images"][0]["id"])' "$manifest")" >/dev/null

(cd "$package_dir" && sha256sum --check --strict checksums.sha256)
printf 'PASS: artifact package verified: %s\n' "$package_dir"
