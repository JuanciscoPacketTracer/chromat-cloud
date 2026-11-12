# Guía de producción: Ubuntu Server 26.04 LTS AMD64

Ubuntu Server 26.04 LTS AMD64 es la plataforma objetivo de CHROMAT Server
según ADR-0001. Esta guía describe el aprovisionamiento del host y la
promoción reproducible definida en ADR-0008. Antes de continuar, lea
[requisitos.md](requisitos.md).

## 1. Preparar el host

Use una VM nueva AMD64 con acceso `sudo`. Confirme arquitectura, espacio y
hora; reserve espacio en `/var/lib/docker` y para el filesystem externo de
backups:

```bash
uname -m
df -h
timedatectl status
sudo apt update
sudo apt install --yes ca-certificates curl openssl python3 age
```

Instale Docker Engine, `docker-compose-plugin` y sus dependencias desde el
repositorio apt oficial de Docker para Ubuntu. No use el script de
conveniencia. Registre `docker --version` y `docker compose version` en la
evidencia de la promoción. El grupo `docker` equivale a privilegios root y
debe limitarse a operadores autorizados.

## 2. Preparar secretos y TLS

Los secretos no se copian al paquete ni a Git:

```bash
sudo install -d -m 0700 /etc/chromat/secrets
sudo install -m 0600 /dev/null /etc/chromat/secrets/db_password
sudo install -m 0600 /dev/null /etc/chromat/secrets/db_root_password
sudo install -m 0600 /dev/null /etc/chromat/secrets/telegram_bot_token
sudo install -m 0600 /dev/null /etc/chromat/secrets/operator_password
sudo install -d -m 0700 /srv/chromat/tls
```

Un custodio escribe los valores sin mostrarlos en consola. Instale
`ca.crt`, `server.crt` y `server.key` con
`scripts/install-production-tls.sh`; la clave privada de la CA no se instala
en la VM. El certificado debe incluir `chromat.lan` y la IP de la VM en sus
SAN.

## 3. Promover artefactos verificados

La producción **no se clona ni se construye desde Git**. En el entorno de
construcción se crea un paquete limpio con `scripts/package-artifacts.sh`.
Transfiera el paquete, sus checksums y los secretos provisionados fuera de
Git al host; luego verifique el paquete y cargue sus imágenes con `docker
load`. La configuración de la release debe partir de
`production.env.example` y conservar:

```dotenv
PULL_POLICY=never
DB_PASSWORD_HOST_FILE=/etc/chromat/secrets/db_password
DB_ROOT_PASSWORD_HOST_FILE=/etc/chromat/secrets/db_root_password
TELEGRAM_BOT_TOKEN_HOST_FILE=/etc/chromat/secrets/telegram_bot_token
TLS_CERT_HOST_PATH=/srv/chromat/tls/server.crt
TLS_KEY_HOST_PATH=/srv/chromat/tls/server.key
BACKUP_SECRET_FILES=/etc/chromat/secrets/db_password /etc/chromat/secrets/db_root_password /etc/chromat/secrets/telegram_bot_token
```

Ejecute la secuencia completa de
[`../deployment/artifacts.md`](../deployment/artifacts.md) y
[`../deployment/promotion.md`](../deployment/promotion.md): verificación,
backup, migraciones forward-only, `docker compose ... up -d --no-build`,
readiness, smoke, apertura de TCP/443 y conservación de evidencia. No ejecute
`docker compose build`, `docker compose pull` ni `git pull` en la VM de
producción.

El paquete incluye `docs/deployment/` porque son runbooks que se usan durante
la promoción. Deliberadamente no incluye `docs/installation/`: estas guías
aprovisionan el host antes de recibir la release y no forman parte del runtime
autocontenido. Por ello no se modifica `scripts/package-artifacts.sh`.

## 4. Desarrollo desde Git

El clon Git y `docker compose build` son válidos sólo para desarrollo o
validación explícita. Use un directorio diferente del de releases y no trate
la imagen resultante como una promoción reproducible. Ubuntu 24.04.5 se
documenta por separado como alternativa experimental.
