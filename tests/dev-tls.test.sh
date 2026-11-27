#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -f "$work_dir/ca.key" "$work_dir/ca.crt" "$work_dir/server.key" "$work_dir/server.crt"; rmdir "$work_dir"' EXIT

CHROMAT_VM_IP=192.0.2.10 bash "$repo_root/scripts/dev-tls.sh" "$work_dir"
openssl verify -x509_strict -purpose sslserver -verify_ip 192.0.2.10 \
  -CAfile "$work_dir/ca.crt" "$work_dir/server.crt"
python3 - "$work_dir" <<'PY'
from pathlib import Path
import socket
import ssl
import sys
import threading

root = Path(sys.argv[1])
server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
server_context.load_cert_chain(root / "server.crt", root / "server.key")
client_context = ssl.create_default_context(cafile=root / "ca.crt")
client_context.verify_flags |= ssl.VERIFY_X509_STRICT
errors = []

with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    listener.settimeout(5)

    def serve():
        try:
            connection, _ = listener.accept()
            connection.settimeout(5)
            with server_context.wrap_socket(connection, server_side=True) as secure:
                secure.sendall(b"ok")
        except Exception as error:
            errors.append(error)

    thread = threading.Thread(target=serve)
    thread.start()
    try:
        with socket.create_connection(listener.getsockname(), timeout=5) as connection:
            with client_context.wrap_socket(connection, server_hostname="192.0.2.10") as secure:
                assert secure.recv(2) == b"ok"
    finally:
        thread.join(timeout=6)
    assert not thread.is_alive(), "TLS server did not finish"
    assert not errors, errors
print("PASS: Python SSL strict handshake with development CA")
PY
if openssl verify -x509_strict -verify_ip 192.0.2.11 \
  -CAfile "$work_dir/ca.crt" "$work_dir/server.crt" >/dev/null 2>&1; then
  printf 'FAIL: certificate accepted for another IP\n' >&2
  exit 1
fi
test "$(stat -c '%a' "$work_dir/ca.key")" = 600
test "$(stat -c '%a' "$work_dir/server.key")" = 600
printf 'PASS: development TLS strict validation and IP identity\n'
