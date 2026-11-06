# Etapa 1: Preparar el servidor

Guía para dejar la máquina virtual con Ubuntu Server lista para alojar los servicios de Chromat Cloud (Nginx, API Node.js, inferencia en Python y MariaDB, todos en contenedores Docker).

**Resultado esperado al terminar:** una VM con IP fija, acceso por SSH con llave, firewall activo, Docker y Docker Compose funcionando, y la estructura de carpetas del proyecto creada.

---

## 1. Requisitos

### Máquina virtual

| Recurso | Mínimo recomendado |
|---|---|
| CPU | 4 vCPU |
| RAM | 8 GB |
| Disco | 60 a 80 GB |
| Sistema | Ubuntu Server 24.04 LTS o 26.04 LTS, 64 bits |
| Red | Adaptador en **modo puente (bridged)** |

Notas:

- Docker Engine es compatible con Ubuntu 26.04, 25.10, 24.04 y 22.04 de 64 bits. Usa la versión que indique tu profesor.
- El modo puente es indispensable: con NAT, la Raspberry Pi no puede alcanzar la VM desde la red local.
- La VM necesita una IP fija para que la Raspberry Pi siempre sepa a dónde enviar las imágenes.
- El disco depende sobre todo de las imágenes; unas 315 por semana ocupan poco espacio.

### Lo que necesitas tener a la mano

- El ISO de Ubuntu Server instalado y un usuario con permisos de `sudo`.
- Tu computadora con cliente SSH.
- La Raspberry Pi conectada a la misma red.
- Los datos de tu red: IP libre para la VM, puerta de enlace (normalmente la IP del router) y DNS.

---

## 2. Qué se instala

En el sistema anfitrión (Ubuntu) solo va lo esencial:

| Paquete | Para qué |
|---|---|
| `openssh-server` | Acceso remoto por SSH |
| `ufw` | Firewall |
| `fail2ban` | Bloqueo de intentos repetidos de acceso |
| `unattended-upgrades` | Actualizaciones de seguridad automáticas |
| `git`, `curl`, `htop`, `net-tools`, `unzip` | Herramientas de trabajo y diagnóstico |
| Docker Engine y plugin de Compose | Ejecutar los servicios en contenedores |

Node.js, Python y MariaDB **no se instalan en el host**: corren dentro de contenedores, lo que mantiene el servidor limpio y reproducible.

---

## 3. Guía de comandos

Todos los comandos se ejecutan en la VM, salvo que se indique lo contrario.

### 3.1 Actualizar el sistema y herramientas base

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git ufw htop net-tools ca-certificates gnupg unzip fail2ban unattended-upgrades
sudo hostnamectl set-hostname chromat-server
sudo timedatectl set-timezone America/Mazatlan
```

Activar las actualizaciones de seguridad automáticas (acepta la opción por defecto):

```bash
sudo dpkg-reconfigure -plow unattended-upgrades
```

### 3.2 IP fija con Netplan

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

### 3.4 Firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status verbose
```

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

### 3.6 Estructura de carpetas del proyecto

```bash
mkdir -p ~/chromat-cloud/{docs/diagramas,nginx/conf.d,api/src/{config,routes,controllers,services,middlewares,db},api/tests,inference/{app,models},db/init,web/public,edge/systemd,scripts,uploads,backups}
cd ~/chromat-cloud
git init
```

Crear el `.gitignore` para no subir secretos, imágenes ni respaldos:

```bash
cat > .gitignore <<'EOF'
.env
node_modules/
uploads/
backups/
inference/models/
__pycache__/
*.log
EOF
```

Copia `README.md` a `~/chromat-cloud/` y esta guía a `~/chromat-cloud/docs/`.

---

## 4. Verificación final

```bash
lsb_release -a            # versión de Ubuntu
ip -4 a                   # IP fija
sudo ufw status           # firewall activo
docker ps                 # Docker responde
docker compose version    # Compose instalado
free -h && df -h          # memoria y disco
```

Desde la Raspberry Pi:

```bash
ping 192.168.1.50
```

### Lista de comprobación

- [ ] La VM tiene el adaptador de red en modo puente.
- [ ] La IP fija responde después de reiniciar (`sudo reboot`).
- [ ] Puedo entrar por SSH con llave desde mi computadora.
- [ ] `ufw` está activo y solo permite SSH, 80 y 443.
- [ ] `docker run hello-world` funciona sin `sudo`.
- [ ] `docker compose version` muestra la versión.
- [ ] La Raspberry Pi hace `ping` a la VM.
- [ ] La estructura de carpetas existe en `chromat-cloud`.

---

## 5. Seguridad: Docker y el firewall

Docker publica los puertos saltándose las reglas de `ufw`. Por eso, en el `docker-compose.yml` (etapa 2) **solo Nginx tendrá la sección `ports`**. La API, la inferencia y MariaDB se comunicarán por la red interna de Compose y nunca quedarán expuestas.

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
- El árbol de carpetas: `tree ~/chromat-cloud` (instala con `sudo apt install tree`).

---

**Siguiente:** Etapa 2, esqueleto de servicios con `docker-compose.yml` (Nginx, API, inferencia y MariaDB).
