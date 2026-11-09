# ADR-0003: Contrato de Eventos de monitoreo

- **Estado:** Aceptada
- **Fecha:** 2026-11-07
- **Alcance:** Nginx, API, worker, inferencia Python y MariaDB de CHROMAT Server

## Contexto

CHROMAT recibe imágenes y mediciones desde cada Fuente de monitoreo. La
recepción debe tolerar reintentos de la Raspberry Pi sin duplicar Datos crudos,
trabajos de clasificación ni alertas, y debe separar la ingesta durable del
procesamiento asíncrono.

## Decisión

### Identidad e idempotencia

- La fuente genera un `event_id` UUIDv4 al capturar y lo conserva para todos
  los reintentos.
- `source_id` se deriva de la credencial autenticada; el cliente no lo
  declara en el cuerpo.
- MariaDB impone `UNIQUE (source_id, event_id)`.
- El servidor calcula el SHA-256 autoritativo de la imagen. Un hash enviado por
  la fuente puede verificarse, pero no sustituye al cálculo del servidor.
- Un reintento con el mismo evento e imagen devuelve el estado existente. Un
  hash distinto produce `409 Conflict` y no modifica el Dato crudo.
- Solo existe un trabajo de clasificación por evento.

### Tiempo

- La fuente envía `occurred_at`; el servidor asigna `received_at`; el worker
  asigna `processed_at`.
- Son timestamps ISO 8601 UTC con milisegundos y sufijo `Z`, almacenados como
  `DATETIME(3)` en UTC.
- Si `occurred_at` está más de 5 minutos en el futuro o más de 7 días en el
  pasado respecto a `received_at`, se conserva el evento y se marca
  `clock_suspect = true`.
- El historial se ordena por `occurred_at`; la idempotencia no depende del
  tiempo.

### Ingesta y consulta

- `POST /api/v1/events` usa `multipart/form-data` con una parte JSON y una
  imagen JPEG o PNG.
- `event_id`, `occurred_at` e imagen son obligatorios. `temperature_c` y
  `humidity_rh` son mediciones opcionales con unidades explícitas.
- La carga tiene un límite inicial configurable de 10 MiB.
- Tras validar y persistir durablemente el Dato crudo en estado `pending`, la
  API responde `202 Accepted` con `event_id`, `status`, `received_at` y
  `status_url`.
- `GET /api/v1/events/{event_id}` expone `pending`, `processing`, `completed`
  o `failed`, además de los metadatos, `processed_at`, `clock_suspect` y el
  Dato derivado disponible.
- Un reintento idéntico devuelve `202` mientras el evento está en
  `pending`/`processing`, y `200` si está en estado final. Un evento idéntico
  en `failed` devuelve `200` y no se reprocesa automáticamente.
- La API usa respuestas JSON estructuradas y códigos `400`, `404`, `409`,
  `413`, `415` y `422` según el error. La consulta de un evento ajeno devuelve
  `404`, no `403`.

### Garantías y límites

La fuente debe conservar el mismo evento para reintentos y sincronizar su reloj
por NTP. CHROMAT Server garantiza autenticación, validación, idempotencia y
persistencia previa a `202`, además de no duplicar trabajos.

El límite de CHROMAT Server termina en Nginx, API, worker, inferencia Python y
MariaDB. Quedan fuera el script de captura de la Raspberry Pi, el entrenamiento
del modelo, la encuesta a productores y la aplicación móvil; esta última solo
consumirá la API.

Las transiciones detalladas, reintentos y reprocesamiento manual se decidirán
en el ticket de procesamiento asíncrono. Las credenciales y la autorización
concretas se decidirán en el ticket de seguridad.
