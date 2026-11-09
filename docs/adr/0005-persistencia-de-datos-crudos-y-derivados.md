# ADR-0005: Persistencia de Datos crudos y derivados

- **Estado:** Aceptada
- **Fecha:** 2026-11-07
- **Alcance:** MariaDB y volúmenes privados de CHROMAT Server

## Contexto

CHROMAT debe conservar imágenes originales, metadatos y resultados de análisis
con ciclos de vida distintos. La persistencia debe mantener la idempotencia,
permitir restauraciones verificables y evitar que Nginx exponga archivos
privados.

## Decisión

### Modelo y archivos

- MariaDB separa `monitoring_events`, `raw_files`, `analysis_runs`, `jobs` y
  `alerts`.
- Los metadatos y resultados estructurados viven en MariaDB; las imágenes
  originales viven en el volumen privado de datos crudos, nunca como BLOB.
- Se conserva una copia física por Evento, aunque el SHA-256 coincida con otro.
- La ruta es `raw/<source_id>/<event_id>.<ext>`. Ambos segmentos se validan y
  `source_id` se deriva de la credencial autenticada; la unicidad lógica sigue
  siendo `(source_id, event_id)`.
- La API escribe el volumen de crudos y el worker lo lee. Solo el job de
  retención puede borrar. Nginx no accede al volumen; las descargas pasan por
  API autorizada.
- El volumen de modelos es privado y se monta en solo lectura para
  worker/inferencia.

### Retención

- El plazo inicial se cuenta desde `received_at`: 90 días para archivos y
  metadatos crudos, y 365 días para Datos derivados, ejecuciones, auditoría y
  alertas.
- `retention_hold` exime las imágenes que forman parte del conjunto de datos
  de investigación. Antes de aplicar la retención se ejecuta el procedimiento
  de exportación del conjunto.
- Al vencer el plazo se elimina el archivo y su ruta. El Evento permanece como
  tombstone con identidad, hash y vencimiento, conservando referencias de
  Datos derivados e idempotencia frente a reintentos tardíos.

### Backup, restauración y migraciones

- El backup diario congela temporalmente ingesta y jobs. Durante el
  congelamiento la API responde `503` con `Retry-After`; la fuente lo trata
  como reintentable. El congelamiento tiene una duración máxima.
- Cada copia incluye dump consistente de MariaDB, archivos del volumen crudo y
  manifiesto de hashes. La política usa copias incrementales entre copias
  completas periódicas y una conservación propia para respaldos.
- Se realiza un backup antes de cada migración.
- Las migraciones SQL son numeradas, forward-only, explícitas y registradas.
  Esquemas pendientes o incompatibles bloquean API/worker.
- La restauración ocurre aislada antes de aceptar tráfico y verifica
  referencias sin archivo, archivos sin referencia, hashes incorrectos y
  migraciones pendientes.

## Consecuencias

- La retención preserva trazabilidad e idempotencia sin conservar
  indefinidamente los archivos originales.
- La ventana de backup hace visible una indisponibilidad breve y acotada.
- Los permisos de borrado quedan concentrados en un único proceso operativo.

## Fuera de alcance

Los valores finales de RPO/RTO, la capacidad de almacenamiento y la política
detallada de conservación de respaldos se decidirán en el ticket operativo.
