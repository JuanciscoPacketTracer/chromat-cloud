#!/usr/bin/env python3
"""Verify pinned BusyBox OCI exports without loading or extracting them."""

import hashlib
import json
import re
import sys
import tarfile

PLATFORM_DIGEST = "sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f"
CONFIG_DIGEST = "sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d"
INDEX_DIGEST = "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662"


def verify(stream, name="busybox:1.36.1"):
    blobs = {}
    documents = {}
    files = {}
    total = 0
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for member in archive:
            path = member.name.removeprefix("./")
            if path in files:
                raise ValueError(f"duplicate archive entry: {path}")
            files[path] = member.size
            if not member.isfile():
                if member.isdir():
                    continue
                raise ValueError("image archive must not contain links or special files")
            total += member.size
            if total > 256 * 1024 * 1024:
                raise ValueError("BusyBox archive exceeds verification size limit")
            match = re.fullmatch(r"blobs/sha256/([0-9a-f]{64})", path)
            keep = path in {"manifest.json", "index.json"} or (
                match and member.size <= 1024 * 1024
            )
            if path in {"manifest.json", "index.json"} and member.size > 1024 * 1024:
                raise ValueError("export metadata exceeds verification size limit")
            hasher = hashlib.sha256()
            chunks = []
            source = archive.extractfile(member)
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                hasher.update(chunk)
                if keep:
                    chunks.append(chunk)
            if match:
                digest = "sha256:" + match[1]
                if hasher.hexdigest() != match[1]:
                    raise ValueError(f"blob bytes do not match digest: {digest}")
                blobs[digest] = member.size
            if keep:
                try:
                    documents[path] = json.loads(b"".join(chunks))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    pass

    def blob(digest):
        return documents.get("blobs/sha256/" + digest.removeprefix("sha256:"))

    def descriptor(record):
        if not isinstance(record, dict):
            raise ValueError("invalid OCI descriptor")
        digest = record.get("digest")
        if digest not in blobs or record.get("size") != blobs[digest]:
            raise ValueError("referenced blob missing or descriptor size mismatch")
        return digest

    manifest = blob(PLATFORM_DIGEST)
    config = blob(CONFIG_DIGEST)
    if not isinstance(manifest, dict) or not isinstance(config, dict):
        raise ValueError("pinned OCI platform manifest/config missing; classic exports are not supported")
    if manifest.get("schemaVersion") != 2:
        raise ValueError("invalid pinned manifest schema")
    if descriptor(manifest.get("config")) != CONFIG_DIGEST:
        raise ValueError("platform manifest does not reference pinned config")
    if config.get("os") != "linux" or config.get("architecture") != "amd64":
        raise ValueError("config platform must be linux/amd64")
    layers = manifest.get("layers")
    if not isinstance(layers, list) or not layers:
        raise ValueError("platform manifest must contain layers")
    layer_digests = [descriptor(layer) for layer in layers]

    records = documents.get("manifest.json")
    if not isinstance(records, list) or len(records) != 1:
        raise ValueError("export must contain exactly one tagged image")
    record = records[0]
    if not isinstance(record, dict) or record.get("RepoTags") != [name]:
        raise ValueError("exported tag does not match requested image")
    expected_config_path = "blobs/sha256/" + CONFIG_DIGEST.removeprefix("sha256:")
    expected_layers = ["blobs/sha256/" + digest.removeprefix("sha256:") for digest in layer_digests]
    if record.get("Config") != expected_config_path or record.get("Layers") != expected_layers:
        raise ValueError("tagged export does not reference pinned config/layers")

    identities = {CONFIG_DIGEST, PLATFORM_DIGEST}
    verified_indexes = {}
    descriptor_work = 0
    # Every selectable branch must lead exclusively to the pinned manifest.
    def reaches_platform(index, visited):
        nonlocal descriptor_work
        if not isinstance(index, dict) or not isinstance(index.get("manifests"), list):
            raise ValueError("selectable OCI branch is not the pinned platform or an index")
        if index.get("schemaVersion") != 2:
            raise ValueError("invalid OCI index schema")
        if len(visited) > 32:
            raise ValueError("OCI index nesting exceeds verification limit")
        linked = set()
        height = 0
        for entry in index["manifests"]:
            descriptor_work += 1
            if descriptor_work > 4096:
                raise ValueError("OCI descriptor verification work limit exceeded")
            if not isinstance(entry, dict):
                raise ValueError("invalid OCI index descriptor")
            platform = entry.get("platform", {})
            if not isinstance(platform, dict):
                raise ValueError("invalid OCI platform descriptor")
            if platform and (platform.get("os"), platform.get("architecture")) != ("linux", "amd64"):
                if entry.get("digest") == PLATFORM_DIGEST:
                    raise ValueError("index platform does not match linux/amd64")
                continue
            digest = descriptor(entry)
            if digest == PLATFORM_DIGEST:
                linked.add(digest)
            else:
                if digest in visited:
                    raise ValueError("selectable OCI index contains a cycle")
                if digest not in verified_indexes:
                    verified_indexes[digest] = reaches_platform(blob(digest), visited | {digest})
                descendants, child_height = verified_indexes[digest]
                if len(visited) + 1 + child_height > 32:
                    raise ValueError("OCI index nesting exceeds verification limit")
                height = max(height, 1 + child_height)
                if not descendants:
                    raise ValueError("selectable OCI index does not reference pinned platform")
                linked.update(descendants | {digest})
        return linked, height

    linked, _ = reaches_platform(documents.get("index.json"), set())
    if not linked:
        raise ValueError("OCI export index does not reference pinned platform")
    identities.update(linked)
    return {
        "config_digest": CONFIG_DIGEST,
        "platform_digest": PLATFORM_DIGEST,
        "architecture": "amd64",
        "os": "linux",
        "ids": sorted(identities),
    }


if __name__ == "__main__":
    try:
        with open(sys.argv[1], "rb") as source:
            identity = verify(source)
        if len(sys.argv) > 2 and sys.argv[2] not in identity["ids"]:
            raise ValueError("daemon image ID does not match verified archive identity")
        print(json.dumps(identity, sort_keys=True))
    except (OSError, ValueError, tarfile.TarError, IndexError) as error:
        raise SystemExit(f"image identity verification failed: {error}")
