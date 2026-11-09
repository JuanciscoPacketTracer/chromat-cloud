# Promoción manual Fedora → Ubuntu

Este runbook une los contratos de artefactos, Ubuntu, TLS y backups en una
promoción serializada. El operador conserva el manifiesto, logs, checksums,
backup y resultados de cada paso. Un fallo aborta la promoción y mantiene el
tráfico cerrado.

El orden obligatorio es:

```text
backup → verificación → migraciones compatibles → servicios
→ readiness → smoke → apertura de tráfico
```

No hay CI/CD, Kubernetes, alta disponibilidad ni rollback automático.

## Evidencia y lock

Define un identificador de promoción y prepara un directorio de evidencia
fuera de la release:

```bash
set -o errexit -o nounset -o pipefail
export PROMOTION_ID=20261109-1
export EVIDENCE_DIR=/srv/chromat/promotions/$PROMOTION_ID
sudo install -d -m 0750 "$EVIDENCE_DIR"
exec 9>/run/lock/chromat-promotion.lock
flock -n 9 || { echo "another promotion is active" >&2; exit 1; }
```

Registra el commit, manifiesto, versión de Ubuntu/Docker/Compose, operador,
hora UTC y los checksums en `EVIDENCE_DIR`. No se inicia una segunda promoción
mientras el lock exista.

## 1. Cerrar el tráfico y validar precondiciones

Antes de cargar la release, conserva la regla SSH de administración y cierra
temporalmente TCP/443 para clientes externos:

```bash
sudo ufw delete allow 443/tcp
sudo ufw status verbose
```

No se abre TCP/80. Verifica antes de tocar la base:

```bash
scripts/verify-artifacts.sh /srv/chromat/releases/$PROMOTION_ID
scripts/check-tls-expiry.sh /srv/chromat/tls/server.crt 30
docker compose --env-file production.env config --quiet
df -h /srv/chromat /var/lib/docker
ss -lntup
```

Comprueba también permisos de secretos, la resolución de `chromat.lan`, la
identidad TLS con `ca.crt` y que ningún servicio distinto de Nginx tenga un
puerto publicado. Un fallo conserva la evidencia y termina aquí.

## 2. Backup y verificación

Ejecuta un backup completo antes de modificar la base y verifica el directorio
local o su copia externa:

```bash
set -o pipefail
export BACKUP_MODE=full
scripts/backup.sh | tee "$EVIDENCE_DIR/backup.path"
backup_dir="$(cat "$EVIDENCE_DIR/backup.path" | tail -n 1)"
scripts/verify-backup.sh "$backup_dir" \
  | tee "$EVIDENCE_DIR/backup-verification.txt"
```

No continúes si falla el cifrado, checksum, copia externa, restauración
aislada, migración, hash de dato crudo, archivo referenciado o archivo faltante.

## 3. Migraciones forward-only compatibles

Carga las imágenes verificadas con `docker load` según el manifiesto. Revisa
que cada migración nueva sea aditiva y declare compatibilidad con la versión
anterior. No se ejecutan down-migrations.

La aplicación ejecuta `migrate()` al iniciar API, worker y
`telegram-worker`. Arranca primero la base y deja que la sección de servicios
ejecute las migraciones; antes de abrir tráfico, conserva los logs y confirma
que todas las versiones esperadas aparecen en `schema_migrations`:

```bash
docker compose --env-file production.env up -d db
```

Si la migración no es compatible hacia atrás, no se intenta volver a una
release anterior con la base modificada: se detiene el tráfico y se restaura
el backup verificado asociado.

## 4. Arrancar servicios y readiness

Arranca la release sin construir ni descargar imágenes:

```bash
docker compose --env-file production.env up -d --no-build
docker compose --env-file production.env ps
docker compose --env-file production.env logs --no-color api worker telegram-worker \
  | tee "$EVIDENCE_DIR/migrations.log"
docker compose --env-file production.env exec -T db \
  sh -c 'mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE" \
    -e "SELECT version FROM schema_migrations ORDER BY version"'
```

Espera a que MariaDB, API e inferencia estén saludables y confirma que
`worker` y `telegram-worker` estén `running`:

```bash
for service in db api worker telegram-worker inference nginx; do
  docker compose --env-file production.env ps --status running "$service" \
    | grep -q "$service"
done
docker inspect --format '{{.Name}} {{.State.Health.Status}}' \
  chromat-db-1 chromat-api-1 chromat-inference-1
```

`/health/live` y `/health/ready` son probes operativos existentes, no rutas de
negocio; por eso permanecen sin versión aunque las rutas API sí usan `/api/v1`.
El readiness público debe comprobarse con la CA de producción, no con
`--insecure`:

```bash
export CHROMAT_VM_IP=192.168.1.50
curl --fail --cacert /srv/chromat/tls/ca.crt \
  --resolve chromat.lan:443:"$CHROMAT_VM_IP" \
  https://chromat.lan/health/live
curl --fail --cacert /srv/chromat/tls/ca.crt \
  --resolve chromat.lan:443:"$CHROMAT_VM_IP" \
  https://chromat.lan/health/ready
```

La prueba con `--resolve` conserva la identidad `chromat.lan`; cualquier IP
usada directamente debe figurar en los SAN del certificado.

## 5. Smoke tests completos

Provisiona una Fuente de monitoreo dedicada y sus credenciales en variables
fuera de Git. Ejecuta todos los escenarios con la CA de producción:

```bash
set -o pipefail
CA_CERT=/srv/chromat/tls/ca.crt \
BASE_URL=https://chromat.lan \
SMOKE_TESTS=all \
ADMIN_USERNAME="$ADMIN_USERNAME" \
ADMIN_PASSWORD="$ADMIN_PASSWORD" \
SMOKE_SOURCE_ID="$SMOKE_SOURCE_ID" \
SMOKE_SOURCE_API_KEY="$SMOKE_SOURCE_API_KEY" \
FOREIGN_EVENT_ID="$FOREIGN_EVENT_ID" \
tests/smoke/run.sh | tee "$EVIDENCE_DIR/smoke.log"
```

El conjunto cubre autenticación, gestión de fuentes, ingesta idempotente,
aislamiento entre fuentes, procesamiento con leases/reintentos, inferencia
HSV/CNN, estado agregado, protección de capacidad, readiness y limpieza de la
Fuente de monitoreo. La traza de limpieza debe completarse y la fuente de
prueba no debe quedar visible en el panel ni en el conjunto de investigación.

El smoke no envía un mensaje real a Telegram. Valida la salida HTTPS del
`telegram-worker` por separado, sin convertirla en dependencia del readiness:

```bash
docker compose --env-file production.env exec -T telegram-worker \
  node -e "fetch('https://api.telegram.org').then(r => { if (!r.ok) process.exit(1) })"
```

Un fallo de Telegram se registra como fallo de conectividad de la integración,
pero no invalida el arranque local del resto de CHROMAT.

## 6. Abrir tráfico y declarar éxito

Solo después de que backup, migraciones, readiness, TLS, autenticación,
ingesta, procesamiento, inferencia, agregado, capacidad, Telegram aislado y
limpieza estén documentados como correctos:

```bash
sudo ufw allow 443/tcp comment 'CHROMAT HTTPS'
sudo ufw status verbose
curl --fail --cacert /srv/chromat/tls/ca.crt https://chromat.lan/health/ready
date -u +%FT%TZ | tee "$EVIDENCE_DIR/success.utc"
```

La promoción queda incompleta si el tráfico se abre antes de esta sección.
Conserva el manifiesto, backup, logs, smoke y salida de UFW.

## Abortos y rollback compatible

Ante cualquier fallo, no abras el tráfico. Conserva la evidencia y deja la
release activa sin declarar éxito. Si la base no cambió de forma incompatible,
el rollback de aplicación puede usar `previous`:

```bash
sudo ufw delete allow 443/tcp
docker compose --env-file production.env down
previous_release="$(readlink -f /srv/chromat/previous)"
test -d "$previous_release"
for image_archive in "$previous_release"/images/*.tar; do
  docker load --input "$image_archive"
done
sudo ln -sfn "$previous_release" /srv/chromat/active
cd /srv/chromat/active
docker compose --env-file production.env up -d --no-build
```

Solo se revierte dentro del rango de compatibilidad declarado por las
migraciones. Se vuelven a ejecutar readiness y smoke antes de abrir tráfico.
Nunca se ejecutan down-migrations.

Si la base ya no es compatible, el rollback requiere restaurar en aislamiento
el backup verificado de la versión anterior y promover esa restauración según
el runbook de backups. La promoción anterior y la inmediatamente anterior se
conservan hasta completar la verificación.
