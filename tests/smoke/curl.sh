#!/usr/bin/env bash

smoke_curl() {
  local tls_args=()
  if [[ "${ALLOW_INSECURE_TLS:-false}" == "true" ]]; then
    tls_args+=(--insecure)
  else
    : "${CA_CERT:?CA_CERT is required unless ALLOW_INSECURE_TLS=true}"
    tls_args+=(--cacert "$CA_CERT")
  fi
  command curl "${tls_args[@]}" "$@"
}
