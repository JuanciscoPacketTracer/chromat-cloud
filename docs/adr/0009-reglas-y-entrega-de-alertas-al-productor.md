# ADR-0009: Reglas y entrega de alertas al productor

- **Estado:** Aceptada
- **Fecha:** 2026-11-07
- **Alcance:** alertas de cambio de etapa para productores

## Contexto

Una clasificación individual no representa por sí sola un cambio fiable de
estado del cultivo. Las alertas deben tolerar ruido del análisis, eventos
fuera de orden, relojes sospechosos y fallos temporales de conectividad, sin
perder trazabilidad ni generar duplicados.

## Decisión

### Estado agregado y transición

- El estado se mantiene por `source_id` y `crop`, donde `crop` pertenece al
  contexto configurado de la Fuente de monitoreo y no es un valor libre del
  evento.
- Solo el `current_result` del algoritmo oficial puede proponer un cambio de
  etapa. El reprocesamiento nunca genera alertas al productor.
- Una nueva etapa debe superar un umbral de confianza configurable y
  mantenerse durante `N` eventos consecutivos antes de cambiar el estado
  agregado.
- Se aplica un intervalo mínimo configurable entre alertas del mismo cultivo.
- La primera regla habilitada alerta al entrar en `maduro`. Las reglas para
  otras transiciones, incluido `sobremaduro`, quedan para una decisión futura.
- Los eventos se ordenan por `occurred_at`. Los eventos con `clock_suspect` o
  más antiguos que el plazo configurable no cambian el estado ni generan
  alertas. No se emiten alertas retroactivas por transiciones ya superadas por
  eventos más recientes.

### Episodios y deduplicación

- Cada entrada del estado agregado a una etapa crea un `episode_seq`.
- La identidad lógica de una alerta es
  `(source_id, crop, to_stage, episode_seq)`.
- Una secuencia `maduro → otra etapa → maduro` crea un episodio nuevo. Repetir
  la misma clasificación o reprocesar un evento no crea otro.
- La Fuente de prueba de despliegue nunca genera alertas al productor.

### Canal y contenido

- El canal inicial es Telegram para productores, separado del chat operativo.
- El `chat_id` se configura por fuente y cultivo; el token del bot se conserva
  como secreto de archivo.
- La alerta incluye fuente, cultivo, evento de referencia, etapa anterior y
  nueva, timestamp y enlace HTTPS al panel. No adjunta imágenes ni embebe
  credenciales.
- El productor accede mediante un rol de solo lectura limitado a sus fuentes.

### Entrega y recuperación

- La entrega es al menos una vez y usa un lease para evitar envíos
  concurrentes.
- Los estados persistidos son `pending`, `sent` y `failed`.
- Se realizan hasta tres intentos totales. Se respetan los valores
  `retry_after` de Telegram; los errores permanentes, como chat inexistente o
  bot bloqueado, no se reintentan.
- Los fallos de conectividad quedan visibles para operación y pueden
  reemitirse manualmente o al recuperarse la red. La reemisión conserva la
  identidad y auditoría de la alerta, sin reclasificar ni duplicar.
- El correo queda fuera del canal inicial.

## Consecuencias

- El modelo de datos debe conservar el historial suficiente para calcular
  episodios, orden temporal y estado agregado por fuente/cultivo.
- La configuración de umbral, consecutividad, antigüedad máxima e intervalo
  mínimo debe ser auditable y versionada junto con la regla.
- Telegram es una dependencia externa de entrega, pero los fallos no afectan
  la persistencia del evento ni del análisis.
- El rol de productor requiere autorización por fuente antes de exponer el
  panel.

## Fuera de alcance

Correo, alertas de `sobremaduro` y otras reglas de transición requieren
decisiones posteriores.
