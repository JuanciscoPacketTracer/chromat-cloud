# Requisitos preliminares de instalación

Este documento describe los requisitos observables en el repositorio actual
para una instalación de CHROMAT Server. La plataforma objetivo es **Ubuntu
Server 26.04 LTS AMD64**, conforme a ADR-0001. Ubuntu Server 24.04.5 LTS queda
como alternativa experimental no soportada; no debe recibir una promoción de
producción hasta contar con una decisión arquitectónica y evidencia propia.

## Confirmados por el repositorio

| Área | Requisito |
| --- | --- |
| Arquitectura | CPU x86_64/amd64. Las construcciones Compose declaran `linux/amd64`. |
| Sistema de contenedores | Docker Engine y el plugin Docker Compose. |
| Desarrollo desde Git | Git y acceso de lectura a `https://github.com/JuanciscoPacketTracer/chromat-cloud.git`; este flujo construye imágenes localmente y no es una promoción productiva. |
| Producción por artefactos | Paquete verificado para `linux/amd64`, Docker Engine, Compose y acceso administrativo mediante `sudo`. El host carga imágenes con `docker load`; no requiere Git ni acceso a registros durante la promoción. |
| Servicios | Nginx 1.29.2, Node.js 26.0.0, Python 3.13.9 y MariaDB 11.8.2, según `compose.yaml` y los Dockerfiles. |
| Puerto publicado | TCP/443 únicamente. API, workers, inferencia y MariaDB permanecen en la red interna de Compose. |
| Almacenamiento persistente | Volúmenes Docker `chromat_db_data` y `chromat_raw_data` para MariaDB y datos crudos. |
| Modelo | `inference/models/deterministic-model.json`, montado de solo lectura en inferencia. |
| Secretos de servicio | Archivos externos: contraseña de MariaDB, contraseña root de MariaDB y token de Telegram. No se admiten como valores de entorno de Compose. |
| TLS | `server.crt` y `server.key` se montan de solo lectura en Nginx. Los clientes autorizados validan con `ca.crt`; no se usa `--insecure`. |
| Inicialización | Las migraciones SQL numeradas están en `db/migrations/`; API, worker y worker de Telegram ejecutan migraciones forward-only al iniciar. |
| Operador | El primer operador se crea una sola vez con `npm run create-operator`; su contraseña se guarda como Argon2id. |
| Backup | `scripts/backup.sh` requiere `age`, una identidad/destinatario configurados, un filesystem externo no raíz y Docker. |

## Valores recomendados provisionales

Estos valores no son requisitos definitivos. ADR-0001 propone **4 vCPU, 8 GB
RAM y 60 a 80 GB de disco** sujetos a mediciones de carga, retención, tamaño de
imágenes y respaldo. Antes de usar una VM distinta, mida espacio en
`/var/lib/docker`, crecimiento de datos crudos y el volumen de backups.

Use un disco o filesystem adicional para `BACKUP_EXTERNAL_DIR`; el script de
backup rechaza un destino en el filesystem raíz y exige que esté fuera del
directorio local de backups.

## Materiales que debe preparar el operador

No se deben copiar a Git ni al paquete de artefactos:

- `db_password` y `db_root_password`;
- `telegram_bot_token`, si se habilitan alertas de Telegram;
- contraseña inicial del operador;
- `server.crt`, `server.key` y `ca.crt`;
- destinatario público e identidad privada de `age` para backups.

La clave privada de la CA (`ca.key`) nunca se instala en el servidor.

`BACKUP_SECRET_FILES` debe enumerar exactamente los secretos de servicio
instalados en `/etc/chromat/secrets`: `db_password`, `db_root_password` y
`telegram_bot_token`. El nombre canónico del token es siempre
`telegram_bot_token`, tanto en el host como en `/run/secrets`.

## Flujos de instalación

- **Producción en Ubuntu 26.04:** siga
  [ubuntu-server-26.04.md](ubuntu-server-26.04.md). La promoción usa el
  paquete de artefactos y los runbooks de `docs/deployment/`, conforme a
  ADR-0008.
- **Desarrollo desde Git:** construya y ejecute Compose sólo en un entorno de
  desarrollo o de validación explícita. No equivale a una release reproducible.
- **Ubuntu 24.04.5 experimental:** consulte
  [ubuntu-server-24.04.md](ubuntu-server-24.04.md). No está soportado para
  producción ni por el manifiesto de artefactos.

## Pendiente de validación

- Instalación completa en una VM nueva con Ubuntu Server **26.04 LTS AMD64**,
  incluido el flujo de promoción de artefactos.
- Validación independiente de Ubuntu Server **24.04.5 LTS AMD64** antes de
  considerar ampliar la plataforma soportada.
- Dimensionamiento definitivo, rendimiento de inferencia, espacio para
  retención y capacidad de backups.
- Procedimiento de firewall del host y comportamiento de Docker frente a las
  reglas de filtrado.
- Ejecución de la promoción reproducible Fedora a Ubuntu y su rollback:
  consulte `../deployment/artifacts.md` y `../deployment/promotion.md`.

## Referencias

- `../../compose.yaml`
- `../../.env.example`
- `../adr/0001-linea-base-de-despliegue.md`
- `../adr/0002-certificados-tls-en-red-local.md`
- `../adr/0006-autenticacion-autorizacion-y-exposicion.md`
- `../deployment/tls.md`
- `../deployment/backups.md`
