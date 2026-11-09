# CHROMAT Server

Lenguaje compartido para el servidor que recibe datos de monitoreo desde módulos Raspberry, los conserva y ejecuta análisis sobre ellos.

## Fuentes y datos

**Fuente de monitoreo**:
Un módulo Raspberry autenticado que envía datos de monitoreo a CHROMAT Server.
_Evitar_: dispositivo, cliente, sensor, agente (cuando se refiera a la identidad del origen).

**Evento de monitoreo**:
Una observación enviada por una fuente de monitoreo, identificada de forma única y con el momento en que ocurrió y el momento en que fue recibida.
_Evitar_: registro, muestra, mensaje (cuando se refiera al dato de dominio).

**Dato crudo**:
La representación original de un evento de monitoreo, conservada sin ser reemplazada por resultados del análisis.
_Evitar_: dato sin procesar (como nombre canónico).

**Dato derivado**:
Un resultado producido al analizar uno o más datos crudos, asociado con la versión del análisis que lo generó.
_Evitar_: resultado, predicción (cuando se use de forma genérica).
