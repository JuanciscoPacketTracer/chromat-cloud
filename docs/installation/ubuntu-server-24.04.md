# Guía experimental: Ubuntu Server 24.04.5 LTS AMD64

Ubuntu Server 24.04.5 es una alternativa de **validación experimental**, no
una plataforma soportada. ADR-0001 y los manifiestos de artefactos establecen
Ubuntu Server 26.04 LTS AMD64 como objetivo. No use esta guía para promover una
release ni cambie `target_ubuntu_version` para sortear esa restricción.

Lea primero [requisitos.md](requisitos.md). Para producción en Ubuntu 26.04,
use [ubuntu-server-26.04.md](ubuntu-server-26.04.md) junto con los runbooks de
[`../deployment/`](../deployment/). Esta guía sólo documenta una construcción
desde Git para probar compatibilidad de 24.04.5.

## 1. Preparar la VM

Use una instalación AMD64 de Ubuntu Server 24.04.5 LTS con acceso `sudo`.
Actualice los paquetes del sistema y confirme arquitectura, espacio y hora:

```bash
sudo apt update
sudo apt upgrade
uname -m
df -h
timedatectl status
```

La arquitectura esperada es `x86_64`. Revise el espacio de `/var/lib/docker`
antes de construir o cargar imágenes. Los requisitos definitivos de CPU, RAM y
disco siguen pendientes de medición.

Instale las utilidades que requieren el repositorio y los runbooks:

```bash
sudo apt install --yes ca-certificates curl git openssl python3 age
```

## 2. Instalar Docker Engine y Compose

Use el repositorio apt oficial de Docker; no use el script de conveniencia.
Los comandos siguientes corresponden al procedimiento oficial de Docker para
Ubuntu y deben validarse durante #39:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt update
sudo apt install --yes docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
docker --version
docker compose version
```

Para permitir a la cuenta operadora usar Docker sin `sudo`, agréguela al grupo
`docker` y abra una sesión nueva:

```bash
sudo usermod -aG docker "$USER"
```

La pertenencia al grupo `docker` concede privilegios equivalentes a root;
restrinja ese grupo a operadores autorizados.

## 3. Flujo experimental desde Git

Configure un método de acceso a GitHub autorizado para la cuenta operadora.
Con acceso HTTPS de lectura, clone la URL remota actual:

```bash
sudo install -d -o "$USER" -g "$USER" -m 0750 /srv/chromat
git clone https://github.com/JuanciscoPacketTracer/chromat-cloud.git \
  /srv/chromat/app
cd /srv/chromat/app
```

La clonación y construcción local descarga imágenes base y crea las imágenes
de API e inferencia. Es un flujo de desarrollo o validación experimental:
**no es una promoción productiva reproducible** y no sustituye los artefactos
verificados de ADR-0008.

## 4. Crear secretos, directorios y configuración

Los secretos no se guardan en el árbol Git. Cree un directorio restringido:

```bash
sudo install -d -m 0700 /etc/chromat/secrets
sudo install -m 0600 /dev/null /etc/chromat/secrets/db_password
sudo install -m 0600 /dev/null /etc/chromat/secrets/db_root_password
sudo install -m 0600 /dev/null /etc/chromat/secrets/telegram_bot_token
sudo install -m 0600 /dev/null /etc/chromat/secrets/operator_password
```

Un custodio debe escribir los valores reales en esos archivos sin imprimirlos
en consola ni añadirlos a Git. Si Telegram no se habilita todavía, el archivo
del token sigue siendo necesario porque `telegram-worker` lo monta.

Copie la plantilla y ajuste los valores de despliegue:

```bash
cd /srv/chromat/app
cp .env.example .env
```

En `.env`, mantenga los nombres y valores funcionales de la plantilla y cambie
al menos las rutas de secretos a:

```dotenv
DB_PASSWORD_HOST_FILE=/etc/chromat/secrets/db_password
DB_ROOT_PASSWORD_HOST_FILE=/etc/chromat/secrets/db_root_password
TELEGRAM_BOT_TOKEN_HOST_FILE=/etc/chromat/secrets/telegram_bot_token
TLS_CERT_HOST_PATH=/srv/chromat/tls/server.crt
TLS_KEY_HOST_PATH=/srv/chromat/tls/server.key
```

No sustituya las contraseñas de base de datos por variables de entorno. No
cambie sin decisión explícita los límites, la retención, el algoritmo oficial
ni las reglas de agregación definidos en `.env.example`.

## 5. Instalar TLS

La CA se administra fuera de la VM. Reciba solamente `ca.crt`, `server.crt` y
`server.key` en un directorio externo temporal y valide/instale el material:

```bash
sudo install -d -m 0700 /srv/chromat/tls
cd /srv/chromat/app
sudo scripts/install-production-tls.sh \
  /ruta/externa/tls \
  /srv/chromat/tls \
  IP_DE_LA_VM
```

El certificado debe contener el SAN DNS `chromat.lan` y cada IP de prueba.
El script instala `server.key` con modo `0600`; `ca.crt` se distribuye por
separado a clientes autorizados. No use los certificados de
`scripts/dev-tls.sh` como materiales de producción.

Consulte [`../deployment/tls.md`](../deployment/tls.md) para validación,
renovación y revisión de expiración.

## 6. Construir y arrancar para validación experimental

Antes del primer arranque, revise la configuración sin revelar secretos:

```bash
cd /srv/chromat/app
docker compose --env-file .env config --quiet
docker compose --env-file .env build
docker compose --env-file .env up -d
docker compose --env-file .env ps
```

Compose publica únicamente `443:443`. MariaDB inicializa una base nueva con
`db/migrations` y los servicios Node ejecutan las migraciones forward-only
protegidas por un lock. No ejecute migraciones descendentes.

Para inspeccionar versiones aplicadas después de que `db` esté saludable:

```bash
docker compose --env-file .env exec -T db sh -c \
  'mariadb -u root -p"$(cat /run/secrets/db_root_password)" "$MARIADB_DATABASE" \
    -e "SELECT version FROM schema_migrations ORDER BY version"'
```

## 7. Crear el operador inicial

Este comando sólo funciona mientras no exista ningún operador. Requiere que la
contraseña real ya exista en
`/etc/chromat/secrets/operator_password`:

```bash
docker compose --env-file .env run --rm --no-deps \
  -v /etc/chromat/secrets/operator_password:/run/secrets/operator_password:ro \
  -e OPERATOR_PASSWORD_FILE=/run/secrets/operator_password \
  api npm run create-operator -- NOMBRE_DEL_OPERADOR
```

La aplicación almacena la contraseña como Argon2id. Guarde la contraseña en el
gestor de secretos definido por el equipo; no la añada a `.env`.

## 8. Verificar servicios y TLS

Compruebe el estado de los servicios y los logs:

```bash
docker compose --env-file .env ps
docker compose --env-file .env logs --no-color api worker telegram-worker
```

Compruebe Nginx y las probes mediante la CA interna:

```bash
docker compose --env-file .env exec -T nginx nginx -t
curl --fail --cacert /srv/chromat/tls/ca.crt \
  --resolve chromat.lan:443:IP_DE_LA_VM \
  https://chromat.lan/health/live
curl --fail --cacert /srv/chromat/tls/ca.crt \
  --resolve chromat.lan:443:IP_DE_LA_VM \
  https://chromat.lan/health/ready
```

Reemplace `IP_DE_LA_VM` por una IP incluida en el certificado. La validación
debe terminar sin `--insecure`.

El harness aislado está disponible en `tests/smoke/isolated.sh`, pero esta
guía no constituye evidencia de una ejecución satisfactoria. Conserve los
resultados de la validación de 24.04.5 por separado; la validación del runbook
completo sobre ese sistema sigue pendiente.

## 9. Logs y diagnóstico

Los servicios escriben logs JSON a stdout/stderr. Docker los rota con
`max-size=10m` y `max-file=90` según `compose.yaml`.

```bash
docker compose --env-file .env logs --no-color --tail=200 nginx api worker inference
docker compose --env-file .env ps
docker inspect --format '{{.Name}} {{.State.Health.Status}}' \
  chromat-db-1 chromat-api-1 chromat-inference-1
```

Los nombres exactos de contenedor anteriores derivan del nombre de proyecto
actual (`chromat`) y se deben verificar con `docker compose ps` si se cambia.
Para problemas de certificados, use `scripts/check-tls-expiry.sh`; para
capacidad, revise espacio en `/var/lib/docker` y la política
`RAW_MIN_FREE_PERCENT`.

## 10. Actualización y rollback

No actualice una release de producción desde este clon. La promoción y el
rollback productivos corresponden exclusivamente a Ubuntu 26.04 y usan
paquetes verificados, `docker load`, `PULL_POLICY=never` y ninguna
down-migration, como especifica
[`../deployment/promotion.md`](../deployment/promotion.md).

## 11. Backups y retención

Antes de ejecutar backups, prepare un filesystem externo montado, el
destinatario de `age` y las rutas de `.env.example`. El procedimiento completo,
incluida la verificación aislada, está en
[`../deployment/backups.md`](../deployment/backups.md).

La operación base desde la release activa es:

```bash
cd /srv/chromat/app
scripts/backup.sh
```

El script pausa la ingesta y el worker de forma temporal, genera un dump de
MariaDB, empaqueta datos crudos/configuración/secretos seleccionados y cifra
los resultados antes de copiarlos al destino externo. La restauración se
verifica con `scripts/verify-backup.sh`; nunca se restaura directamente sobre
producción.

La retención se ejecuta por separado:

```bash
cd /srv/chromat/app
scripts/retention.sh
```

## Pendientes para #39

- Ejecutar esta guía de punta a punta en una VM nueva Ubuntu Server 24.04.5
  AMD64 y conservar la evidencia.
- Resolver la diferencia con el baseline Ubuntu 26.04 antes de declararla guía
  definitiva.
- Validar firewall, acceso DNS de `chromat.lan`, distribución de `ca.crt`,
  backups cifrados y restauración en el host Ubuntu.
- Medir y fijar recursos de VM, capacidad de almacenamiento y frecuencia
  operativa de backup/retención.
