#!/usr/bin/env bash
set -euo pipefail

main() {
  local repo_root
  local -a docker_command=(docker)
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cd "$repo_root"

  if [[ $# -eq 1 && "$1" == "--sudo" ]]; then
    docker_command=(sudo docker)
  elif (($#)); then
    printf 'Usage: bash scripts/update.sh [--sudo]\n' >&2
    return 2
  fi
  for command_name in git "${docker_command[@]}"; do
    command -v "$command_name" >/dev/null || {
      printf '%s is required\n' "$command_name" >&2
      return 1
    }
  done
  if [[ ! -f .env ]]; then
    printf 'Missing .env. Follow docs/installation/git-compose.md first.\n' >&2
    return 1
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    printf 'Working tree is not clean. Commit or preserve local changes before updating.\n' >&2
    return 1
  fi
  git rev-parse --verify '@{upstream}' >/dev/null || {
    printf 'The current branch needs an upstream before updating.\n' >&2
    return 1
  }
  "${docker_command[@]}" compose version >/dev/null
  "${docker_command[@]}" info >/dev/null
  git pull --ff-only
  "${docker_command[@]}" compose config --quiet
  "${docker_command[@]}" compose up -d --build --force-recreate --wait --wait-timeout 120
  "${docker_command[@]}" compose ps
  printf 'Update complete. Verify the panel and an image upload from a client.\n'
}

main "$@"; exit
