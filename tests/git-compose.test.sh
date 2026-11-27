#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="$(mktemp -d "${TMPDIR:-/tmp}/chromat-git-compose.XXXXXX")"
run_id="$(openssl rand -hex 12)"
project="chromat-git-$run_id"
holder="$project-old-address"
export CHROMAT_API_IMAGE="$project-api:test"
export CHROMAT_INFERENCE_IMAGE="$project-inference:test"
export CHROMAT_DB_IMAGE=mariadb:11.8.2
export CHROMAT_NGINX_IMAGE=nginx:1.29.2-alpine
export PULL_POLICY=missing COMPOSE_PROFILES=""
export DB_PASSWORD_HOST_FILE="$runtime/db_password"
export DB_ROOT_PASSWORD_HOST_FILE="$runtime/db_root_password"
export TLS_CERT_HOST_PATH="$runtime/server.crt" TLS_KEY_HOST_PATH="$runtime/server.key"
export MODEL_HOST_PATH="$repo_root/inference/models/deterministic-model.json"
compose=(docker compose --project-name "$project" --project-directory "$repo_root"
  --env-file "$repo_root/.env.example" -f "$repo_root/compose.yaml" -f "$runtime/override.yaml")
started=false
holder_started=false
cleanup() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "$holder_started" == true ]]; then
    docker rm -f "$holder" >/dev/null || status=1
  fi
  if [[ "$started" == true ]]; then
    "${compose[@]}" down --volumes --remove-orphans >/dev/null || status=1
    docker image rm "$CHROMAT_API_IMAGE" "$CHROMAT_INFERENCE_IMAGE" >/dev/null || status=1
  fi
  rm -rf -- "$runtime"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077
openssl rand -hex 32 >"$DB_PASSWORD_HOST_FILE"
openssl rand -hex 32 >"$DB_ROOT_PASSWORD_HOST_FILE"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$TLS_KEY_HOST_PATH" -out "$TLS_CERT_HOST_PATH" \
  -subj /CN=nginx -addext subjectAltName=DNS:nginx >/dev/null 2>&1
cat >"$runtime/override.yaml" <<EOF
services:
  api:
    volumes:
      - $TLS_CERT_HOST_PATH:/run/probe-ca.crt:ro
  nginx:
    ports: !reset []
networks:
  edge:
    name: ${project}_edge
  internal:
    name: ${project}_internal
volumes:
  db_data:
    name: ${project}_db_data
  raw_data:
    name: ${project}_raw_data
EOF

probe() {
  "${compose[@]}" exec -T api node --input-type=module -e '
    import https from "node:https";
    import fs from "node:fs";
    const ca = fs.readFileSync("/run/probe-ca.crt");
    const get = (path) => new Promise((resolve, reject) => {
      const request = https.get(`https://nginx${path}`, { ca }, (response) => {
        let body = "";
        response.on("data", (chunk) => { body += chunk; });
        response.on("end", () => resolve({ status: response.statusCode, body }));
      });
      request.on("error", reject);
      request.setTimeout(3000, () => request.destroy(new Error("probe_timeout")));
    });
    let ready = false;
    for (let attempt = 0; attempt < 30; attempt++) {
      try {
        const result = await get("/health/ready");
        if (result.status === 200 && JSON.parse(result.body).status === "ready") {
          ready = true;
          break;
        }
      } catch (error) {
        console.error(`readiness retry: ${error.message}`);
      }
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
    if (!ready) throw new Error("proxy_not_ready");
    const panel = await get("/panel/");
    if (panel.status !== 200 || !panel.body.includes("CHROMAT")) {
      throw new Error("panel_not_available");
    }
  '
}

"${compose[@]}" config --quiet
started=true
"${compose[@]}" up -d --build --wait --wait-timeout 120
[[ -z "$("${compose[@]}" ps -aq telegram-worker)" ]]
probe
"${compose[@]}" exec -T api node --input-type=module -e '
  import fs from "node:fs/promises";
  import mysql from "mysql2/promise";
  import { databaseConfig } from "./src/database.js";
  const connection = await mysql.createConnection(databaseConfig());
  await connection.query("CREATE TABLE deployment_probe (value INT NOT NULL)");
  await connection.query("INSERT INTO deployment_probe VALUES (42)");
  await connection.end();
  await fs.writeFile("/app/uploads/deployment-probe.txt", "preserved");
'
"${compose[@]}" up -d --build --force-recreate --wait --wait-timeout 120
probe

nginx_id="$("${compose[@]}" ps -q nginx)"
api_id="$("${compose[@]}" ps -q api)"
old_ip="$(docker inspect "$api_id" --format "{{(index .NetworkSettings.Networks \"${project}_internal\").IPAddress}}")"
"${compose[@]}" rm -s -f api
docker run -d --name "$holder" --network "${project}_internal" --ip "$old_ip" \
  --entrypoint sh "$CHROMAT_NGINX_IMAGE" -c 'sleep 120' >/dev/null
holder_started=true
"${compose[@]}" up -d --no-deps --wait --wait-timeout 120 api
new_api_id="$("${compose[@]}" ps -q api)"
new_ip="$(docker inspect "$new_api_id" --format "{{(index .NetworkSettings.Networks \"${project}_internal\").IPAddress}}")"
[[ "$old_ip" != "$new_ip" ]]
[[ "$nginx_id" == "$("${compose[@]}" ps -q nginx)" ]]
probe
"${compose[@]}" exec -T api node --input-type=module -e '
  import fs from "node:fs/promises";
  import mysql from "mysql2/promise";
  import { databaseConfig } from "./src/database.js";
  const connection = await mysql.createConnection(databaseConfig());
  const [rows] = await connection.query("SELECT value FROM deployment_probe");
  await connection.end();
  if (rows.length !== 1 || rows[0].value !== 42) throw new Error("db_not_preserved");
  if (await fs.readFile("/app/uploads/deployment-probe.txt", "utf8") !== "preserved") {
    throw new Error("raw_not_preserved");
  }
'
printf 'PASS: core Compose without Telegram, TLS/panel, recreation, DNS refresh and persistence\n'
