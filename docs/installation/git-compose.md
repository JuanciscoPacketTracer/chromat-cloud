# Instalar CHROMAT en una VM Ubuntu

Guía para **Ubuntu Server 26.04 LTS amd64**, una VM con red puente, 4 vCPU,
8 GB de RAM y disco de 80 GB. Necesita Internet, acceso SSH y el puerto 443
libre. No necesita instalar Node.js, Python ni MariaDB en Ubuntu.

La instalación, HTTPS, el reinicio y una actualización con
`scripts/update.sh --sudo` se comprobaron en una VM limpia. Ejecute los
comandos de cada bloque por separado y deténgase ante cualquier error.

## 1. Conectarse a la VM

En Ubuntu, consulte su dirección y confirme que SSH esté activo:

```bash
ip -br -4 addr
systemctl is-active ssh
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Desde Fedora, sustituya `USUARIO` e `IP_VM`:

```bash
ssh USUARIO@IP_VM
```

En la primera conexión compare la huella con la mostrada en la VM y acepte
solo si coincide. Los siguientes comandos se ejecutan **en la VM por SSH**.

## 2. Instalar Docker y Git

Para una instalación limpia, siga los comandos del
[repositorio oficial de Docker](https://docs.docker.com/engine/install/ubuntu/):

```bash
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

```bash
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: resolute
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin git
sudo systemctl enable --now docker
sudo docker compose version
sudo docker run --rm hello-world
```

Debe aparecer `Hello from Docker!`. No ejecute estos bloques sobre otra
instalación Docker sin revisar antes su configuración.

## 3. Clonar CHROMAT

La rama indicada contiene actualmente el flujo simplificado:

```bash
git clone --branch research/wayfinder-deployment-baseline --single-branch \
  https://github.com/JuanciscoPacketTracer/chromat-cloud.git
cd chromat-cloud
```

## 4. Preparar configuración y certificados

Primero consulte la IPv4 de la VM:

```bash
ip -br -4 addr
```

Sustituya `IP_VM` por esa IPv4 en el bloque. Ejecútelo **una sola vez**:

```bash
(
  set -e
  if [ -e .env ] || [ -e secrets ] || [ -e certs/dev ]; then
    echo 'La configuración ya existe; no se sobrescribió.' >&2
    exit 1
  fi
  umask 077
  cp .env.example .env
  mkdir secrets
  openssl rand -hex 32 > secrets/db_password
  openssl rand -hex 32 > secrets/db_root_password
  CHROMAT_VM_IP=IP_VM bash scripts/dev-tls.sh
  sudo docker compose config --quiet
)
```

El certificado es solo para laboratorio; no lo use en un servidor público.
Si cambia la IP, deberá configurar un certificado válido para la nueva dirección.
No comparta contraseñas ni claves privadas.

## 5. Arrancar y crear el operador

```bash
sudo docker compose up -d --build --wait --wait-timeout 180
sudo docker compose ps
curl --fail --cacert certs/dev/ca.crt https://IP_VM/health/ready
```

Sustituya `IP_VM` en `curl`. Debe responder `{"status":"ready"}`. Telegram no
se inicia por defecto. Para activarlo, guarde el token en
`secrets/telegram_bot_token`, configure `PANEL_URL` y añada
`COMPOSE_PROFILES=telegram` a `.env`; después reinicie con Compose.

Cree la contraseña para `admin`; no aparecerá mientras la escribe:

```bash
(
  umask 077
  set -C
  read -r -s -p 'Contraseña nueva para admin: ' password
  printf '\n'
  test -n "$password" && printf '%s\n' "$password" > secrets/operator_password
)
```

```bash
sudo docker compose run --rm --no-deps \
  -v "$PWD/secrets/operator_password:/run/secrets/operator_password:ro" \
  -e OPERATOR_PASSWORD_FILE=/run/secrets/operator_password \
  api npm run create-operator -- admin
```

Debe aparecer `Created operator: admin`. Este paso solo se realiza una vez.

## 6. Abrir el panel desde Fedora

En Fedora, sustituya `USUARIO` e `IP_VM`:

```bash
(
  umask 077
  set -C
  ssh USUARIO@IP_VM \
    'cat ~/chromat-cloud/certs/dev/ca.crt' > "$HOME/chromat-server-ca.crt"
)
curl --fail --cacert "$HOME/chromat-server-ca.crt" \
  https://IP_VM/health/ready
```

Importe `~/chromat-server-ca.crt` como autoridad para sitios web en el navegador.
Si anteriormente aceptó una excepción de certificado, cierre y reinicie el
navegador. Abra `https://IP_VM/panel/` e inicie sesión como `admin`. No
introduzca la contraseña si el navegador indica que la conexión no es segura.
El panel aparece vacío hasta crear una Fuente de monitoreo.

### Preparar una demostración con las cinco fotografías

Ejecute explícitamente este comando **dentro de cada VM Ubuntu**, después de
actualizar el repositorio. Requiere Python 3, incluido en Ubuntu Server; no
instala paquetes Python. Sustituya `IP_VM` por la IP de esa VM:

```bash
python3 scripts/demo-photographs.py --url https://IP_VM --username admin
```

Solicita la contraseña del operador sin mostrarla. Crea una Fuente de prueba
y envía las cinco fotografías de `pruebas/fotografias/` por la API existente,
espera el procesamiento y muestra el resultado oficial. `mango` es una etiqueta
de demostración, no una identificación verificada de las fotografías. `day-1`
y `day-3` son duplicadas exactas, pero se conservan como eventos diferentes.
HSV es experimental y CNN es un simulador; esta demostración no valida precisión
científica, recomendaciones de cosecha ni hardware.

Abra el panel como operador y pulse **Actualizar fuentes**. El productor no ve
la fuente hasta que el operador se la asigne explícitamente. No se crean cuentas
ni contraseñas compartidas, no se muestran imágenes en el panel y la fuente de
prueba no genera alertas externas.

Puede repetir el mismo comando: usa los mismos identificadores de fuente y
eventos, sin crear otra demo. Conserva su API key y manifiesto privados en
`secrets/demo-photographs/`, excluidos de Git. No comparta ni borre ese directorio:
sin él no puede recuperarse la identidad de la prueba. Cada checkout mantiene
su propio manifiesto; no ejecute la demo desde varios checkouts para la misma
instalación. Cambiar la URL o las fotografías requiere revisión del operador;
el comando se detiene para evitar enviar credenciales a otro servidor o cambiar
un evento existente.

Si recibe HTTP 500, se detiene sin reintentar automáticamente. Conserve la hora
y el identificador de evento, revise el fallo y repita el comando para continuar
con los mismos identificadores. Un evento en estado `failed` no se reprocesa al
reenviarlo. El posible HTTP 500 observado en un reintento inmediato de `day-2`
sigue siendo un hallazgo de ingesta pendiente, sin causa confirmada.
Este comando no se ejecuta automáticamente al instalar o actualizar la VM.

## 7. Actualizar el servidor

Después de publicar los cambios en la misma rama, en la VM:

```bash
cd ~/chromat-cloud
bash scripts/update.sh --sudo
sudo docker compose ps
curl --fail --cacert certs/dev/ca.crt https://IP_VM/health/ready
```

Sustituya `IP_VM`. El script requiere un árbol Git limpio y usa `sudo` solo
para Docker. Las migraciones se ejecutan al arrancar; no hay rollback automático.
Compare `.env.example` con su `.env` si se añaden variables nuevas.

## 8. Si algo falla

```bash
cd ~/chromat-cloud
sudo docker compose ps -a
sudo docker compose logs --tail 100 nginx api worker inference db
```

No comparta logs con información privada. No ejecute `docker compose down -v`:
elimina los volúmenes de datos. Sin backups, una pérdida del disco puede
eliminar las fotografías y la base de datos.
