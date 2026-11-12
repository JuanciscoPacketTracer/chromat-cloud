# Guía de producción: Ubuntu Server 26.04 LTS AMD64

CHROMAT se instala mediante un procedimiento **semiautomatizado**. El script
`prepare-ubuntu-production-host.sh` prepara de forma idempotente el host, pero
la custodia de secretos, la emisión de TLS, la comprobación de migraciones y
la autorización de abrir tráfico requieren un administrador. Esto respeta
ADR-0008: no existe CI/CD, registro privado ni despliegue remoto automático.

Esta guía parte de una VM nueva **Ubuntu Server 26.04 LTS AMD64**, con `sudo`,
acceso al repositorio apt oficial de Docker durante el aprovisionamiento y un
filesystem externo ya montado para backups. No clone Git ni construya imágenes
en la VM productiva.

## 1. Crear y transferir una release

En el entorno de construcción amd64, con árbol Git limpio, Docker Engine y
Docker Compose:

```bash
scripts/package-artifacts.sh 2026.11.11-1
cd dist/artifacts
sha256sum --check chromat-2026.11.11-1.tar.gz.sha256
```

Transfiera por el canal operativo autorizado estos dos archivos a la VM, por
ejemplo a un directorio de staging creado por el administrador:

```text
chromat-2026.11.11-1.tar.gz
chromat-2026.11.11-1.tar.gz.sha256
```

El checksum protege integridad accidental; no autentica al emisor. ADR-0008
requiere que el canal de transferencia aporte autenticidad.

## 2. Aprovisionar el host

En la VM, verifique explícitamente la plataforma antes de ejecutar material de
la release:

```bash
. /etc/os-release
printf '%s %s %s\n' "$ID" "$VERSION_ID" "$(uname -m)"
test "$ID" = ubuntu
test "$VERSION_ID" = 26.04
test "$(uname -m)" = x86_64
```

Verifique el tarball antes de extraerlo, extráigalo en staging y verifique su
contenido antes de ejecutar el aprovisionador:

```bash
export RELEASE_VERSION=2026.11.11-1
export STAGING_DIR=/srv/chromat/staging
sudo install -d -m 0700 "$STAGING_DIR"
sudo sha256sum --check "$STAGING_DIR/chromat-${RELEASE_VERSION}.tar.gz.sha256"
sudo tar -xzf "$STAGING_DIR/chromat-${RELEASE_VERSION}.tar.gz" -C "$STAGING_DIR"
sudo "$STAGING_DIR/$RELEASE_VERSION/scripts/verify-artifacts.sh" \
  "$STAGING_DIR/$RELEASE_VERSION"
sudo "$STAGING_DIR/$RELEASE_VERSION/scripts/prepare-ubuntu-production-host.sh"
```

El aprovisionador comprueba Ubuntu 26.04 y `x86_64`, instala Docker Engine y
el plugin Compose desde el repositorio apt oficial de Docker si faltan, activa
Docker y crea directorios de permisos restringidos. Si Docker ya existe,
comprueba que `docker-ce`, `docker-ce-cli`, `containerd.io`,
`docker-buildx-plugin` y `docker-compose-plugin` estén completos, que no
existan paquetes incompatibles y que el binario, la llave y la fuente apt
correspondan a `download.docker.com`. No reemplaza configuraciones, paquetes o
fuentes apt existentes de Docker, secretos, TLS, configuración de producción,
releases ni volúmenes. Ante una instalación incompleta o ajena, se detiene sin
modificarla: un administrador debe corregirla manualmente con el repositorio
oficial y volver a ejecutar el aprovisionador.

Compruebe espacio, hora y el montaje externo antes de continuar:

```bash
df -h /srv/chromat /var/lib/docker /mnt/chromat-backups
findmnt -T /mnt/chromat-backups
timedatectl status
```

## 3. Provisionar secretos, backup y TLS

El script prepara directorios, pero no crea archivos de secretos ni genera
valores. `db_password`, `db_root_password`, `telegram_bot_token` y el
destinatario público de `age` son obligatorios porque Compose siempre inicia
`telegram-worker` y cada promoción exige un backup. La contraseña del primer
operador solo se necesita al crear ese operador. Un custodio crea los archivos
que faltan y escribe valores en un editor seguro, sin incluirlos en comandos,
historial, logs ni Git:

```bash
sudo test ! -e /etc/chromat/secrets/db_password && sudo install -m 0600 /dev/null /etc/chromat/secrets/db_password
sudo test ! -e /etc/chromat/secrets/db_root_password && sudo install -m 0600 /dev/null /etc/chromat/secrets/db_root_password
sudo test ! -e /etc/chromat/secrets/telegram_bot_token && sudo install -m 0600 /dev/null /etc/chromat/secrets/telegram_bot_token
sudo test ! -e /etc/chromat/backup-age-recipient && sudo install -m 0600 /dev/null /etc/chromat/backup-age-recipient
sudo test ! -e /etc/chromat/secrets/operator_password && sudo install -m 0600 /dev/null /etc/chromat/secrets/operator_password
sudoedit /etc/chromat/secrets/db_password
sudoedit /etc/chromat/secrets/db_root_password
sudoedit /etc/chromat/secrets/telegram_bot_token
sudoedit /etc/chromat/secrets/operator_password
sudoedit /etc/chromat/backup-age-recipient
sudo stat -c '%a %U:%G %n' /etc/chromat/secrets/db_password \
  /etc/chromat/secrets/db_root_password \
  /etc/chromat/secrets/telegram_bot_token \
  /etc/chromat/backup-age-recipient
```

`backup-age-recipient` contiene únicamente el destinatario público de `age`.
La identidad privada para descifrar se conserva fuera del servidor y de los
backups. `telegram_bot_token` sigue siendo obligatorio para la configuración
actual de Compose aunque las alertas no se prueben en el smoke.

Un custodio de la CA transfiere un directorio temporal que contenga solamente
`ca.crt`, `server.crt` y `server.key`. La clave privada de la CA nunca llega a
la VM. El certificado debe incluir `chromat.lan` y la IP operativa en SAN:

```bash
sudo scripts/install-production-tls.sh \
  /ruta/temporal/tls /srv/chromat/tls 192.168.1.50
sudo scripts/check-tls-expiry.sh /srv/chromat/tls/server.crt 30
```

Consulte [`../deployment/tls.md`](../deployment/tls.md) para validar la
cadena y renovar. Una renovación que cambie certificados exige la opción
explícita `--replace`; una instalación normal nunca sustituye TLS existente.

## 4. Instalar y configurar la release inicial

Instale cada versión una sola vez. El destino debe no existir; no se
sobrescribe una release ni se eliminan datos:

```bash
export RELEASE_DIR="/srv/chromat/releases/$RELEASE_VERSION"
test ! -e "$RELEASE_DIR"
sudo cp -a "$STAGING_DIR/$RELEASE_VERSION" "$RELEASE_DIR"
sudo "$RELEASE_DIR/scripts/verify-artifacts.sh" "$RELEASE_DIR"
for image_archive in "$RELEASE_DIR"/images/*.tar; do
  sudo docker load --input "$image_archive"
done
```

Inicialice una configuración persistente fuera de la release. El archivo no
contiene valores secretos: sus referencias apuntan a los archivos anteriores.
No lo reemplace durante actualizaciones.

```bash
test ! -e /etc/chromat/production.env
sudo install -m 0600 "$RELEASE_DIR/production.env.example" /etc/chromat/production.env
sudoedit /etc/chromat/production.env
sudo grep -Fx 'PULL_POLICY=never' /etc/chromat/production.env
sudo "$RELEASE_DIR/scripts/verify-production-environment.sh" \
  "$RELEASE_DIR" /etc/chromat/production.env
sudo docker compose --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" config --quiet
```

Conserve `PULL_POLICY=never`, las cuatro imágenes versionadas incluidas en
`production.env.example`, las rutas de secretos en `/etc/chromat/secrets`,
las rutas TLS en `/srv/chromat/tls`, `MODEL_HOST_PATH=./model/deterministic-model.json`
y el destino de backup externo. Todos los comandos Docker usan `sudo`; no se
añade al administrador al grupo `docker` ni se requiere acceso directo al
socket. `--project-directory` y `-f` hacen que Compose
resuelva ese modelo relativo a la release, no al directorio actual del
administrador. No añada secretos como variables de entorno.

Active y arranque sin construir ni descargar imágenes:

```bash
sudo ln -s "$RELEASE_DIR" /srv/chromat/active
sudo docker compose --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" up -d --no-build
sudo docker compose --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" ps
```

Espere a que estén en ejecución y confirme las comprobaciones de salud:

```bash
for service in db api worker telegram-worker inference nginx; do
  sudo docker compose --project-directory "$RELEASE_DIR" \
    --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" \
    ps --status running "$service" | grep -q "$service"
done
sudo docker inspect --format '{{.Name}} {{.State.Health.Status}}' \
  chromat-db-1 chromat-api-1 chromat-inference-1
```

Cree el primer operador una sola vez. La contraseña se monta como archivo
temporal dentro del contenedor y no aparece en la línea de comandos:

```bash
sudo docker compose --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" run --rm \
  -e OPERATOR_PASSWORD_FILE=/run/secrets/operator_password \
  -v /etc/chromat/secrets/operator_password:/run/secrets/operator_password:ro \
  api npm run create-operator -- NOMBRE_DEL_OPERADOR
```

Verifique HTTPS con la CA y la identidad DNS antes de permitir clientes:

```bash
export CHROMAT_VM_IP=192.168.1.50
curl --fail --cacert /srv/chromat/tls/ca.crt \
  --resolve chromat.lan:443:"$CHROMAT_VM_IP" \
  https://chromat.lan/health/live
curl --fail --cacert /srv/chromat/tls/ca.crt \
  --resolve chromat.lan:443:"$CHROMAT_VM_IP" \
  https://chromat.lan/health/ready
sudo ufw allow 443/tcp comment 'CHROMAT HTTPS'
sudo ufw status verbose
```

## 5. Actualizar una release

No regenere secretos ni TLS. Repita la transferencia, checksum, extracción,
`verify-artifacts.sh`, copia a un **nuevo** `RELEASE_DIR`, carga de imágenes y
`docker compose ... config --quiet` de las secciones 1, 2 y 4. Antes de
cambiar la base, compare la nueva plantilla y edite solo las cuatro variables
de imagen en la configuración persistente; no copie ni reemplace el archivo:

```bash
sudo diff -u /etc/chromat/production.env "$RELEASE_DIR/production.env.example" || true
sudoedit /etc/chromat/production.env
sudo "$RELEASE_DIR/scripts/verify-production-environment.sh" \
  "$RELEASE_DIR" /etc/chromat/production.env
sudo docker compose --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" config --quiet
```

Después siga íntegramente
[`../deployment/promotion.md`](../deployment/promotion.md): adquiera el lock,
cierre 443, haga un backup completo y verificado, revise manualmente que las
migraciones sean aditivas y compatibles con la release activa, y conserve la
evidencia.

Cuando esos precondiciones pasen, la activación exacta es:

```bash
sudo docker compose --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" down
previous_release="$(readlink -f /srv/chromat/active)"
sudo ln -sfn "$previous_release" /srv/chromat/previous
sudo ln -sfn "$RELEASE_DIR" /srv/chromat/active
sudo docker compose --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" up -d --no-build
```

Ejecute los readiness y smoke tests de `promotion.md` usando
`--env-file /etc/chromat/production.env`. Abra 443 solo tras registrar el
resultado correcto.

## 6. Rollback

El rollback de aplicación solo es válido si las migraciones de la release
nueva son compatibles hacia atrás. Mantenga 443 cerrado, cargue las imágenes
de `previous`, apunte `active` a esa release, arranque sin build y repita
readiness y smoke:

```bash
sudo ufw delete allow 443/tcp
previous_release="$(readlink -f /srv/chromat/previous)"
test -d "$previous_release"
for image_archive in "$previous_release"/images/*.tar; do
  sudo docker load --input "$image_archive"
done
sudo ln -sfn "$previous_release" /srv/chromat/active
export RELEASE_DIR="$previous_release"
sudo docker compose --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" up -d --no-build
```

No ejecute down-migrations. Si la base no es compatible, el único rollback
aceptable es restaurar en aislamiento el backup verificado de la versión
anterior según [`../deployment/backups.md`](../deployment/backups.md).

## Limitaciones verificables

El repositorio no incluye una declaración mecanizable de compatibilidad entre
versiones y migraciones, ni firma criptográfica de releases, CI/CD, registro
privado o automatización de firewall. Por ello un administrador debe aprobar
la compatibilidad de cada actualización y autenticar el canal de transferencia;
un checksum por sí solo no autoriza ejecutar una release.
