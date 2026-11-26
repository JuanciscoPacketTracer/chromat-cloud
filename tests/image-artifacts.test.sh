#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

package_dir="$tmp_dir/package"
mkdir -p "$package_dir/images"
printf '{}' >"$package_dir/manifest.json"
for archive in api inference db nginx busybox; do
  printf '%s\n' "$archive" >"$package_dir/images/$archive.tar"
done
cat >"$package_dir/manifest.json" <<'EOF'
{
  "images": [
    {"name":"chromat-api:test","archive":"images/api.tar","id":"sha256:api","architecture":"amd64"},
    {"name":"chromat-inference:test","archive":"images/inference.tar","id":"sha256:inference","architecture":"amd64"},
    {"name":"mariadb:test","archive":"images/db.tar","id":"sha256:db","architecture":"amd64"},
    {"name":"nginx:test","archive":"images/nginx.tar","id":"sha256:nginx","architecture":"amd64"}
  ],
  "auxiliary_images": [
    {
      "name":"busybox:1.36.1",
      "archive":"images/busybox.tar",
      "id":"sha256:busybox",
      "architecture":"amd64",
      "config_digest":"sha256:busybox"
    }
  ]
}
EOF
fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == load ]]; then
  [[ "$2" == --input && -f "$3" ]]
  printf 'load-called\n' >>"${LOAD_LOG:?}"
  exit 0
fi
if [[ "$1" == pull ]]; then
  printf 'pull-called\n' >>"${PULL_LOG:?}"
  exit 1
fi
if [[ "$1" == image && "$2" == save ]]; then
  [[ "$3" == --platform=linux/amd64 && "$4" == --output ]]
  cp "${FAKE_EXPORT:?}" "$5"
  exit 0
fi
[[ "$1" == image && "$2" == inspect && "$3" == --format ]]
case "$5" in
  chromat-api:test) printf '%s amd64\n' "${FAKE_API_ID:-sha256:api}" ;;
  chromat-inference:test) printf '%s amd64\n' "${FAKE_INFERENCE_ID:-sha256:inference}" ;;
  mariadb:test) printf '%s amd64\n' "${FAKE_DB_ID:-sha256:db}" ;;
  nginx:test) printf '%s %s\n' "${FAKE_NGINX_ID:-sha256:nginx}" "${FAKE_NGINX_ARCH:-amd64}" ;;
  busybox:1.36.1) printf '%s %s\n' "${FAKE_BUSYBOX_ID:-sha256:busybox}" "${FAKE_BUSYBOX_ARCH:-amd64}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fake_bin/docker"

python3 "$repo_root/tests/image-identity-fixture.py" "$package_dir" >"$tmp_dir/pins.json"
cp "$repo_root/scripts/verify-image-artifacts.sh" "$package_dir/scripts/"
verifier="$package_dir/scripts/verify-image-artifacts.sh"
python3 - "$package_dir/manifest.json" "$tmp_dir/pins.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text())
pins = json.load(open(sys.argv[2]))
manifest["auxiliary_images"][0].update(id=pins["PLATFORM_DIGEST"], config_digest=pins["CONFIG_DIGEST"])
path.write_text(json.dumps(manifest))
PY
export FAKE_BUSYBOX_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["PLATFORM_DIGEST"])' "$tmp_dir/pins.json")"
export FAKE_EXPORT="$package_dir/images/busybox.tar"
export PULL_LOG="$tmp_dir/pull-log"
export LOAD_LOG="$tmp_dir/load-log"

PULL_LOG="$tmp_dir/pull-log" PATH="$fake_bin:$PATH" \
  "$verifier" "$package_dir"
if [[ -s "$tmp_dir/pull-log" ]]; then
  printf 'semantic verification must not pull images\n' >&2
  exit 1
fi
if FAKE_BUSYBOX_ID=sha256:wrong PATH="$fake_bin:$PATH" \
  "$verifier" "$package_dir" >/dev/null 2>&1; then
  printf 'expected wrong BusyBox ID to fail\n' >&2
  exit 1
fi
if FAKE_NGINX_ARCH=arm64 PATH="$fake_bin:$PATH" \
  "$verifier" "$package_dir" >/dev/null 2>&1; then
  printf 'expected wrong image architecture to fail\n' >&2
  exit 1
fi
if FAKE_BUSYBOX_ARCH=arm64 PATH="$fake_bin:$PATH" \
  "$verifier" "$package_dir" >/dev/null 2>&1; then
  printf 'expected wrong BusyBox architecture to fail\n' >&2
  exit 1
fi
index_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["INDEX_DIGEST"])' "$tmp_dir/pins.json")"
if FAKE_BUSYBOX_ID="$index_id" PATH="$fake_bin:$PATH" \
  "$verifier" "$package_dir" >/dev/null 2>&1; then
  printf 'expected native ID representation change to fail closed\n' >&2
  exit 1
fi
printf 'corrupted export\n' >"$tmp_dir/corrupted.tar"
if FAKE_EXPORT="$tmp_dir/corrupted.tar" PATH="$fake_bin:$PATH" \
  "$verifier" "$package_dir" >/dev/null 2>&1; then
  printf 'expected corrupted loaded image export to fail\n' >&2
  exit 1
fi
cp "$package_dir/images/busybox.tar" "$tmp_dir/valid.tar"
printf 'corrupted archive\n' >"$package_dir/images/busybox.tar"
: >"$LOAD_LOG"
if PATH="$fake_bin:$PATH" "$verifier" "$package_dir" >/dev/null 2>&1; then
  printf 'expected corrupted archive to fail\n' >&2
  exit 1
fi
if [[ -s "$LOAD_LOG" ]]; then
  printf 'corrupted BusyBox must fail before any load\n' >&2
  exit 1
fi
cp "$tmp_dir/valid.tar" "$package_dir/images/busybox.tar"
rm "$package_dir/images/busybox.tar"
if PATH="$fake_bin:$PATH" \
  "$verifier" "$package_dir" >/dev/null 2>&1; then
  printf 'expected missing image archive to fail\n' >&2
  exit 1
fi
printf 'PASS: semantic image artifact verification contract\n'
