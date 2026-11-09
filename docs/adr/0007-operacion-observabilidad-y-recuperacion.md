# ADR-0007: Operación, observabilidad y recuperación

- **Estado:** Aceptada
- **Fecha:** 2026-11-07
- **Alcance:** instalación inicial de CHROMAT Server en un Ubuntu Server

## Contexto

La instalación inicial usa un único servidor, backups manuales y sin alta
disponibilidad. Se necesita detectar fallos, conservar eventos durante
interrupciones y poder restaurar el servicio con objetivos explícitos.

## Decisión

### Observabilidad

- Nginx, API, worker e inferencia escriben logs JSON por stdout/stderr, sin
  secretos, credenciales ni imágenes.
- Los logs operativos rotan explícitamente por `max-size` y `max-file` para
  cubrir aproximadamente 30 días. La auditoría de seguridad conserva 365 días.
- Se miden ingesta, códigos y latencia HTTP, profundidad/antigüedad de jobs,
  fallos/reintentos, CPU/RAM/disco, volúmenes, último backup y expiración TLS.
- Health checks separan liveness y readiness. El endpoint público solo indica
  `ok` o `not ready`; el detalle de dependencias es interno o requiere
  credencial de operador.
- Si se adopta una pila de métricas, permanecerá en la red interna y no se
  publicará por Nginx. La herramienta se elige durante la implementación.
- Un heartbeat externo detecta que el servidor completo no responde. Las
  alertas por Telegram dependen de Internet y el token del bot es un secreto
  de archivo.

### Recuperación y capacidad

- Objetivos iniciales: RPO de 24 horas y RTO de 4 horas.
- La fuente conserva cada evento al menos 48 horas después de recibir `202`
  (configurable y siempre superior al RPO). Tras una restauración reenvía los
  eventos posteriores al backup; la idempotencia evita duplicados.
- Al acercarse a capacidad, la ingesta se pausa antes de agotar el disco y la
  API responde `503 Retry-After`. Se reanuda tras intervención del operador.
- Umbrales iniciales configurables: 20%/10% de espacio libre, 15 minutos/1
  hora de antigüedad de cola, CPU/RAM sostenidas de 85%/95% y TLS a 30 días.
- La VM usa NTP y los servicios arrancan automáticamente tras un reinicio.

### Backups y restauración

- Los backups incluyen dump de MariaDB, archivos y manifiestos de hashes,
  además de una copia cifrada fuera del servidor.
- `compose.yaml`, configuración de Nginx y secretos de servicio se respaldan
  por separado y cifrados. La clave de la CA permanece fuera del servidor.
- Un operador ejecuta backups, restauraciones, rotación TLS, retención y
  recuperación mediante runbooks versionados y auditados.
- Se realiza una restauración aislada al menos trimestralmente, después de
  cambios importantes y antes de la entrega del proyecto, con evidencia
  documentada.

## Consecuencias

- La recuperación depende de que la fuente conserve y reenvíe eventos durante
  la ventana definida.
- Telegram no es un canal de alerta garantizado cuando el servidor o Internet
  están caídos; el heartbeat externo cubre la indisponibilidad total.
- Los umbrales iniciales requieren ajuste con mediciones reales.

## Fuera de alcance

La herramienta concreta de métricas, el autoescalado, el failover automático y
la alta disponibilidad quedan fuera de esta instalación.
