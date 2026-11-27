# Desarrollo e instalación con Git + Docker Compose

Esta es la guía principal para Fedora local y un servidor Ubuntu amd64.
No requiere releases, paquetes offline, otra VM constructora, backups,
restauración ni rollback. Se conservan los volúmenes y los secretos fuera de Git.

## 1. Requisitos

- Git, Bash, OpenSSL, curl y Docker Engine con el plugin Docker Compose
  actualizado (soporte de `up --wait`).
- Acceso a GitHub y a los registros de imágenes durante la construcción.
- TCP/443 disponible; para acceder desde Raspberry Pi u otro equipo, red
  alcanzable y firewall del host permitiendo HTTPS. No exponga MariaDB ni la API.
- La base actual usa amd64; Raspberry Pi es cliente de captura, no el servidor.

Docker contiene Node.js, Python y MariaDB: no necesita instalarlos en Ubuntu.
Instale Docker según su [guía oficial](https://docs.docker.com/engine/install/)
si aún no está disponible. En Fedora con SELinux, revise denegaciones de los
bind mounts si aparecen errores de permisos; no desactive SELinux globalmente.

En Ubuntu, si el usuario no tiene acceso al socket Docker, anteponga `sudo` a
los comandos `docker compose` de esta guía. Ejecute Git, `scripts/dev-tls.sh`
y `scripts/update.sh` como su usuario normal; para el actualizador use
`bash scripts/update.sh --sudo`. No es necesario añadir el usuario al grupo
`docker`, que concede privilegios equivalentes a root.

## 2. Primera instalación

En Fedora o en Ubuntu:

```bash
git clone https://github.com/JuanciscoPacketTracer/chromat-cloud.git
cd chromat-cloud
```

El checkout debe contener estos cambios; una rama remota que todavía no los
incluya no tiene el nuevo flujo. Una vez publicados, use la rama que los contenga
y mantenga su upstream configurado.

Prepare la configuración **una sola vez**, en un checkout nuevo:

```bash
test ! -e .env && cp .env.example .env
mkdir -p secrets
chmod 700 secrets
(umask 077; set -C; openssl rand -hex 32 > secrets/db_password)
(umask 077; set -C; openssl rand -hex 32 > secrets/db_root_password)

# En Fedora local puede usar 127.0.0.1; en la VM use su IPv4 alcanzable.
export CHROMAT_VM_IP=127.0.0.1
bash scripts/dev-tls.sh
docker compose config --quiet
docker compose up -d --build --force-recreate --wait --wait-timeout 120
docker compose ps
curl --fail --cacert certs/dev/ca.crt \
  "https://${CHROMAT_VM_IP}/health/ready"
```

Deténgase si un comando falla. No sobrescriba `.env`, contraseñas o certificados
en una instalación existente. Cambiar las contraseñas de archivo no cambia
automáticamente las credenciales de una base ya inicializada.

Los certificados de este bloque son **de desarrollo/laboratorio**. Para un
servidor público configure en `.env` `TLS_CERT_HOST_PATH` y
`TLS_KEY_HOST_PATH` con un certificado válido para su dominio. Los clientes
deben confiar en su emisor; no use `curl -k` ni desactive la validación TLS.
El cliente Raspberry Pi solo necesita el certificado público de la CA, nunca
su clave privada ni las contraseñas de MariaDB.

### Primer acceso al panel

Cree una contraseña del operador en un archivo privado; no se guarda en Git
ni se pasa como argumento:

```bash
(
  umask 077
  set -C
  read -r -s -p "Contraseña del operador: " password
  printf '\n'
  test -n "$password" && printf '%s\n' "$password" > secrets/operator_password
)
docker compose run --rm --no-deps \
  -v "$PWD/secrets/operator_password:/run/secrets/operator_password:ro" \
  -e OPERATOR_PASSWORD_FILE=/run/secrets/operator_password \
  api npm run create-operator -- admin
```

Este comando crea únicamente el primer operador; no se repite en actualizaciones.
Abra `https://<IP-o-dominio>/panel/`, con la CA confiable en el navegador.
El panel actual es de consulta: crear fuentes, productores y asignaciones se
hace mediante la API administrativa, no mediante botones del panel.

## 3. Trabajo diario en Fedora

Edite código, compruebe el panel y pruebe imágenes. Para aplicar cambios locales:

```bash
docker compose up -d --build --force-recreate --wait --wait-timeout 120
```

No necesita publicar una release. Tras revisar y probar sus cambios, haga commit
y push a la rama que usarán los servidores. El servidor no recibe cambios
que solo existen en su máquina.

## 4. Actualizar un servidor

Desde el checkout del servidor, con árbol limpio y upstream configurado:

```bash
bash scripts/update.sh
```

En Ubuntu con Docker accesible solo mediante `sudo`:

```bash
bash scripts/update.sh --sudo
```

La opción eleva únicamente Docker, no Git ni el script completo.

El script comprueba Git/Docker y `.env`, ejecuta `git pull --ff-only`, valida
Compose, reconstruye y espera los servicios. Aborta ante errores; no crea
commits, no hace stash, no fuerza merges ni ejecuta backups/restauración.
Equivale al flujo principal:

```bash
git pull --ff-only
docker compose config --quiet
docker compose up -d --build --force-recreate --wait --wait-timeout 120
docker compose ps
```

`.env`, certificados y secretos se conservan en cada host. Compare los cambios
de `.env.example` al actualizar: Git no incorpora variables nuevas a su `.env`.
Nginx vuelve a resolver la dirección de la API si su contenedor cambia.
Se recrean los contenedores para aplicar también cambios de archivos montados,
como la configuración de Nginx y las migraciones. Sus volúmenes se conservan.

Las migraciones pendientes se ejecutan al iniciar API/workers con un lock
compartido. Pueden modificar la base: **no hay deshacer automático**. Los cambios
de esquema deben revisarse y probarse antes del push. La actualización puede
interrumpir solicitudes; no garantiza cero downtime.

## 5. Datos, fallos y Telegram opcional

Las fotografías y MariaDB viven en `chromat_raw_data` y `chromat_db_data`.
Reconstruir/recrear contenedores no elimina esos volúmenes. No use
`docker compose down -v` ni elimine volúmenes para solucionar errores.
Sin backups no hay protección ante pérdida del disco: use datos de prueba
o conserve las fotografías originales fuera del servidor.

Si el arranque falla:

```bash
docker compose ps -a
docker compose logs --tail 100 nginx api worker inference db
```

No publique logs que contengan información privada. Después de cada actualización
compruebe readiness, acceso al panel y una imagen de prueba desde un cliente;
un health check no demuestra que el clasificador sea científicamente correcto.

Telegram no se inicia por defecto. Si desea entrega de alertas, prepare
`secrets/telegram_bot_token` de forma privada, configure `PANEL_URL` y añada
`COMPOSE_PROFILES=telegram` a `.env`. Luego ejecute el mismo comando de arranque.
Para desactivarlo en una instalación que ya lo ejecutaba:

```bash
docker compose --profile telegram stop telegram-worker
```

Después retire `COMPOSE_PROFILES=telegram` de `.env`. No se borran las alertas
persistidas; las pendientes pueden entregarse al volver a activar el worker.
