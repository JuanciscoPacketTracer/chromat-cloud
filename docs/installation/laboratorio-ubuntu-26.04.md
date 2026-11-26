# Registro del laboratorio de instalación

## Nota de publicación: registro anonimizado

Esta copia pública sustituye las identidades del host y de la cuenta SSH,
las rutas personales, los identificadores de logs, el UUID del disco, el
hash de la configuración local `fstab` y los prefijos de red por ejemplos
o marcadores. Las direcciones de
`192.0.2.0/24` y `198.51.100.0/24` son rangos de documentación, no direcciones
operativas. No copiar el UUID de ejemplo a `fstab` ni ejecutar los comandos
históricos sin adaptar las rutas, identidades y red al entorno propio.
Los nombres `servidor-ejemplo` y `usuario-vm` son ficticios; `$HOME` representa
el directorio personal del operador, no una ruta observada.

Se conservan las fechas, resultados históricos, hashes de código, baseline
y pins de imágenes. El original privado, la captura experimental y su
recibo permanecen intactos. Esta copia anonimizada no coincide con el hash
de la fuente del laboratorio incluida en aquella captura ni la sustituye.
Las afirmaciones de verificación siguientes pertenecen a las etapas
históricas indicadas; no son validaciones nuevas de Actions o de CHROMAT.

## Alcance y estado

- **Proyecto:** `JuanciscoPacketTracer/chromat-cloud`
- **Fecha de inicio:** 2026-11-18
- **Fase:** host Ubuntu preparado; instalación de CHROMAT pendiente.
- **Estado actual (2026-11-24, fecha local):** preparación verificada,
  Docker instalado y activo, dpkg sin pendientes, acceso por nueva conexión
  SSH confirmado, UFW y fstab sin cambios. Artefactos, secretos/TLS y despliegue
  siguen pendientes.
  La preparación del segundo disco pertenece a una sesión anterior.
- **Actualización (2026-11-25):** SSH y preparación parcialmente revalidados;
  prerrequisito 0 corregido localmente y tests pertinentes PASS. Los tests de
  empaquetado usan imágenes sintéticas y Docker/GitHub simulados. Revisión
  del resultado, constructor aislado y paquete desplegable siguen pendientes.

Este registro separa la evidencia **verificada en la VM**, la evidencia
**verificada mediante tests automatizados**, lo **inferido por inspección del
código** y lo **pendiente de validar**. Las horas exactas de cada operación
deberán añadirse al continuar el laboratorio.

Las secciones anteriores a **Reanudación: 2026-11-24** conservan la auditoría
inicial y su plan histórico. Sus bloqueos y resultados de tests no deben
interpretarse como comprobaciones repetidas en la sesión actual.

## Estado inicial del repositorio

### Verificado localmente

- Rama: `research/wayfinder-deployment-baseline`.
- Commit: `4f23638dd77fe23fc0788fdeea1f4e290bb37b63`
  (`chore: consolidate offline deployment and release validation`).
- Working tree limpio; no había cambios locales que proteger.
- Se auditaron la guía Ubuntu 26.04, requisitos, runbooks de artefactos,
  backups, promoción y TLS, Compose, scripts de `scripts/` y tests de
  contratos y smoke.
- No se observó una Release publicada utilizable con `gh release list`; la
  entrega de artefactos queda pendiente de confirmar al iniciar la etapa de
  promoción.

## Estado inicial de la VM

### Verificado en la VM mediante SSH de solo lectura

Comando de conexión usado:

```bash
ssh chromat-vm
```

Resultado observado:

| Elemento | Resultado |
| --- | --- |
| Hostname | `servidor-ejemplo` |
| Sistema | Ubuntu `26.04.1 LTS`, codename `resolute` |
| Kernel | `7.0.0-30-generic` |
| Arquitectura | `amd64` / `x86_64` |
| CPU | 4 vCPU |
| Memoria | 7.2 GiB; swap 4.0 GiB |
| Raíz | ext4, 69 GiB, 58 GiB libres |
| Disco | 80 GiB; `/dev/sda3` LVM; raíz en volumen de 70 GiB |
| Red escuchando | SSH TCP/22; no se observó TCP/443 ni TCP/2222 |
| Servicios CHROMAT | No instalados |
| Docker/Compose | No instalados |
| `age` | No instalado |
| Nginx/MariaDB | No instalados |
| UFW | Instalado, estado no consultable sin autenticación `sudo` no interactiva |
| `/srv/chromat` | Ausente |
| `/etc/chromat` | Ausente |
| `/var/lib/chromat` | Ausente |
| `/mnt/chromat-backups` | Ausente |

También se verificó que el volumen raíz está separado de `/boot` y que no
existe todavía un montaje externo para backups.

## Auditoría de implementación

### Inferido por inspección del código y documentación

- La producción usa seis servicios Compose: `db`, `api`, `worker`,
  `telegram-worker`, `inference` y `nginx`. Hay cuatro imágenes únicas de
  Compose; BusyBox es una imagen auxiliar de backup y no un servicio.
- `PULL_POLICY=never` es obligatorio en `production.env.example` y lo exige
  `verify-production-environment.sh`; producción no debe ejecutar `pull` ni
  `build`.
- `prepare-ubuntu-production-host.sh` instala o valida:
  `ca-certificates`, `curl`, `gnupg`, `openssl`, `python3`, `age`, `ufw`,
  `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin` y
  `docker-compose-plugin`. Añade la fuente y llave oficiales de Docker solo
  cuando Docker no existe y crea los directorios operativos con permisos
  restringidos.
- La release contiene Compose, migraciones SQL 001--016, modelo, configuración
  Nginx, cuatro imágenes de Compose y `images/busybox.tar`. El empaquetado y la
  validación semántica se realizan fuera de Ubuntu; Ubuntu solo descarga,
  verifica, carga y ejecuta.
- Los secretos obligatorios son `db_password`, `db_root_password`,
  `telegram_bot_token`, `operator_password` y el destinatario público de
  `age`. La identidad privada de `age` y la clave privada de la CA permanecen
  fuera de la VM productiva.
- TLS exige `ca.crt`, `server.crt` y `server.key`, SAN `chromat.lan` y la IP
  operativa, EKU `serverAuth`, coincidencia de clave y permisos
  `0644/0600`.
- MariaDB se inicializa mediante migraciones forward-only y los servicios
  API, worker y Telegram ejecutan migraciones al arrancar. La promoción
  consulta `schema_migrations` y ejecuta smoke tests antes de abrir 443.
- Los datos persistentes son los volúmenes Docker `chromat_db_data` y
  `chromat_raw_data`. El backup exige un filesystem no raíz, `age`, BusyBox
  `1.36.1` precargada y detiene temporalmente el worker.
- El restore implementado es una verificación de restauración aislada:
  descifra, importa en MariaDB sin red y compara migraciones, hashes y
  referencias de archivos. No es una restauración destructiva sobre la
  instancia productiva.
- La promoción protege SSH, activa UFW, bloquea temporalmente 443, arranca y
  verifica, y solo después solicita confirmaciones externas `BLOCKED` y
  `OPENED`. El rollback usa `.promotion-link-state` y
  `recover-release-links.sh`; no usa down-migrations ni elimina volúmenes.

## Validación automatizada realizada

### Verificado mediante tests automatizados

Se ejecutó:

```bash
for test in tests/*.test.sh; do bash "$test"; done
```

Resultado:

- Tests de contratos de artefactos, imágenes, release Draft, backups,
  promoción, TLS y preparación de Ubuntu: **PASS**.
- `tests/backup-integration.test.sh`: **SKIP**, porque el entorno local no
  dispone de Docker/sudo no interactivo para ejecutar la integración.
- No se ejecutó ningún test de smoke contra la VM; todavía no hay servicios.

## Riesgos y bloqueos identificados

1. No hay release publicada confirmada para descargar en Ubuntu.
2. No hay disco/filesystem externo montado para `BACKUP_EXTERNAL_DIR`; no se
   puede validar producción ni backups sin provisionarlo.
3. No se han entregado secretos, destinatario de `age` ni certificados TLS;
   la transferencia requerirá autorización explícita.
4. La prueba de Telegram requiere un stub o autorización específica; no se
   deben enviar mensajes reales.
5. El smoke completo necesita credenciales de operador, fuente de prueba,
   claves API y una CA confiable instalada en el cliente.
6. La promoción modifica UFW y publica HTTPS; requiere una segunda máquina o
   cliente de red para confirmar efectivamente `BLOCKED` y `OPENED`.
7. El tamaño definitivo de almacenamiento y el rendimiento de inferencia aún
   no están medidos.

## Próxima secuencia propuesta

1. Aprobar el plan y crear el snapshot indicado.
2. Preparar o confirmar el filesystem externo de backups, sin reutilizar la
   raíz.
3. Probar conectividad, DNS/hosts y cliente de administración desde Fedora.
4. Ejecutar el aprovisionador del host y verificar paquetes, Docker, UFW y
   directorios.
5. Provisionar secretos y TLS mediante transferencia autorizada.
6. Transferir y validar una release publicada; cargar las cinco imágenes y
   ejecutar el preflight con `PULL_POLICY=never`.
7. Ejecutar la promoción inicial cerrada, migraciones, salud, smoke y
   persistencia.
8. Ejecutar backup y verificación de restore aislado; documentar rollback sin
   tocar datos productivos.
9. Actualizar la guía con comandos y resultados reales, distinguiendo cada
   validación de lo pendiente.

## Reanudación: 2026-11-24

### Contexto recuperado y límites

- Se mantiene la rama `research/wayfinder-deployment-baseline` y el commit
  `4f23638dd77fe23fc0788fdeea1f4e290bb37b63`.
- Al iniciar esta sesión, el único cambio Git era este registro, existente
  como archivo **no rastreado**. No se cambió de rama ni se descartó contenido.
- El historial local de la sesión anterior contiene la decisión del usuario:
  «es el dispositivo correcto, al final me decidi por 40 gb, autorizo su uso».
  Esa sesión documentó el particionado, formato y montaje del segundo disco.
  Por tanto, la propuesta inicial de 10 GiB no describe el estado actual.
- Snapshot 3: confirmado por el usuario; no inspeccionado ni restaurado.
- En esta reanudación solo se consultó la VM por SSH. No se ejecutaron APT,
  instalaciones, cambios de firewall, particionado, formateo, montaje,
  modificación de `fstab`, transferencia de secretos ni despliegue.

### Evidencia actual obtenida por SSH

Comprobación remota fechada `2026-11-24T23:05:46Z`:

| Elemento | Resultado |
| --- | --- |
| Conexión | `ssh chromat-vm` funciona; alias anonimizado hacia `usuario-vm@192.0.2.10:22` |
| Identidad y sistema | `servidor-ejemplo`, Ubuntu 26.04.1 LTS, `x86_64` |
| Recursos | 4 vCPU, 7.2 GiB de RAM, 4.0 GiB de swap |
| Disco original | `/dev/sda`, 80 GiB; raíz LVM de 70 GiB |
| Raíz montada | ext4, 69 GiB reportados por `df`, 58 GiB disponibles; `MAJ:MIN 252:0` |
| Segundo disco | `/dev/sdb`, 40 GiB; partición `/dev/sdb1`, ext4 |
| Backups | `/mnt/chromat-backups`, 40 GiB reportados por `df`, 38 GiB disponibles; `MAJ:MIN 8:17` |
| Permisos del destino | `root:root`, `0700`; requiere ejecución privilegiada para acceder |
| Montaje persistente | Unidad systemd activa, generada desde `/etc/fstab`, con UUID coincidente |
| Paquetes consultados | Sin Docker Engine/Compose, containerd, age, Nginx ni MariaDB instalados según `dpkg-query`; sin sus ejecutables en el PATH consultado |
| Servicios consultados | Sin unidades cargadas de Docker, containerd, Nginx, MariaDB/MySQL o CHROMAT |
| TCP escuchando | SSH en 22; DNS local en 53; sin listener en 443 |
| UFW | Paquete instalado; estado y reglas no comprobados en esta sesión |
| Directorios de instalación | `/srv/chromat`, `/etc/chromat` y `/var/lib/chromat` ausentes |

Entrada existente en `/etc/fstab`, consultada sin modificarla:

```fstab
UUID=00000000-0000-4000-8000-000000000001 /mnt/chromat-backups ext4 defaults,nofail,x-systemd.device-timeout=30s 0 2
```

El UUID real, omitido en esta copia, coincidía con `/dev/sdb1`. Las fuentes,
los identificadores `MAJ:MIN` y los dispositivos de `stat` difieren de los de
`/`: se cumplen
los criterios de independencia de filesystem de
`scripts/lib/backup-config.sh`. No se ejecutó el preflight completo ni una
prueba de escritura, backup o restore. Se comprobó el montaje activo y su
configuración persistente, sin provocar otro reinicio.

### Comprobación reproducible de solo lectura

Desde Fedora, sin asumir que la VM está encendida o conserva su dirección:

```bash
git status --short --branch
git branch --show-current
git rev-parse HEAD
ssh -G chromat-vm | grep -E '^(hostname|user|port) '
ssh -o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 \
  -o StrictHostKeyChecking=yes -o UpdateHostKeys=no chromat-vm '
  date -u +%FT%TZ
  hostname
  cat /etc/os-release
  uname -m
  ip -br -4 address
  lsblk -e 7 -o NAME,PATH,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINTS
  findmnt -T / -o SOURCE,TARGET,FSTYPE,MAJ:MIN
  findmnt -T /mnt/chromat-backups -o SOURCE,TARGET,FSTYPE,MAJ:MIN,OPTIONS
  findmnt --fstab --evaluate --target /mnt/chromat-backups \
    -o SOURCE,TARGET,FSTYPE,OPTIONS
  df -hT / /mnt/chromat-backups
  stat -c "%n device=%d owner=%U:%G mode=%a" / /mnt/chromat-backups
  ss -ltn
'
```

No omitir la comprobación de la clave SSH ni borrar `known_hosts` ante un
error. Si no conecta, comprobar desde la consola de VMware el encendido,
el adaptador conectado y la IP mostrada por `ip -br -4 address` antes de
proponer cambios. No particionar basándose en el nombre `/dev/sdb`: aquí es
un resultado observado, no una identidad garantizada para otras instalaciones.

### Contraste con el checkout y pendientes

Se volvió a inspeccionar Compose: seis servicios (`db`, `api`, `worker`,
`telegram-worker`, `inference`, `nginx`), cuatro imágenes únicas y solo
Nginx publicando `443:443`. Los volúmenes mantienen los nombres
`chromat_db_data` y `chromat_raw_data`; existen las migraciones 001--016.
`backup.sh` requiere la imagen auxiliar `busybox:1.36.1`, no un servicio
adicional.

El empaquetador genera `production.env.example` con `PULL_POLICY=never`
y el preflight lo exige. El Compose del checkout conserva valores por
defecto de desarrollo y secciones `build`: no debe arrancarse directamente
como sustituto del procedimiento de release offline. No se construyeron ni
descargaron imágenes en la VM. Los secretos y TLS siguen pendientes de
provisión autorizada; la identidad privada de age y la clave privada de la
CA deben permanecer fuera de ella.

`BACKUP_ROOT` tiene como ruta prevista `/srv/chromat/backups`: el backup
prepara datos en la raíz antes de copiarlos al destino externo. Los 58 GiB
libres de raíz y los 38 GiB disponibles en backups son capacidad observada,
no una garantía de dimensionamiento ni de siete cadenas recuperables.
El segundo disco virtual no demuestra independencia del almacenamiento
físico del anfitrión; no se verificó la ubicación del VMDK ni su modalidad
de aprovisionamiento.

Siguiente etapa: solicitar autorización antes de aprovisionar paquetes o
crear configuración. La disponibilidad de una release publicada y de
secretos/TLS no se volvió a comprobar en esta etapa. No repetir la preparación
del disco ya montado.

## Propuesta de preparación de Ubuntu: pendiente de autorización

Inspección local fechada `2026-11-25T02:43:26Z` (2026-11-24 en la zona horaria
del laboratorio). **No se ejecutó esta etapa en Ubuntu.** Solo se modificó
este registro local; no hubo commits, push ni publicación de releases.

### Evidencia obtenida en esta etapa de planificación

| Comando o inspección en Fedora | Resultado |
| --- | --- |
| `git status --short --branch` y `git rev-parse HEAD` | Misma rama y commit; este registro sigue siendo el único archivo no rastreado |
| Lectura de `scripts/prepare-ubuntu-production-host.sh` | 133 líneas; alcance descrito abajo por inspección, no por ejecución |
| `git diff HEAD -- scripts/prepare-ubuntu-production-host.sh` | Sin cambios del aprovisionador respecto al commit fijado |
| `sha256sum scripts/prepare-ubuntu-production-host.sh` | `ecd2da00a004b4e0b2b0ca0c13f2d6dc11a0f4f786f38bc8fdf4e623c65ab73c` |
| `bash -n scripts/prepare-ubuntu-production-host.sh` | PASS de sintaxis local; no ejecuta el script |
| `bash tests/ubuntu-production-host-contract.test.sh` | `PASS: Ubuntu production host preparation contract`; comprueba texto y orden del script, no instalación real |
| `gh release list --repo JuanciscoPacketTracer/chromat-cloud --limit 5 --json tagName,isDraft,isPrerelease,publishedAt,name` | `[]`; ninguna release disponible para este flujo en la consulta |
| `command -v shellcheck` | No disponible; no se instaló |

Ante la consulta de procedencia, el usuario pidió comprobar dependencias y
procedencia, detallar efectos de paquetes/servicios/red y esperar
autorización explícita. **No autorizó la ejecución ni eligió todavía la
alternativa experimental.**

Errores de exploración local, sin efectos en Ubuntu: se solicitó un rango
261--540 de un script de 133 líneas y se consultaron los nombres inexistentes
`tests/prepare-ubuntu-production-host.test.sh` y
`docs/deployment/promocion.md`. Se corrigieron usando
`tests/ubuntu-production-host-contract.test.sh` y
`docs/deployment/promotion.md`. No son errores de aprovisionamiento.

### Alcance exacto del script propuesto

Ejecutar únicamente `scripts/prepare-ubuntu-production-host.sh` como root
**en Ubuntu**, nunca en Fedora. No acepta un modo dry-run.

**Dependencias de archivos:** es un script autónomo. No calcula rutas del
checkout, no carga helpers, `.env`, Compose, manifiestos ni otros scripts.
El único archivo que carga con `.` es `/etc/os-release`, del sistema Ubuntu.
Necesita Bash y utilidades del sistema (`uname`, `grep`, `readlink`, `install`,
`chmod`, herramientas APT/dpkg y `systemctl`). Instala curl y demás
dependencias antes de usarlas para configurar Docker. Copiar solo este script
es técnicamente suficiente para preparar el host, no para instalar CHROMAT.
`verify-artifacts.sh` no valida un script aislado: requiere el paquete
completo, manifiesto y checksums.

| Acción inferida del script | Cambios previstos |
| --- | --- |
| Comprobar plataforma | Exige root, `/etc/os-release`, Ubuntu 26.04 y `x86_64`; sale antes de APT si no coinciden |
| `apt-get update` | Actualiza índices APT incluso antes de comprobar conflictos de Docker |
| Comprobar Docker existente | Rechaza instalaciones parciales, paquetes incompatibles o archivos previos; no los elimina ni repara |
| `apt-get install --yes ca-certificates curl gnupg openssl python3 age ufw` | Instala o actualiza estos paquetes y las dependencias/recomendaciones que resuelva APT |
| Preparar fuente Docker si no está instalado | Crea `/etc/apt/keyrings` con `0755`, descarga `/etc/apt/keyrings/docker.asc` desde HTTPS oficial y le añade lectura para todos; crea `/etc/apt/sources.list.d/docker.list` |
| Segundo `apt-get update` e instalación Docker | Solicita `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` desde la fuente oficial |
| `systemctl enable --now docker` | Habilita inicio al arranque y arranca el daemon; los paquetes/servicios crean su estado y almacenamiento |
| Comprobación Docker | Consulta la versión del servidor y del plugin Compose; no ejecuta contenedores |
| `install -d` | Crea directorios y aplica sus modos, también a directorios que ya existan |

La fuente esperada en esta VM sería:

```text
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu resolute stable
```

Directorios operativos previstos, ejecutando con sudo como root:

| Permisos previstos | Directorios |
| --- | --- |
| `0750`, root:root | `/srv/chromat`, `/srv/chromat/releases`, `/srv/chromat/promotions` |
| `0700`, root:root | `/srv/chromat/tls`, `/srv/chromat/backups`, `/etc/chromat`, `/etc/chromat/secrets`, `/var/lib/chromat`, `/var/lib/chromat/backup-state` |

El script no crea `/srv/chromat/staging`, secretos, certificados ni
`production.env`. No toca `/mnt/chromat-backups`, particiones, formatos o
`fstab`. No añade usuarios al grupo `docker`, no configura un socket TCP de
Docker ni instala Nginx/MariaDB/Node.js como servicios del host. No carga,
descarga o construye imágenes, no ejecuta Compose ni abre 443.

### Requisitos, riesgos y protección de SSH

- La preparación requiere acceso saliente a los repositorios Ubuntu, Docker
  y sus dependencias, DNS y reloj correctos. El régimen offline se conserva
  para las imágenes y la ejecución de CHROMAT; no implica aprovisionar APT
  sin conexión. La documentación oficial de Docker consultada enumera Ubuntu
  Resolute 26.04 LTS como soportado; la disponibilidad y descarga efectiva de
  paquetes desde esta VM siguen pendientes.
- Deben existir privilegios sudo en una sesión SSH interactiva. La caché de
  `sudo -v` de otra terminal no se comparte necesariamente. No se solicitará
  ni registrará una contraseña.
- Conservar una sesión SSH abierta y tener disponible la consola VMware.
  Probar una segunda conexión antes y después. No reiniciar ni restaurar
  Snapshot 3 como parte de esta etapa.
- El script **no invoca UFW**, no cambia `sshd_config` ni reinicia SSH
  explícitamente. UFW ya está instalado, pero APT puede actualizarlo.
  Instalación/actualización de paquetes puede tener efectos de servicios.
- Arrancar Docker puede crear reglas de firewall, interfaces y rutas, y
  afectar el forwarding; comprobarlas antes/después. No prometer riesgo cero
  para SSH. Sin contenedores publicados no debería aparecer un listener 443.
  La gestión de UFW de `docs/deployment/promotion.md` pertenece a una etapa
  posterior y **no se ejecutará ahora**.
- Según la documentación oficial, Docker usa iptables por defecto y puede
  activar forwarding IPv4/IPv6 y establecer política DROP para tráfico
  reenviado. Puede crear `docker0`, reglas de aislamiento y NAT/masquerading;
  no son una edición de las reglas UFW, pero sí cambios efectivos de red.
  SSH hacia la propia VM no es el mismo flujo que tráfico reenviado; probar
  una conexión nueva, no inferir seguridad solo porque la sesión vieja siga.
- **Riesgo para la promoción posterior:** los puertos publicados por Docker
  pueden eludir las reglas UFW al pasar por NAT/forwarding antes de INPUT.
  No considerar que `ufw deny 443` bloquee por sí solo Nginx publicado por
  Compose. Antes de desplegar habrá que revisar el control de exposición y
  comprobar BLOCKED/OPENED desde otro cliente. No se modifica ahora el
  runbook, el backend del firewall, `daemon.json` ni cadenas Docker.
- APT no fija versiones ni usa `--no-remove`. Registrar versiones reales y
  revisar candidatos y simulación antes de instalar. Si aparecen remociones,
  cambios inesperados o paquetes incompatibles, detenerse y solicitar un
  plan específico; no desinstalarlos automáticamente.
- El script usa `set -Eeuo pipefail`, pero no es transaccional: un fallo puede
  dejar índices, paquetes, fuente Docker o servicios parcialmente preparados.
  Algunas advertencias de APT no generan un exit code distinto de cero.
  Revisar el log y no considerar el mensaje PASS suficiente por sí solo.
- El script confía en la descarga HTTPS de la clave oficial; no fija su
  fingerprint ni versiones de paquetes. Un hash de la copia del script
  verifica igualdad con el checkout revisado, no autenticidad de una release.
- El espacio y el montaje verificados se conservan como referencia; medir
  consumo al terminar. No redimensionar ni volver a preparar los discos.

### Procedencia y secuencia propuesta

El flujo normal de la guía usa un paquete de release publicado y verificado:
checksum del TAR, comparación del manifiesto y
`scripts/verify-artifacts.sh`, antes del aprovisionador. Sin release disponible,
ese camino está bloqueado. No se publicará una para sortear el bloqueo.

**Procedencia comprobada por consultas de solo lectura a GitHub:**

- El commit existe en `JuanciscoPacketTracer/chromat-cloud`.
- El blob del script en ese commit es
  `bdd14322ed7c08621b37f5fb4b7bc683ae36326e`, tanto en Git local como en la
  API de contenidos de GitHub; tamaño remoto: 4816 bytes.
- El contenido obtenido mediante `git show <commit>:scripts/prepare-ubuntu-production-host.sh`
  y el archivo del checkout tienen el mismo SHA-256 registrado arriba.
- GitHub reporta el commit como `verified: false`, motivo `unsigned`.
  Por tanto, se comprobó igualdad con el repositorio y commit fijados, **no
  una firma de autor ni una release autenticada criptográficamente**.

Comandos de evidencia ejecutados en Fedora:

```bash
git rev-parse 4f23638dd77fe23fc0788fdeea1f4e290bb37b63:scripts/prepare-ubuntu-production-host.sh
git show 4f23638dd77fe23fc0788fdeea1f4e290bb37b63:scripts/prepare-ubuntu-production-host.sh | sha256sum
gh api 'repos/JuanciscoPacketTracer/chromat-cloud/contents/scripts/prepare-ubuntu-production-host.sh?ref=4f23638dd77fe23fc0788fdeea1f4e290bb37b63' \
  --jq '{path: .path, sha: .sha, size: .size}'
gh api repos/JuanciscoPacketTracer/chromat-cloud/commits/4f23638dd77fe23fc0788fdeea1f4e290bb37b63 \
  --jq '{sha: .sha, verified: .commit.verification.verified, verification_reason: .commit.verification.reason}'
```

**Alternativa experimental, sujeta a aprobación expresa:** copiar únicamente
el aprovisionador sin cambios desde el commit
`4f23638dd77fe23fc0788fdeea1f4e290bb37b63`, comparar su SHA-256 y usarlo para
preparar el host. No clonar el repositorio en Ubuntu, no transferir `.env` ni
secretos y no equiparar esto a una promoción validada. Esta alternativa no
resuelve todavía la entrega de imágenes o la ausencia de release.

Los bloques siguientes son **propuestos, no ejecutados**. No encadenarlos
automáticamente: cualquier fallo detiene la secuencia para revisar evidencia.

1. **Fedora:** confirmar procedencia, crear un directorio privado en el HOME
   de Ubuntu y copiar solo el script. `mkdir` debe fallar si el destino ya
   existe; no sobrescribirlo sin investigar.

```bash
cd ~/chromat
git rev-parse HEAD
git diff HEAD -- scripts/prepare-ubuntu-production-host.sh
sha256sum scripts/prepare-ubuntu-production-host.sh
ssh chromat-vm 'umask 077; mkdir "$HOME/chromat-host-prep-4f23638"'
scp scripts/prepare-ubuntu-production-host.sh \
  chromat-vm:chromat-host-prep-4f23638/prepare-ubuntu-production-host.sh
ssh -t chromat-vm
```

2. **Ubuntu, dentro de esa sesión interactiva:** comprobar hash y plataforma,
   autenticar sudo y recoger estado previo sin cambiar configuración.
   Revisar manualmente todos los resultados antes de ejecutar el paso 3.
   Registrar salidas relevantes sin secretos en este documento.

```bash
cd "$HOME/chromat-host-prep-4f23638"
printf '%s  %s\n' \
  ecd2da00a004b4e0b2b0ca0c13f2d6dc11a0f4f786f38bc8fdf4e623c65ab73c \
  prepare-ubuntu-production-host.sh | sha256sum -c -
. /etc/os-release
test "$ID" = ubuntu && test "$VERSION_ID" = 26.04
test "$(uname -m)" = x86_64
sudo -v
date -u +%FT%TZ
timedatectl status
ip -4 route
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
getent ahostsv4 download.docker.com
df -hT / /mnt/chromat-backups
sudo dpkg --audit
sudo ufw status verbose
sudo /usr/sbin/sshd -T | grep '^port '
sudo ss -ltnp
if command -v iptables-save >/dev/null; then sudo iptables-save; fi
if command -v nft >/dev/null; then sudo nft list ruleset; fi
sudo apt-get --simulate install ca-certificates curl gnupg openssl python3 age ufw
```

Además, revisar fuentes y candidatos APT con `apt-cache policy`, paquetes y
archivos de Docker que el script rechaza, y procesos APT/dpkg activos.
Inventariar también `docker-doc`, `docker-buildx` y una posible fuente
`docker.sources`: la guía oficial actual los menciona, pero el script no
incluye todos esos casos y exige su formato `docker.list`. Si existen, parar
para revisar, no reemplazar ni eliminar automáticamente. No borrar locks ni
detener actualizaciones para forzar la ejecución. La
simulación usa índices actuales y no valida todavía los paquetes del
repositorio Docker que falta añadir. Comprobar los hosts de las fuentes
Ubuntu realmente configuradas, no asumir un mirror concreto.

3. **Ubuntu, solo después de autorización y prechecks satisfactorios:**
   ejecutar el aprovisionador y guardar stdout/stderr en un log privado.
   La contraseña sudo nunca se introduce en el comando ni se copia al log.

```bash
umask 077
set -o pipefail
sudo bash ./prepare-ubuntu-production-host.sh 2>&1 | tee preparation.log
resultado=$?
printf 'Resultado de preparación: %s\n' "$resultado"
```

Si `resultado` no es cero, o hay advertencias relevantes, **parar**. No
ejecutar automáticamente el bloque siguiente ni reintentar la instalación.
El log permanece en el directorio privado para investigar; no borrarlo.

4. **Ubuntu, después de éxito aparente:** verificar paquetes, fuente,
   servicios, almacenamiento, permisos, red y ausencia de despliegue.

```bash
sudo dpkg --audit
dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\t${Version}\n' \
  ca-certificates curl gnupg openssl python3 age ufw \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo apt-cache policy docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo cat /etc/apt/sources.list.d/docker.list
sudo stat -c '%a %U:%G %n' /etc/apt/keyrings/docker.asc
sudo systemctl is-enabled docker
sudo systemctl is-active docker containerd
sudo docker version
sudo docker compose version
sudo docker info
age --version
sudo stat -c '%a %U:%G %n' /srv/chromat /srv/chromat/releases \
  /srv/chromat/promotions /srv/chromat/tls /srv/chromat/backups \
  /etc/chromat /etc/chromat/secrets /var/lib/chromat /var/lib/chromat/backup-state
sudo docker ps -a
sudo docker image ls
sudo docker volume ls
sudo docker network inspect bridge
sudo ufw status verbose
sudo ss -ltnp
if command -v iptables-save >/dev/null; then sudo iptables-save; fi
if command -v nft >/dev/null; then sudo nft list ruleset; fi
ip -4 route
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
df -hT / /mnt/chromat-backups
```

**Fedora:** abrir otra conexión `ssh chromat-vm` antes de cerrar la original.
Comparar UFW, reglas Docker, puertos y rutas con el estado previo. No ejecutar
`docker run hello-world`, `docker pull`, `docker compose up` ni builds para
verificar Docker: la respuesta del daemon y Compose basta para esta etapa.
Registrar versiones y salidas reales; la ausencia de contenedores no valida
todavía CHROMAT.

### Manejo de errores y cierre

| Error o discrepancia | Respuesta propuesta |
| --- | --- |
| SSH, hash o plataforma no coinciden | Parar antes de sudo/APT; revisar identidad y procedencia |
| DNS, TLS, mirror o Docker `resolute` no disponibles | Registrar error y fuente; no cambiar codename, usar repositorios alternativos ni omitir validaciones |
| Locks APT/dpkg o estado incompleto | Esperar o diagnosticar; no borrar locks ni ejecutar reparaciones sin aprobación |
| Docker parcial/ajeno | Respetar la negativa del script; inventariar y pedir autorización para cualquier corrección |
| APT o servicio Docker falla | Conservar log, consultar `sudo dpkg --audit` y `sudo journalctl -u docker -u containerd --no-pager -n 100`; identificar hasta dónde hubo cambios |
| SSH o rutas se afectan | Usar la consola VMware y comparar estado; proponer corrección mínima con autorización, sin desactivar globalmente UFW |
| Modos, fuente o versiones inesperados | No declarar éxito ni avanzar; investigar y aprobar corrección puntual |

No hay rollback automático ni autorización para `apt-get -f install`,
purges, desactivar servicios, eliminar datos, reiniciar o restaurar snapshots.
Si todo pasa, cerrar esta etapa con evidencia y solicitar aprobación de la
siguiente: resolver la entrega de artefactos offline verificados y la
provisión de secretos/TLS. No arrancar CHROMAT ni modificar UFW hasta sus
respectivas autorizaciones. `PULL_POLICY=never`, seis servicios, cinco imágenes
en total contando BusyBox auxiliar, volúmenes y filesystem de backups siguen
siendo decisiones conservadas.

Fuentes primarias consultadas desde Fedora para contrastar riesgos y soporte,
no pruebas de la VM:

- <https://docs.docker.com/engine/install/ubuntu/>
- <https://docs.docker.com/engine/network/packet-filtering-firewalls/>

## Etapa autorizada: comprobación previa, sin instalación

Autorización del usuario recibida el 2026-11-24 a las 19:53, hora del
laboratorio: copiar el aprovisionador revisado, comprobar hash, instalar
paquetes previstos y activar Docker. Se mantienen excluidos discos, `fstab`,
secretos, TLS, reglas UFW explícitas, imágenes y arranque de CHROMAT.
Ante un requisito fallido debe detenerse la ejecución y consultar.

Comprobaciones de solo lectura desde Fedora y una nueva sesión SSH, fechadas
`2026-11-25T02:54:00Z`:

| Comprobación ejecutada | Resultado |
| --- | --- |
| Git, diff del aprovisionador y SHA-256 | Misma rama/commit; script sin cambios y hash coincidente con el revisado |
| `hostname`, `/etc/os-release`, `uname -m` | `servidor-ejemplo`, Ubuntu 26.04.1 LTS, `x86_64` |
| `sudo -n true` | **FALLA:** `sudo: interactive authentication is required` |
| `timedatectl status` | Reloj sincronizado, NTP activo |
| `ip -4 route` | Ejemplo anonimizado: red `192.0.2.0/24`; gateway `192.0.2.1`, interfaz `ens33` |
| `sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding` | Ambos valores `0`, antes de Docker |
| `df -hT / /mnt/chromat-backups` | Raíz: 58 GiB disponibles; backups: 38 GiB disponibles |
| `getent ahostsv4 download.docker.com` | Resolución DNS correcta |
| Consulta de utilidades | Bash, herramientas APT/dpkg/systemd, curl, Python, GPG y SHA-256 disponibles |
| Consulta de paquetes Docker y conflictos conocidos | Ninguno de los consultados instalado; `age` tampoco instalado |
| Archivos previos Docker consultados | No detectados con los permisos actuales; falta comprobación privilegiada definitiva |
| `ps -eo pid,comm` filtrado por APT/dpkg | Proceso `unattended-upgr`, PID 1566; no demuestra que un lock esté ocupado |
| `ss -ltn` | SSH TCP/22 y DNS local TCP/53; sin TCP/443 |

Paquetes ya instalados, según `dpkg-query` con estado `ii`:

| Paquete | Versión previa |
| --- | --- |
| `ca-certificates` | `20260816ubuntu0.26.04.2` |
| `curl` | `8.18.0-1ubuntu2.8` |
| `gnupg` | `2.4.8-4ubuntu3.1` |
| `openssl` | `3.5.5-1ubuntu3.7` |
| `python3` | `3.14.3-0ubuntu2` |
| `ufw` | `0.36.2-9build1` |

**Decisión:** detenerse antes de copiar o ejecutar el aprovisionador.
No se ejecutó APT, no se añadió la fuente/clave Docker y no se activó Docker.
No hubo cambios parciales de aprovisionamiento. La inspección sudo de UFW,
locks y estado dpkg, la comprobación de clave/repositorio desde la VM y la
confirmación de consola VMware y segunda sesión mantenida siguen pendientes.
No se intentó cambiar sudoers ni reutilizar credenciales de otra terminal.
La autenticación deberá hacerse en una terminal interactiva del usuario,
sin comunicar su contraseña al agente ni guardarla en documentación.

### Continuación acordada: asistente para sudo interactivo

El usuario confirmó que dispone de la consola VMware y de dos terminales
conectadas por SSH, y solicitó preparar un asistente para ejecutarlo en su
propia terminal. No se solicitó ni recibió su contraseña.

**Comprobado antes de instalar:**

- Una nueva conexión SSH respondió el `2026-11-25T03:01:14Z`.
- Desde Ubuntu, consultas `curl --head` a los endpoints oficiales de la clave
  Docker y de `dists/resolute/InRelease` devolvieron HTTP 200 por HTTPS.
- `apt-cache policy` mostró candidatos de los repositorios Ubuntu configurados
  (`archive.ubuntu.com`, `security.ubuntu.com`): los paquetes generales ya
  instalados coinciden con sus candidatos; `age` tiene candidato
  `1.2.1-1build1`. Son índices existentes, no una actualización ejecutada.
- Desde Fedora se descargó la clave pública por HTTPS del endpoint oficial
  `https://download.docker.com/linux/ubuntu/gpg`, a una carpeta privada de
  esta sesión, sin instalarla en ningún keyring APT.
- Fingerprint primario observado:
  `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`.
  SHA-256 del archivo:
  `1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570`.
- `gpgv` con keyring aislado devolvió firma correcta del `InRelease` para
  `resolute`, mediante la subclave `7EA0A9C3F273FCD8`. Los campos firmados
  incluyen `Origin: Docker`, `Suite: resolute`, `amd64` y `stable`.
- Se descargó `stable/binary-amd64/Packages.gz`; su hash y tamaño coinciden
  con la sección SHA256 del manifiesto firmado. El índice contiene las cinco
  familias de paquetes Docker previstas. Esto no fija versiones ni sustituye
  la resolución de dependencias de APT en Ubuntu.

Se creó un asistente temporal fuera de Git:
`preparar-host-interactivo.sh`, junto al aprovisionador original sin cambios.
La biblioteca de la plantilla del asistente permanece intacta.
Sus cinco pasos son: confirmar consola/dos sesiones y sudo; comprobar
conflictos/locks/dpkg y simulación APT; verificar clave/firma/índice Docker;
confirmar y ejecutar el aprovisionador con postchecks; pedir nueva conexión
SSH y revisión antes de declarar éxito.

El asistente no escribe `.env`, secretos ni configuración de aplicación.
Descarga metadatos públicos en su directorio privado y toma logs antes/después.
Consulta locks POSIX sin borrar sus archivos ni detener procesos. Repite la
comprobación inmediatamente antes del aprovisionador; no elimina la posibilidad
de una carrera con actualizaciones posteriores.

La simulación previa cubre los paquetes generales usando índices existentes,
no toda la transacción Docker tras añadir su fuente. El aprovisionador original
no se modificó: conserva su manejo de APT y no convierte todas las advertencias
en errores. Se debe revisar el log antes de cerrar la etapa. Ante un exit code
de error, el asistente se detiene y solo consulta estado para documentarlo;
no ejecuta reparaciones, purges, cambios de firewall o restauración.

**Validación local realizada, no instalación:**

- `bash -n` correcto para ambos scripts.
- Biblioteca de la plantilla idéntica a su original.
- Ejecución sin terminal rechazada antes de sudo o instalación.
- Parser del índice Docker: acepta el índice auténtico; rechaza un índice
  alterado y una suite distinta de `resolute`.
- Revisión técnica: las consultas Docker propagan errores y se comprueba por
  separado que Docker y containerd estén activos.
- ShellCheck no disponible; no se instaló.
- Un primer intento de edición de las etapas no coincidió con el contexto
  decorativo de la plantilla; no cambió el archivo y se corrigió localmente.

**Cambios efectivamente realizados en Ubuntu, autorizados:**

Se creó `$HOME/chromat-host-prep-4f23638` y se transfirieron solo:

| Archivo | SHA-256 comprobado en Fedora y Ubuntu |
| --- | --- |
| `prepare-ubuntu-production-host.sh` | `ecd2da00a004b4e0b2b0ca0c13f2d6dc11a0f4f786f38bc8fdf4e623c65ab73c` |
| `preparar-host-interactivo.sh` | `aad15b3ffd1c45d31bc79a0326ba83dc390b03ca3a98c43b469d4ba2d1bbf8cc` |

Directorio y archivos: `0700`, `usuario-vm:usuario-vm`. El asistente se
actualizó antes de entregarlo tras verificar que la copia previa conservaba
su hash; no se sobrescribieron cambios del usuario.
Sintaxis comprobada también en Ubuntu. Nueva conexión independiente
(`ControlMaster=no`, `ControlPath=none`) correcta el
`2026-11-25T03:13:41Z`.

**No ejecutado todavía:** asistente completo, APT, instalación de la
clave/fuente Docker, activación de Docker o cualquier despliegue.
Los únicos cambios remotos de esta continuación son el directorio privado
y los dos archivos. No se tocó disco, `fstab`, secretos, TLS o reglas UFW.

### Acción del usuario, en una terminal ya conectada a Ubuntu

No ejecutar el aprovisionador directamente; el asistente aplica los
prechecks y conserva evidencia privada:

```bash
cd "$HOME/chromat-host-prep-4f23638"
printf '%s  %s\n' \
  aad15b3ffd1c45d31bc79a0326ba83dc390b03ca3a98c43b469d4ba2d1bbf8cc \
  preparar-host-interactivo.sh | sha256sum -c -
bash ./preparar-host-interactivo.sh
```

Responder `y` solo cuando se cumpla lo mostrado. Sudo solicita la contraseña
localmente, sin incluirla en comandos. Si aparece `STOP`, no repetir ni
reparar: conservar la salida y comunicarla al agente. El asistente deja
`session.log`, `before.txt`, `after.txt` cuando procede y `result.txt` en
un subdirectorio privado `run-XXXXXXXX`. No compartir contraseñas o logs
sin revisar posibles datos sensibles.

Si llega al último paso, mantener las conexiones abiertas y abrir **otra
conexión desde Fedora**:

```bash
ssh chromat-vm
hostname
sudo -v
sudo docker version
```

Comunicar al agente el resultado y el nombre del subdirectorio `run-XXXXXXXX`
para consultar la evidencia. La marca `PREPARED_SSH_AND_REVIEW_PENDING` no
declara instalación verificada: aún requiere la conexión nueva y revisión de
salidas/versiones, reglas Docker y UFW, permisos y conservación de `fstab`.
No cargar imágenes ni arrancar CHROMAT después de esta etapa. La siguiente
etapa se propondrá solo tras cerrar esta con evidencia y nueva aprobación.

## Incidencia durante el paso 4/5

El usuario reportó aparente atasco y aportó la salida del asistente:
la actualización de índices Ubuntu terminó; la instalación de `age` llegó
a `Setting up age (1.2.1-1build1)` y a los triggers de `man-db`.
No se repitió la instalación para reproducir el problema: hacerlo podría
alterar una operación APT en curso. Se observó el proceso existente por SSH
de solo lectura.

### Evidencia observada el 2026-11-25 a las 04:27 UTC

| Consulta | Resultado |
| --- | --- |
| Nueva conexión SSH | Correcta; hostname `servidor-ejemplo` |
| Log actual | `$HOME/chromat-host-prep-4f23638/run-EJEMPLO-1/session.log`; última modificación 04:04:24 UTC |
| Proceso APT | PID `16192`, padre `16061`; estado `T+`, detenido, unos 23 minutos transcurridos |
| Procesos `dpkg` o `mandb` | No aparecen en la consulta actual de procesos relevantes |
| `dpkg-query` de age | Estado `ii`, versión `1.2.1-1build1` |
| Paquetes Docker consultados | No instalados |
| `/etc/apt/sources.list.d/docker.list` | No presente |
| `sudo -n true` en sesión del agente | Sigue requiriendo autenticación interactiva |
| `/proc/16192/status` | `State: T (stopped)`, `TracerPid: 0`, `ShdPnd: 0000000000000002` |
| Grupo/terminal APT | PGID `16061`, TPGID `16061`, `pts/2`; coincide con el grupo en primer plano de la PTY creada por sudo |

La máscara `ShdPnd` contiene una señal SIGINT pendiente. No demuestra quién
la envió ni qué señal causó la suspensión. La evidencia identifica una
**suspensión de APT**, no lentitud de `man-db`. No atribuir todavía la causa
a Ctrl+Z, al asistente o a un proceso externo.

La comprobación de estado `ps -o stat= -p 16192` devolvió el marcador
`RED: apt-get PID 16192 esta detenido, no procesando man-db` y exit code 1
en el diagnóstico. Es una observación del proceso bloqueado, no un test
de instalación ni una reproducción del evento que lo suspendió.

Hipótesis comunicadas antes de consultar grupos/señales: suspensión por
control del terminal, señal manual de pausa, señal externa. El grupo APT
está en primer plano en el instante observado; no confirma una lectura
actual de terminal en segundo plano. Falta conocer qué interacción o señal
precedió al estado detenido.

### Cambios parciales y decisión

Comprobado: índices APT actualizados e instalación de `age` completada según
su estado dpkg. El log también informa que los seis paquetes generales
preexistentes fueron marcados como instalados manualmente. La transacción
APT aún no ha devuelto un resultado final al asistente; no declarar toda la
etapa exitosa ni asegurar que dpkg no tenga pendientes sin comprobarlo.

El asistente no llegó al repositorio Docker. No hay evidencia de activación
de Docker ni despliegue. No se enviaron señales a procesos, no se borraron
locks, no se reinició la VM y no se ejecutaron reparaciones o una segunda
instalación. Se solicitó contexto de la interacción del usuario antes de
proponer cualquier reanudación o terminación; una SIGINT pendiente hace
especialmente importante no reanudar a ciegas.

El usuario aclaró que no pulsó teclas de interrupción ni realizó otras acciones
y que la terminal original sigue esperando sin recuperar el prompt.
Una segunda consulta a las 04:30:33 UTC confirmó el mismo estado `T+` y SIGINT
pendiente. El log sigue sin cambiar desde las 04:04:24.
La sesión sudo del aprovisionador figura abierta a las 04:04:12 en el journal.
No hay diagnóstico confirmado de la señal que detuvo APT.

La consulta de `/proc/16192/syscall` y `/proc/16192/stack` falló con
`Permission denied` desde la sesión sin sudo; no se intentó eludir permisos.
Se requiere una inspección privilegiada **de solo lectura** desde la segunda
terminal del usuario. No se autoriza ni propone todavía reanudar el proceso,
enviar señales, reparar dpkg o repetir la instalación.

### Resultado de la inspección privilegiada aportada por el usuario

Las consultas se ejecutaron en la segunda terminal, sin modificar procesos:

- `ps` identifica `do_signal_stop` como punto de espera de APT.
- `/proc/16192/stack` muestra `do_signal_stop`, `get_signal` y el retorno
  de una llamada de sistema.
- `/proc/16192/syscall` muestra syscall `16` (`ioctl` en x86_64), descriptor
  `0` y solicitud `0x402c542d`, correspondiente a `TCSETSF2` (configuración
  de terminal). El header disponible define
  `TCSETSF2` como `_IOW('T', 0x2D, struct termios2)`.
- FD 0 apunta a `/dev/pts/2`; stdout y stderr apuntan a una tubería.
- `sudo dpkg --audit` no produjo salida en la consulta aportada.
- `/var/log/dpkg.log` registra `status installed` para `age` y para
  `man-db` a las 04:04:24. Los triggers no quedaron trabajando.
- APT es versión `3.2.1`; el asistente sigue sin `result.txt`.

Diagnóstico delimitado: APT está suspendido por una señal en una operación
de terminal después de completar dpkg, con stdout/stderr canalizados por el
asistente. La interacción de control de terminal/PTY es una explicación
compatible; no se ha demostrado la señal original ni atribuido la causa a
una línea del asistente. No se construyó una reproducción de esa interacción:
no se repite una instalación en la VM para forzar el síntoma.

**Siguiente acción propuesta, requiere autorización específica:** terminar
solo la ejecución APT detenida, tras volver a comprobar PID e identidad.
Para un proceso detenido, encolar SIGTERM y luego SIGCONT permite entregar la
señal de terminación. No enviar SIGCONT aislado, no usar SIGKILL por defecto
y no terminar procesos por nombre. La salida no cero debe detener el
aprovisionador (`set -e`) y activar el registro de estado del asistente,
sin avanzar hacia Docker.

Después, comprobar salida del asistente, procesos, `dpkg --audit`, paquetes
y logs. No ejecutar `dpkg --configure -a`, reparaciones APT ni un nuevo
intento. Una eventual corrección del mecanismo de terminal y una repetición
de la preparación se propondrán por separado.

El usuario autorizó específicamente terminar ese APT y comprobar el estado,
sin reparaciones ni reinstalación. Se preparó y copió
`terminar-apt-detenido.py` al directorio privado del laboratorio, con modo
`0700`. Hash coincidente en Fedora y Ubuntu:
`0e30d6680584f1b7f57c9e5d476edfd8c55d76112d47674bcddd389beecaefe7`.

La herramienta solo admite el PID 16192, nombre `apt-get`, estado detenido,
padre 16061 e instante de inicio 1854703 (ticks de arranque); utiliza un pidfd
para evitar enviar señales a un proceso distinto si se reutiliza el PID.
Pruebas locales con llamadas de señal simuladas confirmaron rechazo de nombre,
estado o inicio distintos sin enviar señales y modo diagnóstico sin señales.
El modo diagnóstico ejecutado en Ubuntu confirmó identidad y estado actuales.
**No se ejecutó todavía `--terminate`** desde la sesión del agente.

Comando autorizado para la segunda terminal del usuario:

```bash
sudo python3 "$HOME/chromat-host-prep-4f23638/terminar-apt-detenido.py" --terminate
```

Encola SIGTERM y después SIGCONT sobre el pidfd verificado; espera hasta diez
segundos a confirmar salida. No emplea SIGKILL, no libera locks manualmente,
no ejecuta APT y no realiza reparaciones. Si no confirma salida, se detiene
sin enviar más señales. Después se consultará el log del asistente y el
estado dpkg; no repetir el aprovisionamiento.

### Terminación autorizada y salida del asistente

El usuario ejecutó la herramienta en su segunda terminal y aportó:

```text
Identidad confirmada: PID 16192, apt-get detenido, inicio 1854703.
SIGTERM enviado al proceso verificado.
SIGCONT enviado para entregar la terminacion pendiente.
Salida de APT confirmada. No se hicieron reparaciones ni instalaciones.
```

Después, la terminal original mostró:

```text
STOP: exit=130 line=413 stage=4 install_started=1
sudo: interactive authentication is required
```

La marca `install_started=1` indica que el aprovisionador había comenzado,
no que Docker estuviera instalado. El código 130 es compatible con la SIGINT
que ya estaba pendiente al reactivar el proceso para terminarlo.
El asistente entró en su ruta de registro de errores, no continuó hacia Docker
y anunció que no intentaba reparar.

En el registro de estado aportado por el usuario:

- `age`: `ii`, `1.2.1-1build1`; `ufw`: `ii`, `0.36.2-9build1`.
- Los cinco paquetes Docker consultados siguen ausentes.
- Red: `ens33`, IP de ejemplo `192.0.2.10`, gateway de ejemplo `192.0.2.1`.
- Forwarding IPv4/IPv6: ambos `0`.
- Raíz: 58 GiB disponibles; backups: 38 GiB disponibles.
- Backups: `/dev/sdb1`, ext4, mismo UUID, montaje independiente `8:17`,
  permisos `0700 root:root`.
- Timestamp del registro de salida: `2026-11-25T05:23:57Z`.

Las consultas privilegiadas del manejador de error fallaron porque
`sudo -n` requería autenticación de nuevo. Eso no prueba un fallo nuevo de
APT, pero deja incompletas las comprobaciones de dpkg, servicios y UFW de ese
manejador. La explicación compatible es caducidad o falta de caché sudo para
esa sesión; no se modificó sudoers.

Se requiere `sudo -v` en una terminal interactiva del usuario y consultas
privilegiadas de solo lectura para cerrar la incidencia. No se ha autorizado
un nuevo intento, una reparación de paquetes o cambios de logging/PTY.
La propuesta para un futuro intento deberá preservar una terminal real para
APT en vez de canalizar su stdout/stderr por `tee`, pero no se presenta como
una corrección probada de la causa de suspensión.

La consulta remota posterior, fechada `2026-11-25T05:25:08Z`, confirmó:
una nueva conexión SSH funciona; ninguno de los PIDs del asistente, tee, sudo,
aprovisionador o APT de esta ejecución sigue presente; `result.txt` contiene
`STOP exit=130 line=413 stage=4 install_started=1`; `age` y `man-db` están en
estado `ii`; los paquetes y la fuente Docker siguen ausentes.
`dpkg --audit` ejecutado sin sudo no produjo salida. No se ejecutaron
reparaciones para conseguir ese estado.

Pendiente para cerrar esta incidencia: comparar UFW y el hash de `/etc/fstab`
contra la evidencia anterior con consultas privilegiadas desde la terminal
del usuario. Cualquier corrección del asistente y nuevo intento requerirá
aprobación separada; no reutilizar a ciegas el asistente anterior.

### Cierre de comprobaciones de la incidencia

El usuario ejecutó `sudo ufw status verbose` en la segunda terminal:
`Status: inactive`, coincidente con `ufw-before.txt`.
El último comando `cat` quedó con una comilla doble sin cerrar; Bash mostró
el prompt de continuación `>`. Esto es entrada incompleta del shell, no
un segundo bloqueo de APT. Se indicó cancelar únicamente esa línea con
Ctrl+C en la segunda terminal.

Consulta de solo lectura por nueva conexión SSH el
`2026-11-25T05:31:59Z`: el SHA-256 actual de `/etc/fstab` coincide exactamente
con el de `fstab-before.txt`:
`[HASH_FSTAB_PRIVADO]` (valor omitido en esta copia pública).
Por tanto, UFW sigue inactivo y `fstab` no cambió.

Incidencia cerrada en estado **preparación incompleta**, no instalación exitosa:
`age` instalado, dpkg sin pendientes observados, Docker ausente, ejecución
detenida sin reparaciones y acceso SSH conservado. No se tocó el almacenamiento
de backups. El origen exacto de la suspensión de APT sigue sin demostrarse.

Se comprobó que `/usr/bin/script` de util-linux `2.41.3` ya está disponible
en Ubuntu, sin instalar herramientas. Siguiente propuesta: revisar la
captura del asistente para conservar una PTY real en stdin/stdout/stderr
durante APT y probar esa propiedad con comandos inocuos, sin paquetes ni
señales. No se ha ejecutado esa modificación/prueba ni autorizado otro
aprovisionamiento.

### Revisión autorizada de captura PTY, sin aprovisionamiento

El usuario autorizó revisar y probar la captura del asistente, excluyendo
instalación o reanudación de la preparación. Se creó una revisión separada
`preparar-host-interactivo-pty.sh`, preservando el asistente anterior, los logs
y el aprovisionador del commit sin cambios.

Cambios de la revisión:

- El modo por defecto es `--probe-tty`, que solo comprueba captura de terminal
  y propagación de errores; nunca invoca el aprovisionador.
- `--probe-sudo-tty` añade una prueba privilegiada inocua después de
  `sudo -v` en la terminal del usuario; no ejecuta APT ni Docker.
- El modo futuro `--prepare` queda pendiente de autorización separada.
  Conserva los prechecks y sustituye la invocación del aprovisionador por
  `sudo -n env CHROMAT_PREPARER=... script --quiet --return --command ...`.
  `script` crea una PTY para el hijo y registra su salida; `--return`
  conserva el código de salida. No se registra entrada con `--log-in`.
- Sudo se ejecuta **antes** de crear esa PTY, no dentro de ella, para usar
  la autenticación de la terminal original y no depender de compartir su
  caché con otra TTY. El aprovisionador dentro de la PTY sigue ejecutándose
  como root. Esta ruta de instalación no se ha ejecutado.

Hash de la nueva revisión, igual en Fedora y Ubuntu:
`15b5aa8cbf2709caee56b8bfc2f0d8153b43a310ef086ef89df4e8a41dc9a4c9`.
Se transfirió al directorio privado del laboratorio sin sobrescribir un
archivo previo. Se comprobó sintaxis y diff completo; la biblioteca de la
plantilla permanece idéntica.

**Prueba realizada por el agente**, en SSH con PTY, sin sudo:

```bash
bash ./preparar-host-interactivo-pty.sh --probe-tty
```

Resultado observado:

```text
BASELINE: stdout canalizado por tee no es una terminal.
RED: el hijo directo falla el contrato stdin/stdout/stderr TTY.
PASS: stdin/stdout/stderr TTY
PASS: error del hijo propagado (37).
PROBE_PASS: no se ejecuto APT, Docker ni reparaciones.
```

Log en
`$HOME/chromat-host-prep-4f23638/pty-probe-EJEMPLO-1/session.log`.
La prueba reproduce y corrige la propiedad de descriptores del mecanismo de
captura, **no el evento de suspensión original de APT**. No se declara
resuelta esa causa ni validado un nuevo aprovisionamiento.

Siguiente comprobación autorizada de captura, en la terminal Ubuntu del usuario:

```bash
bash "$HOME/chromat-host-prep-4f23638/preparar-host-interactivo-pty.sh" --probe-sudo-tty
```

Debe mostrar terminal para stdin/stdout/stderr bajo sudo, UID `0`, propagación
del código `37` y `PROBE_PASS`. La contraseña se solicita antes de iniciar
la captura. Si falla, detenerse y registrar salida; no usar `--prepare`
ni repetir instalaciones.

### Prueba PTY bajo sudo completada

El usuario ejecutó `--probe-sudo-tty` y aportó `PROBE_PASS`.
Consulta remota de solo lectura a las `2026-11-25T05:41:28Z` confirmó el log
en `pty-probe-EJEMPLO-2/session.log`, UID `0`, terminal en los tres descriptores
bajo sudo y propagación del código `37`. Los hashes de la revisión y del
aprovisionador original siguen coincidiendo con los registrados.
No se ejecutó APT, Docker, señales o reparaciones durante esta prueba.

La captura está validada en su contrato de terminal y salida de error.
La disposición visual de líneas en la consola durante la prueba no afecta
esas comprobaciones; se conserva el log como evidencia. Esto no demuestra
que una futura instalación no pueda fallar por otro motivo.

**Siguiente etapa propuesta:** nueva ejecución de preparación mediante
`preparar-host-interactivo-pty.sh --prepare`, únicamente tras autorización
expresa. Repetirá prechecks, hash, firma del repositorio y simulación de
paquetes generales; se detendrá ante conflictos antes de instalar.
Los efectos autorizables siguen siendo índices/fuente/clave APT oficiales,
paquetes previstos, activación Docker y directorios operativos. No incluye
imágenes, CHROMAT, secretos/TLS, discos, `fstab` o reglas UFW explícitas.
No cambiar sudoers ni fijar excepciones para ocultar errores.

Si el nuevo intento falla, parar y conservar log/estado; no reparaciones
automáticas. Si termina, comprobar servicios, versiones, permisos, fuente
y clave, ausencia de imágenes/contenedores/volúmenes, UFW/fstab y otra
conexión SSH antes de declarar la preparación completa.

El usuario autorizó el nuevo intento con captura PTY y las mismas
restricciones. La ejecución debe realizarse en su terminal interactiva:

```bash
bash "$HOME/chromat-host-prep-4f23638/preparar-host-interactivo-pty.sh" --prepare
```

Mantener consola VMware y dos sesiones SSH disponibles. Confirmar dentro del
asistente solo si los prechecks pasan. La captura conservará `session.log` y
`preparation-pty.log` en el nuevo `run-XXXXXXXX`. Autorización recibida;
**resultado del nuevo intento todavía pendiente**. No usar el asistente viejo.

## Resultado del nuevo intento con captura PTY

El usuario ejecutó la revisión con `--prepare`, confirmó los pasos y llegó
al paso 5/5. Registro:
`$HOME/chromat-host-prep-4f23638/run-EJEMPLO-2/session.log`.
`result.txt` contiene `PREPARED_SSH_AND_REVIEW_PENDING`; no se interpreta
por sí solo como cierre de validación.

### Evidencia verificada por el agente

Nueva conexión SSH independiente el `2026-11-25T05:46:49Z`:

| Comprobación | Resultado |
| --- | --- |
| Hostname y acceso | `servidor-ejemplo`; conexión SSH nueva correcta |
| Docker Engine | CLI y daemon `29.10.1` según postchecks del log |
| Docker Compose | Plugin `5.8.0` |
| Buildx | `0.39.1` |
| Docker | `enabled`, `active`, consultado también mediante systemctl en la conexión nueva |
| containerd | `active`; paquete `2.4.2-4~ubuntu.26.04~resolute` |
| `dpkg --audit` | Sin salida, sin pendientes observados |
| Clave Docker instalada | SHA-256 coincide con la clave pública oficial validada |
| UFW antes/después | `Status: inactive`, sin cambios |
| `/etc/fstab` actual/antes/después | Mismo SHA-256 `[HASH_FSTAB_PRIVADO]`, valor omitido |
| TCP escuchando | SSH 22 y DNS local 53; sin 443 ni socket TCP Docker |
| Espacio | Raíz: 58 GiB disponibles, 8.0 GiB usados; backups: 38 GiB disponibles |
| Directorios e imágenes | El asistente pasó las comprobaciones de permisos previstos y ausencia de contenedores, imágenes y volúmenes |

La instalación real volvió a usar el aprovisionador sin cambios del commit
fijado. No se construyeron ni cargaron imágenes, no se inició CHROMAT y no se
provisionaron secretos/TLS. No se ejecutaron reparaciones del intento anterior.

### Paquetes instalados y efectos reales

Según `/var/log/apt/history.log`, la transacción Docker empezó a las
05:45:21 UTC y terminó a las 05:45:26 UTC:

| Paquete | Versión instalada |
| --- | --- |
| `docker-ce`, `docker-ce-cli` | `5:29.10.1-1~ubuntu.26.04~resolute` |
| `containerd.io` | `2.4.2-4~ubuntu.26.04~resolute` |
| `docker-buildx-plugin` | `0.39.1-1~ubuntu.26.04~resolute` |
| `docker-compose-plugin` | `5.8.0-1~ubuntu.26.04~resolute` |
| `docker-ce-rootless-extras` (automático) | `5:29.10.1-1~ubuntu.26.04~resolute` |
| `pigz` (automático) | `2.8-1build1` |

`age 1.2.1-1build1` ya se había instalado en el primer intento. Los seis
paquetes generales preexistentes conservaron las versiones registradas.
Instalar `docker-ce-rootless-extras` no significa haber configurado un daemon
rootless ni añadido al administrador al grupo Docker.

Cambios de red observados en `before.txt`/`after.txt`:

- Se conserva la ruta de administración por `ens33`, gateway de ejemplo `192.0.2.1`.
- Aparece `docker0` con ruta `[PREFIJO_BRIDGE_1]`, IP `[IP_BRIDGE_1]`, sin contenedores.
- `net.ipv4.ip_forward` cambia de `0` a `1`; IPv6 permanece en `0`.
- La tabla filter contiene política `FORWARD DROP` y cadenas `DOCKER`,
  `DOCKER-BRIDGE`, `DOCKER-CT`, `DOCKER-FORWARD`, `DOCKER-INTERNAL`,
  `DOCKER-USER`; aparecen reglas de NAT Docker.
- La consulta nft advierte que las tablas observadas son administradas por
  iptables-nft y no deben editarse directamente. No son errores de instalación
  ni se modificaron esas tablas manualmente.

Estos cambios confirman que activar Docker afectó el firewall efectivo,
aunque no se ejecutaran comandos UFW. Sigue pendiente revisar el filtrado de
puertos publicados antes de una futura promoción de CHROMAT.

### Advertencia de permisos y revisión pendiente

El log contiene:

```text
W: Unable to read /etc/apt/sources.list.d/docker.list - open (13: Permission denied)
```

Se produjo en el postcheck `apt-cache policy` ejecutado como `usuario-vm`,
no en las instalaciones APT ejecutadas como root. Se comprobó:

- `/etc/apt/sources.list.d/docker.list`: `0600 root:root`.
- `/etc/apt/keyrings/docker.asc`: `0644 root:root`, hash correcto.
- El aprovisionador creó la fuente con la umask restrictiva de la ejecución;
  no fija el modo de ese archivo explícitamente. Su lectura sin sudo falla.
- Los postchecks con sudo leyeron y verificaron la línea de fuente esperada.

No se cambiaron permisos automáticamente ni se ocultó la advertencia.
Para cerrar la comprobación de procedencia, se solicita `sudo apt-cache policy`
desde la nueva conexión del usuario. Corregir el modo de la fuente o el
postcheck de futuras ejecuciones requeriría una decisión explícita; no
repetir el aprovisionador por esta advertencia.

El usuario debe completar el paso 5/5 con otra conexión desde Fedora y
comunicar `hostname`, `sudo docker version` y la consulta privilegiada de
procedencia. La preparación del host no equivale a una instalación funcional
de CHROMAT ni autoriza su siguiente etapa.

### Cierre verificado de preparación del host

El usuario completó una conexión SSH nueva desde Fedora y aportó:

- Hostname `servidor-ejemplo`.
- `sudo docker version`: CLI y daemon `29.10.1`, `linux/amd64`; containerd
  `v2.4.2`, runc `1.5.3`, docker-init `0.19.0`.
- `sudo apt-cache policy` para los cinco paquetes Docker: versiones instaladas
  coincidentes con sus candidatos, procedentes de
  `https://download.docker.com/linux/ubuntu resolute/stable amd64 Packages`.
  La consulta privilegiada no presenta el aviso de lectura de fuente.

**Etapa de preparación completada y verificada.** Se conserva la advertencia
de la consulta APT sin sudo como resultado real, no se borra del log y no
se modificó el modo `0600` de `docker.list`. Las consultas administrativas APT
deben ejecutarse con sudo en este laboratorio.
El bloque manual de postchecks propuesto se actualizó para reflejarlo; los
scripts y logs ya ejecutados se conservan con sus hashes originales.
El marcador original `PREPARED_SSH_AND_REVIEW_PENDING` se mantiene como salida
del asistente; este cierre documental añade la revisión y conexión externa
posteriores sin reescribir la evidencia.

La prueba con captura PTY y el segundo aprovisionamiento sí se ejecutaron.
El primer intento y su suspensión quedan documentados; no se afirma
conocer la señal original que suspendió APT. No se probó reinicio de la VM,
Compose de CHROMAT, migraciones, HTTPS, backup o restore.

La rama y commit permanecen iguales; el registro sigue no rastreado.
No hubo commits, push, releases ni cambios del aprovisionador del checkout.
Los volúmenes de aplicación aún no existen; crear/configurar CHROMAT
requiere otra etapa. `PULL_POLICY=never` sigue siendo una decisión obligatoria
para la configuración futura, no un archivo de producción ya instalado.

**Siguiente propuesta, pendiente de aprobación:** inventariar artefactos
offline disponibles en Fedora y definir su procedencia, integridad y ruta de
entrega experimental sin publicar releases. Alcance inicial solo lectura:
no construir ni descargar imágenes, no transferir ni cargar archivos en
Ubuntu, no provisionar secretos/TLS y no arrancar servicios CHROMAT.
Después se propondrán los cambios necesarios con una autorización propia.

## Inspección autorizada de artefactos offline en Fedora

Fecha de la comprobación: 2026-11-25.

El usuario autorizó solo inspección. No se construyeron, descargaron,
cargaron o transfirieron imágenes; no se publicaron releases. No se
detuvieron contenedores ni se modificaron los artefactos existentes.

### Inventario y validación de solo lectura

Se inspeccionaron `docs/deployment/artifacts.md`, el empaquetador y los
validadores. Una búsqueda glob inicial no mostró artefactos porque la salida
está ignorada por Git; se comprobó directamente la ruta canónica
`dist/artifacts`, ignorada por `.gitignore:25` (`/dist/`).
La ausencia de coincidencias en el glob no se interpretó como ausencia real.

| Paquete local | Commit declarado | TAR, bytes | Resultado con validador actual |
| --- | --- | --- | --- |
| `2026.11.12-1` | `fb902aa3f2ce3dcc418441dfd4d02b33cffa0f51` | 253302742 | FAIL: falta `scripts/recover-release-links.sh` |
| `2026.11.16-1` | `ec1f446bf9a204e3ca91538c1ec9afbd1c316642` | 253310173 | FAIL: falta `scripts/verify-image-artifacts.sh` |

Comandos ejecutados:

```bash
bash scripts/verify-artifacts.sh dist/artifacts/2026.11.12-1
bash scripts/verify-artifacts.sh dist/artifacts/2026.11.16-1
(
  cd dist/artifacts
  sha256sum --check --strict \
    chromat-2026.11.12-1.tar.gz.sha256 \
    chromat-2026.11.16-1.tar.gz.sha256
)
```

Ambos validadores devolvieron exit code `1`; los dos SHA-256 de TAR
devolvieron **OK**. Integridad del TAR no implica cumplimiento del contrato.
Inspección con Python/tarfile sin extraer archivos confirmó:

- Manifiesto del directorio idéntico al incluido en su TAR.
- Ambos commits existen localmente y son antecesores del checkout actual.
- Cuatro TAR de imágenes en cada paquete, todos declarados `amd64`.
- Ninguno incluye `images/busybox.tar` ni `auxiliary_images`.
- Ninguno tiene el activo externo `chromat-VERSION.manifest.json`.
- Sus manifiestos declaran `pull_policy: never`, Ubuntu 26.04 y migración
  `016`, pero no corresponden al commit actual ni al contrato operativo vigente.
- Enlaces locales de Fedora: `active` a `2026.11.16-1` y `previous` a
  `2026.11.12-1`; no se cambiaron ni se usarán como enlaces operativos Ubuntu.

`gh release list` volvió a devolver `[]`; no hay una release publicada
disponible en esa consulta. No hay tags locales para esas dos versiones.
No se ejecutó `create-github-draft-release.sh`, que crearía una release Draft
y cargaría sus activos, ni el flujo de publicación.

**Decisión de inspección:** no transferir ni usar estos paquetes antiguos.
No añadir BusyBox o scripts actuales manualmente para presentarlos como una
release actual: mezclar contenido rompería la procedencia del conjunto.
No se completó validación semántica ni un smoke test de ninguno.

### Constructor existente y límites

Se confirmó un Docker real de Fedora, no una emulación Podman:

| Elemento | Resultado observado |
| --- | --- |
| CLI | Docker `29.9.3`, paquete `docker-ce-cli-29.9.3-1.fc44.x86_64` |
| Daemon | Docker `29.9.3`, Fedora Linux 44, amd64, endpoint local Unix canónico |
| Compose | `5.7.0` |
| Podman | `5.8.9`, disponible pero no utilizado como sustituto |
| Almacenamiento de imágenes | overlayfs con `io.containerd.snapshotter.v1` |
| Espacio en Fedora | Aproximadamente 63 GiB disponibles en `/home`, btrfs |
| Contenedores activos | Seis servicios del proyecto CHROMAT en Fedora |
| Worktrees | Solo el checkout actual |

Comandos de las comprobaciones finales, ejecutados en Fedora:

```bash
docker image inspect busybox:1.36.1 \
  --format 'ID={{.Id}} Arch={{.Architecture}} RepoDigests={{json .RepoDigests}}'
docker image inspect \
  'docker.io/library/busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f' \
  --format 'Referencia fijada disponible: {{.Id}} {{.Architecture}}'
docker info --format 'Driver={{.Driver}} DriverStatus={{json .DriverStatus}}'
docker ps -q | wc -l
docker ps -a --filter label=com.docker.compose.project=chromat \
  --format '{{.Names}} {{.State}} {{.Image}}'
df -hT .
git worktree list --porcelain
git check-ignore -v dist/artifacts
git status --short --branch
git rev-parse HEAD
date -u +%FT%TZ
```

La consulta de la referencia BusyBox fijada falló con `No such image`.
Los seis contenedores activos son `chromat-db-1`, `chromat-api-1`,
`chromat-worker-1`, `chromat-telegram-worker-1`, `chromat-inference-1` y
`chromat-nginx-1`, todos en **Fedora**, no en Ubuntu.
El estado Git seguía mostrando únicamente este documento no rastreado.

Las consultas de imágenes se limitaron a referencias pertinentes del
laboratorio. Hay imágenes antiguas API/inferencia, MariaDB, Nginx y bases de
Node/Python; eso no valida su reutilización como código del commit actual.

La caché `busybox:1.36.1` tiene `.Id`
`sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662`,
distinto del config ID que exige el contrato actual
`sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d`.
La referencia de plataforma fijada
`busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f`
no está disponible localmente, según `docker image inspect`.
No se realizó pull, retag ni se relajó la validación. El origen y semántica
de esa diferencia de ID requieren comprobarse antes de una nueva construcción.

El daemon actual no es un constructor aislado: se preservaron sus seis
contenedores y sus tags. `verify-image-artifacts.sh` hace `docker load`;
por tanto, **no se ejecutó** bajo esta autorización de solo lectura.

### Bloqueos para un paquete nuevo y siguiente propuesta

- `package-artifacts.sh` requiere árbol limpio, incluidos no rastreados.
  Este registro no rastreado bloquearía construir desde el checkout actual.
  No hacer commit, ocultar el registro o descartarlo para eludirlo.
- Una opción futura es un worktree limpio y detached del commit completo
  `4f23638dd77fe23fc0788fdeea1f4e290bb37b63`, con salida separada de los
  paquetes antiguos y `.env.example` explícito, nunca secretos de `.env`.
  No se creó todavía.
- El empaquetador hace pull de MariaDB/Nginx y BusyBox y build de API/inferencia
  en Fedora; exporta cinco imágenes, manifiestos y checksums. Requiere otra
  autorización para esas escrituras y descargas.
- El empaquetador por sí solo no exige crear tags ni publicar releases.
  Esas operaciones pertenecen al flujo GitHub posterior, que sigue excluido.
- Se debe elegir o preparar un Docker de construcción aislado, sin afectar
  la instalación CHROMAT existente de Fedora ni usar Ubuntu productivo para
  construir/descargar imágenes.

Inspección cerrada: **no hay un paquete actual aprobado para entregar**.
Siguiente propuesta: planificar el constructor aislado y la comprobación de
identidad BusyBox, detallando requisitos y efectos antes de autorizar cualquier
provisión o build. Ubuntu conserva su host preparado; no se realizaron cambios
en ella durante esta inspección.

## Plan del constructor aislado: comprobado frente a pendiente

El usuario autorizó planificar y comprobar requisitos, sin crear ni descargar
nada. Pidió demostrar separación de daemon, almacenamiento, socket y tags,
preservar los servicios existentes y proponer una VM si no se puede garantizar
una separación adecuada.

Solo se actualiza este registro. No se creó directorio, daemon, namespace de
prueba, unidad systemd, contexto Docker, worktree, VM o imagen.
No se consultaron registros externos ni se descargaron metadatos de Internet.

### Capacidad y requisitos existentes en Fedora

| Comprobación de lectura | Resultado |
| --- | --- |
| CPU | 16 procesadores lógicos disponibles |
| RAM | 30 GiB totales, aproximadamente 12 GiB disponibles en la muestra |
| Swap | 8 GiB, sin uso en la muestra |
| Carga media | Aproximadamente 2.08 / 1.75 / 1.60 |
| Espacio | 63 GiB disponibles en btrfs |
| Disco de `/home` y `/var/lib` | Mismo dispositivo y UUID btrfs; subvolúmenes distintos, no capacidad independiente |
| Docker existente | Activo, PID 1422, `/var/lib/docker`, socket Unix canónico |
| Consumo CHROMAT | Seis servicios activos; aproximadamente 261 MiB de RAM sumados en la muestra |
| Docker rootless | `docker-ce-rootless-extras-29.9.3-1.fc44.x86_64` ya instalado |
| RootlessKit | 3.3.0, suministrado por docker-ce-rootless-extras |
| UID/GID subordinados | Rangos existentes de 65536 IDs para el usuario actual |
| User namespaces | `user.max_user_namespaces = 125446` |
| Cgroups | v2; cpu, io, memory y pids delegados al gestor systemd del usuario |
| Red rootless | `pasta` disponible; RootlessKit la marca experimental |
| slirp4netns/vpnkit | No disponibles; no se instalaron |
| Cuota btrfs | Consulta sin privilegios denegada; estado y límite no verificados |

`rpm -q rootlesskit` informa que ese nombre de paquete no está instalado,
pero **el binario sí existe**: `rpm -qf /usr/bin/rootlesskit` identifica
docker-ce-rootless-extras. No confundir ausencia del nombre de paquete con
ausencia de la herramienta.

Los comandos de esta fase incluyen:

```bash
command -v dockerd dockerd-rootless.sh dockerd-rootless-setuptool.sh \
  rootlesskit newuidmap newgidmap pasta fuse-overlayfs systemd-run unshare
rpm -q docker-ce docker-ce-rootless-extras rootlesskit slirp4netns \
  passt fuse-overlayfs shadow-utils
id
awk -F: -v u="$(id -un)" -v n="$(id -u)" \
  '$1==u || $1==n {print FILENAME ":" $0}' /etc/subuid /etc/subgid
sysctl user.max_user_namespaces
stat -fc %T /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers
systemctl --user show --property=Version --property=ControlGroup
nproc
nproc --all
free -h
uptime
df -hT . /tmp
df -i .
docker stats --no-stream --format '{{.Name}} CPU={{.CPUPerc}} RAM={{.MemUsage}}' \
  chromat-db-1 chromat-api-1 chromat-worker-1 chromat-telegram-worker-1 \
  chromat-inference-1 chromat-nginx-1
docker system df
docker info --format \
  'DockerRootDir={{.DockerRootDir}} CgroupDriver={{.CgroupDriver}} CgroupVersion={{.CgroupVersion}} SecurityOptions={{json .SecurityOptions}}'
docker context inspect default --format '{{.Endpoints.docker.Host}}'
rootlesskit --version
rootlesskit --help
dockerd --help
rpm -qf /usr/bin/rootlesskit /usr/bin/dockerd-rootless.sh
cg=$(systemctl --user show --property=ControlGroup --value)
cat "/sys/fs/cgroup$cg/cgroup.controllers"
cat "/sys/fs/cgroup$cg/cgroup.subtree_control"
btrfs qgroup show -reF .
docker compose --help
docker compose build --help
findmnt -no SOURCE,FSTYPE,UUID,TARGET -T .
findmnt -no SOURCE,FSTYPE,UUID,TARGET -T /var/lib
systemctl show docker.service --property=MainPID --property=ActiveState --property=SubState
```

Se leyó `/usr/bin/dockerd-rootless.sh`, sin ejecutarlo. No ejecutar su
`--help` como si fuera una consulta inocua: el wrapper puede crear
RootlessKit antes de que dockerd procese la ayuda. Las consultas `--help`
ejecutadas arriba son las de los binarios, no las del wrapper.

### Cómo se separaría rootless y qué falta probar

Este diseño es **propuesto, no ejecutado**:

| Recurso | Docker existente | Constructor rootless propuesto |
| --- | --- | --- |
| Proceso | Servicio de sistema, PID 1422 | Nuevo proceso UID 1000; unidad de usuario con nombre exclusivo |
| Configuración | Configuración del Docker actual | JSON propio; no copiar ni editar `/etc/docker/daemon.json` |
| Datos Docker | `/var/lib/docker` | Directorio privado bajo `dist/lab-builder-4f23638/data` |
| Containerd | Socket/estado del sistema | Instancia y root/state/socket privados; no reutilizar `/run/containerd/containerd.sock` |
| Socket Docker | `/var/run/docker.sock` | `/run/user/1000/chromat-lab-4f23638/docker.sock` |
| Cliente/Buildx | Configuración actual del usuario | `DOCKER_CONFIG` privado, sin builder o contexto heredado |
| Tags | Tags de los servicios actuales | Namespace del nuevo daemon, aunque coincidan nombres oficiales |
| Red | Bridges del anfitrión y VMware | User/mount/net namespaces propios, sin red host ni puertos publicados |

Las opciones `--config-file`, `--data-root`, `--exec-root`, `--pidfile`,
`--host` y `--cgroup-parent` existen en el dockerd instalado.
Cambiar solo `--data-root` **no basta**: hay que verificar también el
containerd y sus directorios/socket.

El cliente de cada operación tendría `DOCKER_HOST` explícito y
`DOCKER_CONFIG` propio, sin `DOCKER_CONTEXT`, `BUILDX_BUILDER` o
`BUILDKIT_HOST` heredados. No usar `docker context use`, instalar la unidad
genérica `docker.service` del usuario o ejecutar el setuptool `install`.
Eso evita cambiar la selección del Docker de desarrollo.

Una consulta a un socket inexistente demostró que el cliente no cae
automáticamente al daemon actual:

```bash
env -u DOCKER_CONTEXT \
  DOCKER_HOST="unix://${HOME}/chromat/dist/lab-builder-4f23638/docker.sock" \
  docker version --format '{{json .Server}}'
```

Resultado esperado y observado: servidor `null`, exit `1`, error de conexión
solo a esa ruta privada. No se creó el socket ni su directorio.

La red rootless se propondría con host-loopback deshabilitado y
`DOCKERD_ROOTLESS_ROOTLESSKIT_DETACH_NETNS=false`, para poder verificar
directamente la separación del namespace de red del daemon.
No compartir el namespace de red del anfitrión, publicar puertos o tocar sus
reglas de firewall/rutas. Esto no constituye aislamiento total del anfitrión:
el kernel y los recursos físicos seguirían compartidos.

Serían obligatorios antes del primer pull/build:

- Confirmar PID, UID, sockets, root/state de Docker y containerd privados.
- Confirmar namespaces y comprobar que el daemon empieza sin imágenes,
  contenedores o volúmenes del Docker existente.
- Aplicar límites al conjunto daemon + containerd + BuildKit + empaquetador,
  no solo al proceso dockerd. Propuesta inicial: CPU equivalente a dos
  procesadores y RAM máxima de 4 GiB, sin swap del constructor.
- Verificar que el cgroup padre contiene también todos los procesos de build.
  `docker compose build --memory` no soluciona esto: su propia ayuda dice
  que no está soportado por BuildKit.
- Tener un límite de disco realmente exigible. Un directorio privado y un
  chequeo `df` no impiden que se llene el btrfs común.
- Verificar salida DNS/HTTPS dentro del nuevo namespace, no deducirla
  de la ruta del anfitrión. No se ha hecho esa prueba.

**Conclusión rootless:** existen los prerrequisitos básicos, pero no se ha
demostrado el funcionamiento ni la contención completa de recursos.
La cuota de disco no está verificada y la única red disponible es experimental.
No puedo prometer la separación adecuada solicitada ni autorizar el arranque
de ese constructor como si ya estuviera validado. No habilitar cuotas
globales btrfs ni instalar otra red para intentar repararlo automáticamente.

### Red observada y preservación

Se ejecutaron `ip -brief address`, `ip route`, `ss -ltn` y la consulta de
sockets Unix Docker/containerd. Se documentan aquí los roles de red con
prefijos anonimizados, sin copiar direcciones locales reales, identificadores
IPv6 públicos o el hostname público del equipo:

- VMware NAT: ejemplo `192.0.2.0/24`, vmnet8.
- VMware host-only: ejemplo `198.51.100.0/24`, vmnet1.
- Bridges Docker: `[PREFIJO_BRIDGE_1]`, `[PREFIJO_BRIDGE_2]`, `[PREFIJO_BRIDGE_3]`.
- La ruta del anfitrión no muestra el prefijo rootless habitual `10.0.2.0/24`.
  No demuestra conectividad dentro de un namespace que todavía no existe.

La suposición de nombre `chromat_default` devolvió `network not found`.
Se corrigió la consulta con
`docker inspect chromat-api-1 --format '{{json .NetworkSettings.Networks}}'`:
la API usa `chromat_internal`, en `[PREFIJO_BRIDGE_2]`.
No se creó una red para subsanar el nombre supuesto.

Fedora tiene sus propios servicios y publicaciones de desarrollo existentes;
no se configura como el Ubuntu de producción ni se afirma que solo publique 443.
La arquitectura futura de producción conserva únicamente Nginx en 443 y SSH
administrativo independiente.

### BusyBox: corrección de la interpretación inicial y bloqueo de contrato

Consultas locales sin pull/load:

```bash
docker image inspect busybox:1.36.1 \
  --format 'ID={{.Id}} Descriptor={{json .Descriptor}} RepoDigests={{json .RepoDigests}}'
docker image inspect --platform=linux/amd64 busybox:1.36.1 \
  --format 'ID={{.Id}} Arch={{.Architecture}} Descriptor={{json .Descriptor}}'
```

| Identificador | Resultado comprobado |
| --- | --- |
| Índice OCI | `.Id` y descriptor `73aaf090...`, coincide con índice fijado |
| Manifiesto linux/amd64 | `.Id` y descriptor `b7f3d86d...`, coincide con plataforma fijada |
| Config digest esperado | `b116e155...`, declarado en el repositorio; no es ninguno de esos `.Id` |

Los digests completos están registrados en la sección anterior.
El descriptor de plataforma declara Linux/amd64 y BusyBox 1.36.1-glibc.
La consulta directa de la referencia por digest había fallado por el nombre
local; **no demuestra que el manifiesto de plataforma esté ausente de la caché**.
La consulta `--platform` muestra que está disponible dentro del índice.

Por tanto, la diferencia inicial de `.Id` **no prueba corrupción o una imagen
incorrecta**: se estaban comparando clases diferentes de digest.
No se calculó independientemente el hash del JSON config bruto.

El checkout compara `.Id` con el config digest en
`package-artifacts.sh:87`, y repite esa exigencia en manifiesto/validadores.
Con el image store containerd observado, las consultas `.Id` anteriores no
devuelven ese config digest. Esta discrepancia debe resolverse antes del
empaquetado, sin sustituir digests o relajar checksums a ciegas.
No se ejecutó el empaquetador completo para reproducir su fallo: haría pulls,
builds y escrituras no autorizados.

Una nueva conexión SSH leyó solamente el log previo de preparación Ubuntu:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=yes -o UpdateHostKeys=no \
  -o ControlMaster=no -o ControlPath=none chromat-vm \
  "grep -E 'Storage Driver|driver-type|Docker Root Dir|containerd-snapshotter' \
  \$HOME/chromat-host-prep-4f23638/run-EJEMPLO-2/session.log"
```

El log Ubuntu también registra `overlayfs`,
`io.containerd.snapshotter.v1` y `/var/lib/docker`.
`preparation-pty.log` no era legible sin privilegios; no se cambiaron permisos.
No se ejecutó Docker o sudo en Ubuntu ni se modificó nada allí.

Forzar un image store clásico solo en el constructor para obtener otro `.Id`
no demostraría compatibilidad del paquete con el backend actual de Ubuntu.
La elección entre una corrección del contrato de identidad y una configuración
explícita compatible necesita otra decisión y autorización. No modificar el
checkout, configurar/reiniciar Docker Ubuntu o hacer commits para resolverlo
dentro de esta fase de planificación.

### Alternativa recomendada: VM de construcción dedicada

Propuesta, **no creada ni autorizada para aprovisionamiento**:

| Elemento | Diseño experimental |
| --- | --- |
| Nombre/rol | `chromatbuilder`, distinta de `servidor-ejemplo` |
| SO propuesto | Fedora Server 44 amd64, manteniendo el rol Fedora constructor |
| CPU/RAM | 2 vCPU y 4 GiB RAM |
| Disco | Nuevo VMDK dedicado de máximo 24 GiB; no añadirlo a Ubuntu |
| Capacidad física anfitrión | Reservar aproximadamente 35 GiB para VMDK, memoria, ISO y salida; revalidar los 63 GiB actuales |
| Red | vNIC nueva en el NAT vmnet8 existente, IP DHCP propia; no editar vmnet8 ni reenviar puertos |
| Docker/containerd | Servicios y almacenamiento exclusivos dentro de la nueva VM |
| API Docker | Solo socket Unix del invitado; no puerto TCP Docker |
| Acceso | SSH de administración del constructor; identidad/alias por definir |
| Carpetas compartidas | Deshabilitadas; no montar `/var/lib/docker`, `/var/lib/containerd`, sockets o checkout de Fedora |
| Snapshots | No crear cadenas de snapshots de construcción que anulen el presupuesto de disco |

El VMDK limita la capacidad del invitado; con un Docker propio, sus
contenedores, volúmenes y tags no pueden sustituir los del Fedora anfitrión.
Compartir hardware sigue implicando competencia por I/O y pérdida conjunta
ante fallo del anfitrión; la VM no es un backup independiente.
24 GiB es una estimación y límite experimental, no un dimensionamiento
productivo ni garantía de que cualquier build quepa. Si no cabe, detenerse y
consultar, no ampliar discos existentes.

El aprovisionamiento de esa VM se autorizaría aparte. No reutilizar el
aprovisionador de producción como constructor ni descargar/build en
`servidor-ejemplo`. Antes de arrancarla hay que revalidar memoria y espacio
disponibles; no usar los valores de esta muestra como reservas permanentes.

La fuente sería un checkout limpio del commit completo auditado.
Una opción posterior es transferir un Git bundle por SSH y clonarlo en el
constructor: excluye este documento no rastreado y preserva los metadatos Git
que necesita el empaquetador. Copiar un worktree sin su repositorio Git o
usar solo `git archive` no satisface ese requisito. El bundle no se creó.
Los scripts y la salida de empaquetado vivirían en el invitado para quedar
dentro de su límite de disco; entregar el TAR a Fedora requeriría espacio
y autorización de copia propios.

Antes de construir CHROMAT, una etapa separada tendría que comprobar
BusyBox y la compatibilidad de exportación/load/identidad en aislamiento.
Conservar `PULL_POLICY=never` en la salida de producción, cuatro imágenes
Compose y la auxiliar BusyBox, seis servicios y migraciones 001-016.
No ejecutar Compose up, cargar nada en Ubuntu, generar secretos/TLS,
publicar releases o hacer commits/push como parte del constructor.

**Plan cerrado, ejecución bloqueada:** recomiendo la VM dedicada por la
contención más clara de kernel, disco y estado Docker. Primero debe decidirse
cómo resolver el contrato BusyBox; la creación/provisión de la VM, sus
descargas y las pruebas de imágenes necesitan autorizaciones explícitas.

## BusyBox: identidad verificada sin descargar ni crear la VM

El usuario aceptó el diseño de VM Fedora dedicada, sujeto a resolver primero
BusyBox. Autorizó investigar y presentar una verificación confiable, no crear
la VM, descargar, instalar o construir.

### Prueba ejecutada y resultado

Se leyó una exportación del BusyBox ya disponible en el daemon Fedora.
`docker image save --platform=linux/amd64` envió el TAR directamente al
verificador en memoria: no se guardó un TAR, no se extrajeron archivos al
filesystem ni se ejecutó `docker load`, pull o build.
No se creó un contenedor para verificarlo.

El verificador usó como referencia los digests fijados previamente en el
checkout auditado, **no hashes derivados del mismo archivo como expectativa**.
Hash de bytes JSON originales, no de JSON reformateado. Comando ejecutado:

```bash
set -o pipefail
docker image save --platform=linux/amd64 busybox:1.36.1 | python3 -c '
import hashlib
import json
import re
import sys
import tarfile

expected_platform = "b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f"
expected_config = "b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d"
metadata = {}
blobs = {}
size_total = 0
with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as archive:
    for member in archive:
        size_total += member.size
        if size_total > 256 * 1024 * 1024:
            raise SystemExit("STOP: exportacion supera el limite de lectura")
        name = member.name.removeprefix("./")
        match = re.fullmatch(r"blobs/sha256/([0-9a-f]{64})", name)
        if not match or not member.isfile():
            continue
        digest = match.group(1)
        stream = archive.extractfile(member)
        hasher = hashlib.sha256()
        chunks = []
        keep = digest in (expected_platform, expected_config)
        if keep and member.size > 1024 * 1024:
            raise SystemExit("STOP: JSON de identidad excede el limite")
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            hasher.update(chunk)
            if keep:
                chunks.append(chunk)
        actual = hasher.hexdigest()
        if actual != digest:
            raise SystemExit("FAIL: bytes de blob no coinciden con su digest: " + digest)
        blobs[digest] = member.size
        if keep:
            metadata[digest] = json.loads(b"".join(chunks))
if expected_platform not in metadata or expected_config not in metadata:
    raise SystemExit("STOP: formato/contenido no permite comprobar los dos JSON esperados")
manifest = metadata[expected_platform]
config_descriptor = manifest.get("config", {})
if config_descriptor.get("digest") != "sha256:" + expected_config:
    raise SystemExit("FAIL: manifiesto no referencia el config digest fijado")
if config_descriptor.get("size") != blobs[expected_config]:
    raise SystemExit("FAIL: tamano del config no coincide con el descriptor")
config = metadata[expected_config]
if config.get("os") != "linux" or config.get("architecture") != "amd64":
    raise SystemExit("FAIL: plataforma del config no es linux/amd64")
layers = manifest.get("layers", [])
if not layers:
    raise SystemExit("FAIL: manifiesto sin capas")
for layer in layers:
    digest = layer.get("digest", "").removeprefix("sha256:")
    if digest not in blobs or blobs[digest] != layer.get("size"):
        raise SystemExit("FAIL: capa ausente o tamano incorrecto")
print("PASS: SHA256 JSON manifiesto = sha256:" + expected_platform)
print("PASS: SHA256 JSON config = sha256:" + expected_config)
print("PASS: manifiesto referencia ese config; config linux/amd64")
print("PASS: %d capas verificadas por digest y tamano" % len(layers))
print("PASS: %d blobs verificados; %d bytes de contenido leidos sin extraer ni guardar" % (len(blobs), size_total))
'
```

Resultado real, exit `0`:

```text
PASS: SHA256 JSON manifiesto = sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f
PASS: SHA256 JSON config = sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d
PASS: manifiesto referencia ese config; config linux/amd64
PASS: 1 capas verificadas por digest y tamano
PASS: 6 blobs verificados; 2211651 bytes de contenido leidos sin extraer ni guardar
```

**La caché contiene el BusyBox fijado y su config esperado.**
La discrepancia no era una imagen equivocada: `.Id` identificaba un índice
o manifiesto OCI, no los bytes del JSON config. El pin `b116e155...` no debe
reemplazarse por `73aaf090...` ni `b7f3d86d...`.

Esta prueba acredita identidad/integridad respecto a los pins del checkout.
No es una firma de imagen, no verifica una asignación actual del tag mutable
en Docker Hub y no sustituye la confianza en el baseline auditado.
La prueba está limitada al formato OCI exportado que realmente se observó;
no se afirma soporte probado para un archivo Docker clásico.

### Resultado que permitiría continuar

La prueba de identidad requerida ya es **PASS**: SHA del manifiesto de
plataforma fijado, referencia al config fijado, SHA de sus bytes,
Linux/amd64 y todos los blobs de capas referenciados íntegros.
Eso resuelve la duda sobre la imagen disponible y permite mantener el
diseño de VM aceptado, **sin autorizar su creación automáticamente**.

Sigue pendiente que el procedimiento trate correctamente esa identidad:

- `package-artifacts.sh` y los validadores actuales exigen que `.Id` sea el
  config digest. No ejecutarlos tal cual sobre el backend observado para
  intentar que pasen después de haber construido el resto.
- Elegir una corrección explícita del contrato de identidad, o un backend
  compatible documentado en constructor **y** destino. Ambas opciones necesitan
  autorización propia; no modificar Docker Ubuntu ni el código en esta fase.
- Con una solución acordada, probar exportación y load en aislamiento con el
  backend objetivo, y volver a obtener el mismo config digest y Linux/amd64.
  Esta prueba de ida/vuelta no se ejecutó: requiere creación/carga de imágenes
  y un constructor aislado autorizado.
- Exigir PASS real del empaquetador, validación estática y semántica del
  paquete completo antes de transferirlo a producción. Un PASS de hashes de
  BusyBox no aprueba los dos paquetes antiguos ni las otras cuatro imágenes.

Una solución portable debe separar config digest de ID nativo del daemon.
Para OCI puede verificar la cadena de blobs probada aquí; para un archivo
Docker clásico tendría que verificar el JSON config y los hashes de las capas
sin asumir que existe el manifiesto OCI original. Debe rechazar bytes
alterados, config incorrecto, capas ausentes y plataforma equivocada.
No aceptar solo un tag, un label o un `.Id` convertido artificialmente por
un wrapper.

Se mantiene `PULL_POLICY=never` en el futuro despliegue Ubuntu y no se altera
ninguna de las seis aplicaciones existentes de Fedora. No hubo commits,
push, releases, VM creada, instalaciones, descargas o builds en esta fase.

## Corrección local autorizada de identidad de imágenes

Autorización recibida: corregir empaquetador y validadores, mantener pins y
verificar bytes de manifiesto/config/capas, añadir pruebas y presentar el diff.
No autoriza daemon Fedora, descargas, builds, VM, commits o push.

### Cambio implementado, no desplegado

- Nuevo `scripts/lib/image-identity.py`: lee el TAR OCI sin extraerlo,
  calcula SHA-256 de cada blob, exige el manifiesto y config fijados,
  comprueba sus referencias/tamaños, Linux/amd64, capas, índice y enlace del
  tag operativo. Rechaza duplicados, links, archivos especiales y contenido
  que no corresponde al pin; limita lectura a 256 MiB y profundidad de índices.
- `package-artifacts.sh`: reemplaza la comparación incorrecta
  `.Id == config_digest` por la comprobación de la identidad del TAR.
  Conserva `id` nativo y `config_digest` separados. Los tres pins no cambian.
- `verify-artifacts.sh`: exige incluir la biblioteca y verifica los bytes
  BusyBox sin Docker, además de estructura, configuración y checksums.
  Un TAR diferente se rechaza aunque se recalculen los checksums del paquete.
- `verify-image-artifacts.sh`: antes de cualquier load verifica los bytes
  BusyBox; tras load exige IDs/arquitectura y reexporta a un temporal privado
  para comprobar nuevamente el contenido cargado. El temporal se elimina
  tanto al finalizar como ante error; no escribe sobre el paquete.
- Se actualizó `docs/deployment/artifacts.md` para distinguir las identidades
  y documentar el requisito de exportación OCI.

Se preserva la comparación del ID nativo cargado con el ID registrado para
las cinco imágenes. Aunque sea diferente del config digest, no se permite
cambiar silenciosamente de representación nativa entre constructor y destino:
el precheck de backup depende de esa igualdad. No se modificó `backup.sh`.
Las otras cuatro imágenes mantienen su contrato previo; no se les impone
el pin de BusyBox.

Las exportaciones Docker clásicas sin el manifiesto OCI original fijado
**se rechazan**, en vez de omitir ese pin. Es una restricción explícita para
mantener la prueba de bytes solicitada, no compatibilidad universal con todos
los backends Docker. Un índice multi-arquitectura puede referenciar plataformas
no incluidas por `save --platform`; solo se recorre Linux/amd64, exigiendo
todos sus blobs y rechazando que el manifiesto fijado se declare como otra
plataforma.

### Pruebas locales y alcance

Las pruebas usan un TAR sintético pequeño y un ejecutable Docker falso en
PATH. Sus pins sintéticos se sustituyen **solo en copias temporales de la
biblioteca**, nunca en producción ni mediante una variable que el operador
pueda utilizar para relajar los pins. También se prueba que la biblioteca con
pins reales rechaza la imagen sintética.

Los tests existentes de artefactos se adaptaron a TAR OCI sintético, incluyendo
la copia/transferencia de prueba y validaciones de entorno existentes.
Los certificados y secretos de esos tests son fixtures temporales locales,
no certificados o secretos del laboratorio Ubuntu.

Comandos de validación ejecutados en Fedora, dentro del checkout:

```bash
export PYTHONDONTWRITEBYTECODE=1
python3 tests/image-identity.test.py
bash tests/image-artifacts.test.sh
bash tests/artifacts.test.sh
bash -n scripts/package-artifacts.sh scripts/verify-artifacts.sh \
  scripts/verify-image-artifacts.sh tests/artifacts.test.sh \
  tests/image-artifacts.test.sh
git diff --check
```

Casos cubiertos: ID de manifiesto/índice distinto de config digest,
alteraciones de blobs y manifiesto rehasheado, capas ausentes, config/plataforma
incorrectos, tag que apunta a otro config, tamaño de descriptor incorrecto,
plataforma del pin mal declarada, exportación con otras arquitecturas omitidas
y rechazo cerrado de TAR clásico.
La prueba con Docker simulado cubre también arquitectura BusyBox incorrecta,
ID nativo cambiado, exportación posterior al load corrupta y rechazo del TAR
corrupto **antes de cualquier load**.

Primeras validaciones: PASS de identidad (7 casos inicialmente, 9 tras ampliar
casos), contratos de imagen/artefactos y sintaxis; no se observaron fallos.
Los resultados finales tras completar todos los casos se registran al cierre.
ShellCheck no estaba disponible y no se instaló.

### Pendiente y límites de autorización

No se invocó el Docker real ni se consultó su estado durante esta corrección;
no se accedió a Ubuntu. No se ejecutó el empaquetador ni se construyó un paquete
CHROMAT; los TAR generados son exclusivamente fixtures de tests.
La VM Fedora aceptada sigue sin crear.

Queda pendiente verificar en un constructor aislado real el formato exacto
de exportación, carga/reexportación, igualdad del ID nativo y los cinco TAR,
seguido del empaquetador completo y sus validaciones. Los tests simulados
no acreditan esos resultados externos. No cambiar backends ni reiniciar
Docker Ubuntu para hacer pasar el contrato.
El checkout ahora tiene cambios autorizados de código y este registro no
rastreado: sigue bloqueado por el requisito de árbol limpio del empaquetador.
Una futura fuente experimental deberá incluir estas correcciones con una
procedencia verificable y autorización propia; un bundle de HEAD sin ellas
no contiene el arreglo. No se hicieron commits para resolver ese bloqueo.
Se conservan `PULL_POLICY=never`, seis servicios, cuatro imágenes Compose más
BusyBox auxiliar y migraciones 001-016.

Cierre de validación local:

```text
python3 tests/image-identity.test.py: 11 tests, OK
bash tests/image-artifacts.test.sh: PASS
bash tests/artifacts.test.sh: PASS
bash -n (scripts y tests Bash modificados): PASS
git diff --check: PASS
```

Se revisó y mostró el diff completo de los seis archivos rastreados cambiados
y de la biblioteca y dos archivos de prueba nuevos. Solo cambia código de
artefactos, sus pruebas y documentación. Se comprobaron cleanup de temporales,
rechazo previo al load y dependencias del ID en backup.
No quedaron directorios `__pycache__` en `scripts/lib` o `tests`.
Los fixtures temporales se eliminaron por los traps de tests.
Este resultado queda sujeto a revisión del usuario antes de autorizar la
creación/provisión del constructor aislado o ejecutar pruebas con Docker real.

## Revisión técnica y plan de continuación, 2026-11-25

El usuario solicitó revisar el diff completo, seguir BusyBox hasta backup,
comprobar procedencia de cambios sin commit y proponer las cinco etapas
siguientes. No autorizó crear VM, descargar, construir, transferir o hacer
commits/push. Esta etapa solo inspecciona, ejecuta tests locales y documenta.
No se corrigen automáticamente los hallazgos identificados.

### Standards

Revisión independiente de estándares sobre el diff local contra
`4f23638dd77fe23fc0788fdeea1f4e290bb37b63`, incluidos los tres archivos nuevos.
Fuentes: `AGENTS.md`, documentación de agentes, glosario y ADR-0008.
No se encontraron infracciones documentadas ni smells significativos.

### Spec

Dos hallazgos relevantes:

1. **Índice OCI ambiguo aceptado, prioridad alta.**
   `scripts/lib/image-identity.py:97-125` acepta un índice si alguna rama
   alcanza el manifiesto fijado. Otra entrada seleccionable Linux/amd64 puede
   apuntar a otro config y seguir aceptándose el índice como ID.
   El `manifest.json` fijado no elimina la ambigüedad del `index.json`.
   Contradice la exigencia de no relajar integridad/plataforma.
   Deben rechazarse todas las ramas operativas alternativas no fijadas,
   incluidos índices anidados, sin confundirlas con arquitecturas extranjeras
   omitidas por una exportación de plataforma.
2. **Procedencia local aún no admitida por el empaquetador.**
   `scripts/package-artifacts.sh:38-42` sigue exigiendo checkout limpio, y el
   manifiesto registra `git_commit=HEAD`. No puede empaquetar este WORKTREE.
   Actualmente no hay falsa atribución porque aborta. Quitar solamente el
   guard de limpieza produciría una identificación insuficiente del origen.

Resumen por eje: Standards, 0 hallazgos; Spec, 2, siendo el índice ambiguo
el más grave de ese eje. **La corrección no está aprobada para construir.**

#### Reproducción del índice ambiguo, sin Docker

Se ejecutó el siguiente comando. El TAR y los pins sintéticos viven únicamente
en memoria. No cambia constantes del checkout ni usa un daemon.

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -B - <<'PY'
import hashlib
import json
import runpy

helper = runpy.run_path('scripts/lib/image-identity.py', run_name='identity_review')
fixtures = runpy.run_path('tests/image-identity-fixture.py', run_name='fixture_review')
data, pins = fixtures['fixture']()
verify = helper['verify']
verify.__globals__.update(pins)
def add_blob(value):
    content = json.dumps(value, separators=(',', ':')).encode()
    digest = 'sha256:' + hashlib.sha256(content).hexdigest()
    data['blobs/sha256/' + digest[7:]] = content
    return {'digest': digest, 'size': len(content)}
platform_path = 'blobs/sha256/' + pins['PLATFORM_DIGEST'][7:]
original_manifest = json.loads(data[platform_path])
other_config = add_blob({'os': 'linux', 'architecture': 'amd64', 'config': {'Cmd': ['false']}})
other_manifest = add_blob({'schemaVersion': 2, 'config': other_config, 'layers': original_manifest['layers']})
other_manifest['platform'] = {'os': 'linux', 'architecture': 'amd64'}
pinned_manifest = {'digest': pins['PLATFORM_DIGEST'], 'size': len(data[platform_path]), 'platform': {'os': 'linux', 'architecture': 'amd64'}}
ambiguous_index = add_blob({'schemaVersion': 2, 'manifests': [other_manifest, pinned_manifest]})
ambiguous_index['annotations'] = {'io.containerd.image.name': 'docker.io/library/busybox:1.36.1', 'org.opencontainers.image.ref.name': '1.36.1'}
data['index.json'] = json.dumps({'schemaVersion': 2, 'manifests': [ambiguous_index]}).encode()
result = verify(fixtures['archive'](data))
accepted = ambiguous_index['digest'] in result['ids']
print('Unpinned amd64 manifest:', other_manifest['digest'])
print('Altered index accepted as daemon ID:', accepted)
print('Index differs from pinned index:', ambiguous_index['digest'] != pins['INDEX_DIGEST'])
assert accepted, 'La reproduccion ya no acepta el indice ambiguo'
PY
```

Resultado real:

```text
Unpinned amd64 manifest: sha256:1a9b620eb31a3709eb3719dec9a5650f487785347e913fdf537b10458661d144
Altered index accepted as daemon ID: True
Index differs from pinned index: True
```

Esto demuestra la aceptación incorrecta, **no** qué rama ejecutaría Docker
en un load/backup real. La corrección debe convertirlo en un test negativo
que espere rechazo. Los once tests actuales pasan y no cubren ese caso.

#### Empaquetado, carga y backup

El empaquetado exporta BusyBox y verifica los blobs; la validación semántica
vuelve a exportarla tras load. Ambos dependen del helper con el defecto
anterior. `backup.sh:131-146` inspecciona ID/arquitectura por tag y aborta si
no coinciden con el manifiesto, antes de mantenimiento/estado.
`backup.sh:228-231` y `268-274` ejecutan BusyBox por ese tag, para inventario
y TAR de raw. La igualdad de un ID de índice ambiguo no distingue sus ramas:
el precheck de backup no compensa el defecto del helper.
Con un índice exclusivo validado, la igualdad nativa se conserva como
guard operativo. No se presenta el backup como probado con Docker real.
Los dos `docker run` auxiliares de backup no incluyen `--pull=never`.
El inspect previo normalmente detecta ausencia, pero no elimina una carrera
si otro proceso cambia/elimina el tag. Antes de la prueba offline deben
acordarse un guard explícito revisado o controles que impidan descargas del
daemon y cambios concurrentes de tags. No se modifica backup en esta revisión.

#### Bloqueo adicional preexistente, no introducido por el diff

Al planificar la instalación y el backup se comprobó una incompatibilidad:

```bash
git show HEAD:scripts/package-artifacts.sh | grep -n -F 'cp -- db/migrations'
git show HEAD:compose.yaml | grep -n -F './db/migrations'
git show HEAD:scripts/backup.sh | grep -n -F 'db/migrations'
```

El baseline y el script actual copian SQL a `package/db/*.sql`, pero Compose
monta `package/db/migrations` y backup empaqueta `db/migrations`.
Sin alinear esas rutas, un paquete no demuestra inicialización de migraciones
ni backup de configuración correcto. Los tests actuales verifican SQL
aplanado y usan fixtures, no el arranque real. Debe resolverse antes de generar
un paquete candidato, con autorización para una corrección acotada y tests
del contrato de rutas. No se modificaron esos archivos en esta revisión.

### Identidad de la fuente sin commit: comprobación local y diseño

Se calcularon en memoria el patch binario de los seis archivos rastreados
modificados y los tres nuevos, sus hashes/modos y el árbol Git efectivo.
El registro no rastreado del laboratorio y las salidas ignoradas se excluyen
del parche de código. Ningún bundle, índice, objeto Git, patch en disco,
snapshot o commit fue creado.

| Identificador del estado revisado, todavía rechazado | Valor |
| --- | --- |
| Commit baseline | `4f23638dd77fe23fc0788fdeea1f4e290bb37b63` |
| Tree baseline | `b349036d98f36434d9a15cd92bb6c0e1c1d9c5cb` |
| Tree efectivo de fuente | `95310a91acb4a46b25cd4aa9cfbe9b86ba393516` |
| SHA-256 del patch | `32daeb97da7d31191f7280ed8aac9f3250d3e9e860185049c8ffe1014ac02cc0` |
| SHA-256 del mapa canónico de nueve archivos/modos/hashes | `f0c8aed8b1670d82bb8126a05c054b44f6abd6468cce0fb7eeab462e61ea7875` |

La comprobación ejecutada generó el patch mediante
`git diff --binary HEAD -- <seis rutas revisadas>` y
`git diff --no-index --binary -- /dev/null <cada archivo nuevo>`, y pasó sus
bytes por `git apply --reverse --check -`: **PASS**, sin aplicar el patch.
La reconstrucción Python del tree a partir de `git ls-tree -rz HEAD` produjo
exactamente el tree baseline de `git rev-parse HEAD^{tree}`; sustituyendo
los nueve blobs/modos actuales produjo el tree efectivo distinto.
Los SHA-256 se calcularon sobre los bytes del patch y sobre JSON canónico
ordenado de rutas, modos y SHA-256 del contenido, no sobre un nombre de versión.
La aplicación forward sobre una copia limpia aún no se ejecutó.

**Es posible identificar la fuente sin un commit**, pero el empaquetador
actual no admite empaquetarla. La modalidad propuesta, todavía no implementada,
es `source_kind=baseline-plus-local-patch`, con `base_git_commit`, tree
efectivo, patch SHA-256 y mapa de fuente completo verificado.
El manifiesto experimental debe dejar claro que no existe un commit efectivo
para ese contenido; una opción es `git_commit=null` y baseline en su campo
propio. Los metadatos no deben atribuir los bytes corregidos al baseline.
La semántica exacta y todos los lectores de manifiesto deberán probarse.

El modo limpio normal se conserva. Una excepción experimental no puede ser
un `ALLOW_DIRTY=1` sin validación: deberá aceptar exclusivamente los cambios
aprobados, rechazar archivos/deltas adicionales y verificar también todos los
archivos no cambiados contra el baseline. `.env` y secretos quedan fuera;
se usará `.env.example`. La evidencia de origen y sus hashes se incluirán
en el paquete y en el manifiesto externo, con checksums.
Los hashes prueban integridad respecto al registro conocido, no una firma
del commit o del autor.

Tras cualquier reparación se deben recalcular estos identificadores:
**los hashes anteriores no aprueban una futura versión reparada**.
La transferencia posterior podrá usar baseline Git bundle más overlay
identificado o una exportación de fuente validada por el nuevo modo.
Ninguno fue creado o transferido. Un bundle de HEAD solo no contiene el arreglo.

### Recursos revalidados para planificar, no reservas

Comandos ejecutados en Fedora, sin Docker:

```bash
nproc
free -h
df -hT .
uptime
command -v vmware
command -v vmrun
ip -brief address
ip route
find . -maxdepth 3 -type f \( -iname '*.iso' -o -iname '*.vmdk' -o -iname '*.vmx' \) -print
```

Resultado: 16 CPU lógicas, aproximadamente 10 GiB RAM disponibles de 30 GiB,
63 GiB libres en btrfs; VMware y vmrun existen. vmnet8 sigue en
`192.0.2.0/24` como ejemplo anonimizado. No se encontraron ISO/VMX/VMDK en esa
búsqueda limitada al
checkout; no se afirma su ausencia en el equipo. No se inspeccionaron otras
VM ni archivos de otros usuarios.

### Plan por etapas: todo lo siguiente está pendiente

#### Prerrequisito 0: cerrar los hallazgos locales

Requiere autorización de cambios de código, distinta de crear la VM:
rechazar índices ambiguos con test negativo; añadir procedencia experimental
identificable; alinear migraciones con Compose y backup y cubrir esas rutas.
Mantener pins, topología, volúmenes, política offline y checksums.
Después revisar diff y ejecutar tests sin Docker real.
No comenzar construcción de CHROMAT hasta aprobar esa revisión.

#### 1. VM Fedora de construcción aislada

**Intervención del usuario:** creación en VMware y disponibilidad de consola.
**Autorizaciones separadas:** descargar ISO/verificadores, crear VM/VMDK,
instalar Fedora y después paquetes/repositorio Docker.

Diseño: Fedora Server 44 amd64, `chromatbuilder`, 2 vCPU, 4 GiB RAM,
VMDK nuevo limitado a 24 GiB, vNIC NAT en vmnet8 existente, sin reenvío de
puertos ni carpetas/sockets compartidos. No modificar VM Ubuntu, redes VMware,
Docker de Fedora, discos existentes o snapshots. Presupuesto inicial:
aproximadamente 35 GiB físicos para VMDK, ISO, estado y salida.
Los 63 GiB actuales no garantizan capacidad futura; detenerse si falta espacio.
Antes de arrancar, revisar de nuevo RAM disponible para alojar 4 GiB sin
presionar los servicios existentes. El VMDK limita el invitado, no todo el
I/O ni los ficheros externos/snapshots en el anfitrión.

Descargas previstas y **no realizadas**: ISO Fedora Server desde origen
oficial, CHECKSUM firmado y clave Fedora verificada; paquetes Fedora;
configuración, clave RPM y paquetes del repositorio oficial Docker Fedora.
Verificar firma CHECKSUM y SHA-256 de la ISO antes de instalar.
La clave RPM Docker no es la clave APT verificada para Ubuntu:
debe verificarse origen HTTPS y huella oficial RPM antes de importarla.
No aceptar una nueva clave solo porque coincida con una descarga del mismo
canal sin una referencia de confianza revisada.

Comandos propuestos, solo dentro de la nueva VM tras aprobar origen:

```bash
cat /etc/os-release
uname -m
timedatectl
df -hT /
ip route
sudo dnf install ca-certificates curl gnupg2 dnf-plugins-core git python3 \
  openssl age tar gzip
curl --fail --location -o docker-ce.repo \
  https://download.docker.com/linux/fedora/docker-ce.repo
curl --fail --location -o docker-rpm.asc \
  https://download.docker.com/linux/fedora/gpg
gpg --show-keys --with-fingerprint docker-rpm.asc
grep -E '^\[|^baseurl=|^gpgcheck=|^gpgkey=' docker-ce.repo
# DETENERSE hasta comparar la huella con la referencia oficial aprobada.
# Solo después de esa comprobación y autorización de configurar el repositorio:
sudo rpm --import docker-rpm.asc
sudo install -o root -g root -m 0644 docker-ce.repo \
  /etc/yum.repos.d/docker-ce.repo
sudo dnf install docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker version
sudo docker compose version
sudo docker info
sudo docker image ls
sudo docker ps -a
```

SSH: crear identidad/alias propio `chromat-builder` y comprobar huella por
consola antes de conectarse; no reutilizar automáticamente la identidad de
Ubuntu ni ignorar host-key checking. No abrir API Docker por TCP.
Todo sudo se autentica manualmente en la VM, sin solicitar contraseña al agente.
No configurar firewalld ni SELinux a ciegas: comprobar su estado y preservar SSH;
cualquier cambio necesita aprobación específica.

Salida exigida: sistema/clock/red verificados, Docker vacío y activo,
containerd/socket/data-root exclusivos del invitado, límites VMware aplicados
y conexión SSH nueva. Ningún build, tag o volumen del Fedora anfitrión
estará compartido. Ante error, parar y registrar cambios parciales, no reparar
ni reinstalar automáticamente.

#### 2. BusyBox: prueba real de exportación/carga en el constructor

Requiere prerrequisito 0 aprobado, VM preparada y autorización para pull
de la referencia fijada, transferencia del helper/tests revisados,
tag local, exportación y load **solo allí**.
No construir las aplicaciones todavía.

Comandos propuestos dentro de `chromatbuilder`, con helper reparado y
hash de fuente comprobado:

```bash
sudo docker pull --platform=linux/amd64 \
  docker.io/library/busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f
sudo docker tag \
  docker.io/library/busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f \
  busybox:1.36.1
sudo docker image inspect busybox:1.36.1
sudo docker image save --platform=linux/amd64 -o /ruta/prueba/busybox.tar \
  busybox:1.36.1
python3 /ruta/fuente/scripts/lib/image-identity.py /ruta/prueba/busybox.tar
```

Para una carga realmente independiente, usar una segunda instancia vacía
**dentro del invitado**, con configuración, data-root, containerd root/state,
pidfile y socket privados, sin compartir la instancia de construcción.
Su preparación y permisos se detallarán y aprobarán antes de arrancarla.
No basta cargar encima del mismo tag existente. Capturar ambos IDs nativos,
helper, config pin, plataforma y hashes de capas; cargar, reexportar y
volver a verificar bytes. Una ejecución auxiliar `--pull=never --network none`
podrá comprobar BusyBox, únicamente en ese entorno, tras validar identidad.

Salida exigida: PASS de bytes, rechazo real del caso ambiguo por el helper,
igualdad de ID nativo usada por backup y contenido correcto tras load.
El backend debe corresponder al observado en Ubuntu; no cambiar Ubuntu para
ocultar una incompatibilidad. Si el ID cambia o faltan blobs/manifiesto OCI,
detenerse y documentar, no sustituir pins o aceptar TAR clásico silenciosamente.

#### 3. Paquete offline con fuente local identificada

Requiere identidad real BusyBox satisfactoria, source mode implementado y
revisado, contrato de migraciones reparado, versión experimental decidida,
espacio suficiente y autorización para transportar fuente, pull/build/save
en la VM y exportar sus resultados. No hay tag/commit/release/push.

Transportar baseline y overlay aprobados con hashes esperados por un canal
SSH verificado. Aplicar el patch solo sobre baseline limpio en el constructor;
verificar tree efectivo, todos los archivos/modos y exclusión de secretos.
Ejecutar de nuevo los tests locales allí. Registrar `baseline` y
`local modifications` separadamente en la salida.

El comando del empaquetador se concretará cuando exista el modo de fuente
experimental aprobado; **el comando actual no sirve con estos cambios**.
No se documenta un flag inexistente como procedimiento ejecutable.
Seleccionar expresamente `.env.example`, salida nueva y versión que no
sobrescriba los paquetes antiguos. El empaquetador descargará terceros/bases
necesarios y construirá API/inferencia en el constructor; workers comparten API.
Verificar las cinco exportaciones, no solo BusyBox.

Comandos de validación propuestos:

```bash
scripts/verify-artifacts.sh "$PACKAGE_DIR"
scripts/verify-image-artifacts.sh "$PACKAGE_DIR"
sha256sum --check "$ARTIFACT_ROOT/chromat-$VERSION.tar.gz.sha256"
```

Validar también igualdad de manifiesto externo/interno, source attestation,
Linux/amd64, cuatro imágenes Compose más BusyBox, SQL 001-016 en rutas que
realmente consumen Compose/backup, modelo y `PULL_POLICY=never`.
Antes de aprobar entrega, efectuar una prueba de inicialización en el
constructor con configuración/secretos sintéticos aprobados, sin publicar
puertos del anfitrión ni usar secretos productivos. Ese smoke necesita su
propia autorización de contenedores/volúmenes de prueba.
Conservar logs y hashes; no publicar los activos en GitHub.

#### 4. Transferencia e instalación experimental en Ubuntu

Subetapas con autorizaciones independientes:
transferencia/staging; carga de imágenes; secretos/TLS/config; control de
red/firewall; creación de volúmenes/migraciones/arranque y apertura HTTPS.
La autorización de construcción no cubre ninguna de ellas.

Antes de transferir: revalidar SSH y huella, espacio de raíz y el backup
existente, ausencia de instalación/volúmenes y fuente aprobada. No modificar
discos/fstab ni restaurar snapshots. Si ya hay datos, no tratar como
instalación inicial.

Fedora/constructor: copiar por SSH solo paquete/manifiesto/checksums aprobados
a staging Ubuntu, con destino y permisos definidos. Ubuntu:
comprobar checksum antes de extraer, comparar manifiestos y verificar
contenido/source attestation antes de cargar los cinco TAR. No usar enlaces
`dist/artifacts/active` de Fedora como enlaces productivos.

Custodio fuera de Ubuntu: generar/administrar secretos y TLS. Ubuntu recibe
secretos de servicio, destinatario público age y tres archivos TLS permitidos;
nunca identidad privada age o clave privada CA. Instalar permisos según
runbooks con autorización; no copiar `.env` de desarrollo.

Usar el proyecto `chromat`, configuración productiva explícita y los volúmenes
`chromat_db_data`/`chromat_raw_data`. Comandos propuestos tras controles,
no para ejecutar ahora:

```bash
sudo docker compose --project-name chromat --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" config
sudo docker compose --project-name chromat --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" \
  up -d --no-build --pull never
```

  Redactar cualquier credencial que aparezca en configuración/logs; no registrar
  contenido de secretos, claves privadas ni un volcado sin revisar de `config`.
No ejecutar `ensure_https_blocked` del runbook hasta autorizar su cambio UFW.
Mantener consola VMware y dos SSH; proteger SSH y verificar una conexión nueva.
Docker puede eludir UFW: resolver un mecanismo efectivo de bloqueo de 443
antes del arranque y exigir prueba externa BLOCKED, no solo un listado UFW.
No abrir HTTPS hasta readiness, migraciones, TLS y smoke aprobados.
Los enlaces se manejan bajo lock/estado del runbook de promoción, no a mano.
Un error detiene el flujo; cualquier reparación/rollback se propone aparte.

#### 5. Servicios, persistencia, backup y restore

Requiere instalación aprobada y autorizaciones para datos de prueba,
recreación/reinicio de servicios, backup que pausa workers y restauración en
otro host. Custodia y prueba externa TLS/HTTPS requieren intervención humana.

Comprobar los seis servicios, readiness, Nginx/TLS sin `--insecure`,
001-016 aplicadas, exposición únicamente Nginx 443 más SSH administrativo,
smoke y limpieza de datos sintéticos sin alertas reales.
Tras una recreación aprobada, demostrar persistencia de un registro/raw
controlado y su hash en los volúmenes correctos; no usar `down -v`.
Un reinicio de VM necesita autorización y prueba SSH/servicios posterior.

Comando de backup propuesto en Ubuntu:

```bash
sudo /srv/chromat/active/scripts/backup.sh \
  --config /etc/chromat/production.env --mode full
```

Medir duración, espacio temporal en `/srv/chromat/backups` y copia al filesystem
independiente `/mnt/chromat-backups`, comprobar checksums y guard de identidad
BusyBox antes de mantenimiento. Los 40 GiB del disco existente no garantizan
retención productiva o siete cadenas; tampoco protegen pérdida del anfitrión.

Para restaurar, usar un host aislado; se puede reutilizar la VM de construcción
solo después de congelar/verificar el paquete y cesar todos los builds.
No reempaquetar fuente con material de restore. Esa reutilización, copia del
backup cifrado/configuración y montaje temporal de identidad privada age
del custodio requieren autorización propia. Nunca usar la identidad age
en Ubuntu productivo. Configuración, red y volúmenes restore deben ser propios;
el backup se monta/copia en modo solo lectura.

Comando propuesto en el host aislado:

```bash
sudo /ruta/release/scripts/verify-backup.sh \
  --config /ruta/restore/restore.env \
  --identity-file /media/custodian/backup-age-identity \
  /ruta/backup/FECHA-FULL
```

`verify-backup.sh` realmente importa SQL en MariaDB sin red y valida
migraciones/raw/hashes, pero elimina el entorno al terminar: no restaura una
instancia CHROMAT permanente ni arranca los seis servicios.
Su `docker run` tampoco especifica `--pull=never`: exigir imágenes precargadas
y egress del daemon deshabilitado en el host restore, o revisar ese guard con
autorización antes de la prueba offline. `--network none` de un contenedor
por sí solo no impide un pull del daemon.

Distinguir dos resultados: verificación de recuperación SQL/raw y, si se
requiere recuperación funcional completa, un restore adicional a volúmenes
nuevos con override explícito de nombres/puertos/secretos y smoke de los seis
servicios. Ese procedimiento aún no existe como `restore.sh`; no inventar
un comando ni afirmar que `Backup verified` prueba la aplicación completa.
`--project-name` distinto no basta para aislar los volúmenes con nombres
explícitos del Compose canónico; deben sustituirse esos nombres en el override.
El diseño detallado se revisará/aprobará antes de ejecutarlo.
Full más incremental es una subprueba posterior, no garantía previa de cadenas.

### Resultados actuales y autorizaciones

Checks locales repetidos:

```text
python3 tests/image-identity.test.py: 11 tests, OK
bash tests/image-artifacts.test.sh: PASS
bash tests/artifacts.test.sh: PASS
bash tests/backup-contract.test.sh: PASS (Docker/sudo simulados)
git diff --check: PASS
git diff --no-index --check /dev/null docs/installation/laboratorio-ubuntu-26.04.md:
  sin errores de whitespace; exit 1 esperado por ser contenido nuevo
Reproducción adicional de índice ambiguo: defecto confirmado
```

No se ejecutó `tests/backup-integration.test.sh`, que consulta Docker real.
Tampoco se ejecutó restore o build real; los tests verdes no eliminan los
hallazgos nuevos. No se tocaron scripts, daemon, VM, discos, UFW, secretos o TLS.
No hubo commits/push. Solo se añadió esta revisión/plan al registro existente.

Próxima autorización propuesta: **prerrequisito 0, correcciones locales y sus
tests, sin Docker real**. Después revisión del diff y autorización específica
de etapa 1. Cada subetapa tendrá evidencia antes/después, comandos, hashes,
error/salida y cambios parciales, y la guía distinguirá EJECUTADO de PROPUESTO.

## Prerrequisito 0 autorizado: correcciones locales, 2026-11-25

### Autorización y alcance real

El usuario autorizó corregir los tres bloqueos, añadir regresiones, ejecutar
pruebas locales, revisar el diff completo y actualizar este registro.
Confirmó las fronteras de prueba: verificador OCI en memoria, procedencia
aprobada explícitamente por SHA-256 y empaquetado/publicación con dobles.

No se creó la VM constructora, no se usó Docker real, no se descargaron o
construyeron imágenes y no se transfirió nada a Ubuntu. No se modificaron
Ubuntu, discos, red, UFW, secretos, TLS, contenedores o tags del anfitrión.
No se hicieron commits del proyecto, push ni publicaciones.
Los repositorios Git, historiales y paquetes usados por los tests son
fixtures temporales; sus imágenes son sintéticas y no desplegables.

Al comenzar se conservaron los seis archivos rastreados modificados y cuatro
no rastreados existentes. El parche de código anterior seguía teniendo
SHA-256 `32daeb97da7d31191f7280ed8aac9f3250d3e9e860185049c8ffe1014ac02cc0`.
La comprobación `git apply --reverse --check`, sin aplicar nada, pasó.
Ese hash identifica el estado anterior rechazado, no esta corrección.
Se mantuvieron rama y baseline:
`research/wayfinder-deployment-baseline`,
`4f23638dd77fe23fc0788fdeea1f4e290bb37b63`.

### Evidencia actual del anfitrión y Ubuntu, anterior a los cambios de código

**Verificado ahora, mediante consultas de solo lectura:**

- Fedora 44: aproximadamente 24 GiB de RAM disponibles y 63 GiB libres en
  `/home` al inspeccionar. No son reservas para crear otra VM.
- VMware mostró una VM Ubuntu encendida y Tools `running`.
  `getGuestIPAddress` no pudo obtener su IP.
- El primer SSH a la IP anonimizada `192.0.2.10` falló con `No route to host`.
  No se cambió la IP ni se reparó la red. El usuario consultó `hostname`,
  `ip -br -4 address` e `ip -4 route` en la consola y confirmó la misma IP.
- Un nuevo `ssh chromat-vm`, con clave estricta y sin reutilizar conexión,
  funcionó. Consulta remota fechada `2026-11-25T13:46:55Z`: hostname
  `servidor-ejemplo`, Ubuntu 26.04.1 LTS, x86_64, 4 vCPU, 7.2 GiB de RAM.
  La VM reportó unos cuatro minutos de uptime; no se atribuye con certeza
  el fallo anterior a una causa de red o de arranque.
- Docker y containerd: activos; Docker habilitado. Paquetes Docker
  `5:29.10.1-1~ubuntu.26.04~resolute`, containerd
  `2.4.2-4~ubuntu.26.04~resolute`, Buildx
  `0.39.1-1~ubuntu.26.04~resolute`, Compose
  `5.8.0-1~ubuntu.26.04~resolute`, age `1.2.1-1build1`.
  `dpkg --audit` no produjo pendientes; `docker compose version` indicó 5.8.0.
  No se consultó el daemon Docker del anfitrión.
- Raíz LVM de 70 GiB en disco de 80 GiB: ext4, 58 GiB disponibles.
  Backups en `/dev/sdb1`, disco de 40 GiB, ext4, 38 GiB disponibles,
  UUID anonimizado `00000000-0000-4000-8000-000000000001`, `root:root 0700`.
  `findmnt` confirmó montaje y entrada de fstab evaluada.
  `MAJ:MIN 8:17` difiere de `252:0` en raíz.
  No se probó escritura ni se garantiza protección ante pérdida del anfitrión.
- La copia del aprovisionador conserva SHA-256
  `ecd2da00a004b4e0b2b0ca0c13f2d6dc11a0f4f786f38bc8fdf4e623c65ab73c`.
  No se repitió su ejecución. Solo se observaron listeners TCP 22 y DNS
  local 53; no 443.
- `sudo -n true` no estuvo disponible. Se omitieron las consultas
  privilegiadas al daemon, UFW y directorios restringidos; no se solicitó
  contraseña. Su inventario sigue pendiente de revalidación.

`gh release list --repo JuanciscoPacketTracer/chromat-cloud --limit 5
--json tagName,isDraft,isPrerelease,publishedAt,name` volvió a devolver `[]`.
Los dos comandos `bash scripts/verify-artifacts.sh
dist/artifacts/2026.11.12-1` y su equivalente para `2026.11.16-1` devolvieron
exit 1: faltaban respectivamente `scripts/recover-release-links.sh` y
`scripts/verify-image-artifacts.sh`. No se repararon ni reutilizaron.

### Correcciones implementadas y revisadas por inspección

1. **Índices OCI exclusivos.** `scripts/lib/image-identity.py` exige que
   todas las ramas seleccionables, incluidas las anidadas o sin plataforma
   declarada, conduzcan al manifiesto fijado. Rechaza manifiestos
   alternativos, ramas sin destino fijado, ciclos y schema inválido.
   Conserva los tres pins, hashes/tamaños de blobs, config Linux/amd64,
   capas, tag y soporte de referencias extranjeras omitidas en exportaciones
   de plataforma. No demuestra qué seleccionaría un daemon real.
2. **Procedencia experimental explícita.**
   `scripts/lib/source-provenance.py` captura baseline, tree base, parche
   binario completo, SHA-256 del parche e inventario completo de
   rutas/modos/hashes SHA-256. Cada adición debe declararse individualmente.
   `source_tree_sha256` identifica ese inventario canónico, no un tree Git.
   La captura no aprueba su contenido.
   El empaquetador exige `--experimental-source` y `--source-sha256` con el
   hash aprobado por separado, `HEAD` igual al baseline y versión
   `experimental-*`. Verifica contenido, parche, modos y ausencia de
   adiciones desconocidas antes de llamar a Docker. Prepara una copia
   temporal privada de los bytes identificados, sin archivos ignorados,
   y fuerza `.env.example`.
   El paquete incluye `provenance/source.json`, con su parche e inventario.
   Los manifiestos interno y externo registran `package_kind=experimental`,
   `git_commit=null`, baseline separado y hashes de procedencia.
   La verificación estática coteja los archivos operativos copiados contra
   sus hashes, incluso con checksums del paquete recalculados.
   El modo normal mantiene su rechazo de checkout sucio.
   El experimental no cambia `active`/`previous`; el creador de Draft lo
   rechaza por cualquiera de los manifiestos, directorio de procedencia o
   prefijo, antes de checksum, carga de imágenes o consultas GitHub.
3. **SQL en la ruta operativa.** Empaquetador, cálculo de
   `migration_version`, validador y fixtures usan `db/migrations/`.
   Compose, backup y restore no se modificaron para acomodar el defecto.
   La prueba ejecuta la copia real dentro de un paquete sintético, confirma
   16 SQL y versión `016`, y exige rechazo tras aplanarlos.

Se actualizaron `docs/deployment/artifacts.md` y los contratos dependientes.
Se revisó el diff completo de los archivos rastreados y el contenido de los
nuevos helpers/tests. No se cambiaron Compose, Dockerfiles, migraciones SQL,
backup, volúmenes o pins productivos.

### Ciclos rojos, errores de pruebas y resultados verdes

Las regresiones se ejecutaron primero con el comportamiento defectuoso:

- OCI: `ValueError not raised` para la alternativa directa y anidada.
- SQL: el empaquetador simulado terminaba, pero había `0 != 16` migraciones
  bajo `db/migrations/`.
- Procedencia: faltaba el helper; después el empaquetador aún rechazaba el
  caso experimental con `source tree must be clean`.
- Draft: alcanzaba el checksum inválido en vez de rechazar inmediatamente
  la identidad experimental.

También se corrigieron errores reales de los dobles: RepoDigest BusyBox con
tag en lugar de repositorio, reescritura de checksums de fixture con modo
0444, y fixtures Draft antiguas sin helpers/exportación OCI sintética.
La revisión detectó que el orden del parche variaba al hacer staging de
una adición: se reprodujo el rechazo incorrecto y se hizo independiente del
índice, sin modificarlo. El test reconstruye además el baseline con el
parche mediante `git apply` en otro directorio temporal.

Comandos locales ejecutados, con `set -euo pipefail` y
`PYTHONDONTWRITEBYTECODE=1`:

```bash
python3 -B tests/image-identity.test.py
python3 -B tests/package-artifacts.test.py
for test in tests/artifacts.test.sh tests/image-artifacts.test.sh \
  tests/create-github-draft-release.test.sh tests/backup-contract.test.sh; do
  bash "$test"
done
bash -n scripts/package-artifacts.sh scripts/verify-artifacts.sh \
  scripts/verify-image-artifacts.sh scripts/create-github-draft-release.sh \
  tests/artifacts.test.sh tests/image-artifacts.test.sh \
  tests/create-github-draft-release.test.sh
git diff --check
```

Resultados finales de código, comprobados en esta sesión:

| Validación | Resultado y alcance |
| --- | --- |
| Identidad OCI | 12 tests OK; alternativas directas/anidadas, con y sin plataforma declarada; pins sintéticos solo en memoria/copias de test |
| Empaquetado/procedencia | 6 tests OK; Docker/GitHub sustituidos por ejecutables de prueba, sin red ni daemon |
| Artefactos/preflight | PASS; fixtures y dependencias externas simuladas |
| Identidad de imágenes | PASS; load/inspect/reexport simulados |
| Draft normal | PASS; Git remoto local temporal, Docker y GitHub simulados; ningún Draft real |
| Backup | PASS del contrato con Docker/sudo simulados; no backup real |
| Sintaxis Bash y whitespace | PASS |

Las pruebas nuevas incluyen rechazo de cambios posteriores de contenido,
modos, adiciones y snapshot, opciones/hash ausentes o erróneos, no atribución
al baseline, entrada de build congelada, exclusión del `.env` ignorado,
preservación de enlaces y rechazo temprano de publicación.
ShellCheck no está disponible; no se instaló. No hay un linter/formatter
adicional configurado en los archivos de configuración inspeccionados.

### Siguiente revisión y etapas que siguen pendientes

No existe todavía una captura aprobada de esta nueva versión ni un paquete
desplegable. Los hashes antiguos no identifican el código corregido.
Se calculó una identidad candidata **solo en memoria**, repitiendo la captura
dos veces y comparando sus bytes. No se persistió un snapshot ni se aprobó.
El proceso Python capturó stdout de este comando, sin construir imágenes:

```bash
python3 -B scripts/lib/source-provenance.py capture . \
  4f23638dd77fe23fc0788fdeea1f4e290bb37b63 \
  --include-untracked docs/installation/laboratorio-ubuntu-26.04.md \
  --include-untracked scripts/lib/image-identity.py \
  --include-untracked scripts/lib/source-provenance.py \
  --include-untracked tests/image-identity-fixture.py \
  --include-untracked tests/image-identity.test.py \
  --include-untracked tests/package-artifacts.test.py
```

La identidad candidata comprende 127 archivos de fuente, incluido este
registro. Sus hashes finales se comunican fuera de los archivos capturados
para evitar una autorreferencia. Cualquier edición posterior cambia esa
identidad y exige recapturar antes de solicitar aprobación.
Los hashes permiten cotejar los bytes aprobados, no aportan una firma ni
prueban por sí solos el origen de las imágenes.

La siguiente etapa propuesta sigue siendo una **VM Fedora constructora
dedicada**, orientativamente 2 vCPU, 4 GiB RAM y VMDK máximo de 24 GiB.
Antes de crearla hay que revalidar espacio, RAM, coste de ISO/VMDK/snapshots
y red disponible, presentar comandos y obtener autorización específica.
Sin sockets, carpetas compartidas o uso del daemon que mantiene CHROMAT
en el anfitrión. No se creó ni se descargó nada en esta etapa.

Solo después corresponderán, con autorizaciones separadas: prueba BusyBox
real con exportación/carga/reexportación en un image store independiente;
reconstrucción y cotejo de la fuente aprobada; construcción y validación
del paquete completo; transferencia y carga offline en Ubuntu; secretos/TLS,
control de exposición y arranque; pruebas funcionales, persistencia, backup
y recuperación. Un backend Docker incompatible debe abortar sin cambiar pins.

Se mantienen pendientes el guard offline de los `docker run` auxiliares de
backup y la comprobación real del filtrado de puertos Docker frente a UFW.
No se amplió la autorización para modificarlos. El filesystem de backups
es independiente de raíz, pero comparte el anfitrión. Ningún PASS local de
esta sección valida instalación, migraciones ejecutadas, HTTPS, ingesta,
inferencia, Telegram, persistencia o recuperación funcional.

## Revisión independiente del prerrequisito 0, 2026-11-25

### Alcance y resultados de la revisión inicial

El usuario solicitó una revisión independiente antes de aprobar la captura
o crear la VM. Dos agentes de solo lectura revisaron por separado Standards
y Spec contra `4f23638dd77fe23fc0788fdeea1f4e290bb37b63`, incluyendo los ocho
archivos rastreados modificados, los seis no rastreados y la documentación.
No había commits entre baseline y HEAD: se usó `git diff BASE --` más
lectura explícita de los no rastreados, no un diff vacío `BASE...HEAD`.
La especificación fueron las instrucciones del usuario de esta sesión.

**Standards:** no se encontraron problemas significativos ni infracciones
documentadas. **Spec:** se identificaron dos hallazgos, reproducidos y
corregidos después por el agente principal:

1. **Alto: el parche podía no reconstruir el inventario.** Retirar del índice
   el modelo rastreado pero ignorado con `git rm --cached`, conservarlo y
   modificarlo hacía que el inventario incluyera sus bytes, mientras el
   parche solo lo eliminaba. La captura y `prepare` aceptaban esa
   contradicción. La reconstrucción real de las 127 fuentes del estado
   ordinario había pasado, pero no cubría este otro estado del índice.
2. **Medio: recorrido OCI exponencial.** Un DAG de subíndices compartidos,
   con dos referencias al mismo descendiente por nivel, volvía a visitar
   cada rama. El revisor reprodujo 131072 visitas para 16 niveles y 4688
   bytes, sin Docker. El límite de profundidad no limitaba el trabajo total.

No se detectaron nuevos hallazgos en exclusividad del manifiesto fijado,
rechazo de publicación experimental o rutas SQL. Esto no es una validación
de Docker real ni una garantía de ausencia de otros defectos.
La revisión independiente corresponde al estado inicial con hash candidato
`d09606b9a4af975ea69a0d9fc41e3358bd904d347941203e9804431ac80653ae`;
las correcciones posteriores se verificaron localmente, sin atribuirles
una segunda aprobación independiente.

### Correcciones y evidencia local

- `source-provenance.py` reconstruye ahora **todo** el baseline con
  `git cat-file --batch` en temporales privados, aplica el parche sin índice
  y coteja todas las rutas, modos y SHA-256. Tanto `capture` como `prepare`
  ejecutan esa comprobación. No usa `git archive`, por lo que atributos de
  exportación no pueden omitir o sustituir archivos del baseline.
  La aplicación temporal limpia las variables `GIT_*`, no usa configuración
  global/sistema y no modifica el índice u objetos del repositorio original.
- `prepare` compara el inventario real del checkout y el tree base; valida
  el parche recibido en lugar de exigir que otra versión/configuración Git
  regenere sus mismos hunks. Se conservan el SHA-256 de aprobación, hashes
  internos y rechazo de adiciones desconocidas. Si un índice oculta cambios
  y el parche no los reproduce, `capture` falla: no repara ese índice.
- `image-identity.py` memoriza los subíndices ya verificados por digest y
  limita el recorrido a 4096 descriptores. Se mantienen los tres pins,
  verificaciones de bytes/plataforma, exclusividad, límites y rechazo de ciclos.
- No se modificaron Compose, backup, SQL, Dockerfiles, imágenes o Ubuntu.

Regresiones rojas observadas antes de corregir:

```text
Modelo retirado del índice: capture devolvía 0; el test esperaba rechazo.
DAG compartido: vencía el límite del test de 3 segundos.
4097 descriptores: no se producía el rechazo por presupuesto de trabajo.
```

Los tests posteriores también cubren `assume-unchanged`, `skip-worktree`,
un parche irrecuperable cuyos hashes internos se recalcularon y diferencias
de `diff.interHunkContext` en el constructor.

Comandos ejecutados con `PYTHONDONTWRITEBYTECODE=1`, sin Docker real:

```bash
python3 -B tests/image-identity.test.py
python3 -B tests/package-artifacts.test.py
for test in tests/artifacts.test.sh tests/image-artifacts.test.sh \
  tests/create-github-draft-release.test.sh tests/backup-contract.test.sh; do
  bash "$test"
done
bash -n scripts/package-artifacts.sh scripts/verify-artifacts.sh \
  scripts/verify-image-artifacts.sh scripts/create-github-draft-release.sh \
  tests/artifacts.test.sh tests/image-artifacts.test.sh \
  tests/create-github-draft-release.test.sh
git diff --check
```

Resultado: **14 tests OCI OK**, **9 tests de empaquetado/procedencia OK**,
los cuatro contratos Bash PASS, sintaxis y whitespace PASS.
Los mensajes de creación de Draft, carga o empaquetado de esos tests
corresponden exclusivamente a dobles y fixtures temporales sintéticas,
no a publicaciones, imágenes o paquetes desplegables.
No se ejecutó integración Docker, instalación, backup o restore reales.

### Reproducción propuesta en el constructor, no ejecutada

Esta secuencia no autoriza generación/transferencia de material ni creación
del constructor. Solo se ejecutará tras aprobar el código y un SHA-256 final
externo, crear el constructor con autorización propia y autorizar la
transferencia de fuentes. No usa el daemon del anfitrión.
Reproduce **fuentes**, no demuestra reproducción de imágenes.

**Preparación futura en Fedora:** congelar la documentación y ejecutar la
captura con los seis `--include-untracked` del bloque anterior. Guardar
`source.json` fuera del checkout y exigir que su SHA-256 coincida con el
aprobado, sin sustituirlo por un hash calculado automáticamente. Con HEAD
igual al baseline, se podrá generar `git bundle create "$BASE_BUNDLE" HEAD`
y registrar por separado el SHA-256 de ese bundle. Un bundle solo no
contiene el parche local: deben conservarse ambos elementos.
Ninguno de esos archivos de entrega fue creado en esta etapa.

**En el constructor futuro:** los siguientes valores deben apuntar a
archivos ya transferidos y aprobados; los directorios de destino no deben
existir. El bundle, snapshot y patch quedan fuera de `SOURCE_DIR`.

```bash
set -euo pipefail
umask 077
BASE=4f23638dd77fe23fc0788fdeea1f4e290bb37b63
BASE_BUNDLE=/ruta/privada/baseline.bundle
SNAPSHOT=/ruta/privada/source.json
PATCH=/ruta/privada/approved-source.patch
SOURCE_DIR=/ruta/nueva/chromat-source
CHECK_DIR=/ruta/nueva/chromat-source-check
APPROVED_SOURCE_SHA256=REEMPLAZAR_POR_EL_HASH_APROBADO
APPROVED_BUNDLE_SHA256=REEMPLAZAR_POR_EL_HASH_DEL_BUNDLE
printf '%s  %s\n' "$APPROVED_SOURCE_SHA256" "$SNAPSHOT" \
  "$APPROVED_BUNDLE_SHA256" "$BASE_BUNDLE" | sha256sum --check --strict -
test ! -e "$SOURCE_DIR"
test ! -e "$CHECK_DIR"
git init --template= "$SOURCE_DIR"
git -C "$SOURCE_DIR" bundle verify "$BASE_BUNDLE"
git -C "$SOURCE_DIR" -c fetch.fsckObjects=true fetch --no-tags "$BASE_BUNDLE" HEAD
test "$(git -C "$SOURCE_DIR" rev-parse FETCH_HEAD)" = "$BASE"
git -C "$SOURCE_DIR" config core.autocrlf false
git -C "$SOURCE_DIR" -c core.hooksPath=/dev/null checkout --detach "$BASE"
git -C "$SOURCE_DIR" fsck --full --strict
```

Antes de ejecutar código recibido, extraer el parche usando únicamente la
biblioteca estándar y el hash aprobado:

```bash
python3 - "$SNAPSHOT" "$APPROVED_SOURCE_SHA256" "$BASE" "$PATCH" <<'PY'
import hashlib
import json
import pathlib
import sys

raw = pathlib.Path(sys.argv[1]).read_bytes()
if hashlib.sha256(raw).hexdigest() != sys.argv[2]:
    raise SystemExit("snapshot no aprobado")
record = json.loads(raw)
if (record["source_kind"] != "baseline-plus-local-patch"
        or record["base_git_commit"] != sys.argv[3]):
    raise SystemExit("baseline o tipo de fuente inesperado")
patch = record["patch"].encode()
if hashlib.sha256(patch).hexdigest() != record["patch_sha256"]:
    raise SystemExit("hash del parche incorrecto")
with pathlib.Path(sys.argv[4]).open("xb") as output:
    output.write(patch)
PY
git -C "$SOURCE_DIR" apply --check --whitespace=nowarn -- "$PATCH"
git -C "$SOURCE_DIR" apply --whitespace=nowarn -- "$PATCH"
mkdir "$CHECK_DIR"
python3 -B "$SOURCE_DIR/scripts/lib/source-provenance.py" prepare \
  "$SOURCE_DIR" "$SNAPSHOT" "$APPROVED_SOURCE_SHA256" "$CHECK_DIR/source" \
  >"$CHECK_DIR/verified-source.json"
cmp --silent "$SNAPSHOT" "$CHECK_DIR/verified-source.json"
test "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$BASE"
```

`prepare` comprueba las 127 rutas y modos, todos los hashes de archivo,
el tree base, el parche y su replay completo. Los bytes del snapshot
verificado deben ser idénticos a los aprobados; no se recaptura otro diff
para hacerlo pasar. El checkout conserva HEAD en el baseline con el
parche local, sin commit nuevo ni atribución falsa. Cualquier discrepancia
detiene la secuencia antes de Docker. La ejecución de estos comandos en un
constructor real sigue pendiente; aquí se probaron las funciones de
replay/verificación localmente y con fixtures.
Se comprobó además la sintaxis de los tres bloques Bash de esta sección
y del Python incrustado, sin ejecutar sus comandos. Esa comprobación
no equivale a haber ejecutado la receta del constructor.

### Fuentes exactas de la captura candidata final

Las siguientes son las **127 fuentes identificadas**, no una lista de
servicios ni de archivos necesariamente copiados al runtime. Se incluyen
121 archivos del baseline y seis adiciones. No se incluyen `.env`, secretos,
certificados privados, salidas `dist/`, caches o dependencias ignoradas.

```text
.env.example
.gitignore
AGENTS.md
GLOSSARY.md
README.md
api/Dockerfile
api/docker-entrypoint.sh
api/package-lock.json
api/package.json
api/src/aggregation.js
api/src/alerts.js
api/src/capacity.js
api/src/create-operator.js
api/src/create-source.js
api/src/database.js
api/src/hsv.js
api/src/migrate.js
api/src/retention.js
api/src/server.js
api/src/telegram-worker.js
api/src/telegram.js
api/src/time.js
api/src/worker-aggregation.js
api/src/worker.js
api/test/aggregation.test.js
api/test/alerts.test.js
api/test/capacity.test.js
api/test/hsv.test.js
api/test/telegram.test.js
api/test/worker-aggregation.test.js
compose.yaml
db/migrations/001_initial.sql
db/migrations/002_processing.sql
db/migrations/003_processing_constraints.sql
db/migrations/004_admin_auth.sql
db/migrations/005_source_management.sql
db/migrations/006_source_access.sql
db/migrations/007_retention.sql
db/migrations/008_raw_tombstones.sql
db/migrations/009_aggregated_state.sql
db/migrations/010_aggregation_rule_audit.sql
db/migrations/011_aggregated_state_history.sql
db/migrations/012_alerts.sql
db/migrations/013_alert_interval.sql
db/migrations/014_manual_reprocessing.sql
db/migrations/015_raw_file_finalization.sql
db/migrations/016_job_event_uniqueness.sql
docs/adr/0001-linea-base-de-despliegue.md
docs/adr/0002-certificados-tls-en-red-local.md
docs/adr/0003-contrato-de-eventos-de-monitoreo.md
docs/adr/0004-procesamiento-asincrono-y-versionado.md
docs/adr/0005-persistencia-de-datos-crudos-y-derivados.md
docs/adr/0006-autenticacion-autorizacion-y-exposicion.md
docs/adr/0007-operacion-observabilidad-y-recuperacion.md
docs/adr/0008-publicacion-y-despliegue-reproducible.md
docs/adr/0009-reglas-y-entrega-de-alertas-al-productor.md
docs/agents/domain.md
docs/agents/issue-tracker.md
docs/agents/triage-labels.md
docs/audits/auditoria-integral.md
docs/deployment/artifacts.md
docs/deployment/backups.md
docs/deployment/promotion.md
docs/deployment/tls.md
docs/installation/laboratorio-ubuntu-26.04.md
docs/installation/requisitos.md
docs/installation/ubuntu-server-24.04.md
docs/installation/ubuntu-server-26.04.md
docs/research/wayfinder-deployment-baseline.md
etapa-1-preparar-servidor.md
inference/Dockerfile
inference/models/deterministic-model.json
inference/requirements.txt
inference/server.py
nginx/conf.d/default.conf
scripts/backup.sh
scripts/check-tls-expiry.sh
scripts/create-github-draft-release.sh
scripts/dev-tls.sh
scripts/install-production-tls.sh
scripts/lib/backup-config.sh
scripts/lib/image-identity.py
scripts/lib/source-provenance.py
scripts/package-artifacts.sh
scripts/prepare-ubuntu-production-host.sh
scripts/recover-release-links.sh
scripts/retention.sh
scripts/verify-artifacts.sh
scripts/verify-backup.sh
scripts/verify-image-artifacts.sh
scripts/verify-production-environment.sh
tests/artifacts.test.sh
tests/backup-contract.test.sh
tests/backup-integration.test.sh
tests/create-github-draft-release.test.sh
tests/image-artifacts.test.sh
tests/image-identity-fixture.py
tests/image-identity.test.py
tests/package-artifacts.test.py
tests/promotion-contract.test.sh
tests/smoke/Dockerfile
tests/smoke/admin-auth.sh
tests/smoke/aggregation.sh
tests/smoke/capacity.sh
tests/smoke/client-bootstrap.sh
tests/smoke/client-cleanup.sh
tests/smoke/client-entrypoint.sh
tests/smoke/compose.isolated.yaml
tests/smoke/compose.sh
tests/smoke/curl.sh
tests/smoke/inference.sh
tests/smoke/ingestion.sh
tests/smoke/isolated.sh
tests/smoke/isolated.test.sh
tests/smoke/migrations.sh
tests/smoke/processing.sh
tests/smoke/run.sh
tests/smoke/runner.test.sh
tests/smoke/skeleton.sh
tests/smoke/source-management.sh
tests/smoke/telegram-stub.conf
tests/smoke/telegram.sh
tests/tls.test.sh
tests/ubuntu-production-host-contract.test.sh
web/public/app.js
web/public/index.html
web/public/styles.css
```

El hash candidato anterior queda obsoleto tras estas correcciones y cambios
documentales. Después de la última edición se vuelve a capturar dos veces,
se exige igualdad de bytes y se coteja que el inventario coincida exactamente
con la lista anterior. El hash final se comunica en la respuesta de revisión,
fuera de los archivos capturados para evitar autorreferencia.
Modificar **cualquier** archivo incluido, también documentación, exige
recapturar y solicitar aprobación del nuevo hash; no autoriza ninguna etapa.

Se espera aprobación del usuario. No se creó la VM, no hubo Docker real,
descargas de imágenes, construcción de paquetes desplegables, transferencias,
modificaciones de Ubuntu, commits del proyecto o publicaciones.
Siguen pendientes BusyBox real e interoperabilidad del image store,
construcción aislada, instalación, servicios, persistencia, backup y restore.

## Revisión acotada, captura definitiva y constructor propuesto, 2026-11-25

### Dos correcciones revisadas independientemente

El usuario autorizó revisar únicamente la reconstrucción exacta de
procedencia y el recorrido OCI acotado, corregir hallazgos confirmados,
preparar la captura para aprobación y revalidar recursos. No autorizó
crear la VM, descargar, construir o transferir material.

Dos revisores de solo lectura examinaron esas funciones y sus regresiones
en ejes independientes. **Standards: un hallazgo funcional Medio;
Spec: un hallazgo Medio**, el mismo defecto, no dos defectos distintos.
No encontraron hallazgos en reconstrucción de procedencia.

La memoización OCI omitía comprobar la profundidad restante al reutilizar
un subíndice. El mismo DAG de profundidad 40 se aceptaba si sus descendientes
se encontraban primero y se rechazaba al invertir las referencias.
La regresión pública añadida antes del arreglo reprodujo:

```text
python3 -B tests/image-identity.test.py \
  IdentityTest.test_cached_indexes_preserve_nesting_limit_in_both_branch_orders
FAIL depth=33, deepest_first=False: ValueError not raised
FAIL depth=40, deepest_first=False: ValueError not raised
```

La corrección guarda junto al resultado cacheado su altura máxima y exige
`profundidad_actual + 1 + altura_del_hijo <= 32`, también en aciertos de
caché. No modifica pins, presupuesto de 4096, integridad, plataforma,
exclusividad o detección de ciclos. El test acepta 32 y rechaza 33 y 40 en
ambos órdenes. El revisor Spec examinó el arreglo, ejecutó la regresión y
confirmó cerrado el hallazgo, sin defectos adicionales en esas líneas.
No hubo una segunda revisión completa del proyecto.

Después del arreglo se ejecutaron los comandos de validación local
documentados en la sección anterior: **15 tests OCI y 9 de procedencia/
empaquetado OK**, cuatro contratos Bash PASS, sintaxis y whitespace PASS.
Docker, sudo y GitHub fueron dobles donde correspondía; solo se usaron
fixtures temporales sintéticas. Ningún mensaje de Draft o carga de esos
tests corresponde a una operación real. ShellCheck sigue ausente.
VS Code no informó diagnósticos en los dos Python modificados; eso no
sustituye un linter completo.

### Captura para aprobación y comprobación local de secretos

Se mantiene la lista exacta de **127 fuentes** del bloque anterior:
121 del baseline y las seis adiciones declaradas. El baseline continúa en
`4f23638dd77fe23fc0788fdeea1f4e290bb37b63`, tree
`b349036d98f36434d9a15cd92bb6c0e1c1d9c5cb`. No hay nuevos commits.
El estado anterior identificado por
`96147841d3465d766403a15f8f1b2632ffd32459234147bf3f94fd108d9b3e79`
queda obsoleto tras el arreglo y esta documentación.

La comprobación local abarca los bytes de las 127 fuentes **y el parche
decodificado**, incluyendo contexto o eliminaciones que no aparezcan ya
en los archivos actuales. Se buscan marcadores de claves privadas y age,
tokens GitHub/AWS/Google/OpenAI/Telegram y URLs con credenciales, además
de asignaciones literales de contraseñas/tokens.
Se cotejan privadamente cuatro valores de credenciales locales disponibles,
sin imprimir sus valores ni incorporarlos al informe.

Resultado de la revisión: cero coincidencias de patrones de alta señal,
cero valores de esas credenciales en fuentes/parche y cero rutas privadas
incluidas. Las 18 coincidencias de asignaciones se revisaron: 16 son
expresiones que leen variables/archivos en ejecución; dos son expectativas
de pruebas de escape con valores ficticios en dobles MariaDB. No son
credenciales desplegadas. Las tres asignaciones sin comillas identificadas
son declaraciones de arrays de rutas/nombres, sin valores de credenciales.
No se incluyen `.env`, `secrets/`, `certs/`,
dependencias, caches ni `dist/`; `.env.example` contiene rutas y defaults,
no valores de credenciales. No se leyó ni auditó todo el historial Git:
un eventual bundle requiere su comprobación propia antes de transferirlo.

Esto es una comprobación local por patrones, contexto y contraste de valores
conocidos, no una prueba universal de ausencia de secretos arbitrarios,
codificados o desconocidos. No se enviaron fuentes a servicios externos ni
se instaló un detector especializado.

Después de la última edición se repite captura y comprobación de secretos,
se exige igualdad de dos capturas y coincidencia de las 127 rutas/modos/
hashes. La captura definitiva candidata se guarda fuera del checkout en
un directorio privado, con modo `0600`; ruta y hashes se comunican en la
respuesta, no dentro de las fuentes, evitando autorreferencia.
Guardar la captura no significa aprobarla. Cualquier cambio incluido
exige recapturar. No se genera un paquete desplegable ni un bundle.

### Recursos revalidados en el anfitrión, solo lectura

Consultas locales del **2026-11-25 14:35-14:36 UTC**: `lscpu`, `free`,
`df`, `uptime`, `btrfs filesystem usage`, `vmrun list`, `vmware -v` y lectura
de claves de recursos del VMX existente. No se invocó Docker real ni se
consultó Ubuntu. El estado actual de sus seis contenedores no se reinventarió.

| Recurso | Verificado ahora |
| --- | --- |
| Anfitrión | Fedora 44, bare metal; AMD Ryzen 7 5700U, 8 cores/16 hilos, AMD-V |
| RAM | 31452 MiB totales; 14818 MiB disponibles, unos 14.5 GiB |
| Swap | 8191 MiB, 0 usados en la muestra |
| Carga | 3.16, 2.02, 1.53; muestra, no reserva de CPU |
| `/home` | btrfs, 62.37 GiB libres estimados; cota mínima informada 48.38 GiB |
| Asignación btrfs | 27.98 GiB sin asignar a chunks; no equivale al espacio libre total |
| VMware | Workstation 26.0.1; una VM encendida, Ubuntu |
| VM Ubuntu existente | VMX: 4 vCPU, 8192 MiB, NAT, dos VMDK; sin modificaciones |
| ISO Fedora | No encontrada en Downloads/Descargas/vmware a profundidad 2; no es búsqueda global |

`btrfs filesystem usage` advirtió que, sin root, no muestra detalles por
dispositivo; no se elevó privilegio. Estos valores son temporales y deben
revalidarse inmediatamente antes de crear/encender el constructor.
No se garantiza capacidad para toda la construcción por disponer de espacio.

### Creación de la VM: instrucciones propuestas, NO ejecutadas

La siguiente autorización debe identificar por separado creación, descarga
de ISO, instalación/provisión y pruebas de imágenes. Nada de ello queda
autorizado por este documento.

1. Revalidar `free -h`, `df -h /home`, `btrfs filesystem usage /home` y
   `vmrun list` en el anfitrión, sin Docker. Presupuestar unos **35 GiB**
   físicos: hasta 24 GiB VMDK, 4 GiB de memoria/estado VMware, hasta 4 GiB
   de ISO y 3 GiB de margen. Si la ISO real supera la estimación,
   recalcular antes de descargar. No crear snapshots de construcción.
   Con la cota mínima actual quedarían unos 13 GiB, no una reserva garantizada.
   Detenerse si no puede mantenerse ese margen o hay presión de memoria/I/O.
   Snapshots btrfs del anfitrión pueden aumentar el consumo físico; no se
   auditó ni modificó su política. No activar AutoProtect en la VM nueva.
2. Solo con autorización de descarga, obtener Fedora Server 44 x86_64 desde
   la distribución oficial y verificar CHECKSUM firmado y huella de la clave
   por canal confiable. No se consultaron disponibilidad, tamaño ni repositorios
   en esta etapa; no sustituir edición o versión silenciosamente.
3. En VMware Workstation: **Create a New Virtual Machine / Typical / I will
   install the operating system later / Linux / Fedora 64-bit**. Nombre
   `chromatbuilder`; directorio nuevo exclusivo. No clonar Ubuntu ni restaurar
   snapshots. Configurar **2 vCPU y 4096 MiB**, firmware UEFI, VMDK nuevo
   thin de capacidad máxima **24 GiB**, sin preasignarlo entero. No tocar
   discos, redes o configuración de la VM existente.
4. Usar una vNIC **NAT** sobre la red existente, sin editar vmnet8 ni añadir
   port-forwarding. Deshabilitar carpetas compartidas, portapapeles y drag/drop.
   No conectar discos/carpetas/sockets del anfitrión. Desmarcar el encendido
   automático al terminar la creación.
5. Tras autorizar instalación: conectar la ISO verificada, instalar Fedora
   Server mínimo en el VMDK nuevo, hostname `chromatbuilder`, usuario
   administrador dedicado y SSH. Registrar IP/MAC reales, `lsblk -f`,
   `df -h`, RAM, CPU, versión y checksum ISO. No reutilizar claves privadas
   de producción ni aprovisionador Ubuntu. Desconectar ISO al terminar.
6. Aprovisionar Docker CE oficial, no `podman-docker`, solo con autorización
   de red/paquetes. Registrar antes las versiones disponibles y después las
   instaladas de Engine/CLI/containerd/Buildx/Compose, Git y Python.
   Proponer Engine/CLI 29.10.1 para aproximar Ubuntu, cuya disponibilidad
   Fedora no se ha consultado. Si no está disponible, presentar alternativas:
   no inventar un NEVRA ni cambiar de backend para obtener otro ID.
   La API Docker debe permanecer en socket Unix del invitado, nunca TCP.
   No ejecutar `hello-world` ni otros pulls de prueba durante la instalación:
   BusyBox debe ser la primera imagen en el store nuevo.
7. Solo tras aprobar la captura y autorizar transferencia de fuentes:
   reconstruirlas con la receta del apartado anterior. Usar el helper desde
   esa copia verificada. Esto no autoriza a construir imágenes CHROMAT.

La capacidad propuesta sigue siendo experimental. El VMDK de 24 GiB contiene
también caches, exports y la futura salida: si no alcanza, detenerse, no
ampliarlo ni usar el disco del anfitrión automáticamente. La VM comparte
hardware e I/O con los servicios existentes y no es una frontera de backup.

### BusyBox real: receta propuesta, NO ejecutada

Requiere autorización posterior para pull, tags, arranque de daemon auxiliar
y contenedor de prueba **dentro de chromatbuilder**, más transferencia previa
del helper aprobado. No se debe ejecutar en Fedora anfitrión ni Ubuntu.
No es un séptimo servicio Compose; no ejecutar Compose.
Mantener la misma shell para los siguientes bloques.

Primero demostrar identidad del invitado y preparar evidencia privada:

```bash
set -euo pipefail
test "$(hostname -s)" = chromatbuilder
test "$(systemd-detect-virt)" = vmware
umask 077
VERIFIER=/ruta/chromat-source-check/source/scripts/lib/image-identity.py
test -f "$VERIFIER"
EVIDENCE="$HOME/busybox-evidence"
test ! -e "$EVIDENCE"
mkdir -m 700 "$EVIDENCE" "$EVIDENCE/docker-client"
client=(sudo env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY \
  -u DOCKER_CERT_PATH -u DOCKER_API_VERSION /usr/bin/docker \
  --config "$EVIDENCE/docker-client")
D=("${client[@]}" --host unix:///var/run/docker.sock)
rpm -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
  docker-compose-plugin >"$EVIDENCE/packages.txt"
"${D[@]}" version >"$EVIDENCE/source-version.txt"
"${D[@]}" info >"$EVIDENCE/source-info.txt"
df -h /var/lib/docker "$HOME" >"$EVIDENCE/space-before.txt"
test -z "$("${D[@]}" image ls --quiet)"
"${D[@]}" info --format '{{json .DriverStatus}}' |
  python3 -c 'import json,sys; s=dict(json.load(sys.stdin)); sys.exit(s.get("driver-type") != "io.containerd.snapshotter.v1")'
SOURCE_REF=docker.io/library/busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f
"${D[@]}" pull --platform=linux/amd64 "$SOURCE_REF"
"${D[@]}" tag "$SOURCE_REF" busybox:1.36.1
SOURCE_ID="$("${D[@]}" image inspect --format '{{.Id}}' busybox:1.36.1)"
"${D[@]}" image inspect busybox:1.36.1 >"$EVIDENCE/source-inspect.json"
"${D[@]}" image save --platform=linux/amd64 \
  --output "$EVIDENCE/source.tar" busybox:1.36.1
python3 -B "$VERIFIER" "$EVIDENCE/source.tar" "$SOURCE_ID" \
  >"$EVIDENCE/source-identity.json"
```

El verificador conserva los pins de índice, manifiesto y config del código
aprobado; exige los bytes fijados de manifiesto/config, capas, Linux/amd64,
tag y exclusividad de ramas. Que el ID nativo sea distinto del config digest
no es por sí solo un error. No cambiar pins, forzar un store clásico ni
aceptar otra exportación si falla. La comprobación de backend anterior es
un requisito del experimento propuesto, no evidencia del backend actual de
Ubuntu ni de interoperabilidad con él.

Para probar **load en otro image store**, crear después un daemon temporal
en la misma VM, sin puertos TCP ni manipulación de bridges/iptables.
No se reutiliza el socket containerd del Docker principal: al omitir
`--containerd`, dockerd debe gestionar uno propio bajo sus raíces privadas.
Eso se inspecciona antes de cargar imágenes; si no se demuestra, detenerse.

```bash
STORE=/var/lib/chromat-busybox-check
RUN=/run/chromat-busybox-check
test "$(hostname -s)" = chromatbuilder
test "$(systemd-detect-virt)" = vmware
sudo test ! -e "$STORE"
sudo test ! -e "$RUN"
sudo install -d -m 700 "$STORE" "$RUN"
printf '%s\n' '{"features":{"containerd-snapshotter":true}}' |
  sudo tee "$STORE/daemon.json" >/dev/null
sudo systemd-run --unit=chromat-busybox-check --service-type=exec \
  /usr/bin/dockerd --config-file "$STORE/daemon.json" \
  --host "unix://$RUN/docker.sock" --data-root "$STORE/docker" \
  --exec-root "$RUN/exec" --pidfile "$RUN/docker.pid" \
  --bridge=none --iptables=false --ip6tables=false \
  --ip-forward=false --ip-masq=false
V=("${client[@]}" --host "unix://$RUN/docker.sock")
ready=0
for attempt in {1..30}; do
  if "${V[@]}" info >"$EVIDENCE/check-info.txt" 2>"$EVIDENCE/check-info.err"; then
    ready=1
    break
  fi
  sleep 1
done
test "$ready" = 1
test "$("${V[@]}" info --format '{{.DockerRootDir}}')" = "$STORE/docker"
test -z "$("${V[@]}" image ls --quiet)"
"${V[@]}" info --format '{{json .DriverStatus}}' |
  python3 -c 'import json,sys; s=dict(json.load(sys.stdin)); sys.exit(s.get("driver-type") != "io.containerd.snapshotter.v1")'
sudo cat "$RUN/exec/containerd/containerd.toml"
```

**Punto de parada manual:** conservar la salida anterior y comprobar que
root, state y socket gRPC de containerd están bajo `STORE`/`RUN`, no bajo
`/var/lib/containerd` ni `/run/containerd/containerd.sock`. Si el archivo
no existe en esa versión, localizarlo mediante el comando/PID hijo de
dockerd y revisar sus rutas; no continuar por suposición.
La receta del daemon aún no se ha probado con Docker real.

Solo después de esa comprobación:

```bash
"${V[@]}" load --input "$EVIDENCE/source.tar"
LOADED_ID="$("${V[@]}" image inspect --format '{{.Id}}' busybox:1.36.1)"
test "$LOADED_ID" = "$SOURCE_ID"
test "$("${V[@]}" image inspect --format '{{.Os}}/{{.Architecture}}' busybox:1.36.1)" = linux/amd64
"${V[@]}" image save --platform=linux/amd64 \
  --output "$EVIDENCE/reexport.tar" busybox:1.36.1
python3 -B "$VERIFIER" "$EVIDENCE/reexport.tar" "$LOADED_ID" \
  >"$EVIDENCE/reexport-identity.json"
"${V[@]}" run --rm --pull=never --network=none --read-only \
  --cap-drop=ALL --security-opt=no-new-privileges busybox:1.36.1 \
  /bin/sh -c 'test "$(uname -m)" = x86_64; printf "BUSYBOX_EXEC_OK\n"' \
  >"$EVIDENCE/execution.txt"
sha256sum "$EVIDENCE/source.tar" "$EVIDENCE/reexport.tar" \
  "$EVIDENCE/source-identity.json" "$EVIDENCE/reexport-identity.json" \
  >"$EVIDENCE/checksums.sha256"
sudo systemctl stop chromat-busybox-check.service
test "$(sudo systemctl is-active chromat-busybox-check.service || true)" != active
```

Ante fallo, detener el daemon temporal mediante
`sudo systemctl stop chromat-busybox-check.service` **en el constructor**
y conservar logs con `sudo journalctl -u chromat-busybox-check.service
--no-pager`. No borrar stores, exports ni ampliar discos para ocultarlo.
Los TAR no tienen por qué coincidir byte a byte; sí deben pasar ambos el
verificador, conservar config/manifiesto fijados y mantener el ID nativo.
Esta prueba no valida todavía las otras imágenes, el paquete completo,
Ubuntu, HTTPS, migraciones, persistencia, backup o restore.

**Estado final de esta etapa:** solo código local, tests con dobles,
captura candidata local y consultas de recursos. Se espera autorización;
no se creó VM, descargó ISO/imagen, usó Docker real, construyó imágenes o
paquetes desplegables, transfirió material, modificó Ubuntu o realizó
commits/push.
