import importlib.util
import hashlib
import json
import pathlib
import signal
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


identity = load("identity", ROOT / "scripts/lib/image-identity.py")
fixtures = load("fixtures", ROOT / "tests/image-identity-fixture.py")


class IdentityTest(unittest.TestCase):
    def setUp(self):
        self.data, self.pins = fixtures.fixture()
        self.original = {key: getattr(identity, key) for key in self.pins}
        for key, value in self.pins.items():
            setattr(identity, key, value)

    def tearDown(self):
        for key, value in self.original.items():
            setattr(identity, key, value)

    def verify(self):
        return identity.verify(fixtures.archive(self.data))

    def test_index_and_platform_ids_differ_from_config(self):
        result = self.verify()
        self.assertEqual(result["config_digest"], self.pins["CONFIG_DIGEST"])
        self.assertIn(self.pins["INDEX_DIGEST"], result["ids"])
        self.assertIn(self.pins["PLATFORM_DIGEST"], result["ids"])
        self.assertNotEqual(self.pins["INDEX_DIGEST"], result["config_digest"])

    def test_production_pins_reject_synthetic_image(self):
        for key, value in self.original.items():
            setattr(identity, key, value)
        with self.assertRaises(ValueError):
            self.verify()

    def test_tampered_manifest_config_and_layer(self):
        for name in list(self.data):
            if not name.startswith("blobs/"):
                continue
            with self.subTest(blob=name):
                original = self.data[name]
                self.data[name] += b"altered"
                with self.assertRaisesRegex(ValueError, "blob bytes"):
                    self.verify()
                self.data[name] = original

    def test_missing_layer(self):
        manifest = json.loads(self.data["blobs/sha256/" + self.pins["PLATFORM_DIGEST"][7:]])
        del self.data["blobs/sha256/" + manifest["layers"][0]["digest"][7:]]
        with self.assertRaisesRegex(ValueError, "missing"):
            self.verify()

    def test_wrong_platform_even_with_matching_test_pins(self):
        self.data, pins = fixtures.fixture("arm64")
        for key, value in pins.items():
            setattr(identity, key, value)
        with self.assertRaisesRegex(ValueError, "platform"):
            self.verify()

    def test_tag_points_to_wrong_config(self):
        records = json.loads(self.data["manifest.json"])
        records[0]["Config"] = "wrong.json"
        self.data["manifest.json"] = json.dumps(records).encode()
        with self.assertRaisesRegex(ValueError, "tagged export"):
            self.verify()

    def test_wrong_manifest_even_with_self_consistent_blob_hash(self):
        manifest_path = "blobs/sha256/" + self.pins["PLATFORM_DIGEST"][7:]
        changed = self.data.pop(manifest_path) + b" "
        self.data["blobs/sha256/" + hashlib.sha256(changed).hexdigest()] = changed
        with self.assertRaisesRegex(ValueError, "pinned OCI"):
            self.verify()

    def test_index_descriptor_size(self):
        root = json.loads(self.data["index.json"])
        root["manifests"][0]["size"] += 1
        self.data["index.json"] = json.dumps(root).encode()
        with self.assertRaisesRegex(ValueError, "descriptor size"):
            self.verify()

    def test_selectable_unpinned_manifest_is_rejected_at_every_index_depth(self):
        for depth, labeled in ((0, True), (1, True), (3, True), (0, False), (2, False)):
            with self.subTest(depth=depth, labeled=labeled):
                self.data, _ = fixtures.fixture()

                def add_blob(document):
                    content = json.dumps(document, separators=(",", ":")).encode()
                    digest = "sha256:" + hashlib.sha256(content).hexdigest()
                    self.data["blobs/sha256/" + digest[7:]] = content
                    return {"digest": digest, "size": len(content)}

                pinned_path = "blobs/sha256/" + self.pins["PLATFORM_DIGEST"][7:]
                manifest = json.loads(self.data[pinned_path])
                other_config = add_blob({
                    "os": "linux", "architecture": "amd64",
                    "config": {"Cmd": ["false"]},
                })
                alternate = add_blob({
                    "schemaVersion": 2, "config": other_config,
                    "layers": manifest["layers"],
                })
                if labeled:
                    alternate["platform"] = {"os": "linux", "architecture": "amd64"}
                for _ in range(depth):
                    alternate = add_blob({"schemaVersion": 2, "manifests": [alternate]})
                pinned = {
                    "digest": self.pins["PLATFORM_DIGEST"],
                    "size": len(self.data[pinned_path]),
                    "platform": {"os": "linux", "architecture": "amd64"},
                }
                self.data["index.json"] = json.dumps({
                    "schemaVersion": 2, "manifests": [alternate, pinned],
                }).encode()
                with self.assertRaisesRegex(ValueError, "selectable"):
                    self.verify()

    def test_shared_index_descendants_are_verified_with_bounded_work(self):
        child = json.loads(self.data["index.json"])["manifests"][0]
        for _ in range(26):
            content = json.dumps({"schemaVersion": 2, "manifests": [child, child]}).encode()
            digest = "sha256:" + hashlib.sha256(content).hexdigest()
            self.data["blobs/sha256/" + digest[7:]] = content
            child = {"digest": digest, "size": len(content)}
        self.data["index.json"] = json.dumps({
            "schemaVersion": 2, "manifests": [child],
        }).encode()

        def deadline(_signal, _frame):
            self.fail("shared OCI index verification exceeded its bounded-work deadline")

        previous = signal.signal(signal.SIGALRM, deadline)
        signal.setitimer(signal.ITIMER_REAL, 3)
        try:
            self.assertIn(child["digest"], self.verify()["ids"])
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)

    def test_excessive_descriptor_work_is_rejected(self):
        descriptor = {
            "digest": self.pins["PLATFORM_DIGEST"],
            "size": len(self.data["blobs/sha256/" + self.pins["PLATFORM_DIGEST"][7:]]),
        }
        self.data["index.json"] = json.dumps({
            "schemaVersion": 2, "manifests": [descriptor] * 4097,
        }).encode()
        with self.assertRaisesRegex(ValueError, "work limit"):
            self.verify()

    def test_cached_indexes_preserve_nesting_limit_in_both_branch_orders(self):
        for depth in (32, 33, 40):
            self.data, _ = fixtures.fixture()
            child = {
                "digest": self.pins["PLATFORM_DIGEST"],
                "size": len(self.data["blobs/sha256/" + self.pins["PLATFORM_DIGEST"][7:]]),
            }
            chain = []
            for _ in range(depth):
                content = json.dumps({"schemaVersion": 2, "manifests": [child]}).encode()
                digest = "sha256:" + hashlib.sha256(content).hexdigest()
                self.data["blobs/sha256/" + digest[7:]] = content
                child = {"digest": digest, "size": len(content)}
                chain.append(child)
            for deepest_first in (False, True):
                with self.subTest(depth=depth, deepest_first=deepest_first):
                    self.data["index.json"] = json.dumps({
                        "schemaVersion": 2,
                        "manifests": chain[::-1] if deepest_first else chain,
                    }).encode()
                    if depth <= 32:
                        self.verify()
                    else:
                        with self.assertRaisesRegex(ValueError, "nesting"):
                            self.verify()

    def test_platform_selected_export_can_omit_foreign_architectures(self):
        root = json.loads(self.data["index.json"])
        root["manifests"].append({
            "digest": "sha256:" + "0" * 64,
            "size": 100,
            "platform": {"os": "linux", "architecture": "arm64"},
        })
        self.data["index.json"] = json.dumps(root).encode()
        self.verify()

    def test_pinned_platform_mislabeled_in_index(self):
        root = json.loads(self.data["index.json"])
        root["manifests"] = [{
            "digest": self.pins["PLATFORM_DIGEST"],
            "size": len(self.data["blobs/sha256/" + self.pins["PLATFORM_DIGEST"][7:]]),
            "platform": {"os": "linux", "architecture": "arm64"},
        }]
        self.data["index.json"] = json.dumps(root).encode()
        with self.assertRaisesRegex(ValueError, "platform"):
            self.verify()

    def test_classic_archive_fails_closed(self):
        self.data = {"manifest.json": b"[]", "config.json": b"{}"}
        with self.assertRaisesRegex(ValueError, "classic exports"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
