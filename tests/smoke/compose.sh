#!/usr/bin/env bash

smoke_compose() {
  if [[ -z "${SMOKE_COMPOSE_FILE:-}" ]]; then
    docker compose "$@"
    return
  fi

  : "${SMOKE_COMPOSE_PROJECT:?SMOKE_COMPOSE_PROJECT is required with SMOKE_COMPOSE_FILE}"
  : "${SMOKE_COMPOSE_ENV_FILE:?SMOKE_COMPOSE_ENV_FILE is required with SMOKE_COMPOSE_FILE}"
  docker compose \
    --project-name "$SMOKE_COMPOSE_PROJECT" \
    --env-file "$SMOKE_COMPOSE_ENV_FILE" \
    --file "$SMOKE_COMPOSE_FILE" \
    "$@"
}
