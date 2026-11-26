#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/create-github-draft-release.sh <version> [artifact-root]

Creates a GitHub Draft Release only from a verified package and a matching
remote Git tag. It uploads the package TAR, its SHA-256 checksum, and the
standalone manifest. It never publishes the release.
EOF
}

version="${1:-}"
artifact_root="${2:-dist/artifacts}"
if [[ -z "$version" || "$version" == "--help" ]]; then
  usage
  [[ "$version" == "--help" ]] && exit 0
  exit 2
fi
[[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  printf 'invalid release version: %s\n' "$version" >&2
  exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
for command_name in gh git python3 sha256sum tar cmp; do
  command -v "$command_name" >/dev/null || {
    printf '%s is required\n' "$command_name" >&2
    exit 1
  }
done

release_root="$(realpath -m "$artifact_root")"
package_dir="$release_root/$version"
archive="$release_root/chromat-${version}.tar.gz"
archive_checksum="$archive.sha256"
manifest="$release_root/chromat-${version}.manifest.json"
for path in "$package_dir" "$archive" "$archive_checksum" "$manifest"; do
  [[ -e "$path" ]] || {
    printf 'release asset is missing: %s\n' "$path" >&2
    exit 1
  }
done

python3 - "$manifest" "$package_dir" "$version" <<'PY'
import json
import pathlib
import sys

package = pathlib.Path(sys.argv[2])
if sys.argv[3].startswith("experimental-") or (package / "provenance").exists():
    raise SystemExit("experimental packages cannot be used for a GitHub release")
for path in (pathlib.Path(sys.argv[1]), package / "manifest.json"):
    data = json.loads(path.read_bytes())
    if (data.get("package_kind", "release") != "release"
            or "source_provenance" in data
            or data.get("git_commit") is None
            or data.get("package_version", "").startswith("experimental-")):
        raise SystemExit("experimental or unidentified packages cannot be used for a GitHub release")
PY

(
  cd "$(dirname "$archive")"
  sha256sum --check --strict "$(basename "$archive_checksum")"
)
"$repo_root/scripts/verify-artifacts.sh" "$package_dir"
"$repo_root/scripts/verify-image-artifacts.sh" "$package_dir"
tar -tzf "$archive" "$version/manifest.json" >/dev/null
cmp -s "$manifest" <(tar -xOzf "$archive" "$version/manifest.json") || {
  printf 'standalone manifest does not match the archive\n' >&2
  exit 1
}

manifest_commit="$(
  python3 - "$manifest" "$version" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if manifest.get("package_version") != sys.argv[2]:
    raise SystemExit("manifest package_version does not match the requested release")
commit = manifest.get("git_commit")
if not isinstance(commit, str) or len(commit) != 40:
    raise SystemExit("manifest git_commit must be a full Git commit")
print(commit)
PY
)"

git rev-parse --verify "${manifest_commit}^{commit}" >/dev/null
mapfile -t remote_tag_lines < <(
  git ls-remote origin "refs/tags/$version" "refs/tags/$version^{}"
)
((${#remote_tag_lines[@]})) || {
  printf 'remote tag is required before creating a draft release: %s\n' "$version" >&2
  exit 1
}
remote_tag_commit=
for remote_tag_line in "${remote_tag_lines[@]}"; do
  read -r remote_object remote_ref <<<"$remote_tag_line"
  if [[ "$remote_ref" == "refs/tags/$version^{}" ]]; then
    remote_tag_commit="$remote_object"
    break
  fi
  [[ "$remote_ref" == "refs/tags/$version" ]] && remote_tag_commit="$remote_object"
done
[[ "$remote_tag_commit" == "$manifest_commit" ]] || {
  printf 'remote tag %s does not point to the manifest commit\n' "$version" >&2
  exit 1
}
local_tag_commit="$(git rev-list -n 1 "refs/tags/$version")"
[[ "$local_tag_commit" == "$manifest_commit" ]] || {
  printf 'tag %s does not point to the manifest commit\n' "$version" >&2
  exit 1
}
release_view_output=
if release_view_output="$(gh api --include \
  "repos/{owner}/{repo}/releases/tags/$version" 2>&1)"; then
  printf 'release already exists: %s\n' "$version" >&2
  exit 1
fi
release_view_status="$(
  awk '
    /^HTTP\/[0-9.]+[[:space:]]+[0-9][0-9][0-9]([[:space:]]|$)/ {
      status = $2
    }
    END {
      print status
    }
  ' <<<"$release_view_output"
)"
if [[ "$release_view_status" != 404 ]]; then
  printf 'unable to determine whether release exists: %s\n' "$version" >&2
  exit 1
fi

gh release create "$version" \
  "$archive" "$archive_checksum" "$manifest" \
  --draft \
  --title "CHROMAT ${version}" \
  --notes "Paquete linux/amd64 verificable para Ubuntu Server 26.04. Siga docs/installation/ubuntu-server-26.04.md incluido en el artefacto. La release permanece en borrador hasta completar la validación en Ubuntu."

printf 'PASS: GitHub Draft Release created for %s\n' "$version"
