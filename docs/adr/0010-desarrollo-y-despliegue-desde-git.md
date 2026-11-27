# ADR-0010: Desarrollo y despliegue desde Git

- **Estado:** Aceptada
- **Fecha:** 2026-11-26

CHROMAT prioriza clasificación de imágenes, panel web y captura desde Raspberry
Pi. Se desarrolla en Fedora y se clona o actualiza desde Git en un servidor
Ubuntu amd64 con Docker Compose; las imágenes se construyen en cada host.
Se acepta depender de Internet durante la instalación y las construcciones
a cambio de evitar una cadena de distribución offline.

Esta decisión sustituye ADR-0008 como flujo principal. Aplaza los requisitos
de backups, restauración y objetivos RPO/RTO de ADR-0007; mantiene logs,
health checks, protección de capacidad, autenticación, TLS y persistencia.
Amplía el límite de ADR-0003 para incluir el futuro cliente de captura Raspberry
Pi en este repositorio. No afirma que ese cliente ya esté implementado.

Telegram se conserva como perfil opcional. Las migraciones siguen siendo
forward-only y se ejecutan al iniciar los servicios. Las actualizaciones pueden
interrumpir solicitudes: no se promete alta disponibilidad, rollback automático
ni recuperación de datos perdidos. El trabajo previo de artefactos, backups y
promoción se conserva como histórico, no como requisito de instalación.

La guía vigente es [Git + Docker Compose](../installation/git-compose.md).
Esta etapa es un prototipo de investigación; no debe utilizarse como única
copia de datos irremplazables ni confundirse con operación productiva validada.
