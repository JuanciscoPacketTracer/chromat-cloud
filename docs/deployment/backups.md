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
cifrar, pero la identidad privada se entrega sólo mediante
`verify-backup.sh --identity-file` en el host aislado. Se conserva fuera de
Git, fuera del directorio de backups y bajo custodia separada.

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
sudo install -d -o root -g root -m 0700 \
  /srv/chromat/backups /var/lib/chromat/backup-state
sudo install -d -o root -g root -m 0700 /mnt/chromat-backups
sudo install -o root -g root -m 0600 /dev/null /etc/chromat/production.env
```

`/etc/chromat/production.env` contiene las rutas de `BACKUP_ROOT`,
`BACKUP_EXTERNAL_DIR`, `BACKUP_AGE_RECIPIENT_FILE`, `BACKUP_SECRET_FILES`,
`BACKUP_MAX_SECONDS`, `BACKUP_MODE` y `BACKUP_STATE_DIR`; conserva permisos
`0600`. El script lo analiza sin evaluarlo como código, valida esas rutas, los
permisos y que el destino externo exista, sea escribible y esté montado fuera
del root. `BACKUP_SECRET_FILES` incluye
`/etc/chromat/secrets/db_password`,
`/etc/chromat/secrets/db_root_password` y
`/etc/chromat/secrets/telegram_bot_token`. No exportes ni cargues ese archivo
en el shell del operador. Los directorios de backup, estado y copia externa no
pueden ser escribibles por grupo u otros; los secretos y la identidad privada
de `age` deben ser `0600`.

Ejecuta el backup desde la release activa. El script y cada llamada a Docker
usan `sudo`, por lo que el administrador no necesita pertenecer al grupo
`docker`:

```bash
sudo /srv/chromat/active/scripts/backup.sh \
  --config /etc/chromat/production.env --mode full
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
sudo /srv/chromat/active/scripts/backup.sh \
  --config /etc/chromat/production.env --mode incremental
```

La primera ejecución de cada cadena siempre es `full`. Si se pierde el full
base, la cadena incremental deja de ser recuperable y debe iniciarse otra
cadena completa.

## Preparar y verificar una restauración aislada

La verificación nunca restaura sobre la base de producción. Prepara un host
limpio Ubuntu Server 26.04, separado de la VM productiva y sin sus volúmenes.
Instala Docker Engine, Docker Compose Plugin, `age`, `openssl` y las imágenes
verificadas desde el paquete de la release; no permitas que Docker descargue
imágenes durante la prueba:

```bash
sudo /ruta/release/scripts/prepare-ubuntu-production-host.sh
sudo /ruta/release/scripts/verify-artifacts.sh /ruta/release
for image_archive in /ruta/release/images/*.tar; do
  sudo docker load --input "$image_archive"
done
```

Transfiere la release verificada y el directorio de backup externo por un canal
autorizado. Antes de usar la copia, valida sus hashes contra
`checksums.sha256`; monta el medio externo en `/mnt/chromat-backups` como sólo
lectura. Provisiona las rutas locales del host aislado y una configuración
mínima con la misma imagen MariaDB incluida en la release:

```bash
sudo install -d -o root -g root -m 0700 /srv/chromat/restore
sudo install -o root -g root -m 0600 /dev/null /srv/chromat/restore/restore.env
sudo sh -c 'printf "%s\n" "CHROMAT_DB_IMAGE=mariadb:11.8.2" \
  > /srv/chromat/restore/restore.env'
sudo sh -c "cd /mnt/chromat-backups/20261109T120000Z && sha256sum --check checksums.sha256"
```

Reemplaza `mariadb:11.8.2` por el valor `CHROMAT_DB_IMAGE` del manifiesto
verificado de la release. El host aislado no necesita secretos de servicio ni
la configuración productiva.

La identidad privada de `age` **no se transfiere ni almacena en la VM productiva**:
identidad privada de `age` **no se transfiere ni almacena en la VM productiva**:
el custodio la conecta sólo al host aislado y la retira al terminar. La ruta de
la identidad no forma parte de `production.env`; el contenido de la identidad
nunca se pasa como argumento, variable de entorno, log ni historial.

En el host aislado, el custodio conecta temporalmente la identidad bajo
`/media/custodian/backup-age-identity` con permisos `0600`; ese contenido no
forma parte de argumentos, variables, logs ni historial:

```bash
sudo /ruta/release/scripts/verify-backup.sh \
  --config /srv/chromat/restore/restore.env \
  --identity-file /media/custodian/backup-age-identity \
  /mnt/chromat-backups/20261109T120000Z
```

`--base-backup-dir` solo es necesario para verificar un incremental. Cada
incremental se calcula respecto de su full base, por lo que la verificación
restaura ese full y el incremental seleccionado; no depende de incrementales
intermedios. Un backup completo no debe recibir una base distinta.

```bash
sudo /ruta/release/scripts/verify-backup.sh \
  --config /srv/chromat/restore/restore.env \
  --identity-file /media/custodian/backup-age-identity \
  --base-backup-dir /mnt/chromat-backups/BASE-FULL \
  /mnt/chromat-backups/INCREMENTAL
```

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

Si se pierde la identidad usada con `--identity-file`, se declara un incidente operativo:

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
