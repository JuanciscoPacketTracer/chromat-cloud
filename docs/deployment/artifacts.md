# Artefactos de promoción Fedora → Ubuntu

Este procedimiento produce un paquete autosuficiente para `linux/amd64`.
Fedora construye y verifica las imágenes; Ubuntu solo carga los tarballs y
ejecuta Compose con `PULL_POLICY=never`.

## Construir el paquete

Requiere Docker Engine con el daemon disponible, Docker Compose, Git, Python 3
y `sha256sum`:

```bash
scripts/package-artifacts.sh 2026.11.09-1
```

El resultado queda en `dist/artifacts/2026.11.09-1/` y contiene:

- `images/*.tar`: imágenes propias y de terceros exportadas con `docker save`.
- `model/deterministic-model.json`: modelo separado.
- `db/*.sql`: migraciones.
- `compose.yaml`, `nginx/`, `web/` y `.env.example`: runtime no secreto.
- `production.env.example`: nombres versionados, `PULL_POLICY=never` y
  placeholders que deben completarse con secretos provisionados fuera del
  paquete.
- `manifest.json`: commit, plataforma, digests, checksums, modelo, migración,
  configuración, Ubuntu objetivo, versiones de Docker/Compose, fecha y
  operador.
- `checksums.sha256`: huellas del contenido del paquete.

El script conserva `active` y `previous` como enlaces simbólicos dentro de
`dist/artifacts/`. La promoción activa anterior se convierte en `previous`
antes de activar la nueva versión.
También genera `chromat-<version>.tar.gz.sha256` para verificar el archivo
comprimido durante el transporte.

## Verificar fuera de Git

La verificación no necesita consultar el repositorio:

```bash
scripts/verify-artifacts.sh dist/artifacts/2026.11.09-1
```

Comprueba los campos obligatorios del manifiesto, la plataforma amd64,
`PULL_POLICY=never`, la existencia del modelo y de cada tarball, los checksums y
la ausencia de archivos con nombres de secretos. Un fallo debe abortar la
promoción.

## Instalar en Ubuntu

Transfiere el directorio o el tarball verificado junto con los materiales
secretos provisionados fuera de Git. Copia `production.env.example` a
`production.env` y completa sus credenciales en Ubuntu; el paquete nunca
contiene contraseñas o tokens reales. En Ubuntu no se ejecutan `docker compose
pull` ni `docker compose build`; se cargan las imágenes con `docker load` y se
usa `production.env`. La clave privada de la CA nunca forma parte del paquete.

El modelo se monta desde `model/deterministic-model.json` como archivo de solo
lectura; no depende de una copia distinta embebida en la imagen.

## Rollback compatible

Conserva `active` y `previous` hasta confirmar la promoción. Para volver atrás,
carga las imágenes de `previous`, usa su manifiesto y `production.env`, y
arranca Compose solo si la migración declara compatibilidad con esa versión.
No se ejecutan down-migrations. Si la base ya no es compatible, detén el
tráfico y restaura el backup verificado asociado a la versión anterior.

El paquete no firma criptográficamente los checksums: el transporte y la
autenticidad del paquete se protegen por el canal operativo elegido, conforme a
ADR-0008.
