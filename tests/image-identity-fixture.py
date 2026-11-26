"""Small synthetic OCI export; pins are replaced only in isolated test copies."""

import hashlib
import io
import json
import pathlib
import re
import sys
import tarfile


def fixture(architecture="amd64"):
    def encode(value):
        return json.dumps(value, separators=(",", ":")).encode()

    def descriptor(data, media):
        return {"digest": "sha256:" + hashlib.sha256(data).hexdigest(),
                "size": len(data), "mediaType": media}

    layer = b"synthetic layer content"
    config = encode({"os": "linux", "architecture": architecture})
    config_desc = descriptor(config, "application/vnd.oci.image.config.v1+json")
    layer_desc = descriptor(layer, "application/vnd.oci.image.layer.v1.tar")
    manifest = encode({"schemaVersion": 2, "config": config_desc, "layers": [layer_desc]})
    platform_desc = descriptor(manifest, "application/vnd.oci.image.manifest.v1+json")
    platform_desc["platform"] = {"os": "linux", "architecture": architecture}
    index = encode({"schemaVersion": 2, "manifests": [platform_desc]})
    index_desc = descriptor(index, "application/vnd.oci.image.index.v1+json")
    data = {
        "index.json": encode({"schemaVersion": 2, "manifests": [index_desc]}),
        "manifest.json": encode([{
            "RepoTags": ["busybox:1.36.1"],
            "Config": "blobs/sha256/" + config_desc["digest"][7:],
            "Layers": ["blobs/sha256/" + layer_desc["digest"][7:]],
        }]),
    }
    for content, desc in ((layer, layer_desc), (config, config_desc),
                          (manifest, platform_desc), (index, index_desc)):
        data["blobs/sha256/" + desc["digest"][7:]] = content
    return data, {"CONFIG_DIGEST": config_desc["digest"],
                  "PLATFORM_DIGEST": platform_desc["digest"],
                  "INDEX_DIGEST": index_desc["digest"]}


def archive(data):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as tar:
        for name, content in data.items():
            member = tarfile.TarInfo(name)
            member.size = len(content)
            tar.addfile(member, io.BytesIO(content))
    output.seek(0)
    return output


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parents[1]
    target = pathlib.Path(sys.argv[1])
    data, pins = fixture()
    (target / "images").mkdir(parents=True, exist_ok=True)
    (target / "scripts/lib").mkdir(parents=True, exist_ok=True)
    (target / "images/busybox.tar").write_bytes(archive(data).getvalue())
    helper = (root / "scripts/lib/image-identity.py").read_text()
    for key, digest in pins.items():
        helper = re.sub(rf'^{key} = ".*"$', f'{key} = "{digest}"', helper, flags=re.M)
    (target / "scripts/lib/image-identity.py").write_text(helper)
    print(json.dumps(pins))
