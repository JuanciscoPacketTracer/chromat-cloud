# ADR-0004: Procesamiento asíncrono y versionado del análisis

- **Estado:** Aceptada
- **Fecha:** 2026-11-07
- **Alcance:** worker, MariaDB y ejecuciones de inferencia de CHROMAT Server

## Contexto

La ingesta debe responder después de persistir un Evento de monitoreo, sin
bloquearse durante la clasificación. El procesamiento necesita recuperarse de
fallos del worker, evitar duplicados y conservar la trazabilidad de las reglas
HSV y del modelo CNN usados en cada resultado.

## Decisión

### Cola y leases

- Cada evento crea exactamente una fila `jobs` en la misma transacción que la
  ingesta. MariaDB impone `UNIQUE (event_id)`.
- Los estados internos son `queued`, `leased`, `done` y `failed`; el estado
  público del evento permanece separado.
- Un job contiene intentos, disponibilidad, propietario y expiración de lease,
  último error y timestamps.
- El worker reclama con `FOR UPDATE SKIP LOCKED`, renueva mediante heartbeat y
  solo cierra un job si conserva `lease_owner`.
- Un lease vencido vuelve a `queued` mientras queden intentos; de lo contrario
  pasa a `failed`. Las comparaciones usan el reloj UTC de MariaDB.

### Reintentos y ejecuciones

- `max_attempts = 3` cuenta intentos totales. Las esperas son de 1 minuto antes
  del segundo intento y 5 minutos antes del tercero.
- Solo errores transitorios se reintentan; errores permanentes pasan a
  `failed`.
- Cada job ejecuta los algoritmos configurados, inicialmente reglas HSV y CNN,
  y registra una fila `analysis_runs` por algoritmo.
- Cada ejecución es inmutable y registra algoritmo, versión de algoritmo,
  versión del modelo, hash SHA-256 del archivo del modelo, tiempos, estado y
  resultado.
- `current_result` apunta a la ejecución exitosa del algoritmo configurado
  como oficial. Las ejecuciones no oficiales se conservan para comparación.

### Reprocesamiento y alertas

- El reprocesamiento es manual, autorizado y auditable. Reutiliza la fila
  `jobs`, la devuelve a `queued` con `attempts = 0` y registra quién, cuándo y
  por qué en una tabla de auditoría.
- Durante el reprocesamiento el evento queda `processing` y conserva su último
  `current_result`. Si falla, queda `failed` pero el resultado previo sigue
  disponible.
- Las alertas se deduplican por evento y tipo, y además por fuente, cultivo y
  cambio de etapa. Su entrega tiene estados independientes y no vuelve a
  ejecutar la clasificación.

## Consecuencias

- La cola no requiere un broker externo, pero depende de transacciones y
  leases correctos en MariaDB.
- El historial conserva resultados de HSV y CNN y permite comparar versiones
  sin perder el resultado oficial.
- El retraso máximo de reintentos automáticos queda acotado y visible.

## Fuera de alcance

La taxonomía completa de errores, las reglas de alertas al productor y los
detalles de entrega se definirán en sus decisiones y tickets correspondientes.
