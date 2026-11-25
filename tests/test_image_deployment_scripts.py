"""Offline image package integrity and updater failure/rollback contracts."""

from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch
import yaml


REPO = Path(__file__).resolve().parents[1]
CONFIG_BYTES = json.dumps({"os": "linux", "architecture": "amd64", "rootfs": {"diff_ids": []}}).encode()
NEW_ID = "sha256:" + hashlib.sha256(CONFIG_BYTES).hexdigest()
OCI_MANIFEST = json.dumps({"config": {"digest": NEW_ID}, "layers": []}).encode()
OCI_MANIFEST_ID = "sha256:" + hashlib.sha256(OCI_MANIFEST).hexdigest()
OCI_INDEX = json.dumps({"manifests": [{"digest": OCI_MANIFEST_ID}]}).encode()
INDEX_ID = "sha256:" + hashlib.sha256(OCI_INDEX).hexdigest()
OLD_ID = "sha256:" + "b" * 64


class ComposeLoader(yaml.SafeLoader):
    pass


def override_value(loader, node):
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_mapping(node)


ComposeLoader.add_constructor("!override", override_value)


def make_archive(path, tag, oci=True):
    config_path = "blobs/sha256/" + NEW_ID.split(":")[1]
    files = {
        "manifest.json": json.dumps([{"Config": config_path, "RepoTags": [tag], "Layers": []}]).encode(),
        config_path: CONFIG_BYTES,
    }
    if oci:
        files.update({
            "index.json": json.dumps({"manifests": [{"digest": INDEX_ID}]}).encode(),
            "blobs/sha256/" + INDEX_ID.split(":")[1]: OCI_INDEX,
            "blobs/sha256/" + OCI_MANIFEST_ID.split(":")[1]: OCI_MANIFEST,
        })
    with tarfile.open(path, "w") as package:
        for name, value in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(value)
            package.addfile(info, io.BytesIO(value))


def load_script(name, marker):
    code = (REPO / "scripts" / name).read_text(encoding="utf-8").split(marker, 1)[1]
    if name.endswith(".sh"):
        code = code.rsplit("\nPYTHON", 1)[0]
    module = types.ModuleType(name)
    # Production updater runs on Linux; only its orchestration is exercised on Windows.
    try:
        import fcntl  # noqa: F401
        exec(compile(code, name, "exec"), module.__dict__)
    except ModuleNotFoundError as error:
        if error.name != "fcntl":
            raise
        with patch.dict(sys.modules, {"fcntl": types.ModuleType("fcntl")}):
            exec(compile(code, name, "exec"), module.__dict__)
    return module


class ImageUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dsa image test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.compose = self.root / "compose.yaml"
        self.compose.write_text("services: {}\n", encoding="utf-8")
        (self.root / "deployment.env").write_text("PRIVATE_VALUE=keep-me\n", encoding="utf-8")
        make_archive(self.root / "image.tar", "dsa:deploy-test")
        self.manifest = {
            "format": 1, "image": "dsa:deploy-test", "image_id": INDEX_ID,
            "platform": "linux/amd64", "sha256": hashlib.sha256((self.root / "image.tar").read_bytes()).hexdigest(),
        }
        self.write_manifest()
        self.module = load_script("update-image.sh", "<<'PYTHON'\n")
        self.calls = []
        self.up_count = 0
        self.fail_health = False
        self.active_image = OLD_ID
        self.loaded_id = NEW_ID
        self.mounts = [{"Destination": "/app/data"}]
        self.architecture = "x86_64"

    def write_manifest(self):
        (self.root / "image.json").write_text(json.dumps(self.manifest), encoding="utf-8")

    def docker(self, args, capture=False):
        self.calls.append(args)
        if "--help" in args:
            return "--wait-timeout --pull"
        if args[1] == "info":
            return json.dumps({"OSType": "linux", "Architecture": self.architecture})
        if args[1:3] == ["image", "inspect"]:
            return json.dumps([{"Id": self.loaded_id, "Os": "linux", "Architecture": "amd64"}])
        if args[1] == "inspect":
            return json.dumps([{
                "Name": "/dsa-server",
                "Image": self.active_image, "State": {"Running": True}, "Mounts": self.mounts,
                "HostConfig": {"PortBindings": {"9123/tcp": [{"HostIp": "127.0.0.1", "HostPort": "18123"}]}},
                "Config": {"Cmd": ["python", "main.py", "--serve-only", "--port", "9123"],
                           "Labels": {"com.docker.compose.project": "existing-project",
                                      "com.docker.compose.project.config_files": str(self.compose)}},
            }])
        if args[1] == "compose" and "ps" in args:
            return "existing-container"
        if args[1] == "compose" and "up" in args:
            self.up_count += 1
            index = max(i for i, value in enumerate(args) if value == "-f")
            override = yaml.load(Path(args[index + 1]).read_text(encoding="utf-8"), Loader=ComposeLoader)
            ref = override["services"]["server"]["image"]
            self.active_image = OLD_ID if ref.startswith("dsa-image-rollback:") else self.loaded_id
            self.assertIn("--no-build", args)
            self.assertEqual(override["services"]["server"]["pull_policy"], "never")
            self.assertNotIn("--pull", args)
            self.assertIn("--no-deps", args)
        if args[1] == "exec":
            self.assertEqual(args[-1], "9123")
            if self.fail_health and self.up_count == 1:
                raise subprocess.CalledProcessError(1, ["docker", "exec", "health-probe"])
        return ""

    def update(self):
        with patch.object(self.module, "run", side_effect=self.docker), redirect_stdout(io.StringIO()):
            self.module.update(self.root)

    def test_success_preserves_configuration_and_pins_image(self):
        self.update()
        self.assertEqual(self.active_image, NEW_ID)
        self.assertEqual(self.up_count, 1)
        self.assertEqual(self.compose.read_text(), "services: {}\n")
        self.assertEqual((self.root / "deployment.env").read_text(), "PRIVATE_VALUE=keep-me\n")
        self.assertTrue(any(call[1] == "exec" for call in self.calls))
        self.assertTrue(any("--env-file" in call for call in self.calls))

    def test_bad_checksum_stops_before_docker_is_called(self):
        self.manifest["sha256"] = "0" * 64
        self.write_manifest()
        with self.assertRaisesRegex(RuntimeError, "SHA256 mismatch"):
            self.update()
        self.assertEqual(self.calls, [])

    def test_containerd_index_identity_is_accepted(self):
        self.loaded_id = INDEX_ID
        self.update()
        self.assertEqual(self.active_image, INDEX_ID)

    def test_unrelated_loaded_identity_never_restarts(self):
        self.loaded_id = "sha256:" + "c" * 64
        with self.assertRaisesRegex(RuntimeError, "verified archive identity"):
            self.update()
        self.assertEqual(self.up_count, 0)

    def test_classic_archive_uses_config_identity(self):
        make_archive(self.root / "image.tar", "dsa:deploy-test", oci=False)
        self.manifest["image_id"] = NEW_ID
        self.manifest["sha256"] = hashlib.sha256((self.root / "image.tar").read_bytes()).hexdigest()
        self.write_manifest()
        self.update()
        self.assertEqual(self.active_image, NEW_ID)

    def test_wrong_package_identity_stops_before_loading(self):
        self.manifest["image_id"] = OLD_ID
        self.write_manifest()
        with self.assertRaisesRegex(RuntimeError, "archive metadata"):
            self.update()
        self.assertEqual(self.calls, [])

    def test_wrong_architecture_never_loads_or_restarts(self):
        self.architecture = "aarch64"
        with self.assertRaisesRegex(RuntimeError, "platform differ"):
            self.update()
        self.assertFalse(any(call[1] in {"load", "compose"} for call in self.calls))

    def test_program_mount_rejected_before_load(self):
        self.mounts = [{"Destination": "/app/static"}]
        with self.assertRaisesRegex(RuntimeError, "hides image program"):
            self.update()
        self.assertFalse(any(call[1] == "load" for call in self.calls))

    def test_failed_http_health_check_restores_previous_image(self):
        self.fail_health = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.update()
        self.assertEqual(self.active_image, OLD_ID)
        self.assertEqual(self.up_count, 2)
        override = json.loads((self.root / ".image-update.override.json").read_text())
        self.assertTrue(override["services"]["server"]["image"].startswith("dsa-image-rollback:"))
        self.assertEqual(len(list((self.root / ".image-update-backups").glob("*/rollback-command.txt"))), 1)


class ManagedComposeTests(ImageUpdateTests):
    def setUp(self):
        super().setUp()
        self.manifest["format"] = 2
        template = (REPO / "docker/docker-compose.yml").read_bytes().replace(b"\r\n", b"\n")
        (self.root / "compose.template.yml").write_bytes(template)
        self.manifest["compose_sha256"] = hashlib.sha256(template).hexdigest()
        self.write_manifest()
        self.mounts = [{"Type": "bind", "Source": str(self.root / "state/data"),
                        "Destination": "/app/data", "RW": True}]
        self.version = "2.30.0"
        self.fail_auth = False
        self.resolved = {
            "name": "existing-project",
            "services": {"server": {"image": "old-image", "container_name": "dsa-server",
                                    "environment": {"ENV_FILE": "/app/data/runtime.env"},
                                    "networks": {"default": {"aliases": ["server"]}}}},
            "networks": {"default": {"name": "existing-project_default"}},
        }

    def docker(self, args, capture=False):
        if args[1:3] == ["compose", "version"]:
            self.calls.append(args)
            return self.version
        if args[1] == "ps":
            self.calls.append(args)
            return "existing-container"
        if args[1] == "compose" and "config" in args and "--format" in args:
            self.calls.append(args)
            return json.dumps(self.resolved)
        if args[1] == "compose" and "run" in args and self.fail_auth:
            self.calls.append(args)
            raise subprocess.CalledProcessError(1, ["docker", "compose", "run", "auth-preflight"])
        return super().docker(args, capture)

    # The inherited identity and integrity tests also exercise version 2 packages.
    def test_success_preserves_configuration_and_pins_image(self):
        original = self.compose.read_bytes()
        self.update()
        self.assertEqual(self.active_image, NEW_ID)
        canonical = self.root / "docker/docker-compose.yml"
        self.assertEqual(canonical.read_bytes(), (self.root / "compose.template.yml").read_bytes())
        self.assertEqual(self.compose.read_bytes(), original)
        data = yaml.load((self.root / ".image-update.override.yaml").read_text(), Loader=ComposeLoader)
        instance = data["services"]["server"]
        self.assertEqual(instance["container_name"], "dsa-server")
        self.assertEqual(instance["ports"][0]["published"], "18123")
        self.assertEqual(instance["ports"][0]["host_ip"], "127.0.0.1")
        self.assertEqual((canonical.parent / instance["volumes"][0]["source"]).resolve(), self.root / "state/data")
        self.assertEqual((canonical.parent / instance["env_file"][-1]).resolve(), self.root / "deployment.env")
        self.assertEqual(instance["environment"]["ENV_FILE"], "/app/data/runtime.env")
        self.assertEqual(data["networks"], self.resolved["networks"])
        self.assertEqual((self.root / "deployment.env").read_text(), "PRIVATE_VALUE=keep-me\n")

    def test_failed_http_health_check_restores_previous_image(self):
        self.fail_health = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.update()
        self.assertEqual(self.active_image, OLD_ID)
        self.assertEqual(self.up_count, 2)
        self.assertFalse((self.root / ".image-update.override.yaml").exists())
        snapshots = list((self.root / ".image-update-backups").glob("*/previous-resolved.json"))
        self.assertEqual(len(snapshots), 1)
        self.assertEqual(json.loads(snapshots[0].read_text()), self.resolved)

    def test_template_checksum_mismatch_never_loads_or_restarts(self):
        self.manifest["compose_sha256"] = "0" * 64
        self.write_manifest()
        with self.assertRaisesRegex(RuntimeError, "Compose template SHA256 mismatch"):
            self.update()
        self.assertEqual(self.up_count, 0)
        self.assertFalse(any(call[1] == "load" for call in self.calls))

    def test_old_compose_version_stops_before_mutating_service(self):
        self.version = "2.23.0"
        with self.assertRaisesRegex(RuntimeError, "2.24.4"):
            self.update()
        self.assertEqual(self.up_count, 0)

    def test_invalid_auth_blocks_update_before_service_recreation(self):
        self.fail_auth = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.update()
        self.assertEqual(self.active_image, OLD_ID)
        self.assertEqual(self.up_count, 0)
        self.assertFalse((self.root / "docker/docker-compose.yml").exists())

    def test_program_mount_rejected_before_load(self):
        self.mounts[0]["Destination"] = "/app/static"
        with self.assertRaisesRegex(RuntimeError, "hides image program"):
            self.update()
        self.assertFalse(any(call[1] == "load" for call in self.calls))


class ImagePackageTests(unittest.TestCase):
    def test_package_checksums_export_and_delivers_lf_updater(self):
        module = load_script("package-image.cmd", "\n# BEGIN_IMAGE_PYTHON\n")
        with tempfile.TemporaryDirectory(prefix="image package ") as folder:
            root = Path(folder)
            (root / "scripts").mkdir()
            (root / "scripts/update-image.sh").write_bytes(b"#!/bin/bash\r\necho test\r\n")
            (root / "docker").mkdir()
            compose_bytes = b"services:\r\n  server:\r\n    image: test\r\n"
            (root / "docker/docker-compose.yml").write_bytes(compose_bytes)
            calls = []

            def run(args, **kwargs):
                calls.append(args)
                if "save" in args:
                    make_archive(Path(args[args.index("--output") + 1]), args[-1])

            info = json.dumps([{"Id": INDEX_ID, "Os": "linux", "Architecture": "amd64"}]).encode()
            with patch.object(sys, "argv", ["-c", "package-image.cmd", str(root)]), \
                    patch.object(module.shutil, "which", return_value="docker"), \
                    patch.object(module.subprocess, "run", side_effect=run), \
                    patch.object(module.subprocess, "check_output", return_value=info), \
                    redirect_stdout(io.StringIO()):
                module.main()
            package = next((root / "dist").iterdir())
            metadata = json.loads((package / "image.json").read_text())
            self.assertEqual(metadata["sha256"], hashlib.sha256((package / "image.tar").read_bytes()).hexdigest())
            self.assertEqual(metadata["image_id"], NEW_ID)
            self.assertEqual(metadata["image"], "daily_stock_analysis:latest")
            self.assertEqual(package.name, "docker-image")
            self.assertEqual(metadata["format"], 2)
            self.assertEqual((package / "compose.template.yml").read_bytes(), compose_bytes.replace(b"\r\n", b"\n"))
            self.assertEqual(metadata["compose_sha256"], hashlib.sha256((package / "compose.template.yml").read_bytes()).hexdigest())
            self.assertNotIn(b"\r", (package / "update-image.sh").read_bytes())
            self.assertTrue(any("--platform" in call and "linux/amd64" in call for call in calls))


if __name__ == "__main__":
    unittest.main()
