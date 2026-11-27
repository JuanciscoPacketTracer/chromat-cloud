# Guía de producción: Ubuntu Server 26.04 LTS AMD64

> **Histórico / aplazado:** esta guía conserva el despliegue offline anterior,
> no la ruta vigente. Se permite clonar, actualizar y construir en el servidor
> según [Git + Docker Compose](git-compose.md) y
> [ADR-0010](../adr/0010-desarrollo-y-despliegue-desde-git.md).

CHROMAT se instala mediante un procedimiento **semiautomatizado**. El script
`prepare-ubuntu-production-host.sh` prepara de forma idempotente el host, pero
la custodia de secretos, la emisión de TLS, la comprobación de migraciones y
la autorización de abrir tráfico requieren un administrador. Esto respeta
ADR-0008: no existe CI/CD, registro privado ni despliegue remoto automático.

Esta guía parte de una VM nueva **Ubuntu Server 26.04 LTS AMD64**, con `sudo`,
acceso al repositorio apt oficial de Docker durante el aprovisionamiento y un
filesystem externo ya montado para backups. No clone Git ni construya imágenes
en la VM productiva.

## Estado de validación

| Estado | Alcance |
| --- | --- |
| Verificado fuera de una VM | La estructura del paquete, sus checksums, el manifiesto y el preflight de configuración se verifican por contratos locales. La release contiene imágenes offline y la guía de instalación. |
| Pendiente de VM Ubuntu 26.04 AMD64 | Descarga desde una Release publicada, preparación del host, carga de imágenes, TLS, backups, promoción, servicios, smoke, actualización y rollback. Ejecute y registre cada comando de esta guía en la VM; esta documentación no afirma que ya hayan pasado. |

## 1. Descargar una release desde GitHub

> **Pendiente de validación en VM:** esta sección describe el flujo que debe
> ejecutarse en Ubuntu Server 26.04 AMD64. No se ha ejecutado todavía en una
> VM objetivo.

```bash
# Ejemplo: debe coincidir con una Release publicada, no con un Draft.
export RELEASE_VERSION=2026.11.12-1
export REPOSITORY=JuanciscoPacketTracer/chromat-cloud
export RELEASE_URL="https://github.com/${REPOSITORY}/releases/download/${RELEASE_VERSION}"
export STAGING_DIR=/srv/chromat/staging
sudo install -d -o root -g root -m 0700 "$STAGING_DIR"
sudo curl --fail --location \
  --output "$STAGING_DIR/chromat-${RELEASE_VERSION}.tar.gz" \
  "${RELEASE_URL}/chromat-${RELEASE_VERSION}.tar.gz"
sudo curl --fail --location \
  --output "$STAGING_DIR/chromat-${RELEASE_VERSION}.tar.gz.sha256" \
  "${RELEASE_URL}/chromat-${RELEASE_VERSION}.tar.gz.sha256"
sudo curl --fail --location \
  --output "$STAGING_DIR/chromat-${RELEASE_VERSION}.manifest.json" \
  "${RELEASE_URL}/chromat-${RELEASE_VERSION}.manifest.json"
sudo bash -c '
set -Eeuo pipefail
read -r expected_digest _ < "$2"
actual_digest="$(sha256sum "$1")"
actual_digest="${actual_digest%% *}"
[[ "$actual_digest" == "$expected_digest" ]]
' _ "$STAGING_DIR/chromat-${RELEASE_VERSION}.tar.gz" \
  "$STAGING_DIR/chromat-${RELEASE_VERSION}.tar.gz.sha256"
```

HTTPS cifra la conexión y autentica el servidor de GitHub mediante TLS; no
demuestra por sí solo quién publicó el artefacto. El checksum detecta
corrupción accidental, pero tampoco autentica al emisor. Esta release no
incluye una firma criptográfica para verificar esa autenticidad: el manifiesto
se compara después con el que está dentro del TAR. No descargue archivos de
otra fuente ni use una release que siga como draft.

## 2. Aprovisionar el host

> **Pendiente de validación en VM:** la preparación de Docker, firewall,
> almacenamiento, TLS y el resto de esta guía requiere evidencia recogida en
> la VM Ubuntu objetivo.

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
sudo tar -xzf "$STAGING_DIR/chromat-${RELEASE_VERSION}.tar.gz" -C "$STAGING_DIR"
sudo "$STAGING_DIR/$RELEASE_VERSION/scripts/verify-artifacts.sh" \
  "$STAGING_DIR/$RELEASE_VERSION"
sudo cmp --silent "$STAGING_DIR/chromat-${RELEASE_VERSION}.manifest.json" \
  "$STAGING_DIR/$RELEASE_VERSION/manifest.json"
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
sudo bash -c '
set -Eeuo pipefail
secret_paths=(
  /etc/chromat/secrets/db_password
  /etc/chromat/secrets/db_root_password
  /etc/chromat/secrets/telegram_bot_token
  /etc/chromat/backup-age-recipient
  /etc/chromat/secrets/operator_password
)
for secret_path in "${secret_paths[@]}"; do
  if [[ -e "$secret_path" ]]; then
    printf "secret already exists: %s\n" "$secret_path" >&2
    exit 1
  fi
done
for secret_path in "${secret_paths[@]}"; do
  install -m 0600 /dev/null "$secret_path"
done
'
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
sudo "$STAGING_DIR/$RELEASE_VERSION/scripts/install-production-tls.sh" \
  /ruta/temporal/tls /srv/chromat/tls 192.168.1.50
sudo "$STAGING_DIR/$RELEASE_VERSION/scripts/check-tls-expiry.sh" \
  /srv/chromat/tls/server.crt 30
```

Consulte [`../deployment/tls.md`](../deployment/tls.md) para validar la
cadena y renovar. Una renovación que cambie certificados exige la opción
explícita `--replace`; una instalación normal nunca sustituye TLS existente.

## 4. Instalar y configurar la release inicial

Instale cada versión una sola vez. El destino debe no existir; no se
sobrescribe una release ni se eliminan datos:

```bash
export RELEASE_DIR="/srv/chromat/releases/$RELEASE_VERSION"
sudo test ! -e "$RELEASE_DIR"
sudo cp -a "$STAGING_DIR/$RELEASE_VERSION" "$RELEASE_DIR"
sudo "$RELEASE_DIR/scripts/verify-artifacts.sh" "$RELEASE_DIR"
sudo bash -c 'for image_archive in "$1"/images/*.tar; do
  sudo docker load --input "$image_archive"
done' _ "$RELEASE_DIR"
```

El paquete incluye las cuatro imágenes de Compose y, separadamente, la imagen
auxiliar `busybox:1.36.1`; el glob anterior carga ambas clases de artefactos.

Inicialice una configuración persistente fuera de la release. El archivo no
contiene valores secretos: sus referencias apuntan a los archivos anteriores.
No lo reemplace durante actualizaciones.

```bash
sudo test ! -e /etc/chromat/production.env
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

No active, arranque ni abra HTTPS mediante comandos independientes. Siga
íntegramente la sección **Instalación inicial** de
[`../deployment/promotion.md`](../deployment/promotion.md), que es el único
procedimiento autorizado para publicar una release. Mantiene el lock de
promoción, persiste `LINK_STATE`, usa el recuperador para rollback y exige
confirmar `BLOCKED` antes de retirar la regla temporal y `OPENED` después de
abrir HTTPS. No ejecute `ln`, `ln -sfn`, `mv` ni `ufw allow 443` sobre los
enlaces o el firewall fuera de ese procedimiento.

Después de que la promoción canónica haya confirmado `OPENED`, cree el primer
operador una sola vez. La contraseña se monta como archivo temporal dentro del
contenedor y no aparece en la línea de comandos:

```bash
sudo docker compose --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" run --rm \
  -e OPERATOR_PASSWORD_FILE=/run/secrets/operator_password \
  -v /etc/chromat/secrets/operator_password:/run/secrets/operator_password:ro \
  api npm run create-operator -- NOMBRE_DEL_OPERADOR
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

Después siga íntegramente la sección **Actualización** de
[`../deployment/promotion.md`](../deployment/promotion.md). Es el único flujo
que puede cambiar `active` o `previous`: adquiere el lock, persiste
`LINK_STATE`, verifica el backup y conserva el estado para que
`recover-release-links.sh` pueda restaurar ambos enlaces. La confirmación
`BLOCKED` es obligatoria antes de retirar la regla temporal y `OPENED` antes
de eliminar el estado. No replique ni sustituya esos pasos con `ln`, `mv`,
`docker compose down` o reglas UFW en esta guía.

## 6. Rollback

Ejecute exclusivamente los escenarios **Aborto y rollback** de
[`../deployment/promotion.md`](../deployment/promotion.md). El recuperador
restaura los enlaces desde `LINK_STATE` bajo el lock de promoción; no cambie
`active`, `previous` ni HTTPS manualmente. No ejecute down-migrations. Si la
base no es compatible, el único rollback aceptable es restaurar en aislamiento
el backup verificado de la versión anterior según
[`../deployment/backups.md`](../deployment/backups.md).

## Limitaciones verificables

El repositorio no incluye una declaración mecanizable de compatibilidad entre
versiones y migraciones, ni firma criptográfica de releases, CI/CD, registro
privado o automatización de firewall. Por ello un administrador debe aprobar
la compatibilidad de cada actualización y autenticar el canal de transferencia;
un checksum por sí solo no autoriza ejecutar una release.
