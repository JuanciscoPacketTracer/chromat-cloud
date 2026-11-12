# Etapa 1: Provisionar y endurecer Ubuntu Server

Runbook manual para dejar un único Ubuntu Server amd64 listo para ejecutar una
release verificada de CHROMAT Server mediante Docker Compose. Fedora construye
y valida los artefactos; este servidor no reconstruye imágenes ni monta código
fuente.

**Resultado esperado al terminar:** un host Ubuntu 26.04 LTS amd64 con nombre
`chromat.lan`, acceso administrativo por SSH con llave, almacenamiento
validado, Docker y Compose instalados desde el repositorio oficial, firewall
activo y un servicio de arranque controlado para la release activa.

---

## 1. Requisitos

### Máquina virtual

| Recurso | Mínimo recomendado |
|---|---|
| CPU | 4 vCPU |
| RAM | 8 GB |
| Disco | 80 GB disponibles como mínimo para la asignación lógica inicial |
| Sistema | Ubuntu Server 26.04 LTS, 64 bits |
| Red | Adaptador en **modo puente (bridged)** e IP fija o reserva DHCP |

La línea base de despliegue usa arquitectura **x86_64 (amd64)**. Docker Engine
se instala desde el repositorio oficial de Docker y Compose mediante el plugin
`docker-compose-plugin`; no se usa el script de conveniencia.


## 2. Qué se instala

En el sistema anfitrión (Ubuntu) solo va lo esencial:

| Paquete | Para qué |
|---|---|
| `openssh-server` | Acceso remoto por SSH |
| `ufw` | Firewall |
| `fail2ban` | Bloqueo de intentos repetidos de acceso |
| `unattended-upgrades` | Actualizaciones de seguridad automáticas |
| `git`, `curl`, `htop`, `net-tools`, `unzip`, `lsb-release` | Herramientas de trabajo y diagnóstico |
| Docker Engine y plugin de Compose | Ejecutar los servicios en contenedores |

Node.js 26, Python 3.13 y MariaDB 11.8 **no se instalan en el host**: corren
dentro de contenedores con etiquetas de versión exactas, lo que mantiene el
servidor limpio y reproducible. Python 3.14 solo se considerará después de
validar sus dependencias de inferencia.

---

## 3. Guía de comandos

Todos los comandos se ejecutan en la VM, salvo que se indique lo contrario.

### 3.1 Actualizar el sistema y herramientas base

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git ufw htop net-tools ca-certificates gnupg unzip \
  fail2ban unattended-upgrades lsb-release
sudo hostnamectl set-hostname chromat.lan
sudo timedatectl set-timezone America/Mazatlan
```

Activar las actualizaciones de seguridad automáticas (acepta la opción por defecto):

```bash
sudo dpkg-reconfigure -plow unattended-upgrades
```

### 3.2 Red, nombre y resolución local

Identifica el nombre de la interfaz de red (por ejemplo `enp0s3`) y el archivo de configuración:

```bash
ip a
ls /etc/netplan/
```

Edita el archivo (el nombre puede variar):

```bash
sudo nano /etc/netplan/50-cloud-init.yaml
```

Ejemplo; ajusta interfaz, IP, puerta de enlace y DNS a tu red:

```yaml
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: false
      addresses: [192.168.1.50/24]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
```

Aplica la configuración con `try`, que revierte los cambios si pierdes la conexión:

```bash
sudo netplan try
```

Registra el nombre operativo en el servidor y en cada cliente que no use el
DNS del router. Sustituye `192.168.1.50` por la IP fija real:

```text
192.168.1.50 chromat.lan
```

En el servidor:

```bash
printf '192.168.1.50 chromat.lan\n' | sudo tee -a /etc/hosts
getent hosts chromat.lan
```

El certificado de producción debe cubrir `chromat.lan`; las IP usadas para
probar HTTPS también deben estar incluidas en sus SAN. La emisión y
provisionamiento de TLS pertenecen al runbook de promoción, no a la instalación
del sistema operativo.

### 3.3 SSH con llave

En la VM:

```bash
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

Desde **tu computadora** (no desde la VM):

```bash
ssh-keygen -t ed25519
ssh-copy-id usuario@192.168.1.50
ssh usuario@192.168.1.50
```

Cuando confirmes que entras sin contraseña, puedes desactivar el acceso con contraseña. En la VM, edita `/etc/ssh/sshd_config`, cambia la línea a `PasswordAuthentication no` y reinicia el servicio:

```bash
sudo nano /etc/ssh/sshd_config
sudo systemctl restart ssh
```

> No cierres tu sesión actual hasta comprobar en otra terminal que sigues pudiendo entrar con la llave.

### 3.4 Firewall y superficie de red

La superficie de aplicación es únicamente TCP/443. SSH es una excepción de
administración y debe limitarse a la red o IP de administración conocida.
No se abre TCP/80: no hay redirección HTTP en esta fase.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.1.0/24 to any port 22 proto tcp comment 'SSH administracion'
sudo ufw allow 443/tcp comment 'CHROMAT HTTPS'
sudo ufw enable
sudo ufw status verbose
```

Si la administración llega desde otra red, cambia `192.168.1.0/24` antes de
activar UFW. La salida HTTPS del `telegram-worker` se valida por separado en
la promoción; no se abre ningún puerto entrante para Telegram.

### 3.5 Docker Engine y Compose (repositorio oficial)

Quitar paquetes no oficiales que puedan chocar (si dice que no hay ninguno instalado, es normal):

```bash
sudo apt remove $(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc | cut -f1)
```

Agregar el repositorio oficial de Docker:

```bash
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
```

Instalar Docker:

```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Usar Docker sin `sudo`, habilitarlo al arranque y verificar:

```bash
sudo usermod -aG docker $USER
newgrp docker
sudo systemctl enable docker
docker run hello-world
docker compose version
```

### 3.6 Almacenamiento y permisos

La asignación puede residir inicialmente en un único disco, pero las áreas se
mantienen separadas lógicamente para poder medirlas y migrarlas después:

| Área | Mínimo inicial | Uso |
|---|---:|---|
| Crudos | 20 GiB | Imágenes recibidas y retención operativa |
| Derivados | 10 GiB | Resultados derivados y exportaciones |
| MariaDB | 20 GiB | Volumen persistente de la base |
| Backups | 20 GiB | Retención local y copia de la promoción |
| Reserva operativa | 10 GiB | Imágenes, logs, actualizaciones y margen |

La topología actual usa el volumen Docker `chromat_raw_data` para crudos y
`chromat_db_data` para MariaDB y los metadatos derivados; `derived` queda como
reserva lógica para exportaciones o una futura separación. Por eso se
contabilizan tanto los volúmenes Docker como las áreas del host.

Valida que las áreas estén en el filesystem esperado y que haya al menos
80 GiB disponibles antes de cargar una release:

```bash
sudo install -d -m 0750 -o "$USER" -g "$USER" \
  /srv/chromat/{releases,backups,raw,derived,mariadb,logs,secrets,tls}
df -h /srv/chromat /var/lib/docker
findmnt -T /srv/chromat
test "$(df --output=avail -k /srv/chromat | tail -n 1)" -ge 83886080
docker system df
```

El volumen de MariaDB y el volumen de crudos de Compose deben medirse después
de la primera puesta en marcha:

```bash
docker volume inspect chromat_db_data chromat_raw_data
sudo du -sh /srv/chromat/{releases,backups,raw,derived,mariadb,logs}
```

Protege las áreas que contendrán secretos o backups. Los valores reales se
provisionan fuera de Git y fuera del paquete de artefactos:

```bash
sudo chown -R root:root /srv/chromat/{secrets,tls}
sudo chmod 0700 /srv/chromat/{secrets,tls}
sudo chmod 0700 /srv/chromat/backups
```

### 3.7 Directorios de releases, no código fuente

La promoción coloca el paquete verificado en una release versionada. No se
clona el repositorio ni se monta el árbol de desarrollo en producción:

```bash
sudo install -d -m 0755 /srv/chromat/releases
sudo ln -sfn /srv/chromat/releases/VERSION /srv/chromat/active
sudo chown -R "$USER":"$USER" /srv/chromat/releases
```

La instalación de imágenes, `production.env`, certificados y tokens sigue el
procedimiento de `docs/deployment/artifacts.md`. La clave privada de la CA
nunca se copia al servidor.

### 3.8 Arranque controlado

Docker debe arrancar con el sistema y Compose debe iniciar únicamente la
release activa, sin construir ni descargar imágenes:

```bash
sudo systemctl enable --now docker
sudo tee /etc/systemd/system/chromat-compose.service >/dev/null <<'EOF'
[Unit]
Description=CHROMAT Server Compose release
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/srv/chromat/active
ExecStart=/usr/bin/docker compose --env-file production.env up -d --no-build
ExecStop=/usr/bin/docker compose --env-file production.env down
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable chromat-compose.service
```

Activa el servicio solo después de que la release y sus secretos hayan sido
verificados. La apertura de tráfico, migraciones, readiness y smoke tests son
pasos posteriores de la promoción.

---

## 4. Verificación final

```bash
lsb_release -a            # versión de Ubuntu
dpkg --print-architecture # debe mostrar amd64
hostname --fqdn           # debe resolver chromat.lan
ip -4 a                   # IP fija
sudo ufw status verbose   # firewall activo, SSH restringido y solo 443 público
docker ps                 # Docker responde
docker compose version    # Compose instalado
free -h                   # debe mostrar al menos 8 GiB
df -h /srv/chromat /var/lib/docker
ss -lntup                 # solo 443 público; no 80, 3000, 3306 ni 8000
```

Desde la Raspberry Pi:

```bash
ping 192.168.1.50
```

### Lista de comprobación

- [ ] El sistema es Ubuntu 26.04 LTS amd64 con 4 vCPU y al menos 8 GiB RAM.
- [ ] La IP fija responde después de reiniciar (`sudo reboot`).
- [ ] `chromat.lan` resuelve a la IP operativa desde el servidor y los clientes.
- [ ] El espacio mínimo de crudos, derivados, MariaDB, backups y reserva está documentado y disponible.
- [ ] Puedo entrar por SSH con llave desde la red de administración.
- [ ] `ufw` está activo, no permite TCP/80 y solo publica TCP/443 para la aplicación.
- [ ] `docker run hello-world` funciona sin `sudo`.
- [ ] `docker compose version` muestra la versión instalada desde el repositorio oficial.
- [ ] Docker está habilitado al arranque y `chromat-compose.service` queda preparado.
- [ ] No hay listeners públicos para API, MariaDB, inferencia ni workers.

---

## 5. Seguridad: Docker y el firewall

Docker puede publicar puertos saltándose reglas de `ufw`. Por eso, en
`compose.yaml` **solo Nginx tiene la sección `ports`**, limitada a
`443:443`. La API, la inferencia, MariaDB y los workers se comunican por las
redes internas de Compose y nunca deben recibir una publicación del host.
Verifica esta condición con `docker compose config` y `ss -lntup` antes de
activar el tráfico.

---

## 6. Problemas frecuentes

| Problema | Causa probable | Solución |
|---|---|---|
| Perdí la conexión después de `netplan` | IP, puerta de enlace o interfaz incorrectas | Usar siempre `sudo netplan try`; si falla, corregir el archivo desde la consola de la VM |
| La Raspberry Pi no alcanza la VM | Adaptador en NAT en lugar de puente | Cambiar a modo puente en el hipervisor y reiniciar la VM |
| `permission denied` al usar `docker` | El usuario no está en el grupo `docker` | `sudo usermod -aG docker $USER` y volver a iniciar sesión |
| `ssh-copy-id` pide contraseña y falla | SSH con contraseña ya desactivado o IP incorrecta | Verificar la IP con `ip a` y reactivar temporalmente `PasswordAuthentication yes` |
| Conflicto de paquetes al instalar Docker | Quedó instalado `docker.io` u otro paquete no oficial | Repetir el paso de desinstalación de la sección 3.5 |

---

## 7. Evidencia para el documento de investigación

Guarda capturas de pantalla de lo siguiente; sirven para el Capítulo IV:

- Salida de `lsb_release -a` y `free -h`.
- Configuración de red del hipervisor (modo puente).
- Salida de `sudo ufw status verbose`.
- Salida de `docker run hello-world` y `docker compose version`.
- El árbol de releases: `tree /srv/chromat` (instala con `sudo apt install tree`).

---

**Siguiente:** Etapa 2, esqueleto de servicios con `docker-compose.yml` (Nginx, API, inferencia y MariaDB).
