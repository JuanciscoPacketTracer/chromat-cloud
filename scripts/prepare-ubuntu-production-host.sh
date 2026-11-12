#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  printf 'Run this script as root (for example: sudo %s)\n' "$0" >&2
  exit 2
fi

[[ -r /etc/os-release ]] || {
  printf '/etc/os-release is required\n' >&2
  exit 1
}
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "26.04" ]] || {
  printf 'CHROMAT production requires Ubuntu Server 26.04; found %s %s\n' \
    "${ID:-unknown}" "${VERSION_ID:-unknown}" >&2
  exit 1
}
[[ "$(uname -m)" == "x86_64" ]] || {
  printf 'CHROMAT production requires amd64 (x86_64); found %s\n' "$(uname -m)" >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get update

docker_source=/etc/apt/sources.list.d/docker.list
expected_source="deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable"
expected_docker_packages=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
)
incompatible_docker_packages=(
  docker.io
  docker-compose
  docker-compose-v2
  podman-docker
  containerd
  runc
)

fail_existing_docker() {
  printf '%s\n' "$1" >&2
  printf '%s\n' \
    'Resolve the existing installation manually: remove incompatible packages, install Docker Engine and Docker Compose Plugin from download.docker.com, then rerun this script.' >&2
  exit 1
}

installed_package() {
  dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii '
}

docker_installed=0
compose_installed=0
command -v docker >/dev/null && docker_installed=1
docker compose version >/dev/null 2>&1 && compose_installed=1

if (( docker_installed != compose_installed )); then
  fail_existing_docker 'Existing Docker installation is incomplete (Engine and Compose Plugin must both be installed); this script will not modify it.'
fi

if (( docker_installed )); then
  for package in "${expected_docker_packages[@]}"; do
    installed_package "$package" || fail_existing_docker \
      "Existing Docker installation is incomplete: required package is missing: $package"
  done
  for package in "${incompatible_docker_packages[@]}"; do
    ! installed_package "$package" || fail_existing_docker \
      "Existing Docker installation has incompatible package: $package"
  done
  docker_binary="$(readlink -f "$(command -v docker)")"
  dpkg-query -S "$docker_binary" 2>/dev/null | grep -Eq '^docker-ce-cli:' ||
    fail_existing_docker \
      "Existing docker binary is not provided by docker-ce-cli: $docker_binary"
  [[ -r /etc/apt/keyrings/docker.asc ]] ||
    fail_existing_docker 'Existing Docker installation is missing the Docker apt signing key.'
  [[ -f "$docker_source" ]] && grep -Fxq "$expected_source" "$docker_source" ||
    fail_existing_docker 'Existing Docker installation does not use the required official Docker apt source.'
  apt-cache policy docker-ce | grep -Fq 'download.docker.com' ||
    fail_existing_docker 'Existing Docker package metadata does not identify download.docker.com as its source.'
else
  docker_artifacts=0
  for path in \
    /etc/docker \
    /etc/default/docker \
    /etc/systemd/system/docker.service.d \
    /etc/apt/sources.list.d/docker.list \
    /etc/apt/keyrings/docker.asc; do
    [[ -e "$path" ]] && docker_artifacts=1
  done
  for package in "${expected_docker_packages[@]}" "${incompatible_docker_packages[@]}"; do
    installed_package "$package" && docker_artifacts=1
  done
  if (( docker_artifacts )); then
    fail_existing_docker 'Existing Docker files or packages were detected; this script will not replace or repair them.'
  fi
fi

apt-get install --yes ca-certificates curl gnupg openssl python3 age ufw

if (( ! docker_installed )); then
  install -d -m 0755 /etc/apt/keyrings
  if [[ -e "$docker_source" ]] && ! grep -Fxq "$expected_source" "$docker_source"; then
    printf 'Refusing to replace existing Docker apt source: %s\n' "$docker_source" >&2
    exit 1
  fi
  if [[ ! -e /etc/apt/keyrings/docker.asc ]]; then
    curl --fail --silent --show-error --location \
      https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  if [[ ! -e "$docker_source" ]]; then
    printf '%s\n' "$expected_source" >"$docker_source"
  fi
  apt-get update
  apt-get install --yes "${expected_docker_packages[@]}"
fi

systemctl enable --now docker
docker version --format '{{.Server.Version}}'
docker compose version --short

install -d -m 0750 /srv/chromat /srv/chromat/releases /srv/chromat/promotions
install -d -m 0700 /srv/chromat/tls /srv/chromat/backups /etc/chromat /etc/chromat/secrets
install -d -m 0700 /var/lib/chromat /var/lib/chromat/backup-state

printf '%s\n' 'PASS: Ubuntu production host prepared; provision secrets, backup recipient, TLS, and a verified release next.'
