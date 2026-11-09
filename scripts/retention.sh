#!/usr/bin/env bash
set -Eeuo pipefail

COMPOSE="${COMPOSE:-docker compose}"
MAINTENANCE_ACTIVE=0

cleanup() {
  if (( MAINTENANCE_ACTIVE )); then
    ${COMPOSE} exec -T api node -e \
      'require("node:fs").rmSync("/app/uploads/.maintenance", { force: true })' \
      >/dev/null || true
  fi
}
trap cleanup EXIT

${COMPOSE} exec -T api node -e \
  'require("node:fs").writeFileSync("/app/uploads/.maintenance", "retention\n")'
MAINTENANCE_ACTIVE=1
${COMPOSE} run --rm --no-deps api npm run retention
MAINTENANCE_ACTIVE=0
${COMPOSE} exec -T api node -e \
  'require("node:fs").rmSync("/app/uploads/.maintenance", { force: true })'
