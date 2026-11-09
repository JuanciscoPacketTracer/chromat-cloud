# ADR-0008: Publicación y despliegue reproducible

- **Estado:** Aceptada
- **Fecha:** 2026-11-07
- **Alcance:** promoción desde desarrollo local hasta Ubuntu Server

## Contexto

CHROMAT debe ejecutarse en local y en un único Ubuntu Server con la misma
topología, sin depender inicialmente de CI/CD, un registro privado o
despliegue remoto automático. Las migraciones, secretos, modelos y backups
deben quedar identificados y verificables.

## Decisión

### Artefactos y entornos

- Las imágenes se construyen y prueban con el Compose canónico usando
  `--platform linux/amd64`.
- Se transportan inicialmente mediante `docker save`/`docker load` con
  checksum, incluidas las imágenes de terceros. En producción se usa
  `pull_policy: never`.
- El archivo del modelo es un artefacto separado, con checksum y montaje de
  solo lectura.
- Un manifiesto de solo lectura registra ID de imágenes construidas, digests
  de imágenes base, `model_sha256`, commit del Compose, versión de Ubuntu,
  versión de Docker, versión de migración, hash de configuración no secreta,
  fecha y operador.
- `.env.example` se versiona sin secretos. Cada entorno usa configuración
  parametrizada y secretos de archivo fuera de Git; producción no monta código
  fuente.

### Publicación

Antes de modificar la base, el runbook adquiere un lock, verifica espacio,
artefactos, secretos, TLS, permisos y huellas, genera el backup y valida su
checksum y lectura. La clave de la CA nunca entra a la VM. Se acepta que un
checksum por sí solo no garantiza autenticidad frente a manipulación.

El orden es:

1. Backup y validación.
2. Migraciones forward-only explícitas.
3. Arranque o recreación de servicios.
4. Readiness y smoke tests completos.
5. Apertura del tráfico y declaración de éxito.

Durante la ventana Nginx responde `503 Retry-After` a fuentes reales. Los smoke
tests usan una Fuente de monitoreo dedicada, con credencial propia y acceso
interno; sus eventos no generan alertas, no aparecen en el panel ni entran al
conjunto de datos de investigación, y se limpian al finalizar.

### Migraciones y rollback

- Cada migración declara las versiones de aplicación compatibles y debe ser
  compatible hacia atrás con la versión anterior mediante cambios aditivos.
- Los cambios destructivos se difieren a un despliegue posterior.
- Un fallo aborta cerrado y conserva logs, manifiesto, backup y evidencia.
- El rollback de aplicación solo procede dentro del rango de compatibilidad
  declarado. Si la base cambió de forma incompatible, se requiere restauración
  validada; no se ejecutan down-migrations automáticas.

## Consecuencias

- El despliegue depende de un procedimiento manual serializado y de artefactos
  locales verificables.
- Las pruebas de humo no contaminan datos, alertas ni el conjunto de
  investigación.
- La compatibilidad hacia atrás exige despliegues adicionales para eliminar o
  transformar datos antiguos.

## Fuera de alcance

CI/CD, registro privado, despliegue remoto automático, autoescalado, failover y
autenticidad criptográfica de los checksums requieren decisiones posteriores.
