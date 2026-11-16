#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/prepare-ubuntu-production-host.sh"

for docker_path in \
  /etc/docker \
  /etc/default/docker \
  /etc/systemd/system/docker.service.d \
  /etc/apt/sources.list.d/docker.list \
  /etc/apt/keyrings/docker.asc; do
  grep -Fq "$docker_path" "$script"
done
grep -Fq "Existing Docker files or packages were detected" "$script"
for package in \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin \
  docker.io \
  docker-compose \
  podman-docker \
  runc; do
  grep -Fq "$package" "$script"
done
grep -Fq "download.docker.com" "$script"
grep -Fq "docker-ce-cli:" "$script"
grep -Fq "will not modify it" "$script"
grep -Fq "Resolve the existing installation manually" "$script"

docker_preflight_line="$(grep -n 'docker_installed=0' "$script" | head -n 1 | cut -d: -f1)"
general_dependencies_line="$(grep -n 'apt-get install --yes ca-certificates' "$script" | head -n 1 | cut -d: -f1)"
if (( docker_preflight_line >= general_dependencies_line )); then
  printf 'FAIL: Docker installation preflight must run before general dependency installation\n' >&2
  exit 1
fi

if grep -Eq '(touch|install -m).*?/etc/chromat/(secrets|backup-age-recipient)' "$script"; then
  printf 'FAIL: host preparation must not create secret files\n' >&2
  exit 1
fi

printf 'PASS: Ubuntu production host preparation contract\n'
