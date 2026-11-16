# Backups cifrados y restauración verificable

El objetivo es RPO de 24 horas, RTO de 4 horas y al menos siete cadenas
recuperables. La retención inicial es 14 días; un incremental se conserva sólo
con su full base y todos los incrementales requeridos. Antes de toda
actualización de una instancia existente se crea un backup `full`, se verifica
su checksum y se restaura en aislamiento.

El operador ejecuta el backup diario en `America/Mazatlan`, registra hash,
migraciones, archivos faltantes y copia externa, y el custodio conserva la
clave de descifrado age. Si hay pérdida de un full base, la cadena deja de ser
recuperable y se inicia un full nuevo.

## Almacenamiento externo

Provisiona un disco, LVM o recurso de red independiente del filesystem raíz;
no uses un bind mount de `/`. Registra su UUID o fuente en `/etc/fstab`, monta
antes de producir backups y limita el directorio a root:

```bash
sudo install -d -o root -g root -m 0700 /mnt/chromat-backups
sudo mount /mnt/chromat-backups
findmnt -T /mnt/chromat-backups -o TARGET,SOURCE,MAJ:MIN
findmnt -T / -o TARGET,SOURCE,MAJ:MIN
sudo test -w /mnt/chromat-backups
```

Las fuentes y los identificadores `MAJ:MIN` deben ser distintos de `/`. Los
scripts abortan si el directorio no existe, no es escribible, no está montado,
comparte origen/dispositivo con root o está dentro de `BACKUP_ROOT`; nunca
aceptan silenciosamente un directorio vacío de root.

## Backup y retención

`production.env` queda en `/etc/chromat/production.env` con permisos `0600`.
Incluye `BACKUP_ROOT`, `BACKUP_EXTERNAL_DIR=/mnt/chromat-backups`,
`BACKUP_AGE_RECIPIENT_FILE`, secretos, estado y modo. El servidor recibe sólo
el destinatario público age, nunca la identidad privada:

```dotenv
BACKUP_SECRET_FILES=/etc/chromat/secrets/db_password /etc/chromat/secrets/db_root_password /etc/chromat/secrets/telegram_bot_token
```

```bash
sudo /srv/chromat/active/scripts/backup.sh \
  --config /etc/chromat/production.env --mode full
```

El primer backup de una instancia existente y el primero de cada cadena es
`full`; un incremental exige un full válido. La política no borra un full que
sea base de incrementales: conserva siempre al menos siete cadenas
recuperables. `scripts/retention.sh` aplica retención de datos crudos, no la
política de backups.

## Restauración aislada

La restauración nunca usa la configuración, red ni volúmenes productivos.
Prepara un host limpio, carga la release verificada y monta el almacenamiento
externo en sólo lectura. La identidad privada age la conecta temporalmente el
custodio **sólo en ese host**; jamás se transfiere, almacena o configura en la
VM productiva:

```bash
sudo /ruta/release/scripts/verify-backup.sh \
  --config /srv/chromat/restore/restore.env \
  --identity-file /media/custodian/backup-age-identity \
  /mnt/chromat-backups/FECHA-FULL
```

Para un incremental proporciona también su full base con
`--base-backup-dir`. Conserva evidencia de hashes, resultado de `Backup
verified`, modo, base y custodio antes de autorizar una actualización.
