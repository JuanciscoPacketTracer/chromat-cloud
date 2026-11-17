#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

test_repo="$tmp_dir/repository"
remote_repo="$tmp_dir/remote.git"
mock_bin="$tmp_dir/bin"
gh_log="$tmp_dir/gh-create-args"
commit_file="$tmp_dir/manifest-commit"
mkdir -p "$test_repo/scripts" "$mock_bin"
cp "$repo_root/scripts/create-github-draft-release.sh" \
  "$repo_root/scripts/verify-artifacts.sh" \
  "$repo_root/scripts/verify-image-artifacts.sh" "$test_repo/scripts/"
chmod +x "$test_repo/scripts/"*.sh

git init -q "$test_repo"
git -C "$test_repo" config user.email test@example.invalid
git -C "$test_repo" config user.name "Release test"
printf 'first commit\n' >"$test_repo/source.txt"
git -C "$test_repo" add source.txt
git -C "$test_repo" commit -qm "first commit"
manifest_commit="$(git -C "$test_repo" rev-parse HEAD)"
printf '%s\n' "$manifest_commit" >"$commit_file"
printf 'second commit\n' >>"$test_repo/source.txt"
git -C "$test_repo" commit -am "second commit" -q
git init --bare -q "$remote_repo"
git -C "$test_repo" remote add origin "$remote_repo"

cat >"$mock_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$1" == api ]]; then
  case "${GH_RELEASE_VIEW_RESULT:-missing}" in
    existing)
      printf 'HTTP/2.0 200 OK\n'
      exit 0
      ;;
    missing)
      printf 'HTTP/2.0 404 Not Found\n'
      exit 1
      ;;
    error)
      printf 'network failure\n' >&2
      exit 1
      ;;
    sequence-404-200)
      printf 'HTTP/2.0 404 Not Found\nHTTP/2.0 200 OK\n'
      exit 1
      ;;
    final-500)
      printf 'HTTP/2.0 404 Not Found\nHTTP/2.0 500 Internal Server Error\n'
      exit 1
      ;;
  esac
fi
if [[ "$1" == release && "$2" == create ]]; then
  printf '%s\0' "$@" >"$GH_CREATE_LOG"
  exit 0
fi
printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 64
EOF
chmod +x "$mock_bin/gh"
cat >"$mock_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$1" == load ]]; then
  [[ "${DOCKER_TEST_MODE:-}" != fail-load ]] || exit 1
  [[ "$2" == --input && -f "$3" ]]
  exit 0
fi
[[ "$1" == image && "$2" == inspect && "$3" == --format ]]
[[ "${DOCKER_TEST_MODE:-}" != fail-inspect ]] || exit 1
case "$5" in
  chromat-api:test) printf '%s amd64\n' "${DOCKER_API_ID:-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
  chromat-inference:test) printf '%s amd64\n' "${DOCKER_INFERENCE_ID:-sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" ;;
  mariadb:test) printf '%s amd64\n' "${DOCKER_DB_ID:-sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}" ;;
  nginx:test) printf '%s %s\n' "${DOCKER_NGINX_ID:-sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd}" "${DOCKER_NGINX_ARCH:-amd64}" ;;
  busybox:1.36.1) printf '%s %s\n' "${DOCKER_BUSYBOX_ID:-sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d}" "${DOCKER_BUSYBOX_ARCH:-amd64}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$mock_bin/docker"

no_docker_bin="$tmp_dir/no-docker-bin"
mkdir -p "$no_docker_bin"
for command_name in gh git python3 sha256sum tar cmp realpath awk bash; do
  ln -s "$(command -v "$command_name")" "$no_docker_bin/$command_name"
done

copy_package_files() {
  local package_dir="$1"

  mkdir -p "$package_dir"
  cp "$repo_root/.env.example" "$repo_root/compose.yaml" "$package_dir/"
  mkdir -p "$package_dir/model"
  cp "$repo_root/inference/models/deterministic-model.json" "$package_dir/model/"
  cp -a "$repo_root/nginx" "$repo_root/web" "$package_dir/"
  mkdir -p "$package_dir/db"
  cp -a "$repo_root/db/migrations/." "$package_dir/db/"
  cp -a "$repo_root/scripts" "$package_dir/"
  mkdir -p "$package_dir/tests"
  cp -a "$repo_root/tests/smoke" "$package_dir/tests/"
  mkdir -p "$package_dir/docs"
  cp -a "$repo_root/docs/deployment" "$repo_root/docs/installation" "$package_dir/docs/"
}

write_manifest() {
  local manifest="$1"
  local package_version="$2"
  local git_commit
  git_commit="$(<"$commit_file")"

  python3 - "$manifest" "$package_version" "$git_commit" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
package_dir = manifest_path.parent
model = package_dir / "model/deterministic-model.json"
manifest = {
    "package_version": sys.argv[2],
    "target_platform": "linux/amd64",
    "target_ubuntu_version": "26.04",
    "pull_policy": "never",
    "git_commit": sys.argv[3],
    "model_path": "model/deterministic-model.json",
    "model_sha256": hashlib.sha256(model.read_bytes()).hexdigest(),
    "images": [
        {
            "name": "chromat-api:test",
            "archive": "images/api.tar",
            "id": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "architecture": "amd64"
        },
        {
            "name": "chromat-inference:test",
            "archive": "images/inference.tar",
            "id": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "architecture": "amd64"
        },
        {
            "name": "mariadb:test",
            "archive": "images/db.tar",
            "id": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "architecture": "amd64"
        },
        {
            "name": "nginx:test",
            "archive": "images/nginx.tar",
            "id": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            "architecture": "amd64"
        }
    ],
    "auxiliary_images": [
        {
            "name": "busybox:1.36.1",
            "archive": "images/busybox.tar",
            "id": "sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d",
            "architecture": "amd64",
            "repo_digests": ["busybox@sha256:test"],
            "source_reference": "docker.io/library/busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f",
            "index_digest": "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662",
            "platform_digest": "sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f",
            "config_digest": "sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d"
        },
    ],
}
manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
PY
}

create_assets() {
  local version="$1"
  local package_version="${2:-$version}"
  local release_root="$tmp_dir/artifacts-$version"
  local package_dir="$release_root/$version"

  rm -rf "$release_root"
  mkdir -p "$package_dir/images"
  copy_package_files "$package_dir"
  for image in api inference db nginx busybox; do
    printf '%s image\n' "$image" >"$package_dir/images/$image.tar"
  done
  printf 'PULL_POLICY=never\n' >"$package_dir/production.env.example"
  write_manifest "$package_dir/manifest.json" "$package_version"
  (
    cd "$package_dir"
    find . -type f ! -name checksums.sha256 -print0 | sort -z |
      xargs -0 sha256sum >checksums.sha256
  )
  cp "$package_dir/manifest.json" "$release_root/chromat-${version}.manifest.json"
  tar -C "$release_root" -czf "$release_root/chromat-${version}.tar.gz" "$version"
  (
    cd "$release_root"
    sha256sum "chromat-${version}.tar.gz" >"chromat-${version}.tar.gz.sha256"
  )
  printf '%s\n' "$release_root"
}

run_release() {
  local version="$1"
  local release_root="$2"
  GH_CREATE_LOG="$gh_log" PATH="${RELEASE_PATH:-$mock_bin:$PATH}" \
    bash "$test_repo/scripts/create-github-draft-release.sh" "$version" "$release_root"
}

expect_failure() {
  local case_name="$1"
  shift

  : >"$gh_log"
  if "$@" >/dev/null 2>&1; then
    printf 'expected draft release validation to fail: %s\n' "$case_name" >&2
    exit 1
  fi
  [[ ! -s "$gh_log" ]] || {
    printf 'draft release creation was attempted for rejected case: %s\n' "$case_name" >&2
    exit 1
  }
}

expect_invalid_version() {
  local version="$1"

  expect_failure "invalid-version-$version" \
    run_release "$version" "$tmp_dir/missing-artifacts"
}

create_local_and_remote_tag() {
  local version="$1"
  local tag_type="$2"
  local commit
  commit="$(<"$commit_file")"

  if [[ "$tag_type" == annotated ]]; then
    git -C "$test_repo" tag -a "$version" "$commit" -m "$version"
  else
    git -C "$test_repo" tag "$version" "$commit"
  fi
  git -C "$test_repo" push -q origin "refs/tags/$version"
}

for invalid_version in . .. -preview; do
  expect_invalid_version "$invalid_version"
done

checksum_version="checksum-invalid"
checksum_root="$(create_assets "$checksum_version")"
printf '%064d  chromat-%s.tar.gz\n' 0 "$checksum_version" \
  >"$checksum_root/chromat-${checksum_version}.tar.gz.sha256"
expect_failure invalid-checksum run_release "$checksum_version" "$checksum_root"

manifest_version="external-manifest-differs"
manifest_root="$(create_assets "$manifest_version")"
printf '{}\n' >"$manifest_root/chromat-${manifest_version}.manifest.json"
expect_failure external-manifest-differs run_release "$manifest_version" "$manifest_root"

version_mismatch="package-version-mismatch"
version_mismatch_root="$(create_assets "$version_mismatch" another-version)"
expect_failure package-version-mismatch \
  run_release "$version_mismatch" "$version_mismatch_root"

remote_mismatch="remote-tag-mismatch"
remote_mismatch_root="$(create_assets "$remote_mismatch")"
manifest_commit="$(<"$commit_file")"
git -C "$test_repo" tag "$remote_mismatch" "$manifest_commit"
git -C "$test_repo" tag "remote-$remote_mismatch" HEAD
git -C "$test_repo" push -q origin \
  "refs/tags/remote-$remote_mismatch:refs/tags/$remote_mismatch"
expect_failure remote-tag-mismatch run_release "$remote_mismatch" "$remote_mismatch_root"

missing_remote="remote-tag-missing"
missing_remote_root="$(create_assets "$missing_remote")"
git -C "$test_repo" tag "$missing_remote" "$manifest_commit"
expect_failure remote-tag-missing run_release "$missing_remote" "$missing_remote_root"

existing_release="release-already-exists"
existing_release_root="$(create_assets "$existing_release")"
create_local_and_remote_tag "$existing_release" lightweight
GH_RELEASE_VIEW_RESULT=existing expect_failure release-already-exists \
  run_release "$existing_release" "$existing_release_root"

view_error="release-view-error"
view_error_root="$(create_assets "$view_error")"
create_local_and_remote_tag "$view_error" lightweight
GH_RELEASE_VIEW_RESULT=error expect_failure release-view-error \
  run_release "$view_error" "$view_error_root"

view_sequence="release-view-404-then-200"
view_sequence_root="$(create_assets "$view_sequence")"
create_local_and_remote_tag "$view_sequence" lightweight
GH_RELEASE_VIEW_RESULT=sequence-404-200 expect_failure release-view-404-then-200 \
  run_release "$view_sequence" "$view_sequence_root"

view_final_error="release-view-final-500"
view_final_error_root="$(create_assets "$view_final_error")"
create_local_and_remote_tag "$view_final_error" lightweight
GH_RELEASE_VIEW_RESULT=final-500 expect_failure release-view-final-500 \
  run_release "$view_final_error" "$view_final_error_root"

semantic_failure="semantic-validation-failure"
semantic_failure_root="$(create_assets "$semantic_failure")"
create_local_and_remote_tag "$semantic_failure" lightweight
DOCKER_BUSYBOX_ID=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  expect_failure semantic-validation-failure \
  run_release "$semantic_failure" "$semantic_failure_root"

docker_load_failure="docker-load-failure"
docker_load_failure_root="$(create_assets "$docker_load_failure")"
create_local_and_remote_tag "$docker_load_failure" lightweight
DOCKER_TEST_MODE=fail-load expect_failure docker-load-failure \
  run_release "$docker_load_failure" "$docker_load_failure_root"

docker_inspect_failure="docker-inspect-failure"
docker_inspect_failure_root="$(create_assets "$docker_inspect_failure")"
create_local_and_remote_tag "$docker_inspect_failure" lightweight
DOCKER_TEST_MODE=fail-inspect expect_failure docker-inspect-failure \
  run_release "$docker_inspect_failure" "$docker_inspect_failure_root"

docker_unavailable="docker-unavailable"
docker_unavailable_root="$(create_assets "$docker_unavailable")"
create_local_and_remote_tag "$docker_unavailable" lightweight
RELEASE_PATH="$no_docker_bin" expect_failure docker-unavailable \
  run_release "$docker_unavailable" "$docker_unavailable_root"

assert_release_create() {
  local version="$1"
  local release_root="$2"

  : >"$gh_log"
  run_release "$version" "$release_root"
  python3 - "$gh_log" "$version" "$release_root" <<'PY'
import pathlib
import sys

args = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
version = sys.argv[2]
root = pathlib.Path(sys.argv[3])
expected = [
    b"release",
    b"create",
    version.encode(),
    str(root / f"chromat-{version}.tar.gz").encode(),
    str(root / f"chromat-{version}.tar.gz.sha256").encode(),
    str(root / f"chromat-{version}.manifest.json").encode(),
    b"--draft",
    b"--title",
    f"CHROMAT {version}".encode(),
    b"--notes",
    b"Paquete linux/amd64 verificable para Ubuntu Server 26.04. Siga "
    b"docs/installation/ubuntu-server-26.04.md incluido en el artefacto. "
    + "La release permanece en borrador hasta completar la validación en Ubuntu.".encode(),
]
if args != expected:
    raise SystemExit(f"unexpected gh release create arguments: {args!r}")
PY
}

lightweight="valid-lightweight"
lightweight_root="$(create_assets "$lightweight")"
create_local_and_remote_tag "$lightweight" lightweight
assert_release_create "$lightweight" "$lightweight_root"

annotated="valid-annotated"
annotated_root="$(create_assets "$annotated")"
create_local_and_remote_tag "$annotated" annotated
assert_release_create "$annotated" "$annotated_root"

printf 'PASS: GitHub draft release validation contract\n'
