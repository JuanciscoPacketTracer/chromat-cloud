#!/usr/bin/env python3
"""Prepare an explicit, repeatable photograph demo through the existing API."""

import argparse
from datetime import datetime, timedelta, timezone
import fcntl
import getpass
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import ssl
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parents[1]
PHOTOS = (
    "day-1-1784869369839.jpg",
    "day-2-1784869412552.jpg",
    "day-3-1784869442117.jpg",
    "day-4-1784869467080.jpg",
    "day-5-1784869494502.jpg",
)


class DemoError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise DemoError("Redireccion HTTP rechazada; comprueba la URL de la VM.")


class Client:
    def __init__(self, base, ca_cert):
        self.base = base
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=ca_cert)),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
            NoRedirect(),
        )

    def request(self, path, data=None, headers=None, method=None):
        request = urllib.request.Request(
            self.base + path, data=data, headers=headers or {}, method=method,
        )
        try:
            with self.opener.open(request, timeout=30) as response:
                return None if response.status == 204 else json.load(response)
        except urllib.error.HTTPError as error:
            raise DemoError(
                f"HTTP {error.code} en {path}. No se reintenta automaticamente; "
                "corrige el problema y ejecuta el mismo comando para continuar."
            ) from error
        except urllib.error.URLError as error:
            raise DemoError(
                f"No se pudo conectar a {self.base}: {error.reason}"
            ) from error

    def post(self, path, body, csrf):
        return self.request(path, json.dumps(body).encode(), {
            "Content-Type": "application/json", "X-CSRF-Token": csrf,
        })


def save_state(path, state):
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".demo-")
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(state, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def prepare_state(path, base, photos):
    hashes = {name: hashlib.sha256((photos / name).read_bytes()).hexdigest() for name in PHOTOS}
    if path.exists():
        if path.stat().st_mode & 0o077:
            raise DemoError(f"El archivo {path} debe ser privado (chmod 600).")
        state = json.loads(path.read_text())
        if state["base_url"] != base:
            raise DemoError("Este estado pertenece a otra URL; no se enviaran sus credenciales.")
        if hashes != {name: event["sha256"] for name, event in state["events"].items()}:
            raise DemoError("Las fotografias cambiaron; se conservan los eventos previos sin reenviar.")
        return state
    now = datetime.now(timezone.utc)
    state = {
        "base_url": base,
        "name": f"Demo fotografias {uuid.uuid4()}",
        "source_id": None,
        "api_key": None,
        "events": {
            name: {
                "event_id": str(uuid.uuid4()),
                "occurred_at": (now - timedelta(minutes=4 - index)).isoformat(
                    timespec="milliseconds"
                ).replace("+00:00", "Z"),
                "sha256": hashes[name],
            }
            for index, name in enumerate(PHOTOS)
        },
    }
    save_state(path, state)
    return state


def ensure_source(client, state, state_path, csrf):
    sources = client.request("/api/v1/admin/sources")["sources"]
    matches = [source for source in sources if source["name"] == state["name"]]
    if len(matches) > 1:
        raise DemoError("Hay varias fuentes con el nombre de esta demo; requiere revision del operador.")
    if not matches:
        if state["source_id"]:
            raise DemoError("La fuente guardada ya no existe; no se creara otra automaticamente.")
        source = client.post("/api/v1/admin/sources", {
            "name": state["name"], "crop": "mango", "is_test": True,
        }, csrf)
        state.update(source_id=source["source_id"], api_key=source["api_key"])
        save_state(state_path, state)
        return
    source = matches[0]
    if (source["is_test"] is not True or source["status"] != "active"
            or source["crop"] != "mango" or source.get("has_chat_id")
            or (state["source_id"] and source["source_id"] != state["source_id"])):
        raise DemoError("La fuente no coincide con una demo activa sin canal externo; se detiene.")
    state["source_id"] = source["source_id"]
    if not state["api_key"]:
        # Recover a lost creation response without creating another source.
        key = client.post(f"/api/v1/admin/sources/{source['source_id']}/keys", {}, csrf)
        state["api_key"] = key["api_key"]
    save_state(state_path, state)


def upload(client, state, photos):
    for name in PHOTOS:
        event = state["events"][name]
        boundary = f"chromat-{uuid.uuid4()}"
        metadata = json.dumps({
            "event_id": event["event_id"], "occurred_at": event["occurred_at"],
        }).encode()
        data = (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"metadata\"\r\n"
            "Content-Type: application/json\r\n\r\n"
        ).encode() + metadata + (
            f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; "
            f"filename=\"{name}\"\r\nContent-Type: image/jpeg\r\n\r\n"
        ).encode() + (photos / name).read_bytes() + f"\r\n--{boundary}--\r\n".encode()
        result = client.request("/api/v1/events", data, {
            "Authorization": f"Bearer {state['api_key']}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        })
        if result["event_id"] != event["event_id"]:
            raise DemoError("La ingesta devolvio un event_id diferente al enviado.")
        print(f"{name}: {event['event_id']} ({result['status']})", flush=True)


def wait_for_results(client, state, timeout):
    pending = dict(state["events"])
    deadline = time.monotonic() + timeout
    while pending:
        for name, event in list(pending.items()):
            result = client.request(f"/api/v1/events/{event['event_id']}", headers={
                "Authorization": f"Bearer {state['api_key']}",
            })
            status = result["status"]
            if status == "failed":
                raise DemoError(f"{name}: fallo de procesamiento. Reenviar no reprocesa el evento.")
            if status == "completed":
                run = result.get("current_result")
                if not run:
                    raise DemoError(f"{name}: completado sin resultado oficial.")
                derived = run["result"]
                if isinstance(derived, str):
                    derived = json.loads(derived)
                if not isinstance(derived, dict) or not derived.get("classification"):
                    raise DemoError(f"{name}: resultado oficial sin clasificacion.")
                label = {"hsv": "HSV experimental", "cnn": "CNN simulador"}.get(
                    run["algorithm"], run["algorithm"]
                )
                print(f"{name}: {derived['classification']} | {label} | "
                      f"version {run.get('algorithm_version', 'no disponible')}", flush=True)
                del pending[name]
            elif status not in ("pending", "processing"):
                raise DemoError(f"{name}: estado desconocido {status}.")
        if pending:
            if time.monotonic() >= deadline:
                raise DemoError("Tiempo de espera agotado. Los eventos se conservan; vuelve a ejecutar.")
            time.sleep(2)


def run_demo(client, state_path, photos, username, password, timeout):
    state = prepare_state(state_path, client.base, photos)
    login = client.post("/api/v1/admin/login", {"username": username, "password": password}, "")
    csrf = login["csrf_token"]
    try:
        ensure_source(client, state, state_path, csrf)
        print(f"Fuente de prueba: {state['source_id']} | {state['name']}", flush=True)
        upload(client, state, photos)
        wait_for_results(client, state, timeout)
        print(f"Demo lista. Abre {client.base}/panel/ como operador y pulsa Actualizar fuentes.")
        print("El productor solo podra consultarla tras una asignacion explicita del operador.")
    finally:
        had_error = sys.exc_info()[0] is not None
        try:
            client.request("/api/v1/admin/logout", headers={"X-CSRF-Token": csrf}, method="POST")
        except (DemoError, OSError, ValueError) as error:
            if not had_error:
                raise
            print(f"ERROR adicional al cerrar la sesion: {error}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="Origen HTTPS de tu VM, sin /panel/")
    parser.add_argument("--ca-cert", type=Path, default=ROOT / "certs/dev/ca.crt")
    parser.add_argument("--username", help="Usuario operador; se solicita si se omite")
    parser.add_argument("--wait-timeout", type=int, default=180, help="Espera de procesamiento en segundos")
    args = parser.parse_args()
    parsed = urllib.parse.urlsplit(args.url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        parser.error("--url debe ser un origen HTTPS, sin credenciales, ruta ni parametros")
    if args.wait_timeout <= 0:
        parser.error("--wait-timeout debe ser mayor que cero")
    base = args.url.rstrip("/")
    directory = ROOT / "secrets/demo-photographs"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.is_symlink() or directory.stat().st_mode & 0o077:
        raise DemoError(f"El directorio {directory} debe ser privado (chmod 700) y no un enlace.")
    print("Demo de laboratorio: cinco fotos, day-1 y day-3 duplicadas. "
          "Cultivo mango como etiqueta de demostracion, no verificado.")
    print("Sin validacion cientifica, recomendacion de cosecha ni prueba de hardware.")
    with open(directory / "run.lock", "a", opener=lambda path, flags: os.open(path, flags, 0o600)) as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise DemoError("Ya hay otra demo ejecutandose en este checkout.") from error
        client = Client(base, args.ca_cert)
        username = args.username or input("Usuario operador: ").strip()
        password = getpass.getpass("Contrasena del operador: ")
        if not username or not password:
            raise DemoError("Usuario y contrasena son obligatorios.")
        run_demo(client, directory / "state.json", ROOT / "pruebas/fotografias",
                 username, password, args.wait_timeout)


if __name__ == "__main__":
    try:
        main()
    except (DemoError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
