import contextlib
from email import policy
from email.parser import BytesParser
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("demo", ROOT / "scripts/demo-photographs.py")
demo = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(demo)


class FakeClient:
    base = "https://demo.invalid"

    def __init__(self):
        self.sources = []
        self.events = {}
        self.creations = 0
        self.rotations = 0
        self.logout = 0
        self.fail_upload = False
        self.lost_creation_response = False

    def post(self, path, body, csrf):
        if path.endswith("/login"):
            return {"csrf_token": "fixture-csrf"}
        if path.endswith("/keys"):
            self.rotations += 1
            return {"api_key": "fixture-key"}
        assert path == "/api/v1/admin/sources"
        assert body["is_test"] is True
        assert "chat_id" not in body
        self.creations += 1
        source = {**body, "source_id": "fixture-source", "status": "active", "has_chat_id": False}
        self.sources.append(source)
        if self.lost_creation_response:
            self.lost_creation_response = False
            raise demo.DemoError("lost creation response")
        return {**source, "api_key": "fixture-key"}

    def request(self, path, data=None, headers=None, method=None):
        if path.endswith("/logout"):
            self.logout += 1
            return None
        if path == "/api/v1/admin/sources":
            return {"sources": self.sources}
        assert headers["Authorization"] == "Bearer fixture-key"
        if path == "/api/v1/events":
            message = BytesParser(policy=policy.default).parsebytes(
                f"Content-Type: {headers['Content-Type']}\r\n\r\n".encode() + data
            )
            parts = list(message.iter_parts())
            metadata = json.loads(parts[0].get_payload(decode=True))
            sha256 = hashlib.sha256(parts[1].get_payload(decode=True)).hexdigest()
            event_id = metadata["event_id"]
            if event_id in self.events:
                assert self.events[event_id] == (metadata, sha256)
            self.events[event_id] = (metadata, sha256)
            if self.fail_upload:
                self.fail_upload = False
                raise demo.DemoError("HTTP 500")
            return {"event_id": event_id, "status": "completed"}
        assert path.split("/")[-1] in self.events
        return {
            "status": "completed",
            "current_result": {
                "algorithm": "hsv", "algorithm_version": "1",
                "result": json.dumps({"classification": "verde"}),
            },
        }


class DemoTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "state.json"
        self.photos = ROOT / "pruebas/fotografias"
        self.client = FakeClient()
        self.output = io.StringIO()

    def run_demo(self):
        with contextlib.redirect_stdout(self.output):
            demo.run_demo(self.client, self.path, self.photos, "operator", "fixture-password", 1)

    def test_repeat_preserves_source_five_distinct_events_and_private_key(self):
        self.run_demo()
        original = self.path.read_text()
        self.run_demo()
        self.assertEqual(self.path.read_text(), original)
        self.assertEqual(self.client.creations, 1)
        self.assertEqual(len(self.client.events), 5)
        hashes = [value[1] for value in self.client.events.values()]
        self.assertEqual(len(set(hashes)), 4)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("fixture-key", self.output.getvalue())
        self.assertNotIn("fixture-password", self.output.getvalue())
        self.assertEqual(self.client.logout, 2)

    def test_resume_after_500_keeps_same_event_identity(self):
        self.client.fail_upload = True
        with self.assertRaisesRegex(demo.DemoError, "500"):
            self.run_demo()
        original = self.path.read_text()
        self.run_demo()
        self.assertEqual(self.path.read_text(), original)
        self.assertEqual(self.client.creations, 1)
        self.assertEqual(len(self.client.events), 5)

    def test_recover_lost_creation_response_without_duplicate_source(self):
        self.client.lost_creation_response = True
        with self.assertRaisesRegex(demo.DemoError, "lost creation"):
            self.run_demo()
        self.run_demo()
        self.assertEqual(self.client.creations, 1)
        self.assertEqual(self.client.rotations, 1)

    def test_refuses_changed_origin_before_sending_credentials(self):
        self.run_demo()
        self.client.base = "https://another.invalid"
        with self.assertRaisesRegex(demo.DemoError, "otra URL"):
            self.run_demo()

    def test_refuses_shared_state_and_changed_photographs(self):
        self.run_demo()
        self.path.chmod(0o644)
        with self.assertRaisesRegex(demo.DemoError, "privado"):
            self.run_demo()
        self.path.chmod(0o600)
        state = json.loads(self.path.read_text())
        state["events"][demo.PHOTOS[0]]["sha256"] = "changed"
        demo.save_state(self.path, state)
        with self.assertRaisesRegex(demo.DemoError, "fotografias cambiaron"):
            self.run_demo()

    def test_refuses_non_test_revoked_and_external_channel(self):
        self.run_demo()
        for field, value in (("is_test", False), ("status", "revoked"), ("has_chat_id", True)):
            with self.subTest(field=field):
                original = self.client.sources[0][field]
                self.client.sources[0][field] = value
                with self.assertRaisesRegex(demo.DemoError, "fuente no coincide"):
                    self.run_demo()
                self.client.sources[0][field] = original

    def test_failure_and_timeout_are_not_success(self):
        self.run_demo()
        state = json.loads(self.path.read_text())
        with patch.object(self.client, "request", return_value={"status": "failed"}):
            with self.assertRaisesRegex(demo.DemoError, "fallo de procesamiento"):
                demo.wait_for_results(self.client, state, 1)
        with patch.object(self.client, "request", return_value={"status": "processing"}):
            with patch.object(demo.time, "monotonic", side_effect=[0, 2]):
                with self.assertRaisesRegex(demo.DemoError, "Tiempo de espera"):
                    demo.wait_for_results(self.client, state, 1)

    def test_transport_refuses_redirects_and_does_not_retry_http_500(self):
        with self.assertRaisesRegex(demo.DemoError, "Redireccion"):
            demo.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.invalid")
        client = demo.Client("https://demo.invalid", None)
        with patch.object(client.opener, "open", side_effect=urllib.error.HTTPError(
                client.base, 500, "internal", {}, None)) as request:
            with self.assertRaisesRegex(demo.DemoError, "HTTP 500"):
                client.request("/api/v1/events")
            self.assertEqual(request.call_count, 1)

    def test_logout_failure_does_not_hide_original_upload_failure(self):
        self.client.fail_upload = True
        original_request = self.client.request

        def request(path, *args, **kwargs):
            if path.endswith("/logout"):
                raise demo.DemoError("logout failed")
            return original_request(path, *args, **kwargs)

        errors = io.StringIO()
        with patch.object(self.client, "request", side_effect=request):
            with contextlib.redirect_stderr(errors):
                with self.assertRaisesRegex(demo.DemoError, "HTTP 500"):
                    self.run_demo()
        self.assertIn("logout failed", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
