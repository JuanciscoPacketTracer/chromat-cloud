#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  printf 'Usage: %s <artifact-package-directory> <production-env-file>\n' "$0" >&2
  exit 2
fi

package_dir="$(realpath -e -- "$1")"
env_file="$(realpath -e -- "$2")"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/lib/backup-config.sh"
"$package_dir/scripts/verify-artifacts.sh" "$package_dir"

verification_data="$(
  python3 - "$package_dir/manifest.json" "$env_file" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
package_dir = pathlib.Path(sys.argv[1]).resolve().parent
values = {}
for line in pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        raise SystemExit(f"invalid production environment line: {line!r}")
    key, value = line.split("=", 1)
    if key in values:
        raise SystemExit(f"duplicate production environment key: {key}")
    values[key] = value

if values.get("PULL_POLICY") != "never":
    raise SystemExit("production environment must set PULL_POLICY=never")
images = {
    "images/api.tar": "CHROMAT_API_IMAGE",
    "images/inference.tar": "CHROMAT_INFERENCE_IMAGE",
    "images/db.tar": "CHROMAT_DB_IMAGE",
    "images/nginx.tar": "CHROMAT_NGINX_IMAGE",
}
if {image["archive"] for image in manifest["images"]} != set(images):
    raise SystemExit("manifest must contain exactly the required image archives")
for image in manifest["images"]:
    key = images.get(image["archive"])
    if key is None:
        raise SystemExit(f"unsupported image archive in manifest: {image['archive']}")
    if values.get(key) != image["name"]:
        raise SystemExit(f"{key} does not match manifest image {image['name']}")
    if not image.get("id"):
        raise SystemExit(f"manifest image is missing id: {image['name']}")

expected = {
    "MODEL_HOST_PATH": "./model/deterministic-model.json",
}
for key, value in expected.items():
    if values.get(key) != value:
        raise SystemExit(f"{key} must be {value}")

for key in (
    "DB_PASSWORD_HOST_FILE",
    "DB_ROOT_PASSWORD_HOST_FILE",
    "TLS_CERT_HOST_PATH",
    "TLS_KEY_HOST_PATH",
    "BACKUP_AGE_RECIPIENT_FILE",
):
    value = values.get(key)
    if not value or not value.startswith("/"):
        raise SystemExit(f"{key} must be an absolute host path")
    print(f"FILE\t{key}\t{value}")

backup_external_dir = values.get("BACKUP_EXTERNAL_DIR")
if not backup_external_dir or not backup_external_dir.startswith("/"):
    raise SystemExit("BACKUP_EXTERNAL_DIR must be an absolute host path")
print(f"DIRECTORY\tBACKUP_EXTERNAL_DIR\t{backup_external_dir}")

backup_secret_files = values.get("BACKUP_SECRET_FILES", "").split()
if not backup_secret_files:
    raise SystemExit("BACKUP_SECRET_FILES must list service secret files")
for backup_secret_file in backup_secret_files:
    if not backup_secret_file.startswith("/"):
        raise SystemExit(
            "BACKUP_SECRET_FILES must contain only absolute host paths"
        )
    print(f"BACKUP_SECRET\tBACKUP_SECRET_FILES\t{backup_secret_file}")

telegram_token = values.get("TELEGRAM_BOT_TOKEN_HOST_FILE")
if not telegram_token or not telegram_token.startswith("/"):
    raise SystemExit("TELEGRAM_BOT_TOKEN_HOST_FILE must be an absolute host path")
print(f"FILE\tTELEGRAM_BOT_TOKEN_HOST_FILE\t{telegram_token}")

model_path = (package_dir / values["MODEL_HOST_PATH"]).resolve()
expected_model = (package_dir / manifest["model_path"]).resolve()
if model_path != expected_model or not model_path.is_file():
    raise SystemExit("MODEL_HOST_PATH does not resolve to the packaged model")

for image in manifest["images"]:
    print(f"IMAGE\t{image['name']}\t{image['id']}")
PY
)"

db_password=
db_root_password=
tls_cert=
tls_key=
age_recipient=
telegram_token=
backup_external_dir=
backup_secret_files=()
image_names=()
image_ids=()
while IFS=$'\t' read -r kind key value; do
  if [[ "$kind" == "FILE" ]]; then
    [[ -f "$value" && -r "$value" ]] || {
      printf 'required production file is unreadable: %s\n' "$value" >&2
      exit 1
    }
    case "$key" in
      DB_PASSWORD_HOST_FILE) db_password="$value" ;;
      DB_ROOT_PASSWORD_HOST_FILE) db_root_password="$value" ;;
      TLS_CERT_HOST_PATH) tls_cert="$value" ;;
      TLS_KEY_HOST_PATH) tls_key="$value" ;;
      BACKUP_AGE_RECIPIENT_FILE) age_recipient="$value" ;;
      TELEGRAM_BOT_TOKEN_HOST_FILE) telegram_token="$value" ;;
    esac
  elif [[ "$kind" == "DIRECTORY" ]]; then
    [[ -d "$value" && -w "$value" ]] || {
      printf 'required backup directory is not writable: %s\n' "$value" >&2
      exit 1
    }
    backup_external_dir="$value"
  elif [[ "$kind" == "BACKUP_SECRET" ]]; then
    [[ -f "$value" && -r "$value" ]] || {
      printf 'configured backup secret is unreadable: %s\n' "$value" >&2
      exit 1
    }
    grep -q '[^[:space:]]' "$value" || {
      printf 'configured backup secret is empty: %s\n' "$value" >&2
      exit 1
    }
    case "$(basename "$value")" in
      ca.key|ca-root.key)
        printf 'BACKUP_SECRET_FILES must not include a CA private key: %s\n' "$value" >&2
        exit 1
        ;;
    esac
    backup_secret_files+=("$value")
  elif [[ "$kind" == "IMAGE" ]]; then
    image_names+=("$key")
    image_ids+=("$value")
  fi
done <<<"$verification_data"

require_independent_external_mount "$backup_external_dir"
for required_backup_secret in "$db_password" "$db_root_password" "$telegram_token"; do
  found=0
  for backup_secret in "${backup_secret_files[@]}"; do
    [[ "$backup_secret" == "$required_backup_secret" ]] && found=1
  done
  (( found )) || {
    printf 'BACKUP_SECRET_FILES must include required service secret: %s\n' \
      "$required_backup_secret" >&2
    exit 1
  }
done

for secret_file in "$db_password" "$db_root_password" "$telegram_token"; do
  grep -q '[^[:space:]]' "$secret_file" || {
    printf 'required service secret is empty: %s\n' "$secret_file" >&2
    exit 1
  }
done
grep -q '[^[:space:]]' "$age_recipient" || {
  printf 'backup age recipient is empty: %s\n' "$age_recipient" >&2
  exit 1
}
age -R "$age_recipient" -o /dev/null /dev/null

tls_dir="$(dirname "$tls_cert")"
ca_cert="$tls_dir/ca.crt"
[[ -f "$ca_cert" && -r "$ca_cert" ]] || {
  printf 'TLS CA certificate is unreadable: %s\n' "$ca_cert" >&2
  exit 1
}
openssl x509 -in "$tls_cert" -noout >/dev/null
openssl x509 -in "$ca_cert" -noout >/dev/null
openssl pkey -in "$tls_key" -noout >/dev/null
openssl verify -CAfile "$ca_cert" "$tls_cert" >/dev/null
openssl x509 -in "$tls_cert" -checkhost chromat.lan -noout >/dev/null
openssl x509 -in "$tls_cert" -noout -ext extendedKeyUsage |
  grep -Eq 'TLS Web Server Authentication|serverAuth|1\.3\.6\.1\.5\.5\.7\.3\.1' || {
  printf 'TLS certificate must include extended key usage serverAuth\n' >&2
  exit 1
}
cert_public_key="$(
  openssl x509 -in "$tls_cert" -pubkey -noout |
    openssl pkey -pubin -outform DER |
    sha256sum
)"
key_public_key="$(
  openssl pkey -in "$tls_key" -pubout -outform DER |
    sha256sum
)"
[[ "$cert_public_key" == "$key_public_key" ]] || {
  printf 'TLS key does not match certificate\n' >&2
  exit 1
}

command -v docker >/dev/null || {
  printf 'docker is required to verify loaded images\n' >&2
  exit 1
}
for index in "${!image_names[@]}"; do
  actual_id="$(docker image inspect --format '{{.Id}}' "${image_names[$index]}")"
  [[ "$actual_id" == "${image_ids[$index]}" ]] || {
    printf 'loaded image ID does not match manifest: %s\n' "${image_names[$index]}" >&2
    exit 1
  }
done

printf 'PASS: production environment verified: %s\n' "$env_file"
