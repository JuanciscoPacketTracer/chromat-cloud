"""Exercise CI gates with synthetic OCI archives and Docker/GitHub doubles."""

import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tarfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACKAGING = runpy.run_path(str(ROOT / "tests/package-artifacts.test.py"))
EXTRA_DOCKER = r'''
if args[0] == "info":
    print(json.dumps([["driver-type", os.environ.get("IMAGE_STORE", "io.containerd.snapshotter.v1")]]))
    sys.exit(0)
if args[0] == "load":
    sys.exit(0)
if args[0] == "run":
    print("busybox-offline-ok")
    sys.exit(0)
if args[:2] == ["image", "save"]:
    shutil.copyfile(os.environ["TEST_EXPORT"], args[args.index("--output") + 1])
    sys.exit(0)
'''
DOCKER = PACKAGING["DOCKER"].replace(
    'if args[0] == "compose":', EXTRA_DOCKER + '\nif args[0] == "compose":',
).replace('print("test-docker")', 'print("29.10.1")').replace(
    'pins["PLATFORM_DIGEST"] if "busybox" in name',
    'os.environ.get("NATIVE_ID", pins["PLATFORM_DIGEST"]) if "busybox" in name',
).replace(
    'print(image_id, "amd64")',
    'print(image_id) if args[args.index("--format") + 1] == "{{.Id}}" else print(image_id, "amd64")',
)
GH = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with open(os.environ["GH_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
if sys.argv[1] != "api":
    sys.exit("unexpected GitHub operation")
filename = "RUN_METADATA" if "/actions/runs/" in sys.argv[2] else "WORKFLOW_METADATA"
print(Path(os.environ[filename]).read_text())
"""


class OfflineCITest(PACKAGING["RepositoryTest"]):
    def setUp(self):
        super().setUp()
        bin_dir = self.root / "bin"
        (bin_dir / "docker").write_text(DOCKER)
        (bin_dir / "gh").write_text(GH)
        self.env.update(
            GITHUB_ACTIONS="true", RUNNER_ENVIRONMENT="github-hosted", RUNNER_OS="Linux",
            VERSION="v1.0.0", GITHUB_SHA=self.base, GITHUB_RUN_ID="12345",
            GITHUB_RUN_ATTEMPT="1", GITHUB_REPOSITORY="fixture/repository",
            DOCKER_HOST="unix:///tmp/fixture-only.sock", RUNNER_TEMP=str(self.root),
            DRAFT_CONFIRMATION="CREATE_DRAFT", GITHUB_OUTPUT=str(self.root / "outputs"),
        )
        self.git("tag", "v1.0.0")
        self.git("remote", "add", "origin", str(self.repo))
        self.run_record = {
            "workflow_id": 42, "event": "workflow_dispatch", "status": "completed",
            "conclusion": "success", "head_sha": self.base, "run_attempt": 1,
            "repository": {"full_name": "fixture/repository"},
            "head_repository": {"full_name": "fixture/repository"},
        }
        self.run_metadata = self.root / "run.json"
        self.workflow_metadata = self.root / "workflow.json"
        self.workflow_metadata.write_text(json.dumps(
            {"id": 42, "path": ".github/workflows/offline-package.yml"}))
        self.env.update(RUN_METADATA=str(self.run_metadata),
                        WORKFLOW_METADATA=str(self.workflow_metadata))
        self.run_metadata.write_text(json.dumps(self.run_record))

    def ci(self, *args):
        return subprocess.run(
            [sys.executable, "-B", str(self.repo / "scripts/ci/offline-artifacts.py"),
             *map(str, args)], cwd=self.repo, env=self.env, capture_output=True, text=True,
        )

    def calls(self):
        return [entry["args"] for entry in
                map(json.loads, self.log.read_text().splitlines())] if self.log.exists() else []

    def export(self):
        directory = self.root / "busybox"
        result = self.ci("export-busybox", directory)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return directory

    def test_rejects_local_or_self_hosted_execution_before_docker(self):
        for key, value in (("GITHUB_ACTIONS", "false"),
                           ("RUNNER_ENVIRONMENT", "self-hosted")):
            with self.subTest(key=key):
                old = self.env[key]
                self.env[key] = value
                result = self.ci("export-busybox", self.root / "unused")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("GitHub-hosted", result.stderr)
                self.assertEqual(self.calls(), [])
                self.env[key] = old

    def test_rejects_unsafe_or_experimental_versions_before_operations(self):
        for version in ("../v1", "v1\ninjected", "experimental-laboratory"):
            with self.subTest(version=version):
                self.env["VERSION"] = version
                self.assertNotEqual(self.ci("export-busybox", self.root / "unused").returncode, 0)
                self.assertEqual(self.calls(), [])
                self.assertFalse(self.gh_log.exists())

    def test_requires_clean_matching_source_and_release_tag(self):
        result = self.ci("check-source", "--require-tag")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.env["GITHUB_SHA"] = "0" * 40
        self.assertIn("source commit", self.ci("check-source").stderr)
        self.env["GITHUB_SHA"] = self.base
        (self.repo / "unidentified.txt").write_text("not approved")
        self.assertIn("clean", self.ci("check-source").stderr)
        (self.repo / "unidentified.txt").unlink()
        self.git("tag", "-d", "v1.0.0")
        self.assertNotEqual(self.ci("check-source", "--require-tag").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_requires_containerd_before_pulling(self):
        self.env["IMAGE_STORE"] = "classic"
        result = self.ci("export-busybox", self.root / "unused")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("containerd", result.stderr)
        self.assertFalse(any(call[0] == "pull" for call in self.calls()))

    def test_busybox_roundtrip_uses_verified_archive_and_offline_execution(self):
        directory = self.export()
        result = self.ci("roundtrip-busybox", directory)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertEqual(sum(call[0] == "pull" for call in calls), 1)
        execution = next(call for call in calls if call[0] == "run")
        self.assertIn("--pull=never", execution)
        self.assertIn("--network=none", execution)
        self.assertEqual(sum(call[:2] == ["image", "save"] for call in calls), 2)

    def test_tampered_busybox_proof_aborts_before_load(self):
        directory = self.export()
        proof = directory / "busybox-proof.json"
        record = json.loads(proof.read_text())
        record["source_commit"] = "0" * 40
        proof.write_text(json.dumps(record))
        result = self.ci("roundtrip-busybox", directory)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == "load" for call in self.calls()))

    def test_native_id_change_is_not_accepted_even_with_the_pinned_config(self):
        directory = self.export()
        self.env["NATIVE_ID"] = json.loads(self.pins.read_text())["CONFIG_DIGEST"]
        result = self.ci("roundtrip-busybox", directory)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native ID changed", result.stderr)

    def test_resolves_only_successful_same_source_manual_runs(self):
        result = self.ci("resolve-run", "12345")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("chromat-offline-v1.0.0-1",
                      Path(self.env["GITHUB_OUTPUT"]).read_text())
        for key, value in (("workflow_id", 99), ("event", "pull_request"),
                           ("conclusion", "failure"), ("head_sha", "0" * 40),
                           ("head_repository", {"full_name": "foreign/repository"})):
            with self.subTest(key=key):
                record = dict(self.run_record, **{key: value})
                self.run_metadata.write_text(json.dumps(record))
                self.assertNotEqual(self.ci("resolve-run", "12345").returncode, 0)

    def test_run_id_and_confirmation_are_not_shell_or_api_input(self):
        self.assertNotEqual(self.ci("resolve-run", "123;anything").returncode, 0)
        self.assertFalse(self.gh_log.exists())
        self.env["DRAFT_CONFIRMATION"] = ""
        result = self.ci("resolve-run", "12345")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(Path(self.env["GITHUB_OUTPUT"]).exists())
        self.assertIn("CREATE_DRAFT", result.stderr)

    def test_package_records_source_and_can_be_revalidated_before_draft(self):
        output = self.root / "package-output"
        result = self.ci("package", output)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        incoming = self.root / "incoming"
        incoming.mkdir()
        for suffix in (".tar.gz", ".tar.gz.sha256", ".manifest.json", ".ci-provenance.json"):
            shutil.copyfile(output / f"chromat-v1.0.0{suffix}",
                            incoming / f"chromat-v1.0.0{suffix}")
        proof = json.loads((incoming / "chromat-v1.0.0.ci-provenance.json").read_text())
        self.assertEqual(proof["git_commit"], self.base)
        self.assertEqual(proof["source_run_id"], "12345")
        result = self.ci("validate-package", incoming, "12345", "1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((incoming / "v1.0.0/db/migrations/016_job_event_uniqueness.sql").is_file())
        self.assertFalse(self.gh_log.exists())

    def bundle(self, member):
        incoming = self.root / "unsafe-package"
        incoming.mkdir()
        manifest = {"package_kind": "release", "git_commit": self.base,
                    "package_version": "v1.0.0", "source_env_file": ".env.example"}
        archive = incoming / "chromat-v1.0.0.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for name in [member] if isinstance(member, str) else member:
                entry = tarfile.TarInfo(name)
                content = b"unsafe fixture"
                entry.size = len(content)
                tar.addfile(entry, io.BytesIO(content))
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        (incoming / "chromat-v1.0.0.tar.gz.sha256").write_text(
            f"{checksum}  chromat-v1.0.0.tar.gz\n")
        (incoming / "chromat-v1.0.0.manifest.json").write_text(json.dumps(manifest))
        proof = {
            "schema_version": 1, "package_version": "v1.0.0", "git_commit": self.base,
            "workflow": ".github/workflows/offline-package.yml",
            "source_run_id": "12345", "source_run_attempt": "1",
            "docker_version": "29.10.1", "image_store": "containerd",
            "archive_sha256": checksum,
        }
        (incoming / "chromat-v1.0.0.ci-provenance.json").write_text(json.dumps(proof))
        return incoming

    def test_unsafe_archive_is_rejected_before_extraction_or_docker(self):
        incoming = self.bundle("v1.0.0/../../escape.txt")
        result = self.ci("validate-package", incoming, "12345", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe package archive", result.stderr)
        self.assertFalse((self.root / "escape.txt").exists())
        self.assertEqual(self.calls(), [])

    def test_foreign_provenance_aborts_before_archive_or_docker(self):
        incoming = self.bundle("v1.0.0/placeholder")
        result = self.ci("validate-package", incoming, "999", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("provenance", result.stderr)
        self.assertFalse((incoming / "v1.0.0").exists())
        self.assertEqual(self.calls(), [])

    def test_duplicate_archive_members_abort_before_extraction(self):
        incoming = self.bundle(["v1.0.0/placeholder", "v1.0.0/placeholder"])
        result = self.ci("validate-package", incoming, "12345", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate package archive", result.stderr)
        self.assertFalse((incoming / "v1.0.0").exists())
        self.assertEqual(self.calls(), [])

    def test_checksum_sidecar_must_identify_the_package_archive(self):
        incoming = self.bundle("v1.0.0/placeholder")
        manifest = incoming / "chromat-v1.0.0.manifest.json"
        checksum = hashlib.sha256(manifest.read_bytes()).hexdigest()
        (incoming / "chromat-v1.0.0.tar.gz.sha256").write_text(
            f"{checksum}  {manifest.name}\n")
        result = self.ci("validate-package", incoming, "12345", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum sidecar", result.stderr)
        self.assertFalse((incoming / "v1.0.0").exists())
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
