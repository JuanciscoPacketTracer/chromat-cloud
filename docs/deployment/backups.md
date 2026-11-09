# Backups cifrados y restauración verificable

Este runbook define la operación manual de backups de CHROMAT Server. No
introduce alta disponibilidad, replicación continua ni almacenamiento cloud
obligatorio. El objetivo inicial es un RPO de 24 horas y un RTO de 4 horas,
con al menos siete copias recuperables.

## Política operativa

- El operador ejecuta un backup **diario** en la zona horaria
  `America/Mazatlan`; los nombres internos del script usan UTC para evitar
  ambigüedad durante cambios de horario.
- La retención inicial es de **14 días** de backups diarios.
- Se conservan al menos **siete backups completos o cadenas recuperables**.
  Un incremental solo cuenta si conserva su backup completo base y todos los
  incrementales necesarios.
- Cada promoción conserva una copia externa verificada del backup asociado.
- La copia externa debe estar en un filesystem montado distinto del root y
  fuera de `BACKUP_ROOT`.
- Antes de modificar la base en una promoción se ejecuta un backup completo,
  se valida su checksum y se verifica en aislamiento.
- La retención del dato crudo y la retención de backups son políticas
  distintas. `scripts/retention.sh` no sustituye la retención de backups.

El operador registra fecha UTC, modo (`full`/`incremental`), ruta local, ruta
externa, checksum, resultado de `verify-backup.sh`, custodio que ejecutó la
operación y custodio que conserva la clave de descifrado.

## Cifrado y custodios

`scripts/backup.sh` cifra con `age` antes de copiar fuera del servidor. El
servidor recibe un archivo de destinatario (`BACKUP_AGE_RECIPIENT_FILE`) para
cifrar, pero la identidad privada (`BACKUP_AGE_IDENTITY_FILE`) se conserva
fuera de Git, fuera del directorio de backups y bajo custodia separada.

La clave privada de la CA nunca se incluye en `BACKUP_SECRET_FILES`. El script
rechaza explícitamente `ca.key` y `ca-root.key`. Los secretos de servicio que
sí deban recuperarse se copian al archivo cifrado `secrets.tar.gz.age`.

Responsabilidades mínimas:

| Rol | Responsabilidad |
|---|---|
| Operador de plataforma | Ejecutar backup, verificarlo, registrar evidencia y revisar retención |
| Custodio de backups | Conservar la copia externa y comprobar que las siete copias siguen disponibles |
| Custodio de clave | Proteger la identidad `age` fuera del servidor y autorizar descifrado |

Una sola persona puede desempeñar más de un rol durante el desarrollo, pero la
identidad de descifrado no debe almacenarse junto al backup ni en Git.

## Backup diario y de promoción

Configura las variables reales fuera de Git:

```bash
export BACKUP_ROOT=/srv/chromat/backups
export BACKUP_EXTERNAL_DIR=/mnt/chromat-backups
export BACKUP_AGE_RECIPIENT_FILE=/etc/chromat/backup-age-recipient
export BACKUP_SECRET_FILES='/etc/chromat/secrets/telegram_bot_token'
export BACKUP_MODE=full
```

Ejecuta el backup desde la release activa:

```bash
cd /srv/chromat/active
scripts/backup.sh
```

El script:

1. coloca la ingesta en mantenimiento y detiene temporalmente el worker;
2. genera el dump de MariaDB y el manifiesto de hashes de crudos;
3. empaqueta configuración, migraciones y secretos seleccionados;
4. cifra los artefactos antes de copiarlos a `BACKUP_EXTERNAL_DIR`;
5. publica checksums y conserva el manifiesto de estado para incrementales;
6. retira el mantenimiento y vuelve a arrancar el worker.

Un fallo conserva la evidencia disponible, limpia el estado temporal y debe
tratarse como backup no válido. No se elimina la copia anterior hasta verificar
la nueva.

Para un incremental, primero debe existir un full válido:

```bash
export BACKUP_MODE=incremental
scripts/backup.sh
```

La primera ejecución de cada cadena siempre es `full`. Si se pierde el full
base, la cadena incremental deja de ser recuperable y debe iniciarse otra
cadena completa.

## Verificación y restauración aislada

La verificación nunca restaura sobre la base de producción. Usa una identidad
de descifrado fuera del servidor operativo o provisionada temporalmente por el
custodio:

```bash
export BACKUP_AGE_IDENTITY_FILE=/ruta/segura/backup-age-identity
export BACKUP_BASE_DIR=/srv/chromat/backups/BASE-FULL
scripts/verify-backup.sh /srv/chromat/backups/20261109T120000Z
```

`BACKUP_BASE_DIR` solo es necesario para verificar un incremental. Un backup
completo no debe recibir una base distinta.

`scripts/verify-backup.sh` verifica:

- checksums de cada artefacto cifrado;
- descifrado, integridad gzip y extracción de archivos;
- manifiesto y hashes de cada dato crudo;
- ausencia de archivos referenciados por MariaDB;
- ausencia de archivos crudos no referenciados;
- importación en una MariaDB efímera con red `none`;
- presencia de todas las migraciones versionadas;
- configuración, secretos cifrados y metadatos de modo/base.

La salida `Backup verified` es evidencia de restauración aislada, no una
autorización para sobrescribir producción. Antes de declarar el sistema
recuperable se archivan el comando, el resultado, el checksum y el identificador
del backup.

La restauración operativa posterior a un incidente debe detener el tráfico,
conservar logs y manifiesto, restaurar primero en un entorno aislado y solo
promoverlo cuando las migraciones, hashes, archivos referenciados y faltantes
vuelvan a pasar. No se ejecutan down-migrations automáticas.

## Retención y revisión

Semanalmente, el operador lista las copias locales y externas, comprueba que
existan siete recuperables y revisa que cada incremental tenga su full base:

```bash
find /srv/chromat/backups -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
find /mnt/chromat-backups -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
cat /srv/chromat/backups/last-successful
```

Solo después de verificar una copia nueva se pueden retirar copias diarias con
más de 14 días, siempre que sigan existiendo al menos siete copias o cadenas
recuperables. Nunca se borran la copia externa de la promoción activa ni un
full que sea base de incrementales; si conservar una base antigua es necesario,
queda fuera del corte de 14 días hasta que la cadena se compacte con otro full.

Al menos trimestralmente, después de cambios importantes y antes de una entrega
del proyecto, se ejecuta una restauración aislada completa y se conserva la
evidencia. La revisión también confirma que el filesystem externo sigue montado
y que la identidad de descifrado no reside en él.

## Pérdida de la clave

Si se pierde `BACKUP_AGE_IDENTITY_FILE`, se declara un incidente operativo:

1. se detienen las eliminaciones y se conserva todo el material cifrado;
2. se informa a los custodios y se localiza la copia autorizada de la identidad;
3. se intenta descifrar y verificar una copia en aislamiento;
4. si ninguna copia autorizada existe, los backups cifrados no son recuperables;
5. se emite una nueva identidad/destinatario y se documenta una nueva cadena.

No se guarda una copia de la clave junto a los backups como solución temporal y
no se intenta reconstruir la clave perdida. La pérdida de la identidad es una
condición de recuperación fallida que debe quedar registrada.

## Fuera de alcance

Este procedimiento no define HA, replicación continua, failover, Ansible,
CI/CD ni un proveedor cloud obligatorio.
