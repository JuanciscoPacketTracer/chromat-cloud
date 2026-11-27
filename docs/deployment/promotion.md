# Promoción reproducible en Ubuntu

> **Histórico / aplazado:** la prohibición de Git/builds y los requisitos de
> backup/rollback que siguen pertenecen al flujo offline anterior.
> [ADR-0010](../adr/0010-desarrollo-y-despliegue-desde-git.md) lo sustituye como
> ruta principal por [Git + Docker Compose](../installation/git-compose.md).

Este runbook distingue estrictamente instalación inicial y actualización. Un
fallo aborta y mantiene `active`, `previous`, volúmenes y datos. No hay
down-migrations, `git pull`, descarga o construcción mediante Compose, ni
`docker compose down -v`.

## Flujo de release

El empaquetado ocurre en el host de construcción, no en Ubuntu. Para una
versión parametrizada:

```bash
VERSION="${VERSION:?set VERSION to the release version}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-dist/artifacts}"
PACKAGE_DIR="$ARTIFACT_ROOT/$VERSION"
```

`scripts/package-artifacts.sh` construye las cuatro imágenes de Compose,
descarga BusyBox como imagen auxiliar fijada por digest, exporta los cinco TAR
y genera el manifest. La verificación estática se ejecuta sobre `PACKAGE_DIR`;
la verificación semántica carga los TAR en Docker, comprueba los IDs/config
digest y arquitecturas, y no realiza pulls ni builds.

Antes de crear cualquier Draft Release deben pasar ambas verificaciones sobre
el mismo directorio:

```bash
scripts/verify-artifacts.sh "$PACKAGE_DIR"
scripts/verify-image-artifacts.sh "$PACKAGE_DIR"
scripts/create-github-draft-release.sh "$VERSION" "$ARTIFACT_ROOT"
```

`create-github-draft-release.sh` repite obligatoriamente la verificación
estática y semántica antes de invocar GitHub CLI. Si Docker, la carga, un ID,
una arquitectura o cualquier comprobación falla, no crea el Draft Release.
El Draft permanece sin publicar hasta completar la validación operativa en
Ubuntu.

En producción no se ejecutan `docker compose pull`, `docker compose build`,
`docker pull`, `git pull` ni builds. Ubuntu descarga los activos publicados,
comprueba el checksum, extrae el paquete, verifica su contenido, carga los TAR
existentes y ejecuta Compose con `PULL_POLICY=never`.

## Controles comunes

Ejecuta una sola promoción desde un shell root con evidencia local. `pipefail`
garantiza que un fallo de verificación, carga, migración o smoke no quede
oculto por `tee`:

```bash
CHROMAT_SSH_PORT="${CHROMAT_SSH_PORT:-${SSH_CONNECTION##* }}"
[[ "$CHROMAT_SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] &&
  (( CHROMAT_SSH_PORT <= 65535 )) || {
  echo "set CHROMAT_SSH_PORT to the current administrative SSH port" >&2
  exit 1
}
sudo env "CHROMAT_SSH_PORT=$CHROMAT_SSH_PORT" bash
set -euo pipefail
umask 077
CHROMAT_ROOT="${CHROMAT_ROOT:-/srv/chromat}"
RELEASE_ROOT="${RELEASE_ROOT:-$CHROMAT_ROOT/releases}"
EVIDENCE_ROOT="${EVIDENCE_ROOT:-/var/log/chromat/promotions}"
VERSION="${VERSION:?set VERSION to the release version}"
RELEASE_DIR="$RELEASE_ROOT/$VERSION"
EVIDENCE_DIR="$EVIDENCE_ROOT/$VERSION"
old_active=
old_previous=
old_active_exists=0
old_previous_exists=0
install -d -o root -g root -m 0700 "$EVIDENCE_DIR"
PROMOTION_LOCK=/var/lock/chromat-promotion.lock
lock_parent="$(realpath -e -- "$(dirname -- "$PROMOTION_LOCK")")" || {
  echo "lock directory does not exist: $(dirname -- "$PROMOTION_LOCK")" >&2
  exit 1
}
PROMOTION_LOCK="$lock_parent/$(basename -- "$PROMOTION_LOCK")"
test -d "$lock_parent" && test ! -L "$lock_parent" || {
  echo "lock directory must be a real directory: $lock_parent" >&2
  exit 1
}
test "$(stat -c %u -- "$lock_parent")" = 0 || {
  echo "lock directory must be owned by root: $lock_parent" >&2
  exit 1
}
lock_parent_mode="$(stat -c %a -- "$lock_parent")"
if (( (8#$lock_parent_mode & 0022) != 0 && (8#$lock_parent_mode & 01000) == 0 )); then
  echo "writable lock directory must have the sticky bit: $lock_parent" >&2
  exit 1
fi
if test -L "$PROMOTION_LOCK"; then
  echo "lock file must not be a symbolic link: $PROMOTION_LOCK" >&2
  exit 1
fi
if ! test -e "$PROMOTION_LOCK"; then
  (
    umask 077
    set -C
    : >"$PROMOTION_LOCK"
  ) 2>/dev/null || true
fi
test -f "$PROMOTION_LOCK" && test ! -L "$PROMOTION_LOCK" || {
  echo "lock file must be a regular non-symlink file: $PROMOTION_LOCK" >&2
  exit 1
}
test "$(stat -c %u -- "$PROMOTION_LOCK")" = 0 || {
  echo "lock file must be owned by root: $PROMOTION_LOCK" >&2
  exit 1
}
test "$(stat -c %a -- "$PROMOTION_LOCK")" = 600 || {
  echo "lock file must have mode 0600: $PROMOTION_LOCK" >&2
  exit 1
}
exec 9<>"$PROMOTION_LOCK"
flock -n 9 || { echo "another promotion is active" >&2; exit 1; }
LINK_STATE="$CHROMAT_ROOT/.promotion-link-state"
LINK_STATE_TMP=
cleanup_link_state_tmp() {
  test -z "$LINK_STATE_TMP" || rm -f -- "$LINK_STATE_TMP"
}
trap cleanup_link_state_tmp EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if test -e "$LINK_STATE" || test -L "$LINK_STATE"; then
  echo "unrecovered promotion link state exists: $LINK_STATE" >&2
  exit 1
fi
for link in active previous; do
  path="$CHROMAT_ROOT/$link"
  if test -L "$path"; then
    printf -v "old_${link}" '%s' "$(readlink -f "$path")"
    printf -v "old_${link}_exists" 1
  elif test -e "$path"; then
    echo "refusing to replace non-symlink release path: $path" >&2
    exit 1
  fi
done
LINK_STATE_TMP="$(mktemp "$CHROMAT_ROOT/.promotion-link-state.XXXXXX")"
printf 'active_exists=%s\nactive_target=%s\nprevious_exists=%s\nprevious_target=%s\n' \
  "$old_active_exists" "$old_active" "$old_previous_exists" "$old_previous" \
  >"$LINK_STATE_TMP"
chmod 0600 "$LINK_STATE_TMP"
mv -fT -- "$LINK_STATE_TMP" "$LINK_STATE"
LINK_STATE_TMP=
"$RELEASE_DIR/scripts/verify-artifacts.sh" "$RELEASE_DIR" \
  | tee "$EVIDENCE_DIR/artifacts.txt"
for image_archive in "$RELEASE_DIR"/images/*.tar; do
  sudo docker load --input "$image_archive"
done | tee "$EVIDENCE_DIR/images.txt"
"$RELEASE_DIR/scripts/verify-production-environment.sh" \
  "$RELEASE_DIR" /etc/chromat/production.env \
  | tee "$EVIDENCE_DIR/preflight.txt"
```

El glob carga las cuatro imágenes de Compose y, separadamente, la imagen
auxiliar offline `busybox:1.36.1`. BusyBox no es un servicio de Compose ni se
configura en `.env`; los backups requieren que permanezca precargada y no
descargan imágenes.

La verificación de artefactos, carga y preflight ocurren en ese orden. Compose
siempre usa la release indicada, el proyecto `chromat` y los volúmenes
persistentes `chromat_db_data` y `chromat_raw_data`; no construye ni descarga imágenes:

```bash
compose() {
  sudo docker compose --project-name chromat --project-directory "$RELEASE_DIR" \
    --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" "$@"
}

ensure_https_blocked() {
  ssh_ports=("$CHROMAT_SSH_PORT")
  if command -v sshd >/dev/null; then
    mapfile -t configured_ssh_ports < <(
      sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -u
    )
    ssh_ports+=("${configured_ssh_ports[@]}")
  fi
  declare -A allowed_ssh_ports=()
  for ssh_port in "${ssh_ports[@]}"; do
    [[ "$ssh_port" =~ ^[1-9][0-9]{0,4}$ ]] && (( ssh_port <= 65535 )) || {
      echo "cannot determine SSH port" >&2
      exit 1
    }
    ss -H -ltn "sport = :$ssh_port" | grep -q . || {
      echo "SSH port is not listening: $ssh_port" >&2
      exit 1
    }
    [[ -n "${allowed_ssh_ports[$ssh_port]+x}" ]] && continue
    ufw allow "${ssh_port}/tcp" comment 'CHROMAT administration'
    ufw status numbered | awk -v rule="${ssh_port}/tcp" '
      /ALLOW[[:space:]]+IN/ {
        for (field = 1; field <= NF; field++) {
          if ($field == rule) {
            found = 1
          }
        }
      }
      END { exit !found }
    ' || {
      echo "cannot protect SSH access before enabling UFW" >&2
      exit 1
    }
    allowed_ssh_ports["$ssh_port"]=1
  done
  ufw --force enable
  ufw status | grep -Fxq 'Status: active' || {
    echo "cannot verify the HTTPS validation rule: UFW is inactive" >&2
    exit 1
  }
  validation_rule_count="$(
    ufw status numbered | awk '
      /CHROMAT validation/ && /DENY[[:space:]]+IN/ {
        for (field = 1; field <= NF; field++) {
          if ($field == "443/tcp") {
            count++
          }
        }
      }
      END { print count + 0 }
    '
  )"
  if (( validation_rule_count == 0 )); then
    ufw insert 1 deny 443/tcp comment 'CHROMAT validation' || {
      echo "cannot install the HTTPS validation rule" >&2
      exit 1
    }
  elif (( validation_rule_count != 1 )); then
    echo "multiple CHROMAT validation rules are present" >&2
    exit 1
  fi
  ufw status numbered | awk '
    /CHROMAT validation/ && /DENY[[:space:]]+IN/ {
      for (field = 1; field <= NF; field++) {
        if ($field == "443/tcp") {
          found = 1
        }
      }
    }
    END { exit !found }
  ' || {
    echo "cannot verify the HTTPS validation rule" >&2
    exit 1
  }
}

mariadb_query() {
  compose exec -T db sh -ceu "$(cat <<'EOF'
    defaults_file="$(mktemp /tmp/chromat-mariadb.XXXXXX)"
    cleanup_defaults() {
      rm -f -- "$defaults_file"
    }
    trap cleanup_defaults EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    password="$(cat /run/secrets/db_root_password)"
    case "$password" in
      *"
"*) echo "MariaDB passwords containing newlines are not supported" >&2; exit 2 ;;
    esac
    escaped_password="$(printf "%s" "$password" | sed "s/[\"\\\\]/\\\\&/g")"
    printf "[client]\npassword=\"%s\"\n" "$escaped_password" >"$defaults_file"
    chmod 0600 "$defaults_file"
    mariadb --defaults-extra-file="$defaults_file" -uroot chromat -e "$1"
EOF
)" sh "$1"
}

```

## Instalación inicial

Antes de comenzar, confirma que no existe instalación o datos a preservar. No
se permite reutilizar ni borrar volúmenes sin autorización explícita:

```bash
sudo test ! -e "$CHROMAT_ROOT/active"
sudo test ! -e "$CHROMAT_ROOT/previous"
sudo test ! -d /var/lib/docker/volumes/chromat_db_data/_data
sudo test ! -d /var/lib/docker/volumes/chromat_raw_data/_data
```

Si cualquiera existe, detén este flujo y usa **Actualización**. Prepara Ubuntu,
los secretos, `/mnt/chromat-backups` y TLS según sus runbooks. No se exige un
backup inexistente en una base aún vacía. Tras los controles comunes:

```bash
ensure_https_blocked
compose up -d
compose ps
mariadb_query 'SELECT version FROM schema_migrations ORDER BY version'
compose exec -T nginx nginx -t
CA_CERT="$CHROMAT_ROOT/tls/ca.crt" BASE_URL=https://chromat.lan SMOKE_TESTS=all \
  "$RELEASE_DIR/tests/smoke/run.sh"
```

MariaDB inicializa las migraciones desde cero mediante el volumen nuevo. Sólo
después de readiness, migraciones, TLS, autenticación, Telegram, smoke de
capacidad, agregación y limpieza, actualiza `active` como se indica al final.
No abras HTTPS antes de esos resultados.

## Actualización

La actualización nunca puede usar la excepción de backup de la instalación
inicial. Antes de cambiar la base, exige backup **full**, checksum y
restauración aislada satisfactoria:

```bash
sudo "$CHROMAT_ROOT/active/scripts/backup.sh" \
  --config /etc/chromat/production.env --mode full \
  | tee "$EVIDENCE_DIR/backup.path"
backup_dir="$(tail -n 1 "$EVIDENCE_DIR/backup.path")"
# En el host aislado, después de transferir el backup y la release candidata:
ISOLATED_RELEASE_DIR="$RELEASE_ROOT/$VERSION"
ISOLATED_BACKUP_DIR="/mnt/chromat-backups/$(basename "$backup_dir")"
sudo "$ISOLATED_RELEASE_DIR/scripts/verify-backup.sh" \
  --config /etc/chromat/restore/restore.env \
  --identity-file /media/custodian/backup-age-identity \
  "$ISOLATED_BACKUP_DIR" \
  | tee "$EVIDENCE_DIR/backup-verification.txt"
```

La restauración se ejecuta en un host aislado, no con configuración productiva
ni volúmenes productivos. Copia el backup y el `restore.env` al host aislado:
`verify-backup.sh` crea un contenedor MariaDB sin red, valida checksums,
descifra con la identidad local de ese host, importa la base y compara los
archivos raw con sus referencias. La identidad privada de age nunca llega a la
VM productiva. Revisa antes que cada migración sea compatible hacia atrás con
la release `previous`; las migraciones incompatibles requieren plan de
restauración, no down-migration.

Ejecuta los controles comunes y arranca sin cambiar los enlaces todavía:

```bash
ensure_https_blocked
compose up -d
compose ps
mariadb_query 'SELECT version FROM schema_migrations ORDER BY version' \
  | tee "$EVIDENCE_DIR/migrations.txt"
compose exec -T nginx nginx -t
CA_CERT="$CHROMAT_ROOT/tls/ca.crt" BASE_URL=https://chromat.lan SMOKE_TESTS=all \
  "$RELEASE_DIR/tests/smoke/run.sh" | tee "$EVIDENCE_DIR/smoke.txt"
```

## Tráfico, enlaces y UFW

`ensure_https_blocked` preserva SSH, activa y comprueba UFW antes de iniciar
servicios, y crea una regla CHROMAT de denegación temporal de HTTPS. No cambia
reglas ajenas a CHROMAT. Si no puede demostrar que la regla de UFW está
presente, aborta sin iniciar Compose. Esto aplica tanto a instalación inicial
como a actualización. UFW por sí solo no demuestra que un puerto publicado por
Docker quede inaccesible: antes de abrir HTTPS, comprueba desde otro equipo de
la red que `https://chromat.lan` no responde mientras la regla temporal está
activa. Antes de entrar al shell root, el operador debe conservar la sesión
actual y exportar `CHROMAT_SSH_PORT`; si usa un puerto personalizado, debe
indicar ese puerto. El runbook comprueba que escucha, permite ese puerto y,
cuando existe OpenSSH, permite todos sus puertos configurados. Si no puede
determinarse o protegerse, no continúes.

Tras todas las verificaciones, registra el estado previo de enlaces y publica
la release. Cada reemplazo de enlace usa `mv -T` atómico; como los dos enlaces
no pueden cambiar como una sola operación de filesystem, el estado persistido
permite recuperar ambos si el proceso falla entre ellos:

```bash
old_active="$(awk -F= '$1 == "active_target" { print $2 }' "$LINK_STATE")"
old_active_exists="$(awk -F= '$1 == "active_exists" { print $2 }' "$LINK_STATE")"
rm -f -- "$CHROMAT_ROOT/.active.next" "$CHROMAT_ROOT/.previous.next"
if test "$old_active_exists" = 1; then
  ln -s "$old_active" "$CHROMAT_ROOT/.previous.next"
  mv -Tf "$CHROMAT_ROOT/.previous.next" "$CHROMAT_ROOT/previous"
else
  rm -f -- "$CHROMAT_ROOT/previous"
fi
ln -s "$RELEASE_DIR" "$CHROMAT_ROOT/.active.next"
mv -Tf "$CHROMAT_ROOT/.active.next" "$CHROMAT_ROOT/active"
test "$(readlink -f "$CHROMAT_ROOT/active")" = "$RELEASE_DIR"
if test "$old_active_exists" = 1; then
  test "$(readlink -f "$CHROMAT_ROOT/previous")" = "$old_active"
else
  test ! -e "$CHROMAT_ROOT/previous" && test ! -L "$CHROMAT_ROOT/previous"
fi
read -r -p \
  'Confirm from another host that HTTPS is blocked by the validation rule (type BLOCKED): ' \
  external_https_blocked_result
if test "$external_https_blocked_result" != BLOCKED; then
  echo "external HTTPS blocking verification did not pass; keep recovery state and rollback" >&2
  exit 1
fi
validation_rule="$(
  ufw status numbered | awk '/CHROMAT validation/ {gsub(/[\[\]]/, "", $1); print $1; exit}'
)"
if test -n "$validation_rule"; then
  ufw --force delete "$validation_rule"
fi
ufw allow 443/tcp comment 'CHROMAT HTTPS'
ufw status | grep -Fxq 'Status: active'
if ufw status numbered | grep -Fq 'CHROMAT validation'; then
  echo "CHROMAT validation rule remains installed" >&2
  exit 1
fi
read -r -p \
  'Confirm from another host that HTTPS is reachable after opening it (type OPENED): ' \
  external_https_result
if test "$external_https_result" != OPENED; then
  echo "external HTTPS verification did not pass; keep recovery state and rollback" >&2
  exit 1
fi
# The state remains until the external verification and final UFW checks pass.
rm -f -- "$LINK_STATE"
```

`ufw allow` es idempotente: la primera instalación crea 443 y una actualización
no queda bloqueada si ya existe. La eliminación de la denegación temporal se
guarda con una búsqueda previa, así que no intenta eliminar una regla
inexistente. La apertura ocurre sólo al final. El runbook exige confirmar
`BLOCKED` desde otro equipo antes de quitar la regla y `OPENED` después de
abrir HTTPS; no uses el listado de UFW como sustituto de esas pruebas
efectivas. Si cualquiera falla, responde distinto del valor solicitado:
`LINK_STATE` se conserva y aplica el rollback con
`recover-release-links.sh` antes de reiniciar la release anterior.

## Aborto y rollback

### Fallo antes de cambiar `active`

Antes de ejecutar el segundo `mv -Tf` hacia `active`, la release nueva no está
publicada. Detén sus servicios y recupera exactamente el par original desde el
estado persistido; **No intercambies enlaces manualmente**:

```bash
compose down
CHROMAT_PROMOTION_LOCK_HELD=1 "$RELEASE_DIR/scripts/recover-release-links.sh" \
  --root "$CHROMAT_ROOT" --state "$LINK_STATE"
if test -L "$CHROMAT_ROOT/active"; then
  RELEASE_DIR="$(readlink -f "$CHROMAT_ROOT/active")"
  ensure_https_blocked
  compose up -d
fi
```

En una instalación inicial el estado declara `active_exists=0`: aborta después
de detener la release nueva, sin crear enlaces ni reiniciar servicios.

### Fallo entre los dos cambios de enlace

Si el shell aborta después del primer reemplazo, `LINK_STATE` sigue existiendo.
Desde un shell root nuevo, ejecuta el CLI autónomo. El recuperador adquiere por
sí mismo `/var/lock/chromat-promotion.lock`, lo mantiene durante toda la
recuperación y rechaza una segunda ejecución concurrente. Para rollback desde
el shell de promoción, `CHROMAT_PROMOTION_LOCK_HELD=1` reutiliza su descriptor
9 heredado, sin liberar el bloqueo; desde un shell root nuevo no se define esa
variable y el recuperador adquiere el lock normalmente. Elimina sólo
`.active.next` y `.previous.next` cuando son enlaces
simbólicos temporales y restaura exactamente el par previo:

```bash
"$RELEASE_DIR/scripts/recover-release-links.sh" \
  --root "$CHROMAT_ROOT" --state "$LINK_STATE"
RELEASE_DIR="$(readlink -f "$CHROMAT_ROOT/active")"
ensure_https_blocked
compose up -d
```

### Fallo después de cambiar `active`

Después de publicar, `active` es la release nueva y `previous` es la que
estaba activa. Detén la nueva, restaura ambos enlaces con reemplazos atómicos
y reinicia la anterior:

```bash
compose down
CHROMAT_PROMOTION_LOCK_HELD=1 "$RELEASE_DIR/scripts/recover-release-links.sh" \
  --root "$CHROMAT_ROOT" --state "$LINK_STATE"
if test -L "$CHROMAT_ROOT/active"; then
  RELEASE_DIR="$(readlink -f "$CHROMAT_ROOT/active")"
  ensure_https_blocked
  compose up -d
fi
```

En los tres escenarios, el recuperador conserva el estado hasta que ambos
enlaces restaurados pasan sus verificaciones. No elimina releases,
`chromat_db_data`, `chromat_raw_data` ni otros datos persistentes, y el
rollback no recrea, borra ni sustituye volúmenes. Si la base dejó de ser
compatible, detén tráfico, restaura el backup completo verificado en
aislamiento y promueve la restauración conforme a `backups.md`; nunca ejecutes
una down-migration.
