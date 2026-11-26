# Fabricación offline en GitHub Actions

Este flujo usa runners hospedados `ubuntu-24.04`, no Fedora ni un runner
self-hosted. Los estudiantes solo necesitan la VM Ubuntu de destino.
No se ha ejecutado en GitHub ni validado Docker real durante su preparación
local. No sustituye las pruebas de instalación, persistencia, backup y restore.

## Identidad y autorizaciones

Los workflows son exclusivamente `workflow_dispatch`: no hay triggers push,
pull request, schedule ni publicación automática. Las acciones están fijadas
por commit. Docker Engine se fija en 29.10.1, con image store containerd y
socket Unix explícito creado por `docker/setup-docker-action`. No se expone TCP.
Cada job obtiene un runner y un image store independientes.

Antes de ejecutarlos deben autorizarse revisión, commit, push y ejecución.
Las correcciones locales y estos archivos nuevos deben formar parte de un
commit revisado; un checkout de main que no los contenga no es equivalente.
La versión a empaquetar requiere tag local/remoto apuntando exactamente al
commit del workflow seleccionado. No se crean ni mueven tags en CI.

GitHub exige que el archivo con `workflow_dispatch` exista en la rama
predeterminada, `main`; subirlo únicamente a la rama del PR no basta.
Después de integrar el PR, registrar el SHA completo de `main` y revisar
el contenido integrado: merge o squash pueden producir un SHA distinto
del último commit revisado de la rama. La primera ejecución usa `ref=main`,
`version=busybox-check` y `package=false`, sin requerir un tag.
Conservar run ID, attempt, inputs y `head_sha`; atribuir la prueba al SHA
previsto solo si coincide con `head_sha`. Si `main` avanza antes de ejecutar,
revisar y autorizar esa nueva identidad antes de continuar.

La integración no autoriza ninguna ejecución. La primera autorización de
Actions cubre solo BusyBox; fabricar el paquete y crear un Draft requieren
autorizaciones independientes. `package=false` es un valor predeterminado,
no una barrera técnica de aprobación: un usuario con escritura puede
solicitar `package=true`. El workflow Draft también queda disponible para
dispatch manual, pero no debe ejecutarse sin autorización y sin configurar
previamente las protecciones de `offline-release`.

La captura experimental aprobada se conserva intacta. Estos workflows no
consumen esa captura ni la convierten en release: rechazan `experimental-*`
y usan el modo normal del empaquetador sobre un checkout limpio identificado.
Los nuevos archivos no estaban en su inventario; antes de reutilizar el flujo
experimental con un checkout ampliado se requiere una nueva revisión/captura.

## 1. BusyBox real, sin fabricar todavía

Después de autorización, abrir Actions → Offline package → Run workflow.
Elegir el ref revisado, `version=busybox-check` y `package=false`.

El primer job descarga el manifiesto linux/amd64 fijado, exporta BusyBox y
verifica manifiesto, config, capas, exclusividad OCI y su ID nativo. Guarda
un TAR y recibo temporal ligados al commit, run y attempt.
El segundo job carga ese TAR en otro runner, exige el mismo ID nativo,
reexporta y verifica otra vez, y ejecuta BusyBox con `--pull=never` y
`--network=none`. No cambia ninguno de los pins del verificador existente.
El artifact de prueba dura siete días; no es un paquete instalable.

## 2. Paquete completo

Solo después de revisar la prueba BusyBox y autorizar fabricación: ejecutar
Offline package con el tag/commit revisado, `version=TAG` y `package=true`.
La prueba BusyBox se repite y debe pasar antes del empaquetado.

El runner exige 8 GiB libres antes de construir. Es un guard inicial, no
garantía de capacidad máxima: cachés y exports pueden agotar el disco.
Se precargan las bases Dockerfile porque el empaquetador registra sus
RepoDigests mediante image inspect. Se usa únicamente `.env.example`.
No se envían secretos, TLS privados, datos productivos ni backups.

El empaquetador y sus validadores existentes comprueban los cinco TAR,
Compose, migraciones db/migrations y demás archivos operativos.
La validación semántica carga/reexporta las imágenes en CI. El paquete
conserva los seis servicios y `PULL_POLICY=never` para Ubuntu.

Se suben cuatro archivos al artifact
`chromat-offline-TAG-ATTEMPT`, con retención de 30 días:

- `chromat-TAG.tar.gz`
- `chromat-TAG.tar.gz.sha256`
- `chromat-TAG.manifest.json`
- `chromat-TAG.ci-provenance.json`

El recibo CI registra commit, workflow, run/attempt, Docker/image store y
checksum. No es una firma ni demuestra instalación funcional.
El TAR debe ser menor de 2 GiB; excederlo aborta, sin dividirlo ni modificar
el contrato automáticamente. Dockerfiles usan tags de versión: no se promete
que reconstrucciones futuras sean idénticas bit a bit.

## 3. Draft separado; publicación definitiva fuera de CI

Antes de usar Offline Draft Release, configurar manualmente el environment
`offline-release` con revisores obligatorios y restricciones de refs
adecuadas. El nombre del environment por sí solo no crea esas protecciones.
No se configuró el environment ni se cambiaron permisos del repositorio.

Con autorización, seleccionar exactamente el mismo commit/ref que fabricó
el paquete e introducir versión, run ID exitoso y `CREATE_DRAFT`.
El workflow comprueba por API que el run fue manual, exitoso, del workflow
esperado y del mismo repositorio/commit. No acepta un artifact de otro código.
Identifica el attempt y verifica los cuatro assets, manifiesto, checksum y
miembros TAR antes de extraer/cargar. Usa los validadores del checkout
identificado, no scripts ejecutables descargados sin verificar.

El creador existente revalida las imágenes y genera exclusivamente Draft;
se añade el recibo CI sin sobrescribir assets. Si ese último upload falla,
puede quedar un Draft incompleto: inspeccionarlo, no publicarlo.
Solo este job tiene `contents: write`; la fabricación tiene `contents: read`.

La publicación definitiva requiere prueba real en Ubuntu y autorización
separada. No hay comando `gh release edit --draft=false` en estos workflows.
Actions artifacts son transitorios; GitHub Releases será el canal estudiantil.
No ejecutar builds ni pulls en Ubuntu. Una VM limpia aún requiere preparación
del host, secretos/TLS externos y filesystem independiente para backups.

## Comprobaciones locales

```bash
python3 -B tests/offline-ci.test.py
python3 -B tests/image-identity.test.py
python3 -B tests/package-artifacts.test.py
git diff --check
```

Los tests CI emplean Docker/GitHub simulados y fixtures temporales. No prueban
la instalación de Docker por la acción, capacidad del runner o interoperabilidad
real con Ubuntu. Esas comprobaciones son gates pendientes de ejecución autorizada.
