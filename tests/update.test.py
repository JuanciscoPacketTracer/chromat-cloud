import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class UpdateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="chromat-update-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / "remote.git"
        self.source = self.root / "source"
        self.checkout = self.root / "checkout"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "docker.jsonl"
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "DOCKER_TEST_LOG": str(self.log),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.invalid",
        }
        self.git("init", "--bare", "--initial-branch=main", str(self.remote))
        self.git("clone", str(self.remote), str(self.source))
        (self.source / "scripts").mkdir()
        shutil.copyfile(ROOT / "scripts/update.sh", self.source / "scripts/update.sh")
        (self.source / ".gitignore").write_text(".env\nsecrets/\ncerts/\n")
        (self.source / "version").write_text("1")
        self.git("-C", str(self.source), "add", ".")
        self.git("-C", str(self.source), "commit", "-m", "Initial fixture")
        self.git("-C", str(self.source), "push", "origin", "main")
        self.git("clone", str(self.remote), str(self.checkout))
        (self.checkout / ".env").write_text("fixture=config\n")
        for directory in ("secrets", "certs"):
            (self.checkout / directory).mkdir()
            (self.checkout / directory / "fixture").write_text("keep me")
        docker = self.bin / "docker"
        docker.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['DOCKER_TEST_LOG'], 'a') as log:\n"
            "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "sys.exit(7 if ' '.join(sys.argv[1:]) == "
            "os.environ.get('DOCKER_TEST_FAIL') else 0)\n"
        )
        docker.chmod(0o755)
        sudo = self.bin / "sudo"
        sudo.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['DOCKER_TEST_LOG'], 'a') as log:\n"
            "    log.write(json.dumps(['sudo', *sys.argv[1:]]) + '\\n')\n"
            "os.execvp(sys.argv[1], sys.argv[1:])\n"
        )
        sudo.chmod(0o755)

    def git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.root, env=self.env,
            capture_output=True, text=True, check=True,
        ).stdout.strip()

    def publish(self):
        (self.source / "version").write_text("2")
        self.git("-C", str(self.source), "commit", "-am", "Update fixture")
        self.git("-C", str(self.source), "push", "origin", "main")

    def update(self, *args):
        return subprocess.run(
            ["bash", str(self.checkout / "scripts/update.sh"), *args],
            cwd=self.root, env=self.env, capture_output=True, text=True,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] \
            if self.log.exists() else []

    def assert_not_started(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any("up" in call for call in self.calls()))

    def test_fast_forward_rebuilds_and_preserves_local_configuration(self):
        self.publish()
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.checkout / "version").read_text(), "2")
        self.assertEqual((self.checkout / ".env").read_text(), "fixture=config\n")
        for directory in ("secrets", "certs"):
            self.assertEqual((self.checkout / directory / "fixture").read_text(), "keep me")
        self.assertEqual(self.calls(), [
            ["compose", "version"], ["info"], ["compose", "config", "--quiet"],
            ["compose", "up", "-d", "--build", "--force-recreate", "--wait",
             "--wait-timeout", "120"],
            ["compose", "ps"],
        ])

    def test_missing_env_stops_before_pull(self):
        (self.checkout / ".env").unlink()
        self.publish()
        result = self.update()
        self.assert_not_started(result)
        self.assertIn("Missing .env", result.stderr)
        self.assertEqual((self.checkout / "version").read_text(), "1")

    def test_sudo_applies_only_to_docker_and_git_pull_still_works(self):
        self.publish()
        result = self.update("--sudo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.checkout / "version").read_text(), "2")
        sudo_calls = [call for call in self.calls() if call[0] == "sudo"]
        self.assertEqual(len(sudo_calls), 5)
        self.assertTrue(all(call[1] == "docker" for call in sudo_calls))
        self.assertFalse(any("git" in call for call in sudo_calls))

    def test_sudo_failure_stops_before_pull(self):
        self.publish()
        self.env["DOCKER_TEST_FAIL"] = "info"
        result = self.update("--sudo")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.checkout / "version").read_text(), "1")
        self.assertFalse(any("up" in call for call in self.calls()))

    def test_unknown_option_is_rejected(self):
        result = self.update("--unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_pull_can_update_the_running_script(self):
        script = self.source / "scripts/update.sh"
        script.write_text(script.read_text().replace(
            "Update complete.", "Updated script complete."
        ) + "\n")
        self.git("-C", str(self.source), "commit", "-am", "Update updater")
        self.git("-C", str(self.source), "push", "origin", "main")
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls().count(["compose", "ps"]), 1)
        self.assertEqual((self.checkout / "scripts/update.sh").read_text(), script.read_text())

    def test_tracked_or_untracked_changes_are_not_overwritten(self):
        self.publish()
        for path in ("version", "untracked"):
            with self.subTest(path=path):
                target = self.checkout / path
                target.write_text("local change")
                result = self.update()
                self.assert_not_started(result)
                self.assertIn("not clean", result.stderr)
                self.assertEqual(target.read_text(), "local change")
                if path == "version":
                    target.write_text("1")
                else:
                    target.unlink()

    def test_missing_upstream_is_explicit(self):
        self.git("-C", str(self.checkout), "branch", "--unset-upstream")
        result = self.update()
        self.assert_not_started(result)
        self.assertIn("needs an upstream", result.stderr)

    def test_divergent_branch_is_not_merged(self):
        self.publish()
        (self.checkout / "local").write_text("local")
        self.git("-C", str(self.checkout), "add", "local")
        self.git("-C", str(self.checkout), "commit", "-m", "Local fixture")
        before = self.git("-C", str(self.checkout), "rev-parse", "HEAD")
        result = self.update()
        self.assert_not_started(result)
        self.assertEqual(self.git("-C", str(self.checkout), "rev-parse", "HEAD"), before)

    def test_unavailable_docker_stops_before_pull(self):
        self.publish()
        self.env["DOCKER_TEST_FAIL"] = "info"
        self.assert_not_started(self.update())
        self.assertEqual((self.checkout / "version").read_text(), "1")

    def test_invalid_compose_does_not_start_services(self):
        self.env["DOCKER_TEST_FAIL"] = "compose config --quiet"
        self.assert_not_started(self.update())

    def test_failed_start_is_not_reported_as_success(self):
        self.env["DOCKER_TEST_FAIL"] = (
            "compose up -d --build --force-recreate --wait --wait-timeout 120"
        )
        result = self.update()
        self.assertEqual(result.returncode, 7)
        self.assertNotIn("Update complete", result.stdout)
        self.assertNotIn(["compose", "ps"], self.calls())


if __name__ == "__main__":
    unittest.main()
