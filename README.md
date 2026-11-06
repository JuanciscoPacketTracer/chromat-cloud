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

## 3. Arquitectura

```
 Huerta                                  VM Ubuntu Server (Docker Compose)
┌───────────────┐   imágenes + datos   ┌───────────────────────────────────────────┐
│ Raspberry Pi  │ ───────────────────► │  Nginx (80/443)                           │
│ + cámara      │   HTTP en red local  │    ├─► Panel web                          │
│ (edge/)       │                      │    └─► API Node.js  ──► Inferencia Python │
└───────────────┘                      │              │                            │
                                       │              └──► MariaDB                 │
Productor ──── navegador ────────────► │  Alertas (correo / Telegram)              │
                                       └───────────────────────────────────────────┘
```

| Servicio | Tecnología | Función | Expuesto fuera de la VM |
|---|---|---|---|
| `nginx` | Nginx | Proxy inverso; entrega el panel y enruta `/api` | Sí (80/443) |
| `api` | Node.js | Recibe imágenes, guarda datos, llama a la inferencia, genera alertas | No |
| `inference` | Python | Clasifica la madurez (reglas de color HSV y red neuronal CNN) | No |
| `db` | MariaDB | Resultados, metadatos y lecturas de temperatura y humedad | No |
| `web` | HTML/JS | Panel para consultar estado e historial | Vía Nginx |

**Decisión de seguridad:** solo Nginx publica puertos. La API, la inferencia y la base de datos se comunican por la red interna de Docker Compose.

**Decisión de diseño:** la API se publica bajo `/api/v1/...` para que la futura app móvil use los mismos endpoints que el panel web.

## 4. Flujo de datos

1. La Raspberry Pi captura una imagen y lee temperatura y humedad.
2. Envía la imagen y los datos a `POST /api/v1/images`. Si no hay red, los guarda localmente y los reenvía después.
3. La API guarda la imagen en disco y sus metadatos en MariaDB.
4. La API pide la clasificación al servicio de inferencia y guarda la etapa de maduración resultante.
5. Si la etapa corresponde a "maduro", se genera una alerta.
6. El productor ve el estado y el historial en el panel web.

## 5. Estructura de archivos y carpetas

```
chromat server/
├── README.md                  # Este documento
├── docker-compose.yml         # Orquesta todos los servicios
├── .env.example               # Plantilla de variables de entorno (sin secretos)
├── .gitignoresdddc
├── docs/                      # Documentación
│   ├── etapa-1-preparar-servidor.md
│   └── diagramas/             # Arquitectura, UML, despliegue (para el Capítulo IV)
│
├── nginx/                     # Proxy inverso
│   └── conf.d/                # default.conf
│
├── api/                       # Servidor Node.js
│   ├── Dockerfile
│   ├── package.json
│   ├── src/
│   │   ├── index.js           # Punto de entrada
│   │   ├── config/            # Variables de entorno y configuración
│   │   ├── routes/            # /api/v1/images, /readings, /health
│   │   ├── controllers/       # Lógica de cada endpoint
│   │   ├── services/          # Cliente de inferencia, alertas
│   │   ├── middlewares/       # Autenticación por clave, subida de archivos
│   │   └── db/                # Conexión y consultas a MariaDB
│   └── tests/
│
├── inference/                 # Servicio de clasificación (Python)
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── app/                   # Servicio web y clasificadores (HSV, CNN)
│   └── models/                # Modelo CNN ya entrenado (no se sube a Git)
│
├── db/
│   └── init/                  # Scripts SQL de inicialización (esquema)
│
├── web/                       # Panel web
│   └── public/
│
├── edge/                      # Código de la Raspberry Pi
│   └── systemd/               # Servicio para que la captura arranque sola
│
├── scripts/                   # Respaldos, restauración y verificación de salud
│
├── uploads/                   # Imágenes recibidas (volumen, no se sube a Git)
└── backups/                   # Respaldos de la base de datos (no se sube a Git)
```

> Más adelante se puede agregar una carpeta `mobile/` para la aplicación móvil.

## 6. Plan de trabajo

| Etapa | Contenido | Estado |
|---|---|---|
| 1 | Preparar el servidor: requisitos, instalación base, red, seguridad y Docker ([guía](docs/etapa-1-preparar-servidor.md)) | En curso |
| 2 | Esqueleto de servicios con `docker-compose.yml` (Nginx, API, inferencia, MariaDB) | Pendiente |
| 3 | API y base de datos: subida de imágenes, esquema de tablas, pruebas con la Raspberry Pi | Pendiente |
| 4 | Inferencia: clasificador HSV y luego modelo CNN | Pendiente |
| 5 | Panel web y alertas | Pendiente |
| 6 | Operación: respaldos, monitoreo, pruebas de carga y documentación | Pendiente |

## 7. Convenciones

- **Secretos:** contraseñas y claves van en `.env`, que nunca se sube a Git. Solo se versiona `.env.example`.
- **API:** rutas versionadas (`/api/v1/...`), respuestas en JSON, errores con código HTTP adecuado.
- **Commits:** mensajes cortos en español, en infinitivo (por ejemplo, `Agregar endpoint de subida de imágenes`).
- **Datos:** `uploads/`, `backups/` y los modelos entrenados quedan fuera de Git.

## 8. Relación con el proyecto de investigación

Esta implementación alimenta el **Capítulo IV (Desarrollo del proyecto)**: arquitectura, diagramas de despliegue, base de datos, interfaces y pruebas. También aporta datos para el **Capítulo V (Resultados)**, como tiempo de respuesta del servidor, costo del nodo de captura y desempeño de los clasificadores.

## 9. Autor

Juan Francisco Hernández Camacho · Matrícula 23060120
Asesor: Abel Ignacio Elizalde Gaxiola
Universidad Autónoma de Occidente, Unidad Regional Guamúchil
