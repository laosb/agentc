#!/usr/bin/env python3
"""Run the bootstrap relay in scratch. Set AGENTC_TEST_MINIMAL_RUNTIME=container
for Apple's container CLI; defaults to docker. Requires a local runtime."""
import os
import hashlib
import io
import json
import platform
from pathlib import Path
import secrets
import socket
import subprocess
import tarfile
import tempfile
import threading
import uuid

repo = Path(__file__).resolve().parent.parent
bootstrap = Path(os.environ.get("AGENTC_TEST_BOOTSTRAP", "~/.agentc/bin/bootstrap")).expanduser()
runtime = os.environ.get("AGENTC_TEST_MINIMAL_RUNTIME", "docker")
assert runtime in ("docker", "container")
name = "agentc-relay-test-" + uuid.uuid4().hex
image_name = "docker.io/library/" + name + ":latest"
token = secrets.token_hex(32)
errors = []

with tempfile.TemporaryDirectory(prefix="relay-minimal-", dir=repo / ".build") as directory:
    root = Path(directory)
    # Construct a one-file image directly; no builder, base image, or network
    # download is needed to test a scratch root filesystem.
    layer_buffer = io.BytesIO()
    with tarfile.open(fileobj=layer_buffer, mode="w") as archive:
        info = tarfile.TarInfo("bootstrap")
        contents = bootstrap.read_bytes()
        info.size, info.mode = len(contents), 0o755
        archive.addfile(info, io.BytesIO(contents))
    layer = layer_buffer.getvalue()
    digest = lambda data: "sha256:" + hashlib.sha256(data).hexdigest()
    encode = lambda value: json.dumps(value, separators=(",", ":")).encode()
    config = encode({
        "architecture": "arm64" if platform.machine() in ("arm64", "aarch64") else "amd64",
        "os": "linux",
        "config": {"Entrypoint": ["/bootstrap", "--agentc-mcp-stdio-relay-v1"]},
        "rootfs": {"type": "layers", "diff_ids": [digest(layer)]},
    })
    if runtime == "docker":
        files = {
            "config.json": config, "layer.tar": layer,
            "manifest.json": encode([{
                "Config": "config.json", "RepoTags": [image_name], "Layers": ["layer.tar"]
            }]),
        }
    else:
        descriptor = lambda data, kind: {
            "mediaType": "application/vnd.oci.image." + kind,
            "digest": digest(data), "size": len(data),
        }
        manifest = encode({
            "schemaVersion": 2, "config": descriptor(config, "config.v1+json"),
            "layers": [descriptor(layer, "layer.v1.tar")],
        })
        reference = descriptor(manifest, "manifest.v1+json")
        reference["annotations"] = {"org.opencontainers.image.ref.name": image_name}
        files = {
            "oci-layout": encode({"imageLayoutVersion": "1.0.0"}),
            "index.json": encode({"schemaVersion": 2, "manifests": [reference]}),
            **{"blobs/sha256/" + digest(data).split(":")[1]: data for data in [config, layer, manifest]},
        }
    image = root / "image.tar"
    with tarfile.open(image, "w") as archive:
        for path, contents in files.items():
            info = tarfile.TarInfo(path)
            info.size = len(contents)
            archive.addfile(info, io.BytesIO(contents))
    try:
        subprocess.run([runtime, "image", "load", "--input", str(image)], check=True, timeout=60)
        with socket.socket() as listener:
            listener.bind(("0.0.0.0", 0))
            listener.listen()
            listener.settimeout(60)
            port = listener.getsockname()[1]

            def server():
                try:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(30)
                        greeting = b""
                        while len(greeting) < 65:
                            chunk = connection.recv(65 - len(greeting))
                            assert chunk, "EOF before authentication"
                            greeting += chunk
                        assert greeting == (token + "\n").encode()
                        connection.sendall(b"OK\n")
                        while True:
                            data = connection.recv(8192)
                            if not data:
                                break
                            connection.sendall(data)
                except BaseException as error:
                    errors.append(error)

            thread = threading.Thread(target=server, daemon=True)
            thread.start()
            payload = bytes(range(256)) * 8192
            result = subprocess.run(
                [runtime, "run", "--rm", "-i", "--name", name, image_name, str(port), token],
                input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90,
            )
            thread.join(timeout=5)
            assert result.returncode == 0, result.stderr.decode(errors="replace")
            assert not errors, errors
            assert not thread.is_alive(), "MCP server did not observe EOF"
            assert result.stdout == payload, "Relay corrupted or truncated opaque bytes"
            print("PASS: bootstrap relay in scratch, 2 MiB opaque duplex traffic, backpressure and EOF")
    finally:
        subprocess.run([runtime, "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([runtime, "image", "rm", image_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
