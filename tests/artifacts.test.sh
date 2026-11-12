#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$repo_root/scripts/verify-artifacts.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

package_dir="$tmp_dir/package"
mkdir -p \
  "$package_dir/images" \
  "$package_dir/model" \
  "$package_dir/scripts" \
  "$package_dir/tests/smoke" \
  "$package_dir/docs/deployment"
printf 'model\n' >"$package_dir/model/model.bin"
printf 'image\n' >"$package_dir/images/api.tar"
for path in \
  scripts/backup.sh \
  scripts/check-tls-expiry.sh \
  scripts/prepare-ubuntu-production-host.sh \
  scripts/verify-artifacts.sh \
  scripts/verify-production-environment.sh \
  scripts/verify-backup.sh \
  tests/smoke/run.sh \
  docs/deployment/promotion.md; do
  if [[ "$path" == "scripts/verify-artifacts.sh" ]]; then
    cp "$repo_root/scripts/verify-artifacts.sh" "$package_dir/$path"
  else
    printf 'operational file\n' >"$package_dir/$path"
  fi
  [[ "$path" != scripts/* ]] || chmod +x "$package_dir/$path"
done
(
  cd "$package_dir"
  find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum > checksums.sha256
)
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

printf 'PULL_POLICY=missing\n' >"$package_dir/invalid-production.env"
(
  cd "$package_dir"
  find . -type f ! -name checksums.sha256 -print0 | sort -z | xargs -0 sha256sum > checksums.sha256
)
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
for archive in api inference db nginx; do
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
printf '/mnt/chromat-backups\n'
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

printf 'PASS: artifact package verification contract\n'
