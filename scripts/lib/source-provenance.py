#!/usr/bin/env python3
"""Identify approved experimental sources without changing Git or using Docker."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile

SOURCE_KIND = "baseline-plus-local-patch"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def sha256(content):
    return hashlib.sha256(content).hexdigest()


def git(repo, *args, allow_difference=False, input_data=None):
    result = subprocess.run(
        ["git", "--no-optional-locks", "--literal-pathspecs", "-c", "core.filemode=true",
         "-c", "core.autocrlf=false", "-C", str(repo), *args],
        capture_output=True, input=input_data,
    )
    if result.returncode not in ((0, 1) if allow_difference else (0,)):
        raise ValueError(result.stderr.decode(errors="replace").strip())
    return result.stdout


def source_path(name):
    path = PurePosixPath(name)
    if (not name or path.is_absolute() or str(path) != name
            or any(part in {"..", ".git", "secrets", "__pycache__", "node_modules"}
                   for part in path.parts)):
        raise ValueError(f"invalid source path: {name}")
    if (path.name in {"ca.key", "server.key", "telegram_bot_token", "db_password",
                      "db_root_password", "operator_password"}
            or (path.name.startswith(".env") and path.name != ".env.example")):
        raise ValueError(f"secret-like source path: {name}")
    return path


def read_source(repo, name):
    relative = source_path(name)
    path = repo / relative
    for parent in (path, *path.parents):
        if parent == repo:
            break
        if parent.is_symlink():
            raise ValueError(f"source links are not supported: {name}")
    content = path.read_bytes()
    mode = "100755" if path.stat().st_mode & 0o111 else "100644"
    return content, {"mode": mode, "sha256": sha256(content)}


def baseline_entries(repo, base):
    baseline = {}
    for entry in git(repo, "ls-tree", "-rz", "--full-tree", base).split(b"\0"):
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        mode, kind, oid = metadata.decode().split()
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise ValueError("source links and submodules are not supported")
        name = raw_name.decode()
        source_path(name)
        baseline[name] = (mode, oid)
    return baseline


def checkout_files(repo, base, included):
    repo = repo.resolve()
    if git(repo, "rev-parse", "--show-toplevel").decode().strip() != str(repo):
        raise ValueError("source directory must be the Git repository root")
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        raise ValueError("base must be a full Git commit")
    if git(repo, "rev-parse", "HEAD").decode().strip() != base:
        raise ValueError("HEAD must match the declared baseline commit")
    baseline = baseline_entries(repo, base)
    indexed = set(filter(None, git(repo, "ls-files", "-z").decode().split("\0")))
    untracked = set(filter(None, git(
        repo, "ls-files", "--others", "--exclude-standard", "-z",
    ).decode().split("\0")))
    additions = (indexed | untracked) - baseline.keys()
    if set(included) != additions:
        raise ValueError("unidentified source additions or stale include list: "
                         + ", ".join(sorted(set(included) ^ additions)))
    files = {}
    for name in sorted(baseline.keys() | additions):
        if (repo / name).exists() or (repo / name).is_symlink():
            _, files[name] = read_source(repo, name)
        elif name in additions:
            raise ValueError(f"source addition is missing: {name}")
    return baseline, files, additions


def verify_reconstruction(repo, snapshot):
    baseline = baseline_entries(repo, snapshot["base_git_commit"])
    objects = io.BytesIO(git(
        repo, "cat-file", "--batch",
        input_data=("\n".join(oid for _, oid in baseline.values()) + "\n").encode(),
    ))
    with tempfile.TemporaryDirectory(prefix="chromat-source-replay-") as directory:
        destination = Path(directory)
        for name, (mode, oid) in baseline.items():
            header_oid, kind, size = objects.readline().decode().split()
            if header_oid != oid or kind != "blob":
                raise ValueError("unexpected baseline Git object")
            content = objects.read(int(size))
            if len(content) != int(size) or objects.read(1) != b"\n":
                raise ValueError("truncated baseline Git object")
            path = destination / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            path.chmod(0o755 if mode == "100755" else 0o644)
        if snapshot["patch"]:
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith("GIT_")}
            environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
            result = subprocess.run(
                ["git", "-c", "core.autocrlf=false", "apply", "--no-index",
                 "--whitespace=nowarn", "-"],
                cwd=destination, input=snapshot["patch"].encode(),
                capture_output=True, env=environment,
            )
            if result.returncode:
                raise ValueError("source patch does not reconstruct baseline: "
                                 + result.stderr.decode(errors="replace").strip())
        reconstructed = {}
        for path in destination.rglob("*"):
            if path.is_symlink():
                raise ValueError("source reconstruction must not contain links")
            if path.is_file():
                name = path.relative_to(destination).as_posix()
                _, reconstructed[name] = read_source(destination, name)
        if reconstructed != snapshot["files"]:
            raise ValueError("source patch does not reconstruct the captured source inventory")


def describe(repo, base, included):
    baseline, files, additions = checkout_files(repo, base, included)
    diff_options = (
        "--binary", "--full-index", "--no-ext-diff", "--no-textconv",
        "--no-renames", "--no-color", "--no-relative",
        "--src-prefix=a/", "--dst-prefix=b/", "--diff-algorithm=myers",
        "--no-indent-heuristic", "--unified=3",
    )
    patch = git(repo, "diff", *diff_options, base, "--", *sorted(baseline))
    for name in sorted(additions):
        patch += git(repo, "diff", "--no-index", *diff_options,
                     "--", "/dev/null", name, allow_difference=True)
    snapshot = {
        "schema_version": 1,
        "source_kind": SOURCE_KIND,
        "base_git_commit": base,
        "base_git_tree": git(repo, "rev-parse", base + "^{tree}").decode().strip(),
        "patch": patch.decode(),
        "patch_sha256": sha256(patch),
        "files": files,
        "source_tree_sha256": sha256(canonical(files)),
    }
    verify_reconstruction(repo, snapshot)
    return snapshot


def read_snapshot(raw, expected_digest):
    if not re.fullmatch(r"[0-9a-f]{64}", expected_digest) or sha256(raw) != expected_digest:
        raise ValueError("source snapshot does not match the approved SHA-256")
    snapshot = json.loads(raw)
    if (snapshot.get("schema_version") != 1
            or snapshot.get("source_kind") != SOURCE_KIND):
        raise ValueError("unsupported experimental source snapshot")
    for field in ("base_git_commit", "base_git_tree"):
        if not re.fullmatch(r"[0-9a-f]{40}", snapshot.get(field, "")):
            raise ValueError(f"invalid {field}")
    if sha256(snapshot["patch"].encode()) != snapshot.get("patch_sha256"):
        raise ValueError("source patch hash mismatch")
    files = snapshot.get("files")
    if not isinstance(files, dict) or not files:
        raise ValueError("source snapshot must identify all source files")
    for name, record in files.items():
        source_path(name)
        if (not isinstance(record, dict) or record.get("mode") not in {"100644", "100755"}
                or not re.fullmatch(r"[0-9a-f]{64}", record.get("sha256", ""))):
            raise ValueError(f"invalid source hash/mode: {name}")
    if sha256(canonical(files)) != snapshot.get("source_tree_sha256"):
        raise ValueError("source file inventory hash mismatch")
    return snapshot


def prepare(repo, snapshot_path, expected_digest, destination):
    raw = snapshot_path.read_bytes()
    snapshot = read_snapshot(raw, expected_digest)
    baseline = baseline_entries(repo, snapshot["base_git_commit"])
    included = snapshot["files"].keys() - baseline.keys()
    _, files, _ = checkout_files(repo, snapshot["base_git_commit"], included)
    tree = git(repo, "rev-parse", snapshot["base_git_commit"] + "^{tree}").decode().strip()
    if files != snapshot["files"] or tree != snapshot["base_git_tree"]:
        raise ValueError("checkout does not match the approved source snapshot")
    verify_reconstruction(repo, snapshot)
    destination.mkdir()
    for name, expected in snapshot["files"].items():
        content, actual = read_source(repo, name)
        if actual != expected:
            raise ValueError(f"source changed while freezing: {name}")
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(content)
        target.chmod(0o755 if expected["mode"] == "100755" else 0o644)
    return raw


def verify_package(package):
    manifest = json.loads((package / "manifest.json").read_bytes())
    kind = manifest.get("package_kind", "release")
    provenance = manifest.get("source_provenance")
    if kind == "release":
        if (provenance is not None or (package / "provenance").exists()
                or manifest["package_version"].startswith("experimental-")):
            raise ValueError("experimental provenance cannot be presented as a normal release")
        return
    if (kind != "experimental" or not isinstance(provenance, dict)
            or not manifest["package_version"].startswith("experimental-")
            or "git_commit" not in manifest or manifest["git_commit"] is not None
            or provenance.get("path") != "provenance/source.json"):
        raise ValueError("invalid experimental package classification")
    raw = (package / "provenance/source.json").read_bytes()
    snapshot = read_snapshot(raw, provenance.get("approval_sha256", ""))
    for key in ("source_kind", "base_git_commit", "base_git_tree",
                "patch_sha256", "source_tree_sha256"):
        if provenance.get(key) != snapshot[key]:
            raise ValueError(f"source provenance does not match manifest: {key}")
    expected = {}
    for name, record in snapshot["files"].items():
        if name == "inference/models/deterministic-model.json":
            expected["model/deterministic-model.json"] = record
        elif (name in {"compose.yaml", ".env.example"}
              or name.startswith(("db/migrations/", "scripts/", "tests/",
                                  "docs/deployment/", "docs/installation/",
                                  "nginx/conf.d/", "web/public/"))):
            expected[name] = record
    generated = {
        "manifest.json", "checksums.sha256", "production.env.example",
        "provenance/source.json", "images/api.tar", "images/inference.tar",
        "images/db.tar", "images/nginx.tar", "images/busybox.tar",
    }
    actual = set()
    for path in package.rglob("*"):
        if path.is_symlink():
            raise ValueError("experimental package must not contain links")
        if path.is_file():
            name = path.relative_to(package).as_posix()
            if name not in generated:
                actual.add(name)
    if actual != expected.keys():
        raise ValueError("package files differ from the approved source inventory")
    for name, record in expected.items():
        _, actual_record = read_source(package, name)
        if actual_record != record:
            raise ValueError(f"package source hash/mode mismatch: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("capture", help="capture identity; this does not approve it")
    capture.add_argument("repo", type=Path)
    capture.add_argument("base")
    capture.add_argument("--include-untracked", action="append", default=[])
    stage = commands.add_parser("prepare", help="verify approval and freeze exact source inputs")
    stage.add_argument("repo", type=Path)
    stage.add_argument("snapshot", type=Path)
    stage.add_argument("approved_sha256")
    stage.add_argument("destination", type=Path)
    package = commands.add_parser("verify-package", help="check packaged source provenance")
    package.add_argument("package", type=Path)
    args = parser.parse_args()
    if args.command == "capture":
        print(json.dumps(describe(args.repo, args.base, args.include_untracked),
                         indent=2, sort_keys=True))
    elif args.command == "prepare":
        sys.stdout.buffer.write(prepare(
            args.repo, args.snapshot, args.approved_sha256, args.destination,
        ))
    else:
        verify_package(args.package)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        raise SystemExit(f"source provenance verification failed: {error}")
