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

Prioridades actuales: **clasificación de imágenes, panel web y captura/envío
desde Raspberry Pi**. La API, la base de datos y los workers ya implementados
dan soporte a ese flujo. El cliente de captura Raspberry Pi todavía está pendiente.

El entrenamiento de la red neuronal se realiza en otro entorno, por ejemplo
Google Colab; aquí debe integrarse su inferencia real, aún pendiente. La encuesta
y su análisis estadístico quedan fuera de este repositorio.

Backups, restauración, rollback, paquetes offline y automatización de releases
quedan **aplazados**, no son requisitos para desarrollar ni instalar.
Telegram se conserva como opción, no como dependencia del flujo principal.

## 3. Arquitectura actual

```
 Huerta                                  Fedora / Ubuntu (Docker Compose)
┌───────────────┐   imágenes + datos   ┌───────────────────────────────────────────┐
│ Raspberry Pi  │ ───── HTTPS:443 ───► │  Nginx (443)                              │
│ + cámara      │                      │    ├─► Panel web                          │
│ (pendiente)   │                      │    └─► API Node.js  ──► Inferencia Python │
└───────────────┘                      │              │                            │
                                       │              └──► MariaDB                 │
Productor ──── navegador ────────────► │  Telegram (opcional)                       │
                                       └───────────────────────────────────────────┘
```

| Servicio | Tecnología | Función | Expuesto fuera de la VM |
|---|---|---|---|
| `nginx` | Nginx | TLS, panel y proxy `/api` | Sí, solo 443 |
| `api` | Node.js 26 | Ingesta, autenticación, panel y administración | No |
| `worker` | Node.js 26 | Jobs, inferencia, agregación y alertas | No |
| `telegram-worker` | Node.js 26 | Entrega Telegram, perfil opcional `telegram` | No |
| `inference` | Python 3.13 | Simulador de contrato CNN; modelo real pendiente | No |
| `db` | MariaDB 11.8 | Metadatos, jobs, Datos derivados y auditoría | No |

**Decisión de seguridad:** solo Nginx publica TCP/443. API, workers, inferencia y MariaDB permanecen en la red interna de Compose.

**Decisión de diseño:** la API recibe `POST /api/v1/events` como multipart JSON más JPEG/PNG. La identidad de la fuente se deriva de su API key.

## 4. Flujo de datos

1. La Raspberry Pi captura una imagen y lee temperatura y humedad.
2. Envía la imagen y los datos a `POST /api/v1/events`.
3. La API guarda el Evento de monitoreo, el Dato crudo y un único job antes de responder `202`.
4. El worker procesa el job, conserva ejecuciones versionadas y actualiza el Dato derivado oficial.
5. El estado agregado genera una alerta deduplicada al entrar en `maduro`;
   si se activa Telegram, su worker la entrega con leases y reintentos.
6. El productor consulta únicamente sus fuentes desde el panel de solo lectura.

## 5. Desarrollo y despliegue desde Git

El flujo principal es **editar y probar en Fedora → commit/push → clone/pull
en Ubuntu → construir y arrancar con Compose**. No requiere otra VM constructora
ni distribución offline.

Sigue la [guía de Git + Docker Compose](docs/installation/git-compose.md)
para la primera instalación, secretos, TLS y primer acceso al panel.
Con la configuración inicial preparada:

```bash
# Aplicar cambios locales en Fedora:
docker compose up -d --build --force-recreate --wait --wait-timeout 120

# Actualizar el checkout limpio de un servidor desde su upstream:
bash scripts/update.sh
```

Solo Nginx publica TCP/443. Se mantienen TLS, autenticación y volúmenes
persistentes. Los certificados generados por `scripts/dev-tls.sh` son para
desarrollo/laboratorio, no para un servidor público. Esta etapa es un prototipo:
sin backups no protege datos irremplazables frente a pérdida del disco.

## 6. Operación y validación

### Estado actual

| Parte | Estado |
|---|---|
| Ingesta, persistencia, jobs y autenticación | Implementados; comprobar el flujo completo en cada instalación. |
| HSV | Heurística sobre el color promedio de la imagen; falta validación con fotografías reales. |
| CNN | Simulador determinista basado en un hash, no una red entrenada ni una medida científica de confianza. |
| Panel web | Consulta de fuentes, resultado oficial, estado e historial para operador y productor; falta validar la experiencia con usuarios. |
| Raspberry Pi | Captura y envío pendientes de implementar y probar con hardware. |
| Telegram | Worker opcional; envío real requiere validación independiente. |
| Git + Compose en Ubuntu | Instalación, reinicio y actualización comprobados en una VM de laboratorio; no equivalen a validación productiva. |

El siguiente objetivo es demostrar una fotografía real desde Raspberry Pi,
su clasificación y su consulta en el panel. Después se medirá el desempeño
del modelo real. El entrenamiento no se sustituye con pruebas del simulador.
El [plan de desarrollo funcional](docs/plan-desarrollo.md) detalla las etapas,
sus dependencias y los criterios para validar cada módulo.

Las pruebas unitarias de la API se ejecutan desde `api/`:

```bash
cd api
npm test
```

El panel en `/panel/` ofrece consulta de solo lectura: selecciona una fuente
y actualiza la consulta para ver eventos y estado. El productor solo accede a
fuentes asignadas. La lista muestra hasta 100 eventos y el historial hasta 100
observaciones aceptadas; un estado agregado vacío no implica necesariamente que
no haya eventos. HSV es experimental y CNN es un simulador, no una red entrenada:
sus resultados no están validados y no son una recomendación de cosecha.
No se muestran imágenes crudas en el panel.

El harness aislado crea y elimina sus propios servicios y datos de prueba.
Requiere Docker, acceso a imágenes y capacidad para construir:

```bash
bash tests/smoke/isolated.sh
```

Para comprobar el actualizador y el Compose principal sin tocar servicios
existentes:

```bash
python3 -B tests/update.test.py
bash tests/git-compose.test.sh
```

La segunda prueba requiere Compose con soporte de `!reset` (2.24.4 o posterior).
Comprueba TLS, acceso al panel, cambios de IP de la API y persistencia al recrear
contenedores. La prueba de actualización usa Git real local y Docker simulado;
no demuestra instalación en Ubuntu ni desempeño del clasificador.

Las migraciones siguen siendo numeradas y forward-only; no hay deshacer
automático de cambios de esquema. La decisión de simplificación está en
[ADR-0010](docs/adr/0010-desarrollo-y-despliegue-desde-git.md).
Los scripts y documentos de artefactos, backups y promoción se conservan como
trabajo histórico, no como ruta obligatoria. Sus tickets antiguos no representan
el orden de trabajo actual.

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
