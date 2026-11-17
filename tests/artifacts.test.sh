#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$repo_root/scripts/verify-artifacts.sh"
package_script="$repo_root/scripts/package-artifacts.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

grep -Fq 'docker pull --platform=linux/amd64 "$busybox_source_reference"' "$package_script"
grep -Fq 'docker tag "$busybox_source_reference" "$busybox_operational_name"' \
  "$package_script"
grep -Fq 'docker save -o "$package_dir/images/busybox.tar" "${auxiliary_images[0]}"' \
  "$package_script"
grep -Fq 'busybox_source_reference="docker.io/library/busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f"' \
  "$package_script"
grep -Fq 'busybox_index_digest="sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662"' \
  "$package_script"
grep -Fq 'busybox_platform_digest="sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f"' \
  "$package_script"
grep -Fq 'busybox_config_digest="sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d"' \
  "$package_script"
grep -Fq '"auxiliary_images"' "$package_script"

package_dir="$tmp_dir/package"
mkdir -p "$package_dir/images" "$package_dir/scripts/lib"
required_files=(
  .env.example
  compose.yaml
  model/deterministic-model.json
  nginx/conf.d/default.conf
  web/public/app.js
  web/public/index.html
  web/public/styles.css
  db/001_initial.sql
  db/002_processing.sql
  db/003_processing_constraints.sql
  db/004_admin_auth.sql
  db/005_source_management.sql
  db/006_source_access.sql
  db/007_retention.sql
  db/008_raw_tombstones.sql
  db/009_aggregated_state.sql
  db/010_aggregation_rule_audit.sql
  db/011_aggregated_state_history.sql
  db/012_alerts.sql
  db/013_alert_interval.sql
  db/014_manual_reprocessing.sql
  db/015_raw_file_finalization.sql
  db/016_job_event_uniqueness.sql
  scripts/backup.sh \
  scripts/check-tls-expiry.sh \
  scripts/install-production-tls.sh \
  scripts/prepare-ubuntu-production-host.sh \
  scripts/recover-release-links.sh \
  scripts/retention.sh \
  scripts/verify-artifacts.sh \
  scripts/verify-image-artifacts.sh \
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
  docs/installation/ubuntu-server-26.04.md
)
for path in "${required_files[@]}"; do
  mkdir -p "$(dirname "$package_dir/$path")"
  if [[ "$path" == "scripts/verify-artifacts.sh" ]]; then
    cp "$repo_root/scripts/verify-artifacts.sh" "$package_dir/$path"
  else
    printf 'operational file\n' >"$package_dir/$path"
  fi
  [[ "$path" != scripts/* ]] || chmod 0755 "$package_dir/$path"
done
printf 'backup configuration library\n' >"$package_dir/scripts/lib/backup-config.sh"
chmod 0644 "$package_dir/scripts/lib/backup-config.sh"
for archive in api inference db nginx busybox; do
  printf '%s image\n' "$archive" >"$package_dir/images/$archive.tar"
done
test "$(stat -c %a "$package_dir/scripts/lib/backup-config.sh")" = 644
grep -Fq 'chmod 0644 "$package_dir/scripts/lib/backup-config.sh"' \
  "$repo_root/scripts/package-artifacts.sh"
refresh_checksums() {
  (
    cd "$1"
    find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum > checksums.sha256
  )
}
model_sha256="$(sha256sum "$package_dir/model/deterministic-model.json" | cut -d' ' -f1)"
cat >"$package_dir/manifest.json" <<'EOF'
{
  "package_version": "test-1",
  "target_platform": "linux/amd64",
  "target_ubuntu_version": "26.04",
  "pull_policy": "never",
  "model_path": "model/deterministic-model.json",
  "model_sha256": "__MODEL_SHA256__",
  "images": [
    {"name": "chromat-api:test-1", "archive": "images/api.tar"},
    {"name": "chromat-inference:test-1", "archive": "images/inference.tar"},
    {"name": "mariadb:test-1", "archive": "images/db.tar"},
    {"name": "nginx:test-1", "archive": "images/nginx.tar"}
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
    }
  ]
}
EOF
sed -i "s/__MODEL_SHA256__/$model_sha256/" "$package_dir/manifest.json"
printf 'PULL_POLICY=never\n' >"$package_dir/production.env.example"
refresh_checksums "$package_dir"

"$verifier" "$package_dir"
assert_invalid_manifest() {
  local case_name="$1"
  local invalid_package="$tmp_dir/invalid-manifest-$case_name"

  cp -a "$package_dir" "$invalid_package"
  if [[ "$case_name" == "invalid-json" ]]; then
    printf '{\n' >"$invalid_package/manifest.json"
  else
  python3 - "$invalid_package/manifest.json" "$case_name" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
case = sys.argv[2]
manifest = json.loads(path.read_text(encoding="utf-8"))
if case == "root-list":
    manifest = []
elif case == "images-not-list":
    manifest["images"] = {}
elif case == "three-images":
    manifest["images"].pop()
elif case == "image-not-object":
    manifest["images"][0] = "images/api.tar"
elif case == "duplicate-archive":
    manifest["images"][3]["archive"] = "images/api.tar"
elif case == "non-string-archive":
    manifest["images"][0]["archive"] = []
elif case == "invalid-model-hash":
    manifest["model_sha256"] = "z" * 64
elif case == "mismatched-model-hash":
    manifest["model_sha256"] = "0" * 64
elif case == "non-string-model-path":
    manifest["model_path"] = 1
elif case == "missing-auxiliary-images":
    del manifest["auxiliary_images"]
elif case == "wrong-auxiliary-name":
    manifest["auxiliary_images"][0]["name"] = "busybox:latest"
elif case == "wrong-auxiliary-archive":
    manifest["auxiliary_images"][0]["archive"] = "images/api.tar"
elif case == "missing-auxiliary-id":
    del manifest["auxiliary_images"][0]["id"]
elif case == "wrong-auxiliary-id":
    manifest["auxiliary_images"][0]["id"] = "sha256:wrong"
elif case == "wrong-auxiliary-architecture":
    manifest["auxiliary_images"][0]["architecture"] = "arm64"
elif case == "missing-auxiliary-digest":
    manifest["auxiliary_images"][0]["repo_digests"] = []
elif case == "wrong-source-reference":
    manifest["auxiliary_images"][0]["source_reference"] = "busybox:1.36.1"
elif case == "wrong-index-digest":
    manifest["auxiliary_images"][0]["index_digest"] = "sha256:" + "0" * 64
elif case == "wrong-platform-digest":
    manifest["auxiliary_images"][0]["platform_digest"] = "sha256:" + "0" * 64
elif case == "wrong-config-digest":
    manifest["auxiliary_images"][0]["config_digest"] = "sha256:" + "0" * 64
else:
    raise SystemExit(f"unknown manifest test case: {case}")
path.write_text(json.dumps(manifest), encoding="utf-8")
PY
  fi
  refresh_checksums "$invalid_package"
  if "$verifier" "$invalid_package" >/dev/null 2>&1; then
    printf 'expected invalid manifest to fail: %s\n' "$case_name" >&2
    exit 1
  fi
}
for case_name in \
  invalid-json \
  root-list \
  images-not-list \
  three-images \
  image-not-object \
  duplicate-archive \
  non-string-archive \
  invalid-model-hash \
  mismatched-model-hash \
  non-string-model-path \
  missing-auxiliary-images \
  wrong-auxiliary-name \
  wrong-auxiliary-archive \
  missing-auxiliary-id \
  wrong-auxiliary-id \
  wrong-auxiliary-architecture \
  missing-auxiliary-digest \
  wrong-source-reference \
  wrong-index-digest \
  wrong-platform-digest \
  wrong-config-digest; do
  assert_invalid_manifest "$case_name"
done
for critical_path in \
  compose.yaml \
  nginx/conf.d/default.conf \
  db/016_job_event_uniqueness.sql \
  images/busybox.tar \
  scripts/lib/backup-config.sh \
  model/deterministic-model.json \
  tests/smoke/run.sh \
  docs/deployment/promotion.md; do
  incomplete_package="$tmp_dir/incomplete-$(basename "$critical_path")"
  cp -a "$package_dir" "$incomplete_package"
  rm "$incomplete_package/$critical_path"
  refresh_checksums "$incomplete_package"
  if "$verifier" "$incomplete_package" >/dev/null 2>&1; then
    printf 'expected incomplete package to fail: %s\n' "$critical_path" >&2
    exit 1
  fi
done

printf 'PULL_POLICY=missing\n' >"$package_dir/invalid-production.env"
refresh_checksums "$package_dir"
if bash "$repo_root/scripts/verify-production-environment.sh" \
  "$package_dir" "$package_dir/invalid-production.env" >/dev/null 2>&1; then
  printf 'expected invalid production environment to fail\n' >&2
  exit 1
fi

environment_package="$tmp_dir/environment-package"
cp -a "$package_dir" "$environment_package"
secrets_dir="$tmp_dir/secrets"
tls_dir="$tmp_dir/tls"
external_backup_dir="$tmp_dir/external-backups"
mkdir -p "$secrets_dir" "$tls_dir" "$external_backup_dir" "$tmp_dir/bin"
printf 'model\n' >"$environment_package/model/deterministic-model.json"
for archive in api inference db nginx busybox; do
  printf '%s image\n' "$archive" >"$environment_package/images/$archive.tar"
done
printf 'database-password\n' >"$secrets_dir/db_password"
printf 'database-root-password\n' >"$secrets_dir/db_root_password"
printf 'telegram-token\n' >"$secrets_dir/telegram_bot_token"
printf 'test-recipient\n' >"$secrets_dir/age-recipient"
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp_dir/ca.key"
openssl req -x509 -new -sha256 -days 3650 \
  -key "$tmp_dir/ca.key" -out "$tls_dir/ca.crt" \
  -subj '/CN=CHROMAT Test CA'
openssl ecparam -name prime256v1 -genkey -noout -out "$tls_dir/server.key"
openssl req -new -sha256 -key "$tls_dir/server.key" \
  -out "$tmp_dir/server.csr" -subj '/CN=chromat.lan'
printf 'subjectAltName=DNS:chromat.lan\nextendedKeyUsage=serverAuth\n' >"$tmp_dir/server.ext"
openssl x509 -req -sha256 -days 365 \
  -in "$tmp_dir/server.csr" -CA "$tls_dir/ca.crt" \
  -CAkey "$tmp_dir/ca.key" -CAcreateserial -CAserial "$tmp_dir/ca.srl" \
  -out "$tls_dir/server.crt" -extfile "$tmp_dir/server.ext" \
  >/dev/null 2>&1
cat >"$environment_package/manifest.json" <<EOF
{
  "package_version": "test-1",
  "target_platform": "linux/amd64",
  "target_ubuntu_version": "26.04",
  "pull_policy": "never",
  "model_path": "model/deterministic-model.json",
  "model_sha256": "$(sha256sum "$environment_package/model/deterministic-model.json" | cut -d' ' -f1)",
  "images": [
    {"name": "chromat-api:test-1", "archive": "images/api.tar", "id": "sha256:api"},
    {"name": "chromat-inference:test-1", "archive": "images/inference.tar", "id": "sha256:inference"},
    {"name": "mariadb:test-1", "archive": "images/db.tar", "id": "sha256:db"},
    {"name": "nginx:test-1", "archive": "images/nginx.tar", "id": "sha256:nginx"}
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
    }
  ]
}
EOF
cat >"$environment_package/production.env" <<EOF
PULL_POLICY=never
CHROMAT_API_IMAGE=chromat-api:test-1
CHROMAT_INFERENCE_IMAGE=chromat-inference:test-1
CHROMAT_DB_IMAGE=mariadb:test-1
CHROMAT_NGINX_IMAGE=nginx:test-1
MODEL_HOST_PATH=./model/deterministic-model.json
DB_PASSWORD_HOST_FILE=$secrets_dir/db_password
DB_ROOT_PASSWORD_HOST_FILE=$secrets_dir/db_root_password
TELEGRAM_BOT_TOKEN_HOST_FILE=$secrets_dir/telegram_bot_token
TLS_CERT_HOST_PATH=$tls_dir/server.crt
TLS_KEY_HOST_PATH=$tls_dir/server.key
BACKUP_AGE_RECIPIENT_FILE=$secrets_dir/age-recipient
BACKUP_EXTERNAL_DIR=$external_backup_dir
BACKUP_SECRET_FILES=$secrets_dir/db_password $secrets_dir/db_root_password $secrets_dir/telegram_bot_token
EOF
runtime_env="$tmp_dir/production.env"
cp "$environment_package/production.env" "$runtime_env"
cat >"$tmp_dir/bin/age" <<'EOF'
#!/usr/bin/env bash
test "$(cat "$2")" = test-recipient
EOF
cat >"$tmp_dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == load ]]; then
  test "$2" = --input
  test -f "$3"
  exit 0
fi
test "$1" = image
test "$2" = inspect
test "$3" = --format
case "$5" in
  chromat-api:test-1) echo sha256:api ;;
  chromat-inference:test-1) echo sha256:inference ;;
  mariadb:test-1) echo sha256:db ;;
  nginx:test-1) echo "${MOCK_NGINX_ID:-sha256:nginx}" ;;
  *) exit 1 ;;
esac
EOF
cat >"$tmp_dir/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=
path=
while (($#)); do
  case "$1" in
    -T)
      path="$2"
      shift 2
      ;;
    -o)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "$path" == / ]]; then
  source=/dev/root
  device=8:1
else
  source=/dev/chromat-backups
  device=8:16
fi

case "$output" in
  TARGET) printf '/mnt/chromat-backups\n' ;;
  SOURCE) printf '%s\n' "$source" ;;
  MAJ:MIN) printf '%s\n' "$device" ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$tmp_dir/bin/age" "$tmp_dir/bin/docker" "$tmp_dir/bin/findmnt"
(
  cd "$environment_package"
  find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum > checksums.sha256
)
transfer_dir="$tmp_dir/transfer"
mkdir -p "$transfer_dir"
tar -C "$tmp_dir" -czf "$transfer_dir/chromat-test-1.tar.gz" environment-package
(
  cd "$transfer_dir"
  sha256sum chromat-test-1.tar.gz >chromat-test-1.tar.gz.sha256
  sha256sum --check chromat-test-1.tar.gz.sha256
  tar -xzf chromat-test-1.tar.gz
)
fresh_package="$transfer_dir/environment-package"
PATH="$tmp_dir/bin:$PATH" bash "$fresh_package/scripts/verify-artifacts.sh" "$fresh_package"
for image_archive in "$fresh_package"/images/*.tar; do
  PATH="$tmp_dir/bin:$PATH" docker load --input "$image_archive"
done
PATH="$tmp_dir/bin:$PATH" bash "$repo_root/scripts/verify-production-environment.sh" \
  "$fresh_package" "$runtime_env"
PATH="$tmp_dir/bin:$PATH" bash "$repo_root/scripts/verify-production-environment.sh" \
  "$environment_package" "$runtime_env"
sed -i '/^BACKUP_EXTERNAL_DIR=/d' "$runtime_env"
if PATH="$tmp_dir/bin:$PATH" bash "$repo_root/scripts/verify-production-environment.sh" \
  "$environment_package" "$runtime_env" >/dev/null 2>&1; then
  printf 'expected missing BACKUP_EXTERNAL_DIR to fail\n' >&2
  exit 1
fi
printf 'BACKUP_EXTERNAL_DIR=%s\n' "$external_backup_dir" >>"$runtime_env"
sed -i '/^BACKUP_SECRET_FILES=/d' "$runtime_env"
printf 'BACKUP_SECRET_FILES=%s\n' "$secrets_dir/db_password" \
  >>"$runtime_env"
if PATH="$tmp_dir/bin:$PATH" bash "$repo_root/scripts/verify-production-environment.sh" \
  "$environment_package" "$runtime_env" >/dev/null 2>&1; then
  printf 'expected incomplete BACKUP_SECRET_FILES to fail\n' >&2
  exit 1
fi
printf 'BACKUP_SECRET_FILES=%s %s %s\n' \
  "$secrets_dir/db_password" "$secrets_dir/db_root_password" \
  "$secrets_dir/telegram_bot_token" >>"$runtime_env"
if PATH="$tmp_dir/bin:$PATH" bash "$repo_root/scripts/verify-production-environment.sh" \
  "$environment_package" "$runtime_env" >/dev/null 2>&1; then
  printf 'expected duplicate BACKUP_SECRET_FILES to fail\n' >&2
  exit 1
fi
sed -i '/^BACKUP_SECRET_FILES=/d' "$runtime_env"
printf 'BACKUP_SECRET_FILES=%s %s %s\n' \
  "$secrets_dir/db_password" "$secrets_dir/db_root_password" \
  "$secrets_dir/telegram_bot_token" >>"$runtime_env"
truncate -s 0 "$secrets_dir/db_password"
if PATH="$tmp_dir/bin:$PATH" bash "$repo_root/scripts/verify-production-environment.sh" \
  "$environment_package" "$runtime_env" >/dev/null 2>&1; then
  printf 'expected empty database password to fail\n' >&2
  exit 1
fi
printf 'database-password\n' >"$secrets_dir/db_password"
truncate -s 0 "$secrets_dir/telegram_bot_token"
if PATH="$tmp_dir/bin:$PATH" bash "$repo_root/scripts/verify-production-environment.sh" \
  "$environment_package" "$runtime_env" >/dev/null 2>&1; then
  printf 'expected empty Telegram token to fail\n' >&2
  exit 1
fi
printf 'telegram-token\n' >"$secrets_dir/telegram_bot_token"
printf 'invalid-recipient\n' >"$secrets_dir/age-recipient"
if PATH="$tmp_dir/bin:$PATH" bash "$repo_root/scripts/verify-production-environment.sh" \
  "$environment_package" "$runtime_env" >/dev/null 2>&1; then
  printf 'expected invalid age recipient to fail\n' >&2
  exit 1
fi
printf 'test-recipient\n' >"$secrets_dir/age-recipient"
printf 'invalid certificate\n' >"$tls_dir/server.crt"
if PATH="$tmp_dir/bin:$PATH" bash "$repo_root/scripts/verify-production-environment.sh" \
  "$environment_package" "$environment_package/production.env" >/dev/null 2>&1; then
  printf 'expected invalid TLS certificate to fail\n' >&2
  exit 1
fi
openssl x509 -req -sha256 -days 365 \
  -in "$tmp_dir/server.csr" -CA "$tls_dir/ca.crt" \
  -CAkey "$tmp_dir/ca.key" -CAserial "$tmp_dir/ca.srl" \
  -out "$tls_dir/server.crt" -extfile "$tmp_dir/server.ext" >/dev/null 2>&1
if MOCK_NGINX_ID=sha256:wrong PATH="$tmp_dir/bin:$PATH" \
  bash "$repo_root/scripts/verify-production-environment.sh" \
    "$environment_package" "$runtime_env" >/dev/null 2>&1; then
  printf 'expected unloaded manifest image to fail\n' >&2
  exit 1
fi

if (
  cd "$tmp_dir"
  PATH="$tmp_dir/bin:$PATH" bash "$repo_root/scripts/verify-production-environment.sh" \
    "$environment_package" "$runtime_env"
); then
  :
else
  printf 'expected model path to resolve independently from the current directory\n' >&2
  exit 1
fi

grep -Fx 'DB_PASSWORD_HOST_FILE=./secrets/db_password' "$repo_root/.env.example"
grep -Fx 'DB_ROOT_PASSWORD_HOST_FILE=./secrets/db_root_password' "$repo_root/.env.example"
grep -Fq 'DB_PASSWORD_HOST_FILE=/etc/chromat/secrets/db_password' \
  "$repo_root/scripts/package-artifacts.sh"
grep -Fq 'DB_ROOT_PASSWORD_HOST_FILE=/etc/chromat/secrets/db_root_password' \
  "$repo_root/scripts/package-artifacts.sh"
generated_production_env="$tmp_dir/production.env.example"
sed \
  -e 's/^APP_ENV=.*/APP_ENV=production/' \
  -e 's/^PULL_POLICY=.*/PULL_POLICY=never/' \
  -e 's#^CHROMAT_API_IMAGE=.*#CHROMAT_API_IMAGE=chromat-api:test-1#' \
  -e 's#^CHROMAT_INFERENCE_IMAGE=.*#CHROMAT_INFERENCE_IMAGE=chromat-inference:test-1#' \
  -e 's#^CHROMAT_DB_IMAGE=.*#CHROMAT_DB_IMAGE=mariadb:test-1#' \
  -e 's#^CHROMAT_NGINX_IMAGE=.*#CHROMAT_NGINX_IMAGE=nginx:test-1#' \
  -e 's#^MODEL_HOST_PATH=.*#MODEL_HOST_PATH=./model/deterministic-model.json#' \
  -e 's#^TLS_CERT_HOST_PATH=.*#TLS_CERT_HOST_PATH=/srv/chromat/tls/server.crt#' \
  -e 's#^TLS_KEY_HOST_PATH=.*#TLS_KEY_HOST_PATH=/srv/chromat/tls/server.key#' \
  -e 's#^DB_PASSWORD_HOST_FILE=.*#DB_PASSWORD_HOST_FILE=/etc/chromat/secrets/db_password#' \
  -e 's#^DB_ROOT_PASSWORD_HOST_FILE=.*#DB_ROOT_PASSWORD_HOST_FILE=/etc/chromat/secrets/db_root_password#' \
  -e 's#^TELEGRAM_BOT_TOKEN_HOST_FILE=.*#TELEGRAM_BOT_TOKEN_HOST_FILE=/etc/chromat/secrets/telegram_bot_token#' \
  "$repo_root/.env.example" >"$generated_production_env"
awk -F= '
  /^[[:space:]]*($|#)/ { next }
  !/=/ { exit 1 }
  ++keys[$1] > 1 { printf "duplicate production environment key: %s\n", $1 > "/dev/stderr"; exit 1 }
' "$generated_production_env"
grep -Fx 'BACKUP_ROOT=/srv/chromat/backups' "$generated_production_env"
if grep -Fq "printf 'BACKUP_ROOT=" "$repo_root/scripts/package-artifacts.sh"; then
  printf 'FAIL: artifact generator must not append BACKUP_ROOT\n' >&2
  exit 1
fi
for script in \
  prepare-ubuntu-production-host.sh \
  verify-production-environment.sh; do
  test -x "$repo_root/scripts/$script"
  test -x "$environment_package/scripts/$script"
done

printf 'tampered\n' >"$package_dir/images/api.tar"
if "$verifier" "$package_dir" >/dev/null 2>&1; then
  printf 'expected checksum verification to fail\n' >&2
  exit 1
fi

artifacts_runbook="$repo_root/docs/deployment/artifacts.md"
ubuntu_runbook="$repo_root/docs/installation/ubuntu-server-26.04.md"
for runbook in "$artifacts_runbook" "$ubuntu_runbook"; do
  grep -Fq 'promotion.md' "$runbook"
  if grep -Eq '^[[:space:]]*(sudo )?(ln|mv)[[:space:]]' "$runbook"; then
    printf 'activation runbook must not contain direct link replacement commands: %s\n' \
      "$runbook" >&2
    exit 1
  fi
done
grep -Fq 'LINK_STATE' "$artifacts_runbook"
grep -Fq 'BLOCKED' "$artifacts_runbook"
grep -Fq 'OPENED' "$artifacts_runbook"
grep -Fq 'LINK_STATE' "$ubuntu_runbook"
grep -Fq 'BLOCKED' "$ubuntu_runbook"
grep -Fq 'OPENED' "$ubuntu_runbook"
grep -Fq 'releases/download' "$artifacts_runbook"
grep -Fq 'releases/download' "$ubuntu_runbook"
grep -Fq 'create-github-draft-release.sh' "$artifacts_runbook"
grep -Fq 'cp -- "$package_dir/manifest.json" "$release_root/chromat-${version}.manifest.json"' \
  "$repo_root/scripts/package-artifacts.sh"
grep -Fq 'docs/installation/ubuntu-server-26.04.md' \
  "$repo_root/scripts/verify-artifacts.sh"
test -x "$repo_root/scripts/create-github-draft-release.sh"
"$repo_root/scripts/create-github-draft-release.sh" --help >/dev/null
if "$repo_root/scripts/create-github-draft-release.sh" invalid/version >/dev/null 2>&1; then
  printf 'expected invalid GitHub release version to fail\n' >&2
  exit 1
fi

printf 'PASS: artifact package verification contract\n'
