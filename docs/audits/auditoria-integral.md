# Auditoría integral de CHROMAT Server

- **Fecha:** 2026-11-16
- **Repositorio y rama auditados:** `JuanciscoPacketTracer/chromat-cloud`,
  `research/wayfinder-deployment-baseline`, `ec1f446`
- **Alcance:** solo lectura y pruebas aisladas. No se modificaron secretos,
  `.env`, certificados, volúmenes, servicios existentes, issues, releases ni
  configuración de GitHub.

## Conclusión ejecutiva

CHROMAT Server tiene una implementación local funcional y un artefacto amd64
íntegro. La API, el procesamiento asíncrono, las migraciones, la agregación,
la autenticación administrativa, la capacidad y la entrega simulada de
Telegram superaron una prueba E2E aislada. Sin embargo, no está preparado para
producción: no hay evidencia de una instalación completa en Ubuntu 26.04, de
restauración real de backups, de rollback operativo ni de una distribución
oficial mediante GitHub Releases. La etapa adecuada es **Alpha avanzada**;
el siguiente objetivo es **Beta** tras demostrar el runbook en infraestructura
limpia y publicar una release trazable.

Esta auditoría conserva el estado observado el `2026-11-16`. La implementación
posterior añadió un flujo explícito de empaquetado, verificación semántica y
Draft Release, pero las pruebas contractuales con Docker falso no equivalen a
validar la carga de imágenes reales ni una instalación en Ubuntu.

## Estado del proyecto

| Área | Estado | Evidencia |
|---|---|---|
| API, ingesta idempotente y autorización de fuente | **VALIDADA** | Smoke aislado: `ingestion`, `admin-auth` y `source-management` pasaron. |
| Autenticación administrativa, auditoría y reprocesamiento | **VALIDADA** | Smoke aislado y `api` unit tests; rutas y migración `014` presentes. |
| MariaDB y migraciones forward-only | **VALIDADA** | Smoke aislado inicializó una base limpia y confirmó migraciones `001`–`016`. |
| Worker, leases, reintentos e inferencia | **VALIDADA** | Smoke aislado completó `processing` e `inference`; el worker se interrumpe y recupera durante la prueba. |
| Agregación, historial y alertas | **VALIDADA** | Smoke aislado completó `aggregation`; 18 unit tests cubren regla, historial y supresión. |
| Telegram | **PARCIAL** | Entrega contra `telegram-stub` validada; no se envió un mensaje al servicio real. |
| Panel web y Nginx | **PARCIAL** | Nginx, TLS local y endpoints de salud participaron en el smoke; no hay prueba visual, de navegador ni de UX. |
| TLS productivo | **PARCIAL** | `tests/tls.test.sh` pasó y existe runbook de CA interna; no se instaló un certificado productivo en Ubuntu. |
| Retención y ciclo de vida | **PARCIAL** | Migraciones, script y contratos existen; no se ejecutó una retención sobre datos persistentes de producción. |
| Backups, restauración y retención de cadenas | **PARCIAL** | Contratos pasaron; `backup-integration` se omitió por falta de `sudo` no interactivo, sin restauración aislada real. |
| Artefacto, manifiesto y `PULL_POLICY=never` | **VALIDADA** para integridad; **PARCIAL** para operación | SHA-256, checksums internos y contrato del artefacto pasaron. El paquete contiene cuatro imágenes Compose y BusyBox en `auxiliary_images`; los contratos de identidad/validación semántica usan Docker falso. No se hizo `docker load` ni arranque con `PULL_POLICY=never` en Ubuntu. |
| Instalación, actualización, promoción y rollback | **PARCIAL** | Contrato de promoción y recuperación de enlaces pasó; falta ejecución en host Ubuntu 26.04. |
| Persistencia y recuperación ante fallos | **PARCIAL** | El smoke valida recuperación del worker y el contrato valida enlaces; faltan reinicio del host, backup/restauración y rollback en una instalación real. |

### Arquitectura e implementación

`compose.yaml` define seis servicios: Nginx (único puerto público, 443), API
Node.js, worker, worker de Telegram, inferencia Python y MariaDB. API,
workers, inferencia y base de datos residen en la red interna; los datos
persisten en `chromat_db_data` y `chromat_raw_data`. Las migraciones
numeradas llegan hasta `016_job_event_uniqueness.sql`.

El flujo implementado es: ingesta multipart autenticada por API key, escritura
de evento/dato crudo/job, procesamiento con lease, inferencia HSV/CNN
determinista, dato derivado versionado, estado agregado e historial, alerta
deduplicada y entrega Telegram con lease y reintentos. También hay gestión de
fuentes, productor de solo lectura, métricas administrativas, pausa por
capacidad, retención, backups cifrados y runbooks de promoción.

El historial reciente concentra trabajo de despliegue entre `2026-11-09` y
`2026-11-16`: artefactos, TLS, backups, promoción, rollback y smoke aislado.
La rama auditada está en `ec1f446`; `main` local está atrasada respecto de su
remoto. El árbol no tenía cambios rastreados antes de crear este informe.

### Inconsistencias detectadas

1. `README.md` afirma que la suite API tiene 13 pruebas y que el E2E requiere
   una pila existente. La ejecución actual tuvo **18** pruebas unitarias y el
   harness `tests/smoke/isolated.sh` levantó y limpió una pila propia.
2. `README.md` aún presenta como pendiente la ruta Wayfinder #31–#35 aunque
   el repositorio ya contiene artefacto, scripts y contratos. La evidencia de
   Ubuntu real sí sigue pendiente.
3. **Hallazgo histórico resuelto documentalmente:** versiones anteriores de
   `docs/deployment/artifacts.md` y `docs/deployment/promotion.md` usaban
   `2026.11.12-1` y rutas de release hard-coded. El procedimiento actual usa
   `VERSION`, `ARTIFACT_ROOT`, `CHROMAT_ROOT`, `RELEASE_ROOT` y
   `EVIDENCE_ROOT`; esta auditoría conserva la discrepancia porque formó parte
   del estado auditado.
4. El manifiesto registra commit, imágenes, modelo, migraciones y herramientas,
   pero no registra si el árbol estaba limpio al empaquetar. El checksum
   detecta corrupción, no autentica al publicador.

## Pruebas ejecutadas

| Comando | Resultado |
|---|---|
| `cd api && npm test` | **PASS:** 18/18 pruebas. |
| `bash tests/smoke/isolated.sh` | **PASS:** levantó servicios y recursos exclusivos, ejecutó ingesta, procesamiento, inferencia, agregación, capacidad, autenticación, fuentes y Telegram simulado; eliminó sus contenedores, red y volúmenes. |
| `sha256sum --check dist/artifacts/chromat-2026.11.16-1.tar.gz.sha256` | **PASS.** Hash: `96cad7bf…ceaa4601`. |
| `sha256sum --check checksums.sha256` en el paquete | **PASS:** archivos, imágenes, modelo, scripts, tests y documentación. |
| `tests/artifacts.test.sh` | **PASS.** |
| `tests/tls.test.sh` | **PASS.** Incluye casos negativos esperados de SAN, EKU, expiración y material no permitido. |
| `tests/backup-contract.test.sh` | **PASS.** |
| `tests/backup-integration.test.sh` | **NO VALIDADA:** se omitió explícitamente porque el entorno no tiene `sudo` no interactivo para Docker. |
| `tests/promotion-contract.test.sh` | **PASS.** |
| `tests/ubuntu-production-host-contract.test.sh` | **PASS.** |
| `tests/image-artifacts.test.sh`, `tests/create-github-draft-release.test.sh` | **PASS contractual:** usan Docker falso para comprobar carga, ID, arquitectura, fallos y bloqueo del Draft; no validan una imagen real. |
| `tests/smoke/runner.test.sh`, `isolated.test.sh`, sintaxis Bash/Python y `docker compose config --quiet` | **PASS.** |

Las pruebas contractuales validan propiedades de scripts y documentación; no
sustituyen una promoción real, una restauración ni la comunicación con
Telegram. Falta añadir pruebas de navegador, recuperación tras reinicio de
host, carga/arranque del artefacto sin red, restauración verificable y una
prueba controlada de Telegram real.

## Artefacto e instalación Ubuntu 26.04

El paquete `dist/artifacts/chromat-2026.11.16-1.tar.gz` existe (253,310,173
bytes), su checksum externo e interno son correctos y
`scripts/verify-artifacts.sh` pasó. El manifiesto corresponde a `ec1f446`,
incluye cuatro imágenes Compose amd64, la imagen auxiliar
`busybox:1.36.1`, migración `016`, modelo con hash, `PULL_POLICY=never` y el
objetivo Ubuntu 26.04.

La identidad fijada de BusyBox distingue tres digest: el `index_digest`
multi-arquitectura
`sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662`,
el `platform_digest` `linux/amd64`
`sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f` y
el `config_digest`/Docker Image ID
`sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d`.
El empaquetado descarga la referencia inmutable de plataforma, crea el alias
operativo `busybox:1.36.1` y exporta ese alias al TAR.

El gate actual de Draft Release exige, sobre el mismo directorio de paquete,
`verify-artifacts.sh` y `verify-image-artifacts.sh` antes de invocar GitHub
CLI. La segunda comprobación es offline: carga los TAR existentes, compara
IDs/config digest y arquitecturas, y no realiza pulls. La evidencia disponible
para este gate es contractual y usa Docker falso; no demuestra una validación
semántica con Docker real.

No se ejecutó la instalación solicitada en una VM nueva. El host de auditoría
es Fedora 44; hay `virsh` y soporte QEMU/KVM, pero no hay ISO de Ubuntu 26.04
local, `virt-install` no está disponible, `sudo -n` requiere contraseña y la
conexión operativa de libvirt agotó el tiempo de espera. No se usó ni modificó
ninguna VM de terceros. Por tanto, las siguientes comprobaciones permanecen
**NO VALIDADAS**: transferencia/descarga en Ubuntu, `docker load`, arranque
real con `PULL_POLICY=never`, persistencia tras reinicio, backup/restauración
aislada, TLS de producción, promoción, apertura de tráfico y rollback.

La validación pendiente debe usar una VM Ubuntu Server 26.04 amd64 nueva,
aislada y autorizada: verificar tarball, extraer, ejecutar
`verify-artifacts.sh`, preparar el host, custodiar secretos/TLS fuera del
paquete, cargar las cuatro imágenes Compose y BusyBox auxiliar, validar
`production.env`, mantener `PULL_POLICY=never`, ejecutar la promoción
canónica, smoke, backup y restauración en otro host aislado, reiniciar y hacer
rollback compatible.

## Issues abiertos

Hay **18 issues abiertos**, sin asignados ni hitos. Todos excepto #1 tienen
`ready-for-agent`; por ello las prioridades son inferidas según bloqueo de
producción. La evidencia de código no equivale por sí misma a cumplimiento de
todos los criterios de aceptación.

| Issue | Objetivo, estado real y prioridad |
|---|---|
| #1 | Mapa Fedora→Ubuntu recuperable. Paraguas de #31–#35; **máxima**. |
| #12 | PRD del servidor local. API, workers, DB y panel implementados; requiere revisión de sus 45 historias; **alta**. |
| #20 | Reprocesamiento auditable sin duplicar job ni alertar. Código/migración `014` y smoke relacionados; candidato a revisión de cierre; **media**. |
| #23 | Telegram con secretos externos, leases, reintentos y reemisión. Implementado y simulado, sin prueba real; **media**. |
| #24 | Retención con tombstones y límites 90/365 días. Script/migraciones presentes, sin operación real; **media**. |
| #25 | Observabilidad, salud y protección de capacidad. Implementado y smoke validado; **media**. |
| #26 | Backup/restauración verificables, RPO/RTO y cifrado. Contratos pasan, integración/restauración real pendiente; **alta**. |
| #27 | CA interna, SAN, permisos y renovación TLS. Contrato pasa, instalación Ubuntu pendiente; **alta**. |
| #28 | Despliegue reproducible con prechecks, smoke, restore y rollback. Se solapa con #31/#35 y sigue sin demo Ubuntu; **máxima**. |
| #31 | Artefacto amd64, manifiesto y `never`. Paquete real y verificable; falta evidencia en Ubuntu; **máxima**. |
| #32 | Provisionar/endurecer Ubuntu. Script y contrato presentes, sin host real; **alta**. |
| #33 | TLS de CA interna en Ubuntu. Bloqueado por #32 y evidencia de host; **alta**. |
| #34 | Backup cifrado/restauración aislada durante promoción. Bloqueado por #32; **alta**. |
| #35 | Secuencia backup→migraciones→readiness→smoke→apertura y rollback. Contrato pasa; bloqueado por #31–#34 y sin ejecución real; **máxima**. |
| #36 | PRD de agregación en fuentes de prueba sin alertas. Implementación visible; padre de #37–#39; **media**. |
| #37 | Harness Compose aislado. Implementado y ejecutado en esta auditoría; falta registrar evidencia/cierre; **media**. |
| #38 | Agregación de fuentes de prueba sin alertas. Unit y smoke la cubren; falta revisión formal; **media**. |
| #39 | Validar esa agregación en smoke aislado. Pasó una corrida; el criterio de dos corridas limpias no está evidenciado; **media**. |

Dependencias principales: #31 y #32 habilitan #33/#34; #31–#34 bloquean
#35; #20/#23–#27 aportan a #28; #37 y #38 habilitan #39. Hay solapamientos,
no duplicados exactos, entre #28/#31/#35, #26/#34, #27/#33 y el PRD #36 con
su rebanada #38. No se cerró ni modificó ningún issue.

## GitHub Releases

En el estado auditado no había tags, GitHub Releases, workflows de Actions ni
directorio `.github/`. El flujo actual sí dispone de
`scripts/package-artifacts.sh` y `scripts/create-github-draft-release.sh`;
esto no implica que se haya creado una release real. La autenticación de `gh`
disponible tiene scopes `repo` y `workflow`, y permiso `ADMIN` sobre el
repositorio, pero **no se hizo ninguna escritura**.

La publicación manual actual debe seguir este orden:

1. Definir `VERSION` y `ARTIFACT_ROOT`, construir el paquete y conservar la
   correspondencia entre el commit del manifest y el tag remoto.
2. Ejecutar la validación estática y la semántica sobre el mismo paquete.
   `create-github-draft-release.sh` vuelve a ejecutar ambas y aborta antes de
   GitHub CLI si cualquiera falla.
3. Crear el Draft Release con el TAR, su checksum y el manifest externo. El
   manifest debe conservar las cuatro imágenes Compose separadas de
   `auxiliary_images`, que contiene BusyBox y sus tres digest.
4. Descargar en Ubuntu la versión parametrizada, verificar el checksum,
   extraer y ejecutar el verificador interno antes de instalar.
5. Publicar el borrador solo tras la promoción real y su evidencia.

Un workflow de Actions podría adjuntar un artefacto ya construido, pero no
debe introducirse sin decisión explícita: CI/CD, registry y firma están fuera
del alcance documentado. Sin firma, el checksum adjunto al mismo release no
prueba autenticidad.

## Riesgos y plan priorizado

1. **Bloqueador de Beta:** provisionar una VM Ubuntu 26.04 amd64 limpia y un
   host aislado de restauración; ejecutar el runbook de #32–#35 con evidencia.
2. **Bloqueador de Beta:** ejecutar `backup-integration`, backup full,
   restauración aislada, reinicio y rollback; medir RPO/RTO frente a 24 h/4 h.
3. **Bloqueador histórico de distribución:** decidir tag/versionado y
   documentar descarga de Releases. La sustitución de ejemplos
   `2026.11.12-1` por variables ya fue aplicada; sigue pendiente publicar un
   Draft Release real tras la evidencia anterior.
4. **Antes de producción:** instalar TLS real, probar renovación, verificar
   firewall/apertura desde otro equipo y probar Telegram real con una cuenta
   de ensayo.
5. **Higiene de backlog:** contrastar criterios de #20, #23–#27 y #36–#39,
   adjuntar comandos/commits y cerrar o relacionar los cumplidos; añadir
   prioridades e hitos.
6. **Calidad adicional:** añadir pruebas de navegador, recuperación de host,
   compatibilidad de migraciones entre releases y trazabilidad del estado
   limpio del árbol dentro del manifiesto.

**Criterio para Beta:** una instalación limpia reproducible del artefacto en
Ubuntu 26.04, con las cuatro imágenes Compose y BusyBox auxiliar cargadas,
`PULL_POLICY=never`, smoke completo, TLS operativo, backup y restauración
aislada, reinicio, rollback compatible y Draft Release trazable que haya
pasado ambos verificadores. **Criterio para producción:** repetir esas
evidencias de manera operativa, resolver riesgos de
autenticidad/distribución y establecer responsables, monitoreo y retención
periódica de backups.
