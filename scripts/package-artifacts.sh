#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/package-artifacts.sh <version> [artifact-root]

Builds linux/amd64 images, exports first-party and third-party images with
docker save, copies the model/migrations/runtime files, and writes a manifest.
The default artifact root is dist/artifacts.
EOF
}

version="${1:-}"
artifact_root="${2:-dist/artifacts}"
if [[ -z "$version" || "$version" == "--help" ]]; then
  usage
  [[ "$version" == "--help" ]] && exit 0
  exit 2
fi
[[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'invalid release version: %s\n' "$version" >&2
  exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
for command_name in docker git python3 sha256sum tar; do
  command -v "$command_name" >/dev/null || {
    printf '%s is required\n' "$command_name" >&2
    exit 1
  }
done

env_file="${CHROMAT_ENV_FILE:-.env}"
[[ -f "$env_file" ]] || env_file=".env.example"
compose=(docker compose --env-file "$env_file" -f compose.yaml)
if ! git diff --quiet || ! git diff --cached --quiet ||
  [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  printf 'source tree must be clean before packaging artifacts\n' >&2
  exit 1
fi

mapfile -t compose_images < <(
  "${compose[@]}" config --format json |
    python3 -c 'import json, sys; services=json.load(sys.stdin)["services"]; print(services["api"]["image"]); print(services["inference"]["image"]); print(services["db"]["image"]); print(services["nginx"]["image"])'
)
api_source_image="${compose_images[0]}"
inference_source_image="${compose_images[1]}"
db_source_image="${compose_images[2]}"
nginx_source_image="${compose_images[3]}"
api_release_image="chromat-api:${version}"
inference_release_image="chromat-inference:${version}"

release_root="$(realpath -m "$artifact_root")"
package_dir="$release_root/$version"
[[ ! -e "$package_dir" ]] || {
  printf 'release already exists: %s\n' "$package_dir" >&2
  exit 1
}
mkdir -p "$release_root" "$package_dir/images" "$package_dir/model" "$package_dir/db"

"${compose[@]}" pull db nginx
"${compose[@]}" build --pull=false api worker telegram-worker inference
docker tag "$api_source_image" "$api_release_image"
docker tag "$inference_source_image" "$inference_release_image"

images=(
  "$api_release_image"
  "$inference_release_image"
  "$db_source_image"
  "$nginx_source_image"
)
for image in "${images[@]}"; do
  docker image inspect "$image" >/dev/null || {
    printf 'image is not available locally: %s\n' "$image" >&2
    exit 1
  }
done

docker save -o "$package_dir/images/api.tar" "$api_release_image"
docker save -o "$package_dir/images/inference.tar" "$inference_release_image"
docker save -o "$package_dir/images/db.tar" "$db_source_image"
docker save -o "$package_dir/images/nginx.tar" "$nginx_source_image"

cp -- compose.yaml "$package_dir/compose.yaml"
cp -- .env.example "$package_dir/.env.example"
cp -- inference/models/deterministic-model.json "$package_dir/model/deterministic-model.json"
cp -- db/migrations/*.sql "$package_dir/db/"
mkdir -p "$package_dir/nginx" "$package_dir/web"
cp -R -- nginx/conf.d "$package_dir/nginx/"
cp -R -- web/public "$package_dir/web/"
cp -R -- scripts "$package_dir/scripts"
cp -R -- tests "$package_dir/tests"
mkdir -p "$package_dir/docs"
cp -R -- docs/deployment "$package_dir/docs/"
{
  sed \
    -e 's/^APP_ENV=.*/APP_ENV=production/' \
    -e 's/^PULL_POLICY=.*/PULL_POLICY=never/' \
    -e "s#^CHROMAT_API_IMAGE=.*#CHROMAT_API_IMAGE=$api_release_image#" \
    -e "s#^CHROMAT_INFERENCE_IMAGE=.*#CHROMAT_INFERENCE_IMAGE=$inference_release_image#" \
    -e "s#^CHROMAT_DB_IMAGE=.*#CHROMAT_DB_IMAGE=$db_source_image#" \
    -e "s#^CHROMAT_NGINX_IMAGE=.*#CHROMAT_NGINX_IMAGE=$nginx_source_image#" \
    -e 's#^MODEL_HOST_PATH=.*#MODEL_HOST_PATH=./model/deterministic-model.json#' \
    -e 's#^TLS_CERT_HOST_PATH=.*#TLS_CERT_HOST_PATH=/srv/chromat/tls/server.crt#' \
    -e 's#^TLS_KEY_HOST_PATH=.*#TLS_KEY_HOST_PATH=/srv/chromat/tls/server.key#' \
    .env.example
  printf 'TELEGRAM_BOT_TOKEN_HOST_FILE=/etc/chromat/secrets/telegram_bot_token\n'
} >"$package_dir/production.env.example"

mkdir -p "$package_dir/.metadata"
for image in "${images[@]}"; do
  safe_name="${image//[^A-Za-z0-9._-]/_}"
  docker image inspect "$image" >"$package_dir/.metadata/image-${safe_name}.json"
done

python3 - "$package_dir" "$version" "$repo_root" "$env_file" "$api_release_image" "$inference_release_image" "$db_source_image" "$nginx_source_image" <<'PY'
import hashlib
import json
import pathlib
import platform
import subprocess
import sys
from datetime import datetime, timezone

package_dir = pathlib.Path(sys.argv[1])
version = sys.argv[2]
repo_root = pathlib.Path(sys.argv[3])
env_file = sys.argv[4]
image_names = sys.argv[5:]

def command(*args):
    return subprocess.check_output(args, text=True).strip()

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def inspect_image(name, archive):
    safe_name = "".join(char if char.isalnum() or char in "._-" else "_" for char in name)
    data = json.loads((package_dir / ".metadata" / f"image-{safe_name}.json").read_text())
    image = data[0]
    architecture = image.get("Architecture")
    if architecture != "amd64":
        raise SystemExit(f"{name} has architecture {architecture!r}, expected amd64")
    return {
        "name": name,
        "archive": archive,
        "id": image.get("Id"),
        "architecture": architecture,
        "repo_digests": sorted(image.get("RepoDigests") or []),
    }

dockerfile_bases = []
for dockerfile in (repo_root / "api/Dockerfile", repo_root / "inference/Dockerfile"):
    first_from = next(
        line.split("FROM", 1)[1].strip().split(" AS ", 1)[0]
        for line in dockerfile.read_text().splitlines()
        if line.startswith("FROM ")
    )
    dockerfile_bases.append(first_from)

base_images = []
for name in dockerfile_bases:
    raw = subprocess.check_output(["docker", "image", "inspect", name], text=True)
    image = json.loads(raw)[0]
    digests = sorted(image.get("RepoDigests") or [])
    if not digests:
        raise SystemExit(f"base image has no repo digest: {name}")
    base_images.append({"name": name, "repo_digests": digests})

migrations = sorted((package_dir / "db").glob("*.sql"))
migration_version = max(
    (path.name.split("_", 1)[0] for path in migrations),
    default=None,
)
config_hash_input = b"".join(
    path.read_bytes()
    for path in (package_dir / "compose.yaml", package_dir / "production.env.example")
)
manifest = {
    "package_version": version,
    "target_platform": "linux/amd64",
    "pull_policy": "never",
    "target_ubuntu_version": "26.04",
    "git_commit": command("git", "-C", str(repo_root), "rev-parse", "HEAD"),
    "compose_commit": command("git", "-C", str(repo_root), "hash-object", "compose.yaml"),
    "migration_version": migration_version,
    "model_path": "model/deterministic-model.json",
    "model_sha256": sha256(package_dir / "model/deterministic-model.json"),
    "config_sha256": hashlib.sha256(config_hash_input).hexdigest(),
    "created_at": datetime.now(timezone.utc).isoformat(),
    "operator": command("id", "-un"),
    "host": platform.platform(),
    "docker_version": command("docker", "version", "--format", "{{.Server.Version}}"),
    "compose_version": command("docker", "compose", "version", "--short"),
    "source_env_file": env_file,
    "base_images": base_images,
    "images": [
        inspect_image(name, archive)
        for name, archive in zip(
            image_names,
            ("images/api.tar", "images/inference.tar", "images/db.tar", "images/nginx.tar"),
        )
    ],
}
(package_dir / "manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

rm -rf "$package_dir/.metadata"
(cd "$package_dir" && find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum > checksums.sha256)
chmod -R u=rwX,go=rX "$package_dir"
chmod 444 "$package_dir/manifest.json" "$package_dir/checksums.sha256"

tar -C "$release_root" -czf "$release_root/chromat-${version}.tar.gz" "$version"
(
  cd "$release_root"
  sha256sum "chromat-${version}.tar.gz" >"chromat-${version}.tar.gz.sha256"
)
"$repo_root/scripts/verify-artifacts.sh" "$package_dir"
if [[ -L "$release_root/active" ]]; then
  previous_target="$(readlink "$release_root/active")"
  ln -sfn "$previous_target" "$release_root/previous"
fi
ln -sfn "$version" "$release_root/active"
printf 'PASS: artifact package created: %s\n' "$package_dir"
