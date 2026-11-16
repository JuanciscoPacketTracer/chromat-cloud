# TLS de producción para `chromat.lan`

La CA se administra fuera del servidor. Ubuntu recibe sólo `ca.crt`,
`server.crt` y `server.key`; `ca.key`, CSR, seriales y certificados de
desarrollo están prohibidos en el staging y en la VM.

El instalador exige cadena verificable, coincidencia clave/certificado, SAN DNS
`chromat.lan`, todas las IP proporcionadas, EKU `serverAuth` y exactamente los
tres archivos regulares permitidos. Instala el material con permisos
`0700`/`0644`/`0600` y rechaza material existente diferente salvo `--replace`.

```bash
sudo install -d -o root -g root -m 0700 /srv/chromat/tls
sudo /srv/chromat/active/scripts/install-production-tls.sh \
  /ruta/externa/tls /srv/chromat/tls 192.168.1.50 192.168.1.51
```

Para una renovación, valida el staging y autoriza explícitamente el reemplazo:

```bash
sudo /srv/chromat/active/scripts/install-production-tls.sh --replace \
  /ruta/externa/tls /srv/chromat/tls 192.168.1.50 192.168.1.51
RELEASE_DIR=/srv/chromat/active
sudo docker compose --project-name chromat --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" \
  exec -T nginx nginx -t
sudo docker compose --project-name chromat --project-directory "$RELEASE_DIR" \
  --env-file /etc/chromat/production.env -f "$RELEASE_DIR/compose.yaml" \
  exec -T nginx nginx -s reload
```

Verifica desde el host o cliente autorizado sin `--insecure`:

```bash
openssl s_client -connect chromat.lan:443 -servername chromat.lan \
  -CAfile /srv/chromat/tls/ca.crt -verify_return_error </dev/null
CA_CERT=/srv/chromat/tls/ca.crt BASE_URL=https://chromat.lan SMOKE_TESTS=all \
  /srv/chromat/active/tests/smoke/run.sh
```

El resultado de `s_client` debe incluir `Verify return code: 0 (ok)`. La
renovación no ejecuta `docker compose down`, no modifica la base y conserva el
certificado anterior fuera del árbol activo hasta completar estas pruebas.
