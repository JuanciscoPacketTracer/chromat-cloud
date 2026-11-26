"""Exercise packaging with synthetic images and an isolated Git fixture."""

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
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = runpy.run_path(str(ROOT / "tests/image-identity-fixture.py"))

DOCKER = r"""#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
args = sys.argv[1:]
with open(os.environ["DOCKER_LOG"], "a") as log:
    log.write(json.dumps({
        "args": args, "cwd": str(Path.cwd()),
        "api_source": Path("api/src/server.js").read_text(),
        "has_local_env": Path(".env").exists(),
    }) + "\n")
pins = json.loads(Path(os.environ["TEST_PINS"]).read_text())
if args[0] == "compose":
    if "config" in args:
        print(json.dumps({"services": {name: {"image": image} for name, image in {
            "api": "chromat-api:dev", "inference": "chromat-inference:dev",
            "db": "mariadb:11.8.2", "nginx": "nginx:1.29.2-alpine",
        }.items()}}))
    elif "version" in args:
        print("test-compose")
    elif "pull" not in args and "build" not in args:
        sys.exit("unexpected compose call")
elif args[0] in ("pull", "tag"):
    pass
elif args[0] == "save":
    output = Path(args[args.index("-o") + 1])
    if args[-1] == "busybox:1.36.1":
        shutil.copyfile(os.environ["TEST_EXPORT"], output)
    else:
        output.write_bytes(b"synthetic image, not loadable")
elif args[:2] == ["image", "inspect"]:
    name = args[-1]
    image_id = (pins["PLATFORM_DIGEST"] if "busybox" in name else
                "sha256:" + hashlib.sha256(name.encode()).hexdigest())
    if "--format" in args:
        print(image_id, "amd64")
    else:
        repository = "busybox" if "busybox" in name else name.split("@")[0]
        print(json.dumps([{"Id": image_id, "Architecture": "amd64",
                           "RepoDigests": [repository + "@" + image_id]}]))
elif args[0] == "version":
    print("test-docker")
else:
    sys.exit("unexpected docker call: " + repr(args))
"""


class RepositoryTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repository"
        self.repo.mkdir()
        paths = subprocess.check_output(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            cwd=ROOT,
        ).decode().split("\0")
        for name in set(filter(None, paths)):
            source = ROOT / name
            if source.is_file():
                target = self.repo / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        self.env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        self.env.pop("CHROMAT_ENV_FILE", None)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        docker = bin_dir / "docker"
        docker.write_text(DOCKER)
        docker.chmod(0o755)
        gh = bin_dir / "gh"
        gh.write_text("#!/usr/bin/env bash\nprintf 'unexpected gh call\\n' >>\"$GH_LOG\"\nexit 88\n")
        gh.chmod(0o755)
        self.gh_log = self.root / "github.log"
        self.env["GH_LOG"] = str(self.gh_log)
        export_root = self.root / "export"
        subprocess.run(
            [sys.executable, "-B", str(ROOT / "tests/image-identity-fixture.py"),
             str(export_root)], check=True, stdout=subprocess.DEVNULL, env=self.env,
        )
        _, pins = FIXTURES["fixture"]()
        self.pins = self.root / "pins.json"
        self.pins.write_text(json.dumps(pins))
        shutil.copyfile(export_root / "scripts/lib/image-identity.py",
                        self.repo / "scripts/lib/image-identity.py")
        originals = runpy.run_path(str(ROOT / "scripts/lib/image-identity.py"))
        for name in ("scripts/package-artifacts.sh", "scripts/verify-artifacts.sh"):
            path = self.repo / name
            text = path.read_text()
            for key, digest in pins.items():
                text = text.replace(originals[key], digest)
            path.write_text(text)
        self.log = self.root / "docker.log"
        self.env.update(
            PATH=str(bin_dir) + os.pathsep + self.env["PATH"],
            DOCKER_LOG=str(self.log), TEST_PINS=str(self.pins),
            TEST_EXPORT=str(export_root / "images/busybox.tar"),
        )
        self.git("init", "-q")
        self.git("config", "user.name", "Packaging fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("add", "--force", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", "Synthetic baseline")
        self.base = self.git("rev-parse", "HEAD").strip()

    def git(self, *args):
        return subprocess.check_output(
            ["git", *args], cwd=self.repo, env=self.env, text=True,
        )

    def package(self, version="test-layout", *options):
        return subprocess.run(
            ["bash", "scripts/package-artifacts.sh", version,
             str(self.root / "artifacts"), *options],
            cwd=self.repo, env=self.env, capture_output=True, text=True,
        )


class MigrationLayoutTest(RepositoryTest):
    def test_package_preserves_the_runtime_migration_directory(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        package = self.root / "artifacts/test-layout"
        migrations = sorted((package / "db/migrations").glob("*.sql"))
        self.assertEqual(len(migrations), 16)
        self.assertTrue((package / "db/migrations/016_job_event_uniqueness.sql").is_file())
        self.assertEqual(list((package / "db").glob("*.sql")), [])
        self.assertEqual(json.loads((package / "manifest.json").read_text())["migration_version"], "016")
        self.assertEqual(os.readlink(self.root / "artifacts/active"), "test-layout")
        (package / "db/migrations").rename(package / "db/flattened")
        for migration in (package / "db/flattened").glob("*.sql"):
            migration.rename(package / "db" / migration.name)
        result = subprocess.run(
            ["bash", str(self.repo / "scripts/verify-artifacts.sh"), str(package)],
            capture_output=True, text=True, env=self.env,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("db/migrations/", result.stderr)


class SourceProvenanceTest(RepositoryTest):
    def provenance(self, *args):
        return subprocess.run(
            [sys.executable, "-B", str(self.repo / "scripts/lib/source-provenance.py"),
             *map(str, args)],
            cwd=self.repo, env=self.env, capture_output=True, text=True,
        )

    def capture(self, *extra):
        result = self.provenance("capture", self.repo, self.base, *extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = self.root / "source.json"
        snapshot.write_text(result.stdout)
        return snapshot, hashlib.sha256(snapshot.read_bytes()).hexdigest()

    def test_explicit_snapshot_identifies_and_freezes_the_changed_source(self):
        (self.repo / "api/src/server.js").write_text("// approved fixture change\n")
        (self.repo / "00-local-note.txt").write_text("approved fixture addition\n")
        snapshot, digest = self.capture("--include-untracked", "00-local-note.txt")
        provenance = json.loads(snapshot.read_text())
        self.assertEqual(provenance["source_kind"], "baseline-plus-local-patch")
        self.assertEqual(provenance["base_git_commit"], self.base)
        self.assertIn("approved fixture change", provenance["patch"])
        self.assertIn("00-local-note.txt", provenance["files"])
        self.git("add", "00-local-note.txt", "api/src/server.js")
        stage = self.root / "stage"
        result = self.provenance("prepare", self.repo, snapshot, digest, stage)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, snapshot.read_text())
        self.assertEqual((stage / "api/src/server.js").read_text(),
                         "// approved fixture change\n")
        self.assertEqual((stage / "00-local-note.txt").read_text(),
                         "approved fixture addition\n")
        self.assertFalse((stage / ".git").exists())
        reconstructed = self.root / "reconstructed"
        reconstructed.mkdir()
        baseline = subprocess.check_output(
            ["git", "archive", self.base], cwd=self.repo, env=self.env,
        )
        with tarfile.open(fileobj=io.BytesIO(baseline)) as archive:
            archive.extractall(reconstructed, filter="data")
        subprocess.run(["git", "apply", "-"], cwd=reconstructed, env=self.env,
                       input=provenance["patch"], text=True, check=True)
        self.assertEqual((reconstructed / "api/src/server.js").read_bytes(),
                         (stage / "api/src/server.js").read_bytes())
        self.assertEqual((reconstructed / "00-local-note.txt").read_bytes(),
                         (stage / "00-local-note.txt").read_bytes())

    def test_approval_rejects_later_content_modes_additions_and_snapshot_changes(self):
        snapshot, digest = self.capture()
        source = self.repo / "api/src/server.js"
        original = source.read_bytes()
        for change in ("content", "mode", "addition", "snapshot"):
            with self.subTest(change=change):
                if change == "content":
                    source.write_bytes(original + b"\n// unapproved\n")
                elif change == "mode":
                    source.chmod(0o755)
                elif change == "addition":
                    (self.repo / "unapproved.txt").write_text("extra\n")
                else:
                    snapshot.write_bytes(snapshot.read_bytes() + b" ")
                result = self.provenance(
                    "prepare", self.repo, snapshot, digest, self.root / "stage",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "stage").exists())
                source.write_bytes(original)
                source.chmod(0o644)
                (self.repo / "unapproved.txt").unlink(missing_ok=True)

    def test_snapshot_rejects_an_index_that_hides_effective_source_changes(self):
        name = "inference/models/deterministic-model.json"
        model = self.repo / name
        original = model.read_bytes()
        for state in ("removed", "assume-unchanged", "skip-worktree"):
            with self.subTest(state=state):
                self.git("read-tree", self.base)
                model.write_bytes(original)
                if state == "removed":
                    self.git("rm", "--cached", "--", name)
                else:
                    self.git("update-index", "--" + state, "--", name)
                model.write_bytes(original + b"\n")
                result = self.provenance("capture", self.repo, self.base)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("reconstruct", result.stderr)

    def test_prepare_rejects_an_internally_hashed_but_unreconstructible_patch(self):
        snapshot, _ = self.capture()
        name = "inference/models/deterministic-model.json"
        self.git("rm", "--cached", "--", name)
        record = json.loads(snapshot.read_bytes())
        record["patch"] = self.git("diff", "--binary", self.base, "--", name)
        record["patch_sha256"] = hashlib.sha256(record["patch"].encode()).hexdigest()
        snapshot.write_text(json.dumps(record))
        digest = hashlib.sha256(snapshot.read_bytes()).hexdigest()
        result = self.provenance("prepare", self.repo, snapshot, digest, self.root / "stage")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reconstruct", result.stderr)
        self.assertFalse((self.root / "stage").exists())

    def test_prepare_does_not_depend_on_the_constructors_diff_configuration(self):
        path = self.repo / "scripts/package-artifacts.sh"
        lines = path.read_text().splitlines(keepends=True)
        lines.insert(2, "# approved fixture change at the beginning\n")
        lines.insert(-2, "# approved fixture change at the end\n")
        path.write_text("".join(lines))
        self.git("config", "diff.interHunkContext", "0")
        snapshot, digest = self.capture()
        before = self.git("diff", self.base)
        self.git("config", "diff.interHunkContext", "100000")
        self.assertNotEqual(before, self.git("diff", self.base))
        result = self.provenance("prepare", self.repo, snapshot, digest, self.root / "stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "stage/scripts/package-artifacts.sh").read_bytes(),
                         path.read_bytes())

    def test_experimental_package_records_provenance_without_release_links(self):
        (self.repo / "api/src/server.js").write_text("// approved fixture change\n")
        (self.repo / ".env").write_text("THIS_SECRET_MUST_NOT_BE_COPIED=fixture\n")
        snapshot, digest = self.capture()
        releases = self.root / "artifacts"
        releases.mkdir()
        (releases / "active").symlink_to("normal-active")
        (releases / "previous").symlink_to("normal-previous")
        result = self.package(
            "experimental-fixture", "--experimental-source", str(snapshot),
            "--source-sha256", digest,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        package = self.root / "artifacts/experimental-fixture"
        manifest = json.loads((package / "manifest.json").read_text())
        self.assertEqual(manifest["package_kind"], "experimental")
        self.assertIsNone(manifest["git_commit"])
        self.assertEqual(manifest["source_provenance"]["base_git_commit"], self.base)
        self.assertEqual(manifest["source_provenance"]["approval_sha256"], digest)
        self.assertEqual((package / "provenance/source.json").read_bytes(),
                         snapshot.read_bytes())
        self.assertEqual(os.readlink(releases / "active"), "normal-active")
        self.assertEqual(os.readlink(releases / "previous"), "normal-previous")
        self.assertFalse((package / ".env").exists())
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        for call in calls:
            self.assertNotEqual(call["cwd"], str(self.repo))
            self.assertEqual(call["api_source"], "// approved fixture change\n")
            self.assertFalse(call["has_local_env"])
            args = call["args"]
            if "--env-file" in args:
                self.assertEqual(args[args.index("--env-file") + 1], ".env.example")
        changed = package / "scripts/backup.sh"
        changed.write_text(changed.read_text() + "\n# not approved\n")
        (package / "checksums.sha256").chmod(0o644)
        with (package / "checksums.sha256").open("w") as checksums:
            for path in sorted(package.rglob("*")):
                if path.is_file() and path.name != "checksums.sha256":
                    checksums.write(hashlib.sha256(path.read_bytes()).hexdigest()
                                    + "  ./" + str(path.relative_to(package)) + "\n")
        result = subprocess.run(
            ["bash", str(self.repo / "scripts/verify-artifacts.sh"), str(package)],
            capture_output=True, text=True, env=self.env,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source", result.stderr)

    def test_normal_mode_and_unapproved_experimental_modes_abort_before_docker(self):
        source = self.repo / "api/src/server.js"
        source.write_text("// approved fixture change\n")
        snapshot, digest = self.capture()
        cases = [
            ("ordinary", ()),
            ("ordinary", ("--experimental-source", str(snapshot), "--source-sha256", digest)),
            ("experimental-missing", ()),
            ("experimental-missing-hash", ("--experimental-source", str(snapshot))),
            ("experimental-wrong-hash", ("--experimental-source", str(snapshot),
                                         "--source-sha256", "0" * 64)),
        ]
        source.write_text("// unapproved change after capture\n")
        cases.append(("experimental-changed", ("--experimental-source", str(snapshot),
                                               "--source-sha256", digest)))
        for version, options in cases:
            with self.subTest(version=version):
                result = self.package(version, *options)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.log.exists(), result.stdout + result.stderr)


class ReleaseClassificationTest(RepositoryTest):
    def test_experimental_identity_is_rejected_before_checksum_or_docker(self):
        for location in ("external", "internal", "directory"):
            with self.subTest(location=location):
                release_root = self.root / location
                version = "ordinary-looking-version"
                package = release_root / version
                package.mkdir(parents=True)
                normal = {"package_version": version, "git_commit": self.base}
                experimental = dict(normal, package_kind="experimental", git_commit=None)
                (package / "manifest.json").write_text(json.dumps(
                    experimental if location == "internal" else normal,
                ))
                if location == "directory":
                    (package / "provenance").mkdir()
                (release_root / f"chromat-{version}.manifest.json").write_text(json.dumps(
                    experimental if location == "external" else normal,
                ))
                for suffix in (".tar.gz", ".tar.gz.sha256"):
                    (release_root / f"chromat-{version}{suffix}").write_text(
                        "intentionally invalid; must reject identity first\n",
                    )
                result = subprocess.run(
                    ["bash", "scripts/create-github-draft-release.sh", version,
                     str(release_root)], cwd=self.repo, env=self.env,
                    capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("experimental", result.stderr)
                self.assertFalse(self.log.exists())
                self.assertFalse(self.gh_log.exists())


if __name__ == "__main__":
    unittest.main()
