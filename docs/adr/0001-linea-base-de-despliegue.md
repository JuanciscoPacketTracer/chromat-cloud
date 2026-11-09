# ADR-0001: Línea base inicial de despliegue

- **Estado:** Aceptada
- **Fecha:** 2026-11-07
- **Alcance:** servidor x86_64 (amd64)

## Contexto

CHROMAT necesita una plataforma reproducible para ejecutar Nginx, la API, el
servicio de inferencia y MariaDB en contenedores. La línea base debe cubrir el
sistema operativo, el runtime de contenedores, la orquestación y las versiones
principales de los servicios.

## Decisión

Se adopta la siguiente línea base inicial:

| Capa | Decisión |
|---|---|
| Sistema operativo | Ubuntu Server 26.04 LTS, 64 bits |
| Contenedores | Docker Engine desde el repositorio oficial de apt de Docker |
| Orquestación | Plugin Docker Compose (`docker-compose-plugin`) |
| API | Node.js 26 LTS, con etiqueta de versión exacta |
| Inferencia | Python 3.13, con etiqueta de versión exacta |
| Base de datos | MariaDB 11.8, con etiqueta de versión exacta |
| Arquitectura | x86_64 (amd64) |

Python 3.14 se evaluará únicamente si las dependencias de inferencia son
compatibles; hasta entonces, Python 3.13 es la opción de la línea base.

Las imágenes de Node.js, Python y MariaDB deben fijarse con etiquetas de
parche explícitas o digests cuando se cree el archivo Compose. Solo Nginx
publicará puertos hacia el host; la API, la inferencia y MariaDB permanecerán
en la red interna de Compose.

## Justificación

- Ubuntu 26.04 LTS ofrece mantenimiento de seguridad hasta 2031 y es
  compatible con Docker Engine.
- Node.js, Python y MariaDB publican imágenes oficiales para amd64.
- El repositorio oficial de apt evita el script de conveniencia de Docker,
  destinado a pruebas y desarrollo.
- Las versiones exactas hacen reproducible el despliegue.

## Consecuencias

- La VM objetivo debe ser amd64; otras arquitecturas no forman parte de esta
  línea base.
- Los Dockerfiles y el archivo Compose deben conservar las etiquetas exactas
  definidas al implementar los servicios.
- La elección entre Python 3.13 y 3.14 queda condicionada a una prueba de
  dependencias de inferencia.

## Fuera de alcance

Esta decisión no fija el dimensionamiento definitivo de la VM, TLS, retención
de respaldos, observabilidad ni la política completa de actualizaciones. La
propuesta inicial de recursos es 4 vCPU, 8 GB de RAM y 60 a 80 GB de disco,
sujeta a mediciones.

## Referencia

La matriz de compatibilidad y sus fuentes están en
[`docs/research/wayfinder-deployment-baseline.md`](../research/wayfinder-deployment-baseline.md).
