# TLS de producción para `chromat.lan`

La CA interna se administra fuera del servidor. Ubuntu recibe únicamente
`server.crt`, `server.key` y `ca.crt`; `ca.key` nunca se copia al host, al
paquete de promoción ni a Git.

## Materiales y requisitos

La emisión se realiza en el equipo que administra la CA. El certificado de
servidor debe:

- estar firmado por `ca.crt`;
- contener `chromat.lan` como SAN DNS;
- contener cada IP usada durante las pruebas como SAN IP;
- tener uso extendido `serverAuth`.

Prepara un directorio externo que contenga exactamente:

```text
ca.crt
server.crt
server.key
```

No agregues `ca.key`, CSR, seriales ni certificados de desarrollo. Verifica
también la cadena y los SAN antes de transferir el directorio:

```bash
openssl verify -CAfile ca.crt server.crt
openssl x509 -in server.crt -noout -subject -issuer -dates -ext subjectAltName
```

## Instalación en Ubuntu

Instala los tres materiales en el directorio TLS del host. El script valida la
cadena, la coincidencia entre clave y certificado, `chromat.lan`, las IP
esperadas y los permisos:

```bash
sudo install -d -m 0700 /srv/chromat/tls
sudo scripts/install-production-tls.sh \
  /ruta/externa/tls \
  /srv/chromat/tls \
  192.168.1.50
```

El último argumento es la IP operativa incluida en el certificado; repítelo
para cada IP adicional usada durante las pruebas. El resultado debe ser:

```text
/srv/chromat/tls/server.crt  0644
/srv/chromat/tls/server.key  0600
/srv/chromat/tls/ca.crt      0644
```

La release de producción usa estas rutas mediante `production.env`:

```dotenv
TLS_CERT_HOST_PATH=/srv/chromat/tls/server.crt
TLS_KEY_HOST_PATH=/srv/chromat/tls/server.key
```

Nginx monta `server.crt` y `server.key` como solo lectura. `ca.crt` no se
publica ni se monta en Nginx: se distribuye por separado a los clientes
autorizados, que lo usan como raíz de confianza. Así, la respuesta HTTPS de
Nginx se verifica con `ca.crt` sin excepciones TLS.

## Verificación de Nginx

Después de cargar la release y los materiales:

```bash
docker compose --env-file production.env exec -T nginx nginx -t
openssl s_client -connect chromat.lan:443 \
  -servername chromat.lan \
  -CAfile /srv/chromat/tls/ca.crt \
  -verify_return_error </dev/null
```

El segundo comando debe terminar con `Verify return code: 0 (ok)`. Desde cada
cliente autorizado, instala `ca.crt` en el almacén de confianza y usa
`https://chromat.lan`; no uses `--insecure` ni desactives la verificación.
Los smoke tests de producción usan el mismo ancla:

```bash
CA_CERT=/srv/chromat/tls/ca.crt \
BASE_URL=https://chromat.lan \
SMOKE_TESTS=all \
tests/smoke/run.sh
```

## Revisión y renovación manual

Revisa la expiración al menos diariamente y alerta cuando falten menos de
30 días:

```bash
scripts/check-tls-expiry.sh /srv/chromat/tls/server.crt 30
```

Para renovar, la CA externa genera un nuevo `server.key` y `server.crt` con
los mismos SAN requeridos. Copia temporalmente solo esos tres materiales a un
directorio de staging, repite la verificación e instala con
`install-production-tls.sh`. No reemplaces `ca.crt` salvo que se esté
rotando la CA, una operación fuera de este issue.

Recarga únicamente Nginx después de validar la configuración:

```bash
docker compose --env-file production.env exec -T nginx nginx -t
docker compose --env-file production.env exec -T nginx nginx -s reload
```

La renovación no ejecuta `docker compose down`, no reinicia API, workers,
inferencia ni MariaDB y no cambia la base de datos. Conserva el certificado
anterior fuera del árbol activo hasta completar la prueba HTTPS y la evidencia
de `Verify return code: 0 (ok)`.

## Incidentes

Si `ca.key` se expone o se pierde, no se puede reparar copiándola al servidor.
Debe reemplazarse la CA externamente y redistribuirse el nuevo `ca.crt` a los
clientes autorizados. Un certificado con SAN incorrectos, cadena inválida o
menos de 30 días de vigencia debe abortar la promoción.
