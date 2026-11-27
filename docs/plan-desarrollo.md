# Plan de desarrollo funcional de CHROMAT

Fecha de referencia: 26 de noviembre de 2026. Este plan orienta el trabajo
posterior; no certifica que las tareas pendientes estén implementadas. Contrasta
el código y los issues vigentes antes de iniciar cada etapa.

## Objetivo y límites

Demostrar el recorrido de una fotografía de fruto: una Fuente de monitoreo
Raspberry Pi captura y envía la imagen por HTTPS; el servidor la conserva y
procesa; el productor consulta el estado y el historial de sus fuentes; y una
transición elegible puede generar una alerta. La clasificación es apoyo a la
decisión del productor, no una indicación autónoma de cosecha.

El primer cultivo y sus etapas deben acordarse con el equipo y fundamentarse en
datos etiquetados; mango y calabacita son ejemplos del README, no evidencia de
que ambos ya estén cubiertos. La encuesta, su análisis estadístico y la app
móvil quedan fuera. El entrenamiento ocurre en otro entorno; este repositorio
integra y evalúa la inferencia. Backups, restauración, rollback, distribución
offline y automatización de releases siguen aplazados. Telegram es opcional.
Se mantienen autenticación, TLS, persistencia, controles de capacidad y pruebas
proporcionadas al cambio. El prototipo no es una instalación productiva validada.

## Punto de partida

| Área | Lo que existe | Brecha |
| --- | --- | --- |
| Ingesta y worker | API, persistencia, trabajos asíncronos, autenticación e historial de ejecuciones. | Demostrar una imagen real en el flujo completo; no confundir un smoke sintético con validación en campo. |
| Panel | [Panel estático](../web/public/) con acceso de operador/productor, fuentes, eventos, estado e historial. | Mejorar el recorrido, visibilidad de resultados y estados, accesibilidad y validación con usuarios. |
| HSV | [Heurística](../api/src/hsv.js) del color promedio de toda la imagen; las pruebas incluyen colores sintéticos. | Fondo, iluminación y otros factores pueden dominar el promedio. La confianza es heurística, no probabilidad calibrada. Falta validación con frutos reales. |
| Red neuronal | [Servicio](../inference/server.py) con contrato, versión y hash de modelo. | La clasificación actual se deriva de un hash: **no es una CNN entrenada** y su confianza no es científica. |
| Alertas | Agregación, alertas y worker Telegram implementados; este último es opcional. | Validar reglas con datos adecuados, experiencia y entrega real independientemente. |
| Raspberry Pi | Existe el contrato de ingesta; el cliente de captura no está implementado. | Falta integración con cámara, envío, recuperación de conexión y prueba en hardware. |

El worker ejecuta actualmente HSV y el servicio de inferencia en cada trabajo;
si uno falla, el trabajo no se completa. El algoritmo oficial se configura con
`OFFICIAL_ALGORITHM`. Una clasificación del simulador o una confianza heurística
no deben presentarse como resultado científicamente validado ni usarse para
aconsejar cosechas. Revisar esta dependencia antes de cambiar el comportamiento.

Instalación, HTTPS, reinicio y actualización se comprobaron en una VM de
laboratorio; no equivalen a validar el recorrido funcional ni el uso en campo.
La guía vigente es [Git + Docker Compose](installation/git-compose.md) y la
decisión de alcance es [ADR-0010](adr/0010-desarrollo-y-despliegue-desde-git.md).

## Forma de trabajar

1. Trabajar en Fedora y probar antes de publicar; la VM se actualiza desde Git
   y Compose. Mantener el árbol y los cambios ajenos intactos.
2. Cada etapa es un conjunto de resultados, no una orden de implementar todo
   en una sola sesión. Revisar issues existentes antes de crear duplicados.
3. Antes de delegar una tarea, confirmar sus dependencias y decisiones. El
   agente debe informar archivos, pruebas, resultados y límites; no declarar
   superada una prueba de hardware o de terceros sin haberla ejecutado.
4. Conservar Datos crudos, trazabilidad de versiones y aislamiento por fuente.
   Las migraciones son forward-only. No publicar imágenes, datos de
   investigación, credenciales ni claves sin autorización.
5. Para contratos y términos, consultar [glosario](../GLOSSARY.md),
   [eventos](adr/0003-contrato-de-eventos-de-monitoreo.md),
   [procesamiento](adr/0004-procesamiento-asincrono-y-versionado.md),
   [autorización](adr/0006-autenticacion-autorizacion-y-exposicion.md) y
   [alertas](adr/0009-reglas-y-entrega-de-alertas-al-productor.md). Si una
   mejora exige cambiar una decisión, acordarla y actualizar su documentación.

## Secuencia y dependencias

| Etapa | Propósito | Requisito para completarla |
| --- | --- | --- |
| 1 | Recorrido inicial con fotografía real y diagnóstico del panel. | Fuente y fotografía de prueba autorizadas; resultados observables sin afirmar precisión. |
| 2 | Panel útil para consultar los resultados. | Contratos y necesidades identificados en la etapa 1. |
| 3 | Clasificación HSV evaluable. | Etiquetas, cultivo, particiones y criterio de evaluación acordados; usar los hallazgos de la etapa 1. |
| 4 | Integración de red neuronal real. | Artefacto entrenado y contrato de preprocesamiento y clases disponibles; evaluación independiente acordada. |
| 5 | Alertas comprensibles y verificadas. | Etapas y reglas acordadas; entrega real solo después de disponer de Telegram de prueba. |
| 6 | Captura y envío Raspberry Pi. | Contrato del servidor y acceso al hardware definidos; prueba final con cámara y red reales. |
| 7 | Demostración integrada. | Etapas necesarias para el escenario acordado terminadas y verificadas. |

Las etapas 2, 3 y el trabajo preparatorio de 4–6 pueden dividirse y avanzar
independientemente cuando sus entradas estén disponibles. No inventar un modelo,
dataset, umbral de calidad, cámara o canal para desbloquearlas. Una demostración
inicial puede usar HSV experimental y el simulador identificado; la evaluación
de una red real requiere su propio artefacto y datos.

## 1. Fotografía real: primera vertical

**Alcance.** Preparar una prueba controlada con una fuente y una fotografía
JPEG/PNG autorizadas, sin esperar al hardware Raspberry. Enviar por la API
existente, observar el procesamiento y consultar el evento desde el panel.
Registrar qué información se puede ver y qué pasos requieren operación manual.
Usar fuente de prueba y evitar notificaciones externas durante el ensayo.

**Contexto.** [ADR-0003](adr/0003-contrato-de-eventos-de-monitoreo.md) define
multipart, identidad, reintentos y respuesta; [smoke de procesamiento](../tests/smoke/processing.sh)
usa una imagen sintética y sirve de referencia técnica, no de validación real.
La visualización de la fotografía en el panel y sus permisos requieren revisar
la API existente: no asumir que ya existe para todos los roles.

**Terminado cuando:** una imagen real autorizada llega y produce un evento
identificable, el procesamiento final o su fallo es visible, el resultado
oficial y sus límites se explican en la evidencia, y se documentan los pasos y
brechas del panel. Repetir el envío con el mismo evento y verificar idempotencia
sin generar otro evento; no evaluar la exactitud científica en esta etapa.

## 2. Panel web

**Alcance.** A partir de la prueba anterior, priorizar una consulta clara de
fuentes, eventos, resultado oficial, estado agregado e historial; distinguir
pendiente, procesando, fallo y ausencia de datos. Mostrar algoritmo y versión
cuando estén disponibles, e identificar explícitamente resultados experimentales.
Diseñar para móvil y escritorio, con navegación por teclado y mensajes accesibles.
La visualización de imágenes o comparaciones entre algoritmos requiere revisar
necesidad, datos y autorización antes de ampliar API o interfaz.

**Contexto.** [Interfaz](../web/public/index.html),
[lógica del panel](../web/public/app.js) y
[API](../api/src/server.js). El productor es de solo lectura y solo debe ver
fuentes asignadas; el acceso a imágenes crudas está restringido al operador por
[ADR-0006](adr/0006-autenticacion-autorizacion-y-exposicion.md). No exponer
archivos por rutas públicas ni debilitar controles para facilitar la interfaz.

**Terminado cuando:** el recorrido acordado funciona para ambos roles, incluidos
vacío, carga, error y sesión vencida; se prueban permisos cruzados y la vista
en escritorio/móvil con teclado; un usuario puede localizar el evento y entender
si el resultado es experimental. Registrar qué pruebas fueron automatizadas y
cuáles requirieron revisión humana.

## 3. Clasificación HSV

**Alcance.** Establecer primero una línea base reproducible sobre imágenes reales
etiquetadas; después evaluar mejoras de segmentación o reglas solo si los datos
las justifican. Acordar cultivo, etapas, manejo de imágenes dudosas, condiciones
de captura y versión de reglas. Conservar el resultado y versión previos para
comparar; no ajustar y evaluar con las mismas imágenes.

**Contexto.** [Implementación](../api/src/hsv.js),
[pruebas](../api/test/hsv.test.js) y
[worker](../api/src/worker.js). Las clases actuales incluyen `verde`,
`maduro`, `otro` y `uncertain`; no asumir que cubren la taxonomía acordada.
La agregación utiliza un umbral de confianza: cambiar su significado puede
afectar estados y alertas.

**Terminado cuando:** existe un protocolo documentado de etiquetas y
particiones sin filtraciones entre entrenamiento/ajuste y evaluación, un conjunto
de evaluación autorizado y una línea base reproducible. Reportar cantidad por
clase, matriz de confusión y métricas por clase, casos inciertos y limitaciones
de iluminación/fondo; si se mejora la regla, comparar en la misma partición y
versionarla. Los umbrales de aceptación y el tamaño suficiente del conjunto
deben acordarse con el equipo antes de declarar calidad de clasificación.

## 4. Inferencia con red neuronal

**Entradas humanas necesarias.** Modelo entrenado en un entorno externo;
formato, licencia y procedencia; clases y su orden; tamaño, normalización y
preprocesamiento; versión y hash; datos de evaluación independientes y criterio
de aceptación. Registrar limitaciones del dataset y permiso de uso. Si faltan,
documentar el bloqueo y mantener identificado el simulador.

**Alcance.** Integrar el artefacto en [inference/](../inference/), verificar
integridad y versión, y adaptar el contrato y Compose si hace falta. Mantener
identidad de entrada, trazabilidad y manejo explícito de modelo inválido o
indisponible. Decidir con el equipo si el simulador se conserva como modo de
pruebas; nunca presentarlo como modelo real ni activar CNN como algoritmo
oficial sin validación y decisión explícita.

**Terminado cuando:** pruebas deterministas verifican preprocesamiento, mapeo de
clases, resultado, hash/versión y fallos; una integración real procesa imágenes
autorizadas en CPU y conserva la procedencia hasta el resultado consultado.
Medir latencia y recursos del entorno objetivo. Evaluar sobre datos separados,
reportar métricas por clase y limitaciones, y comparar con HSV en el mismo
conjunto cuando ambos cubran las mismas clases. La integración técnica no
demuestra por sí sola precisión ni utilidad agrícola.

## 5. Alertas

**Alcance.** Validar el flujo de estado agregado y transición a `maduro` según
[ADR-0009](adr/0009-reglas-y-entrega-de-alertas-al-productor.md), con umbral,
consecutividad y tiempos acordados según la fiabilidad del clasificador.
La alerta interna y el resto del servidor deben funcionar sin Telegram. Si se
elige Telegram, validar también configuración, entrega y fallos sin exponer
tokens ni enviar mensajes a productores sin permiso.

**Contexto.** [Agregación](../api/src/aggregation.js),
[alertas](../api/src/alerts.js), [worker Telegram](../api/src/telegram-worker.js),
pruebas en [api/test/](../api/test/) y seguimiento #23. La confianza HSV y la
del simulador no justifican por sí solas un umbral agrícola.

**Terminado cuando:** pruebas cubren transición elegible, consecutividad,
deduplicación, orden temporal, reloj sospechoso, reprocesamiento y ausencia de
alertas para fuente de prueba. Para Telegram, probar éxito, errores, reintentos
y reemisión con doble; documentar por separado una prueba real autorizada o
dejarla pendiente. No presentar una alerta experimental como recomendación de
cosecha validada.

## 6. Módulo Raspberry Pi

**Entradas humanas necesarias.** Modelo de Raspberry Pi, sistema operativo,
cámara y disponibilidad de sensores de temperatura/humedad, energía y
conectividad; acordar frecuencia de captura, límites de almacenamiento, política
cuando se llena y cuándo borrar datos locales. Confirmar primero una fuente y
credencial de prueba y cómo confiar en la CA de laboratorio.

**Alcance.** Cliente sencillo y documentado en este repositorio que capture una
imagen y la envíe por HTTPS. Respetar [ADR-0003](adr/0003-contrato-de-eventos-de-monitoreo.md):
UUID y fotografía se conservan idénticos entre reintentos, `source_id` procede
de la credencial y las mediciones son opcionales. Mantener credenciales fuera
de Git, validar TLS y sincronizar el reloj. Definir recuperación tras reinicio,
caídas de red, `401`/`403`, `409` y `503`; no borrar un evento ante fallo o
respuesta ambigua. El límite de cola y su comportamiento requieren decisión
antes de implementar, no una suposición silenciosa.

**Terminado cuando:** pruebas sin hardware cubren captura simulada, envío,
idempotencia, reinicio, errores y recuperación sin pérdida silenciosa; una
prueba en la Pi real captura y entrega una fotografía, comprueba recuperación
tras pérdida de conectividad y verifica el resultado en el panel. Registrar
modelo, SO, cámara y condiciones probadas sin publicar credenciales ni fotos
privadas. Si no hay hardware, cerrar solo la parte simulada e indicar el bloqueo.

## 7. Demostración y evidencia

En un entorno de laboratorio acordado, verificar la secuencia completa: captura
real → envío autenticado → persistencia → procesamiento → consulta en panel →
transición/alerta cuando corresponda. Comprobar también fallo de conexión y
reintento sin duplicados. Registrar qué algoritmo y versión estaban activos,
qué partes eran simuladas, datos y condiciones de captura, resultados, tiempos
y fallos. Si se prueba Telegram real, documentarlo por separado. Los resultados
del prototipo no sustituyen una validación agrícola ni garantizan recuperación
ante pérdida de disco.

## Seguimiento y primer encargo

Los issues abiertos #20, #23, #24, #25, #36 y #39 están marcados para revisión,
no como especificaciones listas para ejecutar. Revisar si ya se implementaron,
si aún corresponden al alcance o si deben dividirse; no reabrir el trabajo
offline o de recuperación como requisito de estas etapas.

Una vez disponibles una fotografía autorizada y una fuente de prueba, el primer
encargo para un agente es:

> Lee `docs/plan-desarrollo.md`, el README y ADR-0003/0006/0010. Realiza la
> etapa 1 en un entorno aislado o de laboratorio autorizado: envía una
> fotografía real a una fuente de prueba, verifica idempotencia y sigue el
> evento hasta procesamiento y panel sin enviar alertas externas. Informa
> comandos seguros, evidencia sin secretos ni imágenes privadas, límites del
> simulador y brechas concretas. No cambies algoritmos ni despliegue; si falta
> fotografía, acceso o configuración, indica el bloqueo antes de continuar.

Los encargos posteriores se redactarán cuando se cumplan sus requisitos y se
conozcan los hallazgos de esta primera vertical.
