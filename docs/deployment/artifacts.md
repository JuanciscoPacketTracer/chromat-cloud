# Artefactos de promoción Fedora a Ubuntu y GitHub Releases

Fedora construye y verifica el paquete `linux/amd64`; Ubuntu 26.04 solamente
carga sus imágenes y ejecuta Compose con `PULL_POLICY=never`. Los enlaces
`dist/artifacts/active` y `previous` son locales a Fedora: **nunca** se copian
ni se usan como los enlaces operativos de Ubuntu.

## Construir y preparar un Draft Release

El empaquetador genera estos activos para una versión:

| Activo | Propósito |
| --- | --- |
| `chromat-VERSION.tar.gz` | Paquete autosuficiente: imágenes offline, modelo, migraciones, Compose, scripts, smoke tests y runbooks. |
| `chromat-VERSION.tar.gz.sha256` | SHA-256 del TAR. |
| `chromat-VERSION.manifest.json` | Manifiesto legible sin extraer el TAR; debe ser idéntico al manifiesto incluido en él. |

En un entorno de construcción amd64 con Docker Engine y Compose, árbol Git
limpio y un tag remoto que apunte al commit empaquetado:

```bash
VERSION=2026.11.12-1
git tag -a "$VERSION" -m "CHROMAT $VERSION"
git push origin "$VERSION"
scripts/package-artifacts.sh "$VERSION"
scripts/create-github-draft-release.sh "$VERSION"
```

El segundo comando vuelve a validar el paquete, checksum, contenido de las
imágenes y coincidencia del manifiesto con el TAR. La validación semántica
carga los cinco TAR existentes en Docker e inspecciona el ID y la arquitectura
registrados en el manifiesto; si Docker no está disponible o cualquier
comprobación falla, no se invoca GitHub CLI. Rechaza un tag ausente o que no
corresponda al commit del manifiesto y crea solamente un **Draft Release**:
nunca lo publica.
La creación y publicación del tag requiere la autorización operativa
correspondiente; no forma parte de la instalación en Ubuntu.

## Descargar y comprobar una release

En Ubuntu, descargue los tres activos de la Release publicada mediante HTTPS.
GitHub autentica el origen de la release; el checksum detecta corrupción de la
descarga y `verify-artifacts.sh` comprueba el contenido antes de ejecutarlo.
No se necesita Git, acceso a un registro de contenedores ni `gh` en el host.

```bash
VERSION=2026.11.12-1
REPOSITORY=JuanciscoPacketTracer/chromat-cloud
RELEASE_URL="https://github.com/${REPOSITORY}/releases/download/${VERSION}"
STAGING_DIR=/srv/chromat/staging
sudo install -d -o root -g root -m 0700 "$STAGING_DIR"
cd "$STAGING_DIR"
sudo curl --fail --location --remote-name \
  "${RELEASE_URL}/chromat-${VERSION}.tar.gz"
sudo curl --fail --location --remote-name \
  "${RELEASE_URL}/chromat-${VERSION}.tar.gz.sha256"
sudo curl --fail --location --remote-name \
  "${RELEASE_URL}/chromat-${VERSION}.manifest.json"
```

Como administrador, compruebe el checksum **antes** de extraer. No acepte un
TAR sin su checksum ni ejecute el contenido hasta completar ambas
verificaciones:

```bash
sudo install -d -o root -g root -m 0755 /srv/chromat/releases
sudo test ! -e "/srv/chromat/releases/${VERSION}"
sha256sum --check "chromat-${VERSION}.tar.gz.sha256"
sudo tar -xzf "chromat-${VERSION}.tar.gz" -C /srv/chromat/releases
sudo test -d "/srv/chromat/releases/${VERSION}"
sudo "/srv/chromat/releases/${VERSION}/scripts/verify-artifacts.sh" \
  "/srv/chromat/releases/${VERSION}"
sudo cmp --silent "chromat-${VERSION}.manifest.json" \
  "/srv/chromat/releases/${VERSION}/manifest.json"
```

`test ! -e` hace que una release existente aborte; no se sobreescribe una
release verificada. El paquete contiene imágenes, migraciones, scripts,
runbooks —incluida la guía Ubuntu 26.04— y sus checksums. No incluye secretos
ni claves privadas de CA.

## Promoción operativa de Ubuntu

La extracción y verificación no activan una release. No ejecute `ln`, `mv` ni
ninguna otra operación sobre `/srv/chromat/active` o
`/srv/chromat/previous` desde este runbook. La instalación inicial, la
actualización y el rollback se ejecutan exclusivamente siguiendo
[`promotion.md`](promotion.md). Ese procedimiento adquiere el lock de
promoción, persiste `LINK_STATE`, realiza reemplazos atómicos, conserva el
estado para recuperación y exige las confirmaciones externas `BLOCKED` y
`OPENED` antes de finalizar.

El recuperador `scripts/recover-release-links.sh` forma parte de ese flujo:
desde el shell de promoción reutiliza el descriptor 9 heredado y desde un
shell root nuevo adquiere el mismo lock. No sustituya ese procedimiento con
un cambio manual de enlaces.

Todos los comandos operativos usan siempre el mismo proyecto y los nombres de
volumen definidos en `compose.yaml`:

```bash
RELEASE_DIR=/srv/chromat/active
sudo docker compose --project-name chromat --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" config
```

No se ejecutan `docker compose pull`, `docker compose build` ni `git pull` en
Ubuntu. Véanse `promotion.md`, `tls.md` y `backups.md` para los flujos de
instalación, actualización y recuperación.

La verificación estática (`verify-artifacts.sh`) comprueba estructura, manifest,
checksums y presencia de los cinco archivos de imagen. Antes de crear un Draft
Release, `create-github-draft-release.sh` ejecuta obligatoriamente ambas
verificaciones sobre el mismo `PACKAGE_DIR`: la validación semántica carga cada
TAR e inspecciona su ID y arquitectura sin ejecutar pulls ni builds:

```bash
scripts/verify-artifacts.sh "$PACKAGE_DIR"
scripts/verify-image-artifacts.sh "$PACKAGE_DIR"
```

La validación semántica debe ejecutarse en un Docker de construcción aislado;
no forma parte de `verify-artifacts.sh` ni se ejecuta automáticamente en el
host productivo. Es offline respecto al registry: sólo carga los TAR existentes
y no realiza pulls ni builds.

BusyBox se descarga únicamente durante el empaquetado mediante esta referencia
inmutable y plataforma explícita:

```text
docker.io/library/busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f
```

Después se crea el alias operativo local `busybox:1.36.1`, que es el nombre
usado por `docker save`, por el paquete y por las operaciones de backup. El
alias no constituye la identidad reproducible por sí mismo.

El manifest registra tres digest distintos:

| Campo | Identidad |
| --- | --- |
| `index_digest` | `sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662`, índice multi-arquitectura asociado al tag oficial. |
| `platform_digest` | `sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f`, manifiesto específico `linux/amd64`. |
| `config_digest` / `id` | `sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d`, ID/configuración de la imagen cargada. |

`docker save` y `docker load` conservan el contenido y los tags, pero no se
debe asumir que preservan el digest de registry. Por eso la comprobación
offline compara el `.Id` cargado con `config_digest` y exige `amd64`; no compara
el `.Id` con `platform_digest` ni exige que `RepoDigests` sobreviva a
`docker load`.

`manifest.images` conserva las cuatro imágenes de Compose y
`manifest.auxiliary_images` conserva por separado BusyBox. La descarga fijada
no forma parte de la instalación ni de la operación de producción en Ubuntu:
allí sólo se transporta, carga y verifica el TAR incluido en la release.
