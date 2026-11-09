#!/usr/bin/env bash
set -Eeuo pipefail

COMPOSE="${COMPOSE:-docker compose}"
MAINTENANCE_ACTIVE=0
WORKER_STOPPED=0

cleanup() {
  if (( MAINTENANCE_ACTIVE )); then
    ${COMPOSE} exec -T api node -e \
      'require("node:fs").rmSync("/app/uploads/.maintenance", { force: true })' \
      >/dev/null || true
  fi
  if (( WORKER_STOPPED )); then
    ${COMPOSE} start worker >/dev/null || true
  fi
}
trap cleanup EXIT

${COMPOSE} exec -T api node -e \
  'require("node:fs").writeFileSync("/app/uploads/.maintenance", "retention\n")'
MAINTENANCE_ACTIVE=1
${COMPOSE} stop worker >/dev/null
WORKER_STOPPED=1
${COMPOSE} run --rm --no-deps api npm run retention
${COMPOSE} exec -T api node -e \
  'require("node:fs").rmSync("/app/uploads/.maintenance", { force: true })'
MAINTENANCE_ACTIVE=0
${COMPOSE} start worker >/dev/null
WORKER_STOPPED=0
