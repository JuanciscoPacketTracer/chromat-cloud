# Artefactos de promoción Fedora a Ubuntu

Fedora construye y verifica el paquete `linux/amd64`; Ubuntu 26.04 solamente
carga sus imágenes y ejecuta Compose con `PULL_POLICY=never`. Los enlaces
`dist/artifacts/active` y `previous` son locales a Fedora: **nunca** se copian
ni se usan como los enlaces operativos de Ubuntu.

## Transferir y comprobar una release

En el equipo que construyó la release, transfiere ambos archivos mediante SSH
autenticado (clave de operador y validación de la clave de host):

```bash
VERSION=2026.11.12-1
scp -- "/ruta/dist/artifacts/chromat-${VERSION}.tar.gz" \
  "/ruta/dist/artifacts/chromat-${VERSION}.tar.gz.sha256" \
  operator@chromat.lan:/tmp/
```

En Ubuntu, como administrador, comprueba el checksum **antes** de extraer. No
aceptes un tarball sin su checksum ni sustituyas esos archivos por una descarga
sin autenticar.

```bash
VERSION=2026.11.12-1
sudo install -d -o root -g root -m 0755 /srv/chromat/releases
sudo test ! -e "/srv/chromat/releases/${VERSION}"
cd /tmp
sha256sum --check "chromat-${VERSION}.tar.gz.sha256"
sudo tar -xzf "chromat-${VERSION}.tar.gz" -C /srv/chromat/releases
sudo test -d "/srv/chromat/releases/${VERSION}"
sudo "/srv/chromat/releases/${VERSION}/scripts/verify-artifacts.sh" \
  "/srv/chromat/releases/${VERSION}"
```

`test ! -e` hace que una release existente aborte; no se sobreescribe una
release verificada. El paquete contiene imágenes, migraciones, scripts,
runbooks y sus checksums. No incluye secretos ni claves privadas de CA.

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
