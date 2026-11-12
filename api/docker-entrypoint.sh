#!/bin/sh
set -eu

if [ "$(id -u)" = "0" ]; then
  raw_data_dir="${RAW_DATA_DIR:-/app/uploads}"
  mkdir -p "$raw_data_dir"
  chown node:node "$raw_data_dir"
  exec setpriv --reuid=node --regid=node --init-groups "$@"
fi

exec "$@"
