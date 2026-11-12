#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runbook="$repo_root/docs/deployment/promotion.md"
ubuntu_runbook="$repo_root/docs/installation/ubuntu-server-26.04.md"

test -x "$repo_root/tests/smoke/aggregation.sh"
test -x "$repo_root/tests/smoke/migrations.sh"
grep -q 'aggregation' "$repo_root/tests/smoke/run.sh"
grep -q 'migrations' "$repo_root/tests/smoke/run.sh"

for required_phrase in \
  "backup" \
  "verific" \
  "migracion" \
  "readiness" \
  "smoke" \
  "apertura" \
  "rollback" \
  "down-migration" \
  "telegram" \
  "CA_CERT" \
  "idempot" \
  "capacidad" \
  "agreg" \
  "limpieza"; do
  grep -qi "$required_phrase" "$runbook"
done
grep -Fq -- '--project-directory "$RELEASE_DIR"' "$runbook"
grep -Fq -- '-f "$RELEASE_DIR/compose.yaml"' "$runbook"
grep -Fq 'sudo docker load --input "$image_archive"' "$runbook"
grep -Fq 'sudo docker compose' "$runbook"
grep -Fq 'no construye ni descarga imágenes' "$runbook"
grep -Fq -- '--config /etc/chromat/production.env --mode full' "$runbook"
grep -Fq -- '--identity-file /media/custodian/backup-age-identity' "$runbook"
if grep -Fq '. /etc/chromat/production.env' "$runbook"; then
  printf 'FAIL: production runbook must not source its environment before sudo\n' >&2
  exit 1
fi

verify_artifacts_line="$(grep -n 'verify-artifacts.sh' "$runbook" | head -n 1 | cut -d: -f1)"
docker_load_line="$(grep -n 'sudo docker load --input' "$runbook" | head -n 1 | cut -d: -f1)"
verify_environment_line="$(grep -n 'verify-production-environment.sh' "$runbook" | head -n 1 | cut -d: -f1)"
if (( verify_artifacts_line >= docker_load_line || docker_load_line >= verify_environment_line )); then
  printf 'FAIL: package verification, docker load, and preflight are not ordered correctly\n' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*docker (compose|load|inspect)' "$runbook"; then
  printf 'FAIL: production runbook contains Docker commands without sudo\n' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*docker (compose|load|inspect)' "$ubuntu_runbook"; then
  printf 'FAIL: Ubuntu production runbook contains Docker commands without sudo\n' >&2
  exit 1
fi
if grep -Fq 'group docker' "$ubuntu_runbook" && ! grep -Fq 'no se añade al administrador al grupo `docker`' "$ubuntu_runbook"; then
  printf 'FAIL: Ubuntu production runbook must not add administrators to the Docker group\n' >&2
  exit 1
fi
if grep -Eq 'docker compose (build|pull)' "$runbook"; then
  printf 'FAIL: production runbook must not build or pull images\n' >&2
  exit 1
fi

if output="$(
  env -u CA_CERT -u ALLOW_INSECURE_TLS \
    bash "$repo_root/tests/smoke/run.sh" 2>&1
)"; then
  printf 'FAIL: smoke runner accepted missing CA_CERT\n' >&2
  exit 1
fi
grep -q 'CA_CERT' <<<"$output"

printf 'PASS: promotion contract\n'
