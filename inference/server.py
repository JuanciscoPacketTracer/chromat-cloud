import base64
import hashlib
import json
import logging
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


MODEL_PATH = os.environ.get("MODEL_PATH", "/app/models/deterministic-model.json")
MODEL_VERSION = os.environ.get("MODEL_VERSION", "deterministic-1")
MODEL_SHA256 = os.environ["MODEL_SHA256"]
PORT = int(os.environ.get("INFERENCE_PORT", "8000"))
LOGGER = logging.getLogger("chromat.inference")


class JsonFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "event": "inference",
            "level": record.levelname,
            "message": record.getMessage(),
        })


logging.basicConfig(
    level=logging.INFO,
)
for handler in logging.getLogger().handlers:
    handler.setFormatter(JsonFormatter())


def load_model():
    with open(MODEL_PATH, "rb") as model_file:
        model_bytes = model_file.read()
    checksum = hashlib.sha256(model_bytes).hexdigest()
    if checksum != MODEL_SHA256:
        raise RuntimeError("model_checksum_mismatch")
    model = json.loads(model_bytes)
    if model.get("version") != MODEL_VERSION:
        raise RuntimeError("model_version_mismatch")
    return model, checksum


MODEL, LOADED_MODEL_SHA256 = load_model()


def classify(payload):
    image = base64.b64decode(payload["image_base64"], validate=True)
    image_sha256 = hashlib.sha256(image).hexdigest()
    if image_sha256 != payload["raw_sha256"]:
        raise ValueError("raw_checksum_mismatch")
    digest = hashlib.sha256(
        (MODEL["seed"] + image_sha256).encode("utf-8")
    ).digest()
    classification = MODEL["classes"][digest[0] % len(MODEL["classes"])]
    return {
        "algorithm": "cnn",
        "algorithm_version": "contract-1",
        "model_version": MODEL_VERSION,
        "model_sha256": LOADED_MODEL_SHA256,
        "classification": classification,
        "confidence": round(0.5 + digest[1] / 510, 4),
        "input_sha256": image_sha256,
    }


class Handler(BaseHTTPRequestHandler):
    def send_json(self, status, body):
        response = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {
                "status": "ready",
                "model_version": MODEL_VERSION,
                "model_sha256": LOADED_MODEL_SHA256,
            })
            return
        self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path != "/v1/classify":
            self.send_json(404, {"error": "not_found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length))
            result = classify(payload)
            self.send_json(200, result)
        except (ValueError, KeyError, json.JSONDecodeError) as error:
            LOGGER.warning("request_rejected:%s", type(error).__name__)
            self.send_json(422, {"error": str(error)})
        except Exception:
            LOGGER.exception("request_failed")
            self.send_json(500, {"error": "inference_failed"})

    def log_request(self, code="-", size="-"):
        LOGGER.info(
            "http_request method=%s path=%s status=%s bytes=%s",
            self.command,
            self.path,
            code,
            size,
        )


ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
