# CHROMAT Server

Servidor en local para el monitoreo de la maduración de frutos mediante reconocimiento de imágenes.

Este repositorio contiene la parte de servidor del proyecto de investigación **"Tecnologías de reconocimiento de imágenes como apoyo en la agricultura de la región"** (UAdeO, Unidad Regional Guamúchil, Ingeniería de Software). También es el proyecto de la materia de **Cómputo en la Nube**, que se ejecuta en una máquina virtual local con Ubuntu Server.

---

## 1. ¿De qué trata el proyecto?

Los pequeños productores de Sinaloa suelen decidir cuándo cosechar solo por inspección visual, un método subjetivo que no deja registro. Este proyecto propone una solución de bajo costo:

1. Una **Raspberry Pi con cámara** toma fotografías de los frutos en la huerta (mango y otros cultivos, como calabacita).
2. Las imágenes se envían por la red al **servidor**, que las almacena y las clasifica por etapa de maduración.
3. El productor consulta el estado de sus frutos y su historial en un **panel web** (más adelante, también en una app móvil) y recibe **alertas** cuando llegan a la etapa de cosecha.

La herramienta complementa la experiencia del productor; no la sustituye.

## 2. Alcance de este repositorio

Incluye: servidor, API, clasificación de imágenes, base de datos, panel web, alertas y script de captura de la Raspberry Pi.

No incluye: el entrenamiento de la red neuronal (se hace en otro entorno, por ejemplo Google Colab, y aquí solo se usa el modelo ya entrenado), la encuesta a productores ni su análisis estadístico.

## 3. Arquitectura actual

```
 Huerta                                  VM Ubuntu Server (Docker Compose)
┌───────────────┐   imágenes + datos   ┌───────────────────────────────────────────┐
│ Raspberry Pi  │ ───── HTTPS:443 ───► │  Nginx (443)                              │
│ + cámara      │                      │    ├─► Panel web                          │
│ (edge/)       │                      │    └─► API Node.js  ──► Inferencia Python │
└───────────────┘                      │              │                            │
                                       │              └──► MariaDB                 │
Productor ──── navegador ────────────► │  Alertas (correo / Telegram)              │
                                       └───────────────────────────────────────────┘
```

| Servicio | Tecnología | Función | Expuesto fuera de la VM |
|---|---|---|---|
| `nginx` | Nginx | TLS, panel y proxy `/api` | Sí, solo 443 |
| `api` | Node.js 26 | Ingesta, autenticación, panel y administración | No |
| `worker` | Node.js 26 | Jobs, inferencia, agregación y alertas | No |
| `telegram-worker` | Node.js 26 | Entrega Telegram con leases y reintentos | No |
| `inference` | Python 3.13 | Clasificación HSV/CNN determinista | No |
| `db` | MariaDB 11.8 | Metadatos, jobs, Datos derivados y auditoría | No |

**Decisión de seguridad:** solo Nginx publica TCP/443. API, workers, inferencia y MariaDB permanecen en la red interna de Compose.

**Decisión de diseño:** la API recibe `POST /api/v1/events` como multipart JSON más JPEG/PNG. La identidad de la fuente se deriva de su API key.

## 4. Flujo de datos

1. La Raspberry Pi captura una imagen y lee temperatura y humedad.
2. Envía la imagen y los datos a `POST /api/v1/events`.
3. La API guarda el Evento de monitoreo, el Dato crudo y un único job antes de responder `202`.
4. El worker procesa el job, conserva ejecuciones versionadas y actualiza el Dato derivado oficial.
5. El estado agregado genera una alerta deduplicada al entrar en `maduro`; Telegram la entrega con leases y reintentos.
6. El productor consulta únicamente sus fuentes desde el panel de solo lectura.

## 5. Inicio local

```
cp .env.example .env
export CHROMAT_VM_IP=192.0.2.10 # replace with the VM address
mkdir -p secrets
printf '%s\n' 'replace-with-a-development-token' > secrets/telegram_bot_token
printf '%s\n' 'replace-with-a-development-db-password' > secrets/db_password
printf '%s\n' 'replace-with-a-development-root-password' > secrets/db_root_password
bash scripts/dev-tls.sh
docker compose up --build -d
```

Los certificados generados por `scripts/dev-tls.sh` son locales y no deben
usarse como materiales de producción. El único puerto publicado por Compose es
TCP/443; API, workers, inferencia y MariaDB permanecen internos.

Para smoke tests con TLS verificado, exporta `CA_CERT=$PWD/certs/dev/ca.crt` y
configura `ADMIN_USERNAME`, `ADMIN_PASSWORD`, `SMOKE_SOURCE_ID` y
`SMOKE_SOURCE_API_KEY` para la Fuente de monitoreo dedicada. Configura
`FOREIGN_EVENT_ID` con un evento perteneciente a otra Fuente de monitoreo para
probar el aislamiento entre fuentes.
El worker Telegram y las credenciales de MariaDB usan archivos externos
indicados por `TELEGRAM_BOT_TOKEN_HOST_FILE`, `DB_PASSWORD_HOST_FILE` y
`DB_ROOT_PASSWORD_HOST_FILE`.

## 6. Operación y validación

### Estado actual

La implementación local cubre ingesta idempotente, procesamiento asíncrono con
leases y reintentos, inferencia HSV/CNN determinista, autenticación de
operadores y fuentes, panel de productor, estado agregado, alertas Telegram,
reprocesamiento auditable, retención, backups, logs estructurados, métricas
administrativas y protección de capacidad.

La suite API tiene 13 pruebas pasando. También pasan la validación de Compose,
la sintaxis Bash/Python y el smoke skeleton. La validación E2E completa requiere
un entorno Compose iniciado, credenciales de smoke y una CA confiable; el envío
real a Telegram se valida separadamente.

El despliegue reproducible Fedora → Ubuntu está chartado, pero permanece como
trabajo abierto en los tickets Wayfinder #31–#35: paquete amd64, host Ubuntu,
TLS de producción, backup/restore y runbook de readiness/smoke/rollback.
CI/CD, Kubernetes, alta disponibilidad y escalado horizontal siguen fuera de
alcance.

Las pruebas unitarias de la API se ejecutan desde `api/`:

```bash
cd api
npm test
```

La suite de smoke tests requiere un despliegue iniciado y una CA confiable:

```bash
CA_CERT="$PWD/certs/dev/ca.crt" \
SMOKE_TESTS=all \
tests/smoke/run.sh
```

Los backups se generan con `scripts/backup.sh` y se validan en aislamiento con
`scripts/verify-backup.sh`. Las migraciones son numeradas y forward-only.
La preparación de paquetes Fedora → Ubuntu está documentada en
[`docs/deployment/artifacts.md`](docs/deployment/artifacts.md).
La operación de backups cifrados, retención y restauración está documentada en
[`docs/deployment/backups.md`](docs/deployment/backups.md).
La promoción manual con readiness, smoke tests y rollback compatible está
documentada en [`docs/deployment/promotion.md`](docs/deployment/promotion.md).
Los requisitos y la guía de instalación productiva para Ubuntu Server 26.04
están en [`docs/installation/requisitos.md`](docs/installation/requisitos.md)
y [`docs/installation/ubuntu-server-26.04.md`](docs/installation/ubuntu-server-26.04.md).
[`docs/installation/ubuntu-server-24.04.md`](docs/installation/ubuntu-server-24.04.md)
documenta una alternativa experimental, no soportada para producción.

## 7. Convenciones

- **Secretos:** contraseñas, tokens, claves TLS privadas y claves de backup quedan fuera de Git. Solo se versiona `.env.example`.
- **API:** rutas versionadas (`/api/v1/...`), respuestas JSON y errores con código HTTP adecuado.
- **Commits:** mensajes cortos en español, en infinitivo (por ejemplo, `Agregar endpoint de subida de imágenes`).
- **Datos:** los volúmenes de crudos, base de datos y backups no se publican por Nginx.

## 8. Relación con el proyecto de investigación

Esta implementación alimenta el **Capítulo IV (Desarrollo del proyecto)**: arquitectura, diagramas de despliegue, base de datos, interfaces y pruebas. También aporta datos para el **Capítulo V (Resultados)**, como tiempo de respuesta del servidor, costo del nodo de captura y desempeño de los clasificadores.

## 9. Autor

Juan Francisco Hernández Camacho · Matrícula 23060120
Asesor: Abel Ignacio Elizalde Gaxiola
Universidad Autónoma de Occidente, Unidad Regional Guamúchil
