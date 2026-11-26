#!/usr/bin/env python3
"""Gate offline builds and Draft Releases on isolated GitHub-hosted runners."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import runpy
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
IDENTITY = runpy.run_path(str(ROOT / "scripts/lib/image-identity.py"))
DOCKER_VERSION = "29.10.1"
BUSYBOX = "busybox:1.36.1"
BUILD_WORKFLOW = ".github/workflows/offline-package.yml"


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def positive_number(value):
    if not re.fullmatch(r"[1-9][0-9]{0,19}", value):
        raise ValueError("run ID/attempt must be a positive decimal integer")
    return value


def context():
    if (os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or os.environ.get("RUNNER_OS") != "Linux"):
        raise ValueError("this helper only runs on GitHub-hosted Linux runners")
    version = os.environ.get("VERSION", "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", version):
        raise ValueError("invalid package version")
    if version.startswith("experimental-"):
        raise ValueError("experimental sources cannot enter the release workflow")
    commit = os.environ.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("GITHUB_SHA must identify a full source commit")
    return version, commit


def source(require_tag=False):
    version, commit = context()
    if command("git", "rev-parse", "HEAD") != commit:
        raise ValueError("checkout does not match the workflow source commit")
    if command("git", "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("source checkout must be clean")
    if require_tag:
        local = command("git", "rev-parse", "--verify", f"refs/tags/{version}^{{commit}}")
        refs = command("git", "ls-remote", "origin",
                       f"refs/tags/{version}", f"refs/tags/{version}^{{}}")
        remote = dict(line.split()[::-1] for line in refs.splitlines())
        target = remote.get(f"refs/tags/{version}^{{}}",
                            remote.get(f"refs/tags/{version}"))
        if local != commit or target != commit:
            raise ValueError("local and remote release tags must match the source commit")
    return version, commit


def daemon():
    context()
    if not os.environ.get("DOCKER_HOST", "").startswith("unix://"):
        raise ValueError("the CI daemon must use its explicit local Unix socket")
    if command("docker", "version", "--format", "{{.Server.Version}}") != DOCKER_VERSION:
        raise ValueError("unexpected Docker Engine version; no automatic fallback")
    status = json.loads(command("docker", "info", "--format", "{{json .DriverStatus}}"))
    if ["driver-type", "io.containerd.snapshotter.v1"] not in status:
        raise ValueError("the CI daemon must use the containerd image store")
    command("docker", "compose", "version")


def verify_busybox(archive, image_id):
    with archive.open("rb") as stream:
        identity = IDENTITY["verify"](stream)
    if image_id not in identity["ids"]:
        raise ValueError("BusyBox native ID is not backed by the verified OCI archive")


def pins():
    return {key: IDENTITY[key] for key in
            ("INDEX_DIGEST", "PLATFORM_DIGEST", "CONFIG_DIGEST")}


def export_busybox(directory):
    _, commit = source()
    daemon()
    directory.mkdir(parents=True, exist_ok=False)
    archive = directory / "busybox.tar"
    reference = "docker.io/library/busybox@" + IDENTITY["PLATFORM_DIGEST"]
    command("docker", "pull", "--platform=linux/amd64", reference)
    command("docker", "tag", reference, BUSYBOX)
    command("docker", "image", "save", "--platform=linux/amd64",
            "--output", str(archive), BUSYBOX)
    image_id = command("docker", "image", "inspect", "--format", "{{.Id}}", BUSYBOX)
    verify_busybox(archive, image_id)
    proof = {
        "source_commit": commit,
        "source_run_id": positive_number(os.environ["GITHUB_RUN_ID"]),
        "source_run_attempt": positive_number(os.environ["GITHUB_RUN_ATTEMPT"]),
        "docker_version": DOCKER_VERSION,
        "image_store": "containerd",
        "pins": pins(),
        "id": image_id,
        "archive_sha256": digest(archive),
    }
    (directory / "busybox-proof.json").write_text(json.dumps(proof, indent=2) + "\n")


def roundtrip_busybox(directory):
    _, commit = source()
    proof = json.loads((directory / "busybox-proof.json").read_text())
    archive = directory / "busybox.tar"
    if (proof["source_commit"] != commit
            or proof["source_run_id"] != os.environ["GITHUB_RUN_ID"]
            or proof["source_run_attempt"] != os.environ["GITHUB_RUN_ATTEMPT"]
            or proof["docker_version"] != DOCKER_VERSION
            or proof["image_store"] != "containerd"
            or proof["pins"] != pins()
            or proof["archive_sha256"] != digest(archive)):
        raise ValueError("BusyBox proof does not match this source/run/archive")
    verify_busybox(archive, proof["id"])
    daemon()
    command("docker", "load", "--input", str(archive))
    actual = command("docker", "image", "inspect", "--format", "{{.Id}}", BUSYBOX)
    if actual != proof["id"]:
        raise ValueError("BusyBox native ID changed in the independent image store")
    with tempfile.TemporaryDirectory(dir=os.environ["RUNNER_TEMP"]) as temporary:
        exported = Path(temporary) / "busybox.tar"
        command("docker", "image", "save", "--platform=linux/amd64",
                "--output", str(exported), BUSYBOX)
        verify_busybox(exported, actual)
    output = command("docker", "run", "--rm", "--pull=never", "--network=none",
                     BUSYBOX, "sh", "-c",
                     'test "$(uname -m)" = x86_64 && printf busybox-offline-ok')
    if output != "busybox-offline-ok":
        raise ValueError("BusyBox offline execution failed")
    print("PASS: independent BusyBox load, native ID, OCI reexport and offline execution")


def package(directory):
    version, commit = source(require_tag=True)
    daemon()
    directory.mkdir(parents=True, exist_ok=False)
    if shutil.disk_usage(directory).free < 8 * 1024**3:
        raise ValueError("less than 8 GiB free before packaging; stop and review capacity")
    # The packager records base image RepoDigests via Docker image inspect.
    for name in ("api/Dockerfile", "inference/Dockerfile"):
        base = next(line.split()[1] for line in (ROOT / name).read_text().splitlines()
                    if line.startswith("FROM "))
        command("docker", "pull", "--platform=linux/amd64", base)
    env = dict(os.environ, CHROMAT_ENV_FILE=".env.example")
    subprocess.run(["bash", str(ROOT / "scripts/package-artifacts.sh"),
                    version, str(directory)], cwd=ROOT, env=env, check=True)
    subprocess.run(["bash", str(ROOT / "scripts/verify-image-artifacts.sh"),
                    str(directory / version)], cwd=ROOT, check=True)
    archive = directory / f"chromat-{version}.tar.gz"
    if archive.stat().st_size >= 2 * 1024**3:
        raise ValueError("release asset must be smaller than 2 GiB; do not split silently")
    manifest = json.loads((directory / f"chromat-{version}.manifest.json").read_text())
    if (manifest["git_commit"] != commit or manifest["package_kind"] != "release"
            or manifest["source_env_file"] != ".env.example"):
        raise ValueError("package source identity/environment does not match the CI checkout")
    proof = {
        "schema_version": 1,
        "package_version": version,
        "git_commit": commit,
        "workflow": BUILD_WORKFLOW,
        "source_run_id": positive_number(os.environ["GITHUB_RUN_ID"]),
        "source_run_attempt": positive_number(os.environ["GITHUB_RUN_ATTEMPT"]),
        "docker_version": DOCKER_VERSION,
        "image_store": "containerd",
        "archive_sha256": digest(archive),
    }
    (directory / f"chromat-{version}.ci-provenance.json").write_text(
        json.dumps(proof, indent=2, sort_keys=True) + "\n")


def resolve_run(run_id):
    version, commit = context()
    run_id = positive_number(run_id)
    repository = os.environ["GITHUB_REPOSITORY"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("invalid workflow repository")
    run = json.loads(command("gh", "api", f"repos/{repository}/actions/runs/{run_id}"))
    workflow = json.loads(command("gh", "api",
                                  f"repos/{repository}/actions/workflows/offline-package.yml"))
    if (run["workflow_id"] != workflow["id"] or workflow["path"] != BUILD_WORKFLOW
            or run["event"] != "workflow_dispatch" or run["status"] != "completed"
            or run["conclusion"] != "success" or run["head_sha"] != commit
            or run["repository"]["full_name"] != repository
            or run["head_repository"]["full_name"] != repository):
        raise ValueError("source run must be successful, manual, same repository and same commit")
    attempt = positive_number(str(run["run_attempt"]))
    if os.environ.get("DRAFT_CONFIRMATION") != "CREATE_DRAFT":
        raise ValueError("explicit CREATE_DRAFT confirmation is required")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"artifact_name=chromat-offline-{version}-{attempt}\n")
        output.write(f"source_attempt={attempt}\n")


def validate_package(directory, run_id, attempt):
    version, commit = source(require_tag=True)
    run_id, attempt = positive_number(run_id), positive_number(attempt)
    prefix = f"chromat-{version}"
    expected = {f"{prefix}{suffix}" for suffix in
                (".tar.gz", ".tar.gz.sha256", ".manifest.json", ".ci-provenance.json")}
    if {path.name for path in directory.iterdir()} != expected:
        raise ValueError("download must contain exactly the four expected CI assets")
    if any(path.is_symlink() or not path.is_file() for path in directory.iterdir()):
        raise ValueError("CI assets must be regular files")
    archive = directory / f"{prefix}.tar.gz"
    proof = json.loads((directory / f"{prefix}.ci-provenance.json").read_text())
    manifest = json.loads((directory / f"{prefix}.manifest.json").read_text())
    if (proof.get("schema_version") != 1 or proof.get("package_version") != version
            or proof.get("git_commit") != commit or proof.get("workflow") != BUILD_WORKFLOW
            or proof.get("source_run_id") != run_id or proof.get("source_run_attempt") != attempt
            or proof.get("docker_version") != DOCKER_VERSION
            or proof.get("image_store") != "containerd"
            or proof.get("archive_sha256") != digest(archive)
            or manifest.get("git_commit") != commit
            or manifest.get("package_kind") != "release"
            or manifest.get("package_version") != version
            or manifest.get("source_env_file") != ".env.example"):
        raise ValueError("CI provenance or manifest does not match the approved source run")
    if archive.stat().st_size >= 2 * 1024**3:
        raise ValueError("release asset must be smaller than 2 GiB")
    expected_checksum = f"{digest(archive)}  {prefix}.tar.gz\n"
    if (directory / f"{prefix}.tar.gz.sha256").read_text() != expected_checksum:
        raise ValueError("checksum sidecar must identify exactly the package archive")
    subprocess.run(["sha256sum", "--check", "--strict", f"{prefix}.tar.gz.sha256"],
                   cwd=directory, check=True)
    with tarfile.open(archive, "r:gz") as bundle:
        total = 0
        seen = set()
        for member in bundle.getmembers():
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or not path.parts
                    or path.parts[0] != version or not (member.isfile() or member.isdir())):
                raise ValueError("unsafe package archive member")
            if path in seen:
                raise ValueError("duplicate package archive member")
            seen.add(path)
            total += member.size
        if total + 1024**3 > shutil.disk_usage(directory).free:
            raise ValueError("insufficient free space to extract and validate the package")
        if (directory / version).exists():
            raise ValueError("package extraction destination already exists")
        bundle.extractall(directory, filter="data")
    subprocess.run(["bash", str(ROOT / "scripts/verify-artifacts.sh"),
                    str(directory / version)], cwd=ROOT, check=True)
    if (directory / version / "manifest.json").read_bytes() != (
            directory / f"{prefix}.manifest.json").read_bytes():
        raise ValueError("standalone and bundled manifests differ")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    check = sub.add_parser("check-source")
    check.add_argument("--require-tag", action="store_true")
    for name in ("export-busybox", "roundtrip-busybox", "package"):
        sub.add_parser(name).add_argument("directory", type=Path)
    sub.add_parser("resolve-run").add_argument("run_id")
    validate = sub.add_parser("validate-package")
    validate.add_argument("directory", type=Path)
    validate.add_argument("run_id")
    validate.add_argument("attempt")
    args = parser.parse_args()
    context()
    if args.operation == "check-source":
        source(args.require_tag)
    elif args.operation == "export-busybox":
        export_busybox(args.directory)
    elif args.operation == "roundtrip-busybox":
        roundtrip_busybox(args.directory)
    elif args.operation == "package":
        package(args.directory)
    elif args.operation == "resolve-run":
        resolve_run(args.run_id)
    else:
        validate_package(args.directory, args.run_id, args.attempt)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, tarfile.TarError,
            subprocess.CalledProcessError) as error:
        raise SystemExit(f"offline CI gate failed: {error}")
