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
grep -Fq 'sudo "$ISOLATED_RELEASE_DIR/scripts/verify-backup.sh"' "$runbook"
if grep -Fq '/ruta/release' "$runbook"; then
  printf 'FAIL: production runbook contains a placeholder backup verifier path\n' >&2
  exit 1
fi
if grep -Eq -- 'MYSQL_PWD=|-[pP]"?\$\(cat /run/secrets/db_root_password\)' "$runbook"; then
  printf 'FAIL: production runbook exposes the MariaDB password through argv or environment\n' >&2
  exit 1
fi
grep -Fq 'mktemp /tmp/chromat-mariadb.XXXXXX' "$runbook"
grep -Fq 'mariadb --defaults-extra-file="$defaults_file"' "$runbook"
grep -Fq 'trap cleanup_link_state_tmp EXIT' "$runbook"
grep -Fq 'trap cleanup_defaults EXIT' "$runbook"
if grep -Fq 'trap cleanup_link_state_tmp EXIT HUP INT TERM' "$runbook" ||
  grep -Fq 'trap cleanup_defaults EXIT HUP INT TERM' "$runbook"; then
  printf 'FAIL: cleanup traps must not consume termination signals\n' >&2
  exit 1
fi
for signal_spec in \
  "trap 'exit 129' HUP" \
  "trap 'exit 130' INT" \
  "trap 'exit 143' TERM"; do
  if (( $(grep -Fc "$signal_spec" "$runbook") != 2 )); then
    printf 'FAIL: both cleanup blocks must preserve %s\n' "$signal_spec" >&2
    exit 1
  fi
done
grep -Fq 'CHROMAT_ROOT="${CHROMAT_ROOT:-/srv/chromat}"' "$runbook"
grep -Fq 'LINK_STATE="$CHROMAT_ROOT/.promotion-link-state"' "$runbook"
grep -Fq 'LINK_STATE_TMP="$(mktemp "$CHROMAT_ROOT/.promotion-link-state.XXXXXX")"' "$runbook"
if grep -Fq 'mktemp /srv/chromat/.promotion-link-state.XXXXXX' "$runbook"; then
  printf 'FAIL: promotion state temporary path must use CHROMAT_ROOT\n' >&2
  exit 1
fi
grep -Fq 'chmod 0600 "$LINK_STATE_TMP"' "$runbook"
grep -Fq 'mv -fT -- "$LINK_STATE_TMP" "$LINK_STATE"' "$runbook"
grep -Fq 'UFW por sí solo no demuestra' "$runbook"
grep -Fq 'otro equipo de' "$runbook"
grep -Fq 'sshd -T' "$runbook"
grep -Fq 'ufw allow "${ssh_port}/tcp"' "$runbook"
grep -Fq 'ufw --force enable' "$runbook"
grep -Fq "CHROMAT validation" "$runbook"
grep -Fq 'external_https_result' "$runbook"
grep -Fq 'CHROMAT validation rule remains installed' "$runbook"
ssh_line="$(grep -n 'sshd -T' "$runbook" | head -n 1 | cut -d: -f1)"
ufw_enable_line="$(grep -n 'ufw --force enable' "$runbook" | head -n 1 | cut -d: -f1)"
initial_start_line="$(grep -n 'compose up -d' "$runbook" | head -n 1 | cut -d: -f1)"
if (( ssh_line >= ufw_enable_line || ufw_enable_line >= initial_start_line )); then
  printf 'FAIL: UFW must preserve SSH and be active before initial services start\n' >&2
  exit 1
fi
grep -Fq 'Fallo antes de cambiar `active`' "$runbook"
grep -Fq 'Fallo después de cambiar `active`' "$runbook"
grep -Fq 'No intercambies enlaces' "$runbook"
grep -Fq 'Fallo entre los dos cambios de enlace' "$runbook"
grep -Fq 'recover-release-links.sh' "$runbook"
test -x "$repo_root/scripts/recover-release-links.sh"
grep -Fq -- '--lock-file' "$repo_root/scripts/recover-release-links.sh"
grep -Fq 'exec 9<>"$lock_file"' "$repo_root/scripts/recover-release-links.sh"
grep -Fq 'flock -n' "$repo_root/scripts/recover-release-links.sh"
grep -Fq 'CHROMAT_PROMOTION_LOCK_HELD' "$repo_root/scripts/recover-release-links.sh"
grep -Fq 'lock file must be owned by root' "$repo_root/scripts/recover-release-links.sh"
grep -Fq 'lock file must have mode 0600' "$repo_root/scripts/recover-release-links.sh"
grep -Fq 'writable lock directory must have the sticky bit' "$repo_root/scripts/recover-release-links.sh"
grep -Fq 'lock file must be owned by root' "$runbook"
grep -Fq 'lock file must have mode 0600' "$runbook"
grep -Fq 'writable lock directory must have the sticky bit' "$runbook"
links_dir="$(mktemp -d)"
trap 'rm -rf "$links_dir"' EXIT
fake_bin="$links_dir/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/stat" <<'EOF'
#!/usr/bin/env bash
last_argument="${!#}"
if [[ "$1" == -c && "$2" == %u ]]; then
  case "$last_argument" in
    "$RECOVERY_STATE_PATH") printf '%s\n' "${FAKE_STATE_OWNER:-0}"; exit 0 ;;
    "$RECOVERY_LOCK_PATH") printf '%s\n' "${FAKE_LOCK_OWNER:-0}"; exit 0 ;;
    "$RECOVERY_LOCK_PARENT") printf '%s\n' "${FAKE_LOCK_PARENT_OWNER:-0}"; exit 0 ;;
  esac
fi
if [[ "$1" == -c && "$2" == %a && "$last_argument" == "$RECOVERY_LOCK_PARENT" ]]; then
  printf '%s\n' "${FAKE_LOCK_PARENT_MODE:-700}"
  exit 0
fi
exec /usr/bin/stat "$@"
EOF
chmod +x "$fake_bin/stat"
export RECOVERY_LOCK_PATH="$links_dir/promotion.lock"
export RECOVERY_LOCK_PARENT="$links_dir"
mkdir -p "$links_dir/releases/active-original" "$links_dir/releases/previous-original" \
  "$links_dir/releases/interrupted-release"
ln -s "$links_dir/releases/active-original" "$links_dir/active"
ln -s "$links_dir/releases/previous-original" "$links_dir/previous"
write_link_state() {
  cat >"$links_dir/.promotion-link-state" <<EOF
active_exists=$1
active_target=$2
previous_exists=$3
previous_target=$4
EOF
  chmod 0600 "$links_dir/.promotion-link-state"
}
write_link_state \
  1 "$links_dir/releases/active-original" 1 "$links_dir/releases/previous-original"

# Simulate interruption after previous was replaced but before active was replaced.
ln -s "$links_dir/releases/active-original" "$links_dir/.previous.next"
mv -Tf "$links_dir/.previous.next" "$links_dir/previous"
ln -s "$links_dir/releases/interrupted-release" "$links_dir/.active.next"
ln -s "$links_dir/releases/interrupted-release" "$links_dir/.previous.next"
PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"
test "$(readlink -f "$links_dir/active")" = "$links_dir/releases/active-original"
test "$(readlink -f "$links_dir/previous")" = "$links_dir/releases/previous-original"
test ! -e "$links_dir/.active.next"
test ! -e "$links_dir/.previous.next"
test ! -e "$links_dir/.promotion-link-state"

write_link_state 1 "$links_dir/releases/active-original" 1 "$links_dir/releases/previous-original"
rm -f "$links_dir/active" "$links_dir/previous"
ln -s "$links_dir/releases/interrupted-release" "$links_dir/active"
ln -s "$links_dir/releases/interrupted-release" "$links_dir/previous"
cat >"$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
last_argument="${!#}"
if [[ "$last_argument" == "$RECOVERY_TEST_ROOT/active" ]]; then
  exit 1
fi
exec /bin/mv "$@"
EOF
chmod +x "$fake_bin/mv"
if RECOVERY_TEST_ROOT="$links_dir" PATH="$fake_bin:$PATH" \
  RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery accepted a failed link restoration\n' >&2
  exit 1
fi
test -e "$links_dir/.promotion-link-state"
test "$(readlink -f "$links_dir/previous")" = "$links_dir/releases/previous-original"
rm "$fake_bin/mv"
PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"

# A missing original previous link is restored as missing, not inferred from active.
rm -f "$links_dir/previous"
write_link_state 1 "$links_dir/releases/active-original" 0 ''
ln -s "$links_dir/releases/interrupted-release" "$links_dir/active"
ln -s "$links_dir/releases/active-original" "$links_dir/previous"
PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"
test "$(readlink -f "$links_dir/active")" = "$links_dir/releases/active-original"
test ! -e "$links_dir/previous"
test ! -e "$links_dir/.promotion-link-state"

write_link_state 1 "$links_dir/releases/active-original" 1 "$links_dir/releases/previous-original"
sed -i '$d' "$links_dir/.promotion-link-state"
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery accepted incomplete state\n' >&2
  exit 1
fi
test -e "$links_dir/.promotion-link-state"

write_link_state 1 "$links_dir/releases/active-original" 0 ''
printf 'unchanged lock target\n' >"$links_dir/lock-target"
ln -sf "$links_dir/lock-target" "$links_dir/promotion.lock"
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery accepted a symbolic lock file\n' >&2
  exit 1
fi
test "$(cat "$links_dir/lock-target")" = 'unchanged lock target'
test -e "$links_dir/.promotion-link-state"
rm "$links_dir/promotion.lock"
mkdir "$links_dir/promotion.lock"
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery accepted a non-regular lock file\n' >&2
  exit 1
fi
test -e "$links_dir/.promotion-link-state"
rmdir "$links_dir/promotion.lock"

write_link_state 1 "$links_dir/releases/active-original" 0 ''
touch "$links_dir/promotion.lock"
chmod 0644 "$links_dir/promotion.lock"
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery accepted a non-restrictive lock file\n' >&2
  exit 1
fi
test -e "$links_dir/.promotion-link-state"
chmod 0600 "$links_dir/promotion.lock"
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  FAKE_LOCK_OWNER=1000 \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery accepted a non-root-owned lock file\n' >&2
  exit 1
fi
test -e "$links_dir/.promotion-link-state"
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  FAKE_LOCK_PARENT_OWNER=1000 \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery accepted a non-root-owned lock directory\n' >&2
  exit 1
fi
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  FAKE_LOCK_PARENT_MODE=777 \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery accepted a non-sticky writable lock directory\n' >&2
  exit 1
fi
test -e "$links_dir/.promotion-link-state"

write_link_state 1 "$links_dir/releases/active-original" 1 "$links_dir/releases/previous-original"
rm -f "$links_dir/active"
mkdir "$links_dir/active"
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery replaced a non-symlink release path\n' >&2
  exit 1
fi
test -d "$links_dir/active"
test -e "$links_dir/.promotion-link-state"
rmdir "$links_dir/active"
ln -s "$links_dir/releases/interrupted-release" "$links_dir/active"

touch "$links_dir/.active.next"
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery removed a non-symlink temporary path\n' >&2
  exit 1
fi
test -f "$links_dir/.active.next"
test -e "$links_dir/.promotion-link-state"
rm "$links_dir/.active.next"

write_link_state 1 "$links_dir/releases/missing-release" 0 ''
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery accepted a missing persisted target\n' >&2
  exit 1
fi
test -e "$links_dir/.promotion-link-state"

write_link_state 1 "$links_dir/releases/active-original" 0 ''
chmod 0644 "$links_dir/.promotion-link-state"
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery accepted a non-restrictive state file\n' >&2
  exit 1
fi
test -e "$links_dir/.promotion-link-state"
chmod 0600 "$links_dir/.promotion-link-state"

mv "$links_dir/.promotion-link-state" "$links_dir/state.regular"
ln -s "$links_dir/state.regular" "$links_dir/.promotion-link-state"
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery accepted a symlinked state file\n' >&2
  exit 1
fi
test -L "$links_dir/.promotion-link-state"
rm "$links_dir/.promotion-link-state"
mv "$links_dir/state.regular" "$links_dir/.promotion-link-state"

write_link_state 1 "$links_dir/outside-release" 0 ''
mkdir -p "$links_dir/outside-release"
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery accepted a target outside releases\n' >&2
  exit 1
fi
test -e "$links_dir/.promotion-link-state"

write_link_state 1 "$links_dir/releases/active-original" 0 ''
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  FAKE_STATE_OWNER=1000 \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: release-link recovery accepted a non-root-owned state file\n' >&2
  exit 1
fi
test -e "$links_dir/.promotion-link-state"

write_link_state 1 "$links_dir/releases/active-original" 1 "$links_dir/releases/previous-original"
cat >"$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
last_argument="${!#}"
if [[ "$last_argument" == "$RECOVERY_TEST_ROOT/previous" ]]; then
  : >"$RECOVERY_TEST_HOLD"
  sleep 2
fi
exec /bin/mv "$@"
EOF
chmod +x "$fake_bin/mv"
RECOVERY_TEST_ROOT="$links_dir" RECOVERY_TEST_HOLD="$links_dir/recovery-holds-lock" \
  PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock" &
recovery_pid=$!
for _ in {1..20}; do
  test -e "$links_dir/recovery-holds-lock" && break
  sleep 0.1
done
test -e "$links_dir/recovery-holds-lock"
if PATH="$fake_bin:$PATH" RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"; then
  printf 'FAIL: concurrent release-link recovery acquired the promotion lock\n' >&2
  exit 1
fi
test -e "$links_dir/.promotion-link-state"
wait "$recovery_pid"
test ! -e "$links_dir/.promotion-link-state"
rm "$fake_bin/mv"

write_link_state 1 "$links_dir/releases/active-original" 0 ''
exec 9<>"$links_dir/promotion.lock"
flock -n 9
CHROMAT_PROMOTION_LOCK_HELD=1 PATH="$fake_bin:$PATH" \
  RECOVERY_STATE_PATH="$links_dir/.promotion-link-state" \
  bash "$repo_root/scripts/recover-release-links.sh" \
    --root "$links_dir" --state "$links_dir/.promotion-link-state" \
    --lock-file "$links_dir/promotion.lock"
test ! -e "$links_dir/.promotion-link-state"
exec 9>&-

if (( $(grep -Fc 'ensure_https_blocked' "$runbook") < 3 )); then
  printf 'FAIL: UFW HTTPS blocking must cover its definition, installation, and update\n' >&2
  exit 1
fi
if grep -Fq '. /etc/chromat/production.env' "$runbook"; then
  printf 'FAIL: production runbook must not source its environment before sudo\n' >&2
  exit 1
fi

verify_artifacts_line="$(grep -n '"\$RELEASE_DIR/scripts/verify-artifacts.sh"' "$runbook" | head -n 1 | cut -d: -f1)"
link_state_line="$(grep -n 'LINK_STATE="$CHROMAT_ROOT/.promotion-link-state"' "$runbook" | head -n 1 | cut -d: -f1)"
docker_load_line="$(grep -n 'sudo docker load --input' "$runbook" | head -n 1 | cut -d: -f1)"
verify_environment_line="$(grep -n 'verify-production-environment.sh' "$runbook" | head -n 1 | cut -d: -f1)"
if (( link_state_line >= verify_artifacts_line || verify_artifacts_line >= docker_load_line || docker_load_line >= verify_environment_line )); then
  printf 'FAIL: link state, package verification, docker load, and preflight are not ordered correctly\n' >&2
  exit 1
fi
blocked_confirmation_line="$(grep -n 'external_https_blocked_result' "$runbook" | head -n 1 | cut -d: -f1)"
validation_delete_line="$(grep -n 'ufw --force delete "$validation_rule"' "$runbook" | head -n 1 | cut -d: -f1)"
opened_confirmation_line="$(grep -n 'external_https_result' "$runbook" | head -n 1 | cut -d: -f1)"
link_state_removal_line="$(grep -n 'rm -f -- "$LINK_STATE"' "$runbook" | tail -n 1 | cut -d: -f1)"
if (( blocked_confirmation_line >= validation_delete_line ||
      validation_delete_line >= opened_confirmation_line ||
      opened_confirmation_line >= link_state_removal_line )); then
  printf 'FAIL: external HTTPS confirmations do not guard validation removal and finalization\n' >&2
  exit 1
fi
grep -Fq 'if test "$external_https_blocked_result" != BLOCKED; then' "$runbook"
grep -Fq 'if test "$external_https_result" != OPENED; then' "$runbook"
if (( $(grep -Fc 'CHROMAT_PROMOTION_LOCK_HELD=1' "$runbook") < 2 )); then
  printf 'FAIL: same-shell rollback must reuse the held promotion lock\n' >&2
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
if grep -Eq '^[[:space:]]*(sudo[[:space:]]+)?docker compose (build|pull)([[:space:]]|$)' \
  "$runbook"; then
  printf 'FAIL: production runbook must not build or pull images\n' >&2
  exit 1
fi

ufw_test_dir="$links_dir/ufw"
mkdir -p "$ufw_test_dir/bin" "$ufw_test_dir/state"
awk '
  /^ensure_https_blocked\(\) \{/ { printing = 1 }
  printing {
    print
    opens = gsub(/\{/, "&")
    closes = gsub(/\}/, "&")
    depth += opens - closes
    if (depth == 0) {
      exit
    }
  }
' "$runbook" >"$ufw_test_dir/ensure_https_blocked.sh"
# shellcheck source=/dev/null
source "$ufw_test_dir/ensure_https_blocked.sh"
cat >"$ufw_test_dir/bin/sshd" <<'EOF'
#!/usr/bin/env bash
printf 'port 22\n'
EOF
cat >"$ufw_test_dir/bin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n'
EOF
cat >"$ufw_test_dir/bin/ufw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${UFW_TEST_STATE:?}"
case "$1" in
  status)
    printf 'Status: %s\n' "$(cat "$state/status" 2>/dev/null || printf inactive)"
    [[ "${2:-}" == numbered ]] || exit 0
    if [[ -f "$state/deny-ssh" ]]; then
      printf '[ 1] 22/tcp DENY IN Anywhere\n'
    fi
    if [[ -f "$state/ssh-rules" ]]; then
      while IFS= read -r rule; do
        printf '[ 1] %s ALLOW IN Anywhere\n' "$rule"
      done <"$state/ssh-rules"
    fi
    if [[ -f "$state/validation" ]]; then
      printf '[ 2] 443/tcp DENY IN Anywhere # CHROMAT validation\n'
    fi
    ;;
  allow)
    [[ "${UFW_IGNORE_ALLOW:-0}" == 0 ]] || exit 0
    rule="$2"
    grep -Fxq "$rule" "$state/ssh-rules" 2>/dev/null ||
      printf '%s\n' "$rule" >>"$state/ssh-rules"
    ;;
  insert)
    touch "$state/validation"
    printf 'insert\n' >>"$state/inserts"
    ;;
  --force)
    [[ "$2" == enable ]] && printf active >"$state/status"
    ;;
  *)
    printf 'unexpected ufw invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$ufw_test_dir/bin/sshd" "$ufw_test_dir/bin/ss" "$ufw_test_dir/bin/ufw"
printf active >"$ufw_test_dir/state/status"
touch "$ufw_test_dir/state/deny-ssh"
original_path="$PATH"
export PATH="$ufw_test_dir/bin:$PATH"
export UFW_TEST_STATE="$ufw_test_dir/state"
export CHROMAT_SSH_PORT=22
export UFW_IGNORE_ALLOW=1
if (
  ensure_https_blocked
); then
  printf 'FAIL: HTTPS setup accepted an SSH DENY rule as protection\n' >&2
  exit 1
fi
unset UFW_IGNORE_ALLOW
rm "$ufw_test_dir/state/deny-ssh"
ensure_https_blocked
ensure_https_blocked
test "$(wc -l <"$ufw_test_dir/state/inserts")" -eq 1
test -f "$ufw_test_dir/state/validation"
export PATH="$original_path"
unset UFW_TEST_STATE CHROMAT_SSH_PORT

mariadb_test_dir="$(mktemp -d)"
trap 'rm -rf "$links_dir" "$mariadb_test_dir"' EXIT
mkdir -p "$mariadb_test_dir/bin"
awk '
  /^mariadb_query\(\) \{/ { printing = 1 }
  printing { print }
  printing && /^}$/ { exit }
' "$runbook" >"$mariadb_test_dir/mariadb_query.sh"
# shellcheck source=/dev/null
source "$mariadb_test_dir/mariadb_query.sh"
cat >"$mariadb_test_dir/bin/cat" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$MARIADB_TEST_PASSWORD"
EOF
cat >"$mariadb_test_dir/bin/mariadb" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in
    --defaults-extra-file=*)
      defaults_file="${argument#*=}"
      ;;
  esac
done
test -n "${defaults_file:-}"
test -f "$defaults_file"
cp "$defaults_file" "$MARIADB_TEST_CAPTURE"
printf '%s\n' "$defaults_file" >"$MARIADB_TEST_DEFAULTS_PATH"
test "${MARIADB_TEST_RESULT:-success}" = success
EOF
chmod +x "$mariadb_test_dir/bin/cat" "$mariadb_test_dir/bin/mariadb"
compose() {
  PATH="$mariadb_test_dir/bin:$PATH" "$4" "$5" "$6" "$7" "$8"
}
MARIADB_TEST_PASSWORD='quote"and\backslash' \
  MARIADB_TEST_CAPTURE="$mariadb_test_dir/client-success.cnf" \
  MARIADB_TEST_DEFAULTS_PATH="$mariadb_test_dir/defaults-success.path" \
  mariadb_query 'SELECT 1'
grep -Fx 'password="quote\"and\\backslash"' \
  "$mariadb_test_dir/client-success.cnf"
test ! -e "$(cat "$mariadb_test_dir/defaults-success.path")"
if MARIADB_TEST_PASSWORD='quote"and\backslash' \
  MARIADB_TEST_CAPTURE="$mariadb_test_dir/client-error.cnf" \
  MARIADB_TEST_DEFAULTS_PATH="$mariadb_test_dir/defaults-error.path" \
  MARIADB_TEST_RESULT=error \
  mariadb_query 'SELECT 1'; then
  printf 'FAIL: MariaDB query accepted client failure\n' >&2
  exit 1
fi
test ! -e "$(cat "$mariadb_test_dir/defaults-error.path")"

if output="$(
  env -u CA_CERT -u ALLOW_INSECURE_TLS \
    bash "$repo_root/tests/smoke/run.sh" 2>&1
)"; then
  printf 'FAIL: smoke runner accepted missing CA_CERT\n' >&2
  exit 1
fi
grep -q 'CA_CERT' <<<"$output"

printf 'PASS: promotion contract\n'
