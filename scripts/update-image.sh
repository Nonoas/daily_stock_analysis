#!/usr/bin/env bash
# Load an offline image package and update an existing Compose service.
set -Eeuo pipefail
command -v python3 >/dev/null || { echo 'ERROR: Python 3 is required' >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 -I - "$script_dir" "$@" <<'PYTHON'
import argparse
import copy
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import uuid


HTTP_PROBE = '''import sys, time, urllib.request
from src.config import setup_env, get_config
setup_env()
port = int(sys.argv[1]) if sys.argv[1] else get_config().webui_port
url = "http://127.0.0.1:" + str(port) + "/api/v1/health"
# Never send a loopback health request through a configured HTTP proxy.
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
deadline = time.monotonic() + 180
while time.monotonic() < deadline:
    try:
        with opener.open(url, timeout=5) as response:
            if response.status == 200:
                print("HTTP health check passed")
                sys.exit(0)
    except (OSError, ValueError):
        pass
    time.sleep(2)
sys.exit("HTTP health check failed")
'''


AUTH_PROBE = '''import json, sys
from src.auth import get_github_auth_config, is_auth_enabled
c = get_github_auth_config()
if is_auth_enabled() and not c.configured:
    print("OAuth configuration is incomplete or invalid: " + json.dumps({
        "client_id_set": bool(c.client_id), "client_secret_set": bool(c.client_secret),
        "callback_set": bool(c.callback_url), "allowlist_count": len(c.allowed_users),
        "allowlist_valid": c.valid_allowlist, "allow_http": getattr(c, "allow_http", None),
    }))
    sys.exit(1)
print("Authentication configuration check passed")
'''


def run(args, capture=False):
    # Captured inspect/config output can contain secrets: never echo it on failure.
    result = subprocess.run(args, check=True, stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None, text=True)
    return result.stdout.strip() if capture else None


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def write_json(path, value):
    temporary = path.with_name(path.name + ".partial")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def write_override(path, value, managed=False):
    if not managed:
        return write_json(path, value)
    # JSON values are valid YAML. !override prevents old defaults from adding
    # extra mounts/ports/env files to an existing server instance (Compose 2.24.4+).
    lines = ["# Generated instance settings; base configuration lives in docker/docker-compose.yml."]
    for key, item in value.items():
        if key != "services":
            lines.append(json.dumps(key) + ": " + json.dumps(item))
            continue
        lines.append("services:")
        for name, fields in item.items():
            lines.append("  " + json.dumps(name) + ":")
            for field, setting in fields.items():
                tag = "!override " if field in {"volumes", "ports", "env_file", "networks"} else ""
                lines.append("    " + json.dumps(field) + ": " + tag + json.dumps(setting))
    temporary = path.with_name(path.name + ".partial")
    temporary.write_text("\n".join(lines) + "\n", encoding="utf-8")
    temporary.replace(path)


def prepare_project_compose(root, manifest, service, backup):
    """Use the shipped repository Compose, preserving only instance-specific settings."""
    payload = root / "compose.template.yml"
    contents = payload.read_bytes()
    require(hashlib.sha256(contents).hexdigest() == manifest.get("compose_sha256"), "Compose template SHA256 mismatch")
    version = run(["docker", "compose", "version", "--short"], capture=True)
    numbers = re.match(r"v?(\d+)\.(\d+)\.(\d+)", version)
    require(numbers and tuple(map(int, numbers.groups())) >= (2, 24, 4), "Project Compose migration requires Docker Compose 2.24.4 or later")
    env_file = root / "deployment.env"
    require(env_file.is_file(), "Keep server settings in deployment.env before updating")
    # Applies to every service defined by the canonical Compose, including
    # inactive analyzer; no duplicate .env or credentials file is created.
    os.environ["DSA_ENV_FILE"] = str(env_file)
    compose_file = root / "docker/docker-compose.yml"
    require(not compose_file.is_symlink() and compose_file.resolve().is_relative_to(root), "Unsafe managed Compose path")
    compose_file.parent.mkdir(exist_ok=True)
    pending = compose_file.with_name(".compose.pending.yml")
    pending.write_bytes(contents)
    override = root / ".image-update.override.yaml"
    require(not override.is_symlink(), "Image override must not be a symlink")
    backup.mkdir(parents=True, mode=0o700)
    if compose_file.exists():
        shutil.copy2(compose_file, backup / "previous-compose.yml")
    if override.exists():
        shutil.copy2(override, backup / "previous-override.yaml")

    def relative(path):
        path = Path(path).resolve()
        return os.path.relpath(path, compose_file.parent) if path.is_relative_to(root) else str(path)

    candidates = []
    ids = run(["docker", "ps", "-a", "-q", "--filter", "label=com.docker.compose.service=" + service], capture=True).splitlines()
    for identifier in ids:
        item = json.loads(run(["docker", "inspect", identifier], capture=True))[0]
        paths = item["Config"].get("Labels", {}).get("com.docker.compose.project.config_files", "").split(",")
        if any(path and Path(path).resolve().is_relative_to(root) for path in paths):
            candidates.append((item, paths))
    require(len(candidates) <= 1, "Multiple existing services belong to this deployment; resolve the ambiguity first")
    old = None
    old_base = None
    if candidates:
        old, paths = candidates[0]
        require(old["State"]["Running"], "Existing service must be running before migration/update")
        require(all(Path(path).is_file() for path in paths), "Existing Compose files are missing; restore them before migration")
        project = old["Config"]["Labels"]["com.docker.compose.project"]
        old_base = ["docker", "compose", "--env-file", str(env_file), "-p", project]
        for path in paths:
            old_base += ["-f", path]
        resolved = json.loads(run(old_base + ["config", "--format", "json"], capture=True))
        # Freeze the complete previous Compose for rollback; output may contain
        # explicit server credentials and therefore stays in a private backup.
        write_json(backup / "previous-resolved.json", resolved)
        old_base = ["docker", "compose", "--env-file", str(env_file), "-p", project,
                    "-f", str(backup / "previous-resolved.json")]
        previous = resolved["services"][service]
        instance = {key: copy.deepcopy(previous[key]) for key in
                    ("environment", "entrypoint", "network_mode", "extra_hosts", "dns") if key in previous}
        instance["container_name"] = old.get("Name", "/" + previous.get("container_name", service)).lstrip("/")
        instance["command"] = old["Config"].get("Cmd") or previous.get("command")
        mounts = []
        for mount in (old or {}).get("Mounts", []):
            require(mount["Type"] == "bind", "Migration currently requires bind-mounted persistent data; review named volumes manually")
            mounts.append({"type": "bind", "source": relative(mount["Source"]), "target": mount["Destination"],
                           "read_only": not mount.get("RW", True)})
        instance["volumes"] = mounts
        ports = []
        for target, bindings in (old.get("HostConfig", {}).get("PortBindings") or {}).items():
            port, protocol = target.split("/")
            for binding in bindings or []:
                ports.append({"target": int(port), "published": binding["HostPort"],
                              "protocol": protocol, "host_ip": binding.get("HostIp") or "0.0.0.0"})
        instance["ports"] = ports
        networks = {}
        if "network_mode" not in instance:
            instance["networks"] = copy.deepcopy(previous.get("networks", {"default": None}))
            networks = {name: copy.deepcopy(resolved.get("networks", {}).get(name, {})) for name in instance["networks"]}
        files = []
        for value in previous.get("env_file", []):
            value = value.get("path") if isinstance(value, dict) else value
            if value and Path(value).resolve() != env_file:
                files.append(relative(value))
        files.append(relative(env_file))
        instance["env_file"] = files
    elif override.exists():
        # On a new host, a saved instance override can recreate the deployment.
        existing = ["docker", "compose", "--env-file", str(env_file), "-f", str(pending), "-f", str(override)]
        resolved = json.loads(run(existing + ["config", "--format", "json"], capture=True))
        project = resolved["name"]
        previous = resolved["services"][service]
        instance = {key: copy.deepcopy(previous[key]) for key in
                    ("environment", "container_name", "command", "entrypoint", "network_mode", "extra_hosts", "dns", "ports", "networks") if key in previous}
        instance["volumes"] = [dict(mount, source=relative(mount["source"])) for mount in previous.get("volumes", [])]
        instance["env_file"] = [relative(env_file)]
        networks = resolved.get("networks", {})
    else:
        # Fresh offline deployment: use the established state/ layout; strategies
        # stay inside the image instead of being hidden by an empty host mount.
        instance = {"env_file": [relative(env_file)], "environment": {"ENV_FILE": "/app/data/runtime.env"},
                    "volumes": [{"type": "bind", "source": relative(root / "state" / name), "target": target}
                                for name, target in (("data", "/app/data"), ("logs", "/app/logs"),
                                                     ("reports", "/app/reports"), ("longbridge_tokens", "/home/dsa/.longbridge"))]}
        networks = {}
        project = None
    # Older Compose resolves env_file into environment during `config`.
    # Do not freeze deployment.env values into the generated instance override:
    # keep them supplied by env_file so later credential changes are effective.
    managed_keys = set()
    for line in env_file.read_text(encoding="utf-8-sig").splitlines():
        match = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
        if match:
            managed_keys.add(match.group(1))
    runtime_keys = {"ENV_FILE", "DATABASE_PATH", "LOG_DIR", "WEBUI_HOST", "WEBUI_PORT",
                    "WEBUI_AUTO_BUILD", "TZ", "TRUST_X_FORWARDED_FOR"}
    if "environment" in instance:
        instance["environment"] = {key: value for key, value in instance["environment"].items()
                                   if key not in managed_keys or key in runtime_keys}
    runtime = {"services": {service: instance}}
    if project:
        runtime["name"] = project
    if networks:
        runtime["networks"] = networks
    instance["image"] = manifest["image"]
    candidate = backup / "new.override.yaml"
    write_override(candidate, runtime, managed=True)
    preflight = ["docker", "compose", "--env-file", str(env_file), "-f", str(pending), "-f", str(candidate)]
    run(preflight + ["config", "--quiet"])
    if not project:
        project = json.loads(run(preflight + ["config", "--format", "json"], capture=True))["name"]
        runtime["name"] = project
    base = ["docker", "compose", "--env-file", str(env_file), "-p", project, "-f", str(compose_file)]
    return {"compose": compose_file, "pending": pending, "override": override, "runtime": runtime,
            "base": base, "old": old, "old_base": old_base, "backup": backup}


def archive_image_ids(archive, image_name, platform):
    """Bind classic config IDs and containerd manifest/index IDs to the same exported image."""
    with tarfile.open(archive, "r:*") as package:
        def read_json(name):
            member = package.getmember(name)
            require(member.isfile() and member.size <= 4 * 1024 * 1024, "Invalid image metadata entry")
            data = package.extractfile(member).read()
            return json.loads(data), "sha256:" + hashlib.sha256(data).hexdigest()

        entries, _ = read_json("manifest.json")
        matches = [entry for entry in entries if image_name in entry.get("RepoTags", [])]
        require(len(matches) == 1, "Archive must contain exactly one image with the package tag")
        config, config_id = read_json(matches[0]["Config"])
        require(config.get("os", "") + "/" + config.get("architecture", "") == platform,
                "Archive config platform differs from package metadata")
        identities = {config_id}
        try:
            index, _ = read_json("index.json")
        except KeyError:
            return identities  # Classic docker save archives have no OCI index.
        visited = {}
        active = set()

        def visit(descriptor):
            digest = descriptor.get("digest", "")
            require(re.fullmatch(r"sha256:[0-9a-f]{64}", digest), "Invalid OCI descriptor digest")
            if digest in visited:
                return visited[digest]
            require(digest not in active and len(visited) + len(active) < 64, "Invalid OCI descriptor graph")
            active.add(digest)
            node, actual_digest = read_json("blobs/sha256/" + digest.split(":", 1)[1])
            require(digest == actual_digest, "OCI metadata digest mismatch")
            if "manifests" in node:
                # Visit every child, not just the first platform/attestation descriptor.
                children = [visit(child) for child in node["manifests"]]
                matches_config = any(children)
            else:
                matches_config = node.get("config", {}).get("digest") == config_id
            if matches_config:
                identities.add(digest)
            active.remove(digest)
            visited[digest] = matches_config
            return matches_config

        require(any([visit(child) for child in index.get("manifests", [])]),
                "OCI index does not reference the exported image config")
        return identities


def start_service(base, override, up, service, expected_image):
    command = base + ["-f", str(override)]
    run(command + up)
    ids = run(command + ["ps", "-q", service], capture=True).splitlines()
    require(len(ids) == 1, "Expected one running service container after recreation")
    container = json.loads(run(["docker", "inspect", ids[0]], capture=True))[0]
    require(container["Image"] in expected_image, "Running container does not use the expected image")
    port = ""
    args = container["Config"].get("Cmd") or []
    for index, value in enumerate(args):
        if value == "--port" and index + 1 < len(args):
            port = args[index + 1]
        elif value.startswith("--port="):
            port = value.split("=", 1)[1]
    if not port:
        env = dict(value.split("=", 1) for value in container["Config"].get("Env", []) if "=" in value)
        port = env.get("WEBUI_PORT") or env.get("API_PORT") or ""
    require(not port or (port.isdigit() and 1 <= int(port) <= 65535), "Invalid service port")
    run(["docker", "exec", ids[0], "python", "-c", HTTP_PROBE, port], capture=True)


def update(root, compose_file=None, service="server"):
    root = root.resolve()
    require(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", service), "Invalid Compose service name")
    manifest = json.loads((root / "image.json").read_text(encoding="utf-8"))
    managed = manifest.get("format") == 2
    if managed:
        require(compose_file is None, "Version 2 packages always use the repository Compose template")
    if not managed and compose_file is None:
        candidates = [root / name for name in (
            "compose.yaml", "compose.yml", "docker-compose.yml", "docker/docker-compose.yml",
        ) if (root / name).is_file()]
        require(len(candidates) == 1, "Pass the intended Compose file explicitly: bash update-image.sh /path/to/compose.yaml [service]")
        compose_file = candidates[0]
    if not managed:
        compose_file = compose_file.resolve()
        require(compose_file.is_file(), "Compose file not found")
    archive = root / "image.tar"
    require(manifest.get("format") in {1, 2}, "Unsupported package format")
    require(re.fullmatch(r"[a-z0-9][a-z0-9_.-]*:(?:latest|deploy-[a-z0-9-]+)", manifest.get("image", "")), "Invalid image tag")
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", manifest.get("image_id", "")), "Invalid image ID")
    require(manifest.get("platform") in {"linux/amd64", "linux/arm64"}, "Unsupported image platform")
    checksum = hashlib.sha256()
    with archive.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    require(checksum.hexdigest() == manifest.get("sha256"), "Image archive SHA256 mismatch; upload it again")
    expected_ids = archive_image_ids(archive, manifest["image"], manifest["platform"])
    require(manifest["image_id"] in expected_ids, "Package image ID does not match its archive metadata")
    host = json.loads(run(["docker", "info", "--format", "{{json .}}"], capture=True))
    architecture = {"x86_64": "amd64", "aarch64": "arm64"}.get(host["Architecture"], host["Architecture"])
    require(host["OSType"] + "/" + architecture == manifest["platform"], "Image and server platform differ; rebuild for the server architecture")

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    backup = root / ".image-update-backups" / stamp
    context = None
    if managed:
        context = prepare_project_compose(root, manifest, service, backup)
        base, old, compose_file, override = (context[key] for key in ("base", "old", "compose", "override"))
    else:
        base = ["docker", "compose", "-f", str(compose_file)]
        env_candidates = [compose_file.parent / "deployment.env", compose_file.parent / ".env"]
        if compose_file.parent.name == "docker":
            env_candidates.insert(0, compose_file.parent.parent / ".env")
        env_file = next((path for path in env_candidates if path.is_file()), None)
        if env_file:
            base += ["--env-file", str(env_file)]
        help_text = run(base + ["up", "--help"], capture=True)
        require("--wait-timeout" in help_text,
                "Docker Compose v2 with --wait-timeout support is required")
        containers = run(base + ["ps", "-a", "-q", service], capture=True).splitlines()
        require(len(containers) == 1, "Expected one existing service container; this script updates an existing deployment only")
        old = json.loads(run(["docker", "inspect", containers[0]], capture=True))[0]
        require(old["State"]["Running"], "Existing service must be running before an update")
        project = old["Config"]["Labels"]["com.docker.compose.project"]
        base += ["-p", project]
        override = compose_file.parent / ".image-update.override.json"
        config_files = old["Config"]["Labels"].get("com.docker.compose.project.config_files", "")
        require(not config_files or all(Path(path).resolve() in {compose_file, override}
                                       for path in config_files.split(",")),
                "Existing service uses additional Compose overrides; consolidate them into the base file before updating")
    # Host-mounted program files would hide the program bundled in the new image.
    program_paths = ("/app/static", "/app/src", "/app/api", "/app/bot", "/app/data_provider", "/app/main.py")
    for mount in (old or {}).get("Mounts", []):
        destination = mount["Destination"].rstrip("/") or "/"
        require(not any(destination == path or path.startswith(destination.rstrip("/") + "/")
                        or destination.startswith(path + "/") for path in program_paths),
                "Host mount hides image program files: " + destination + "; review the Compose mount before updating")

    print("[1/3] Verified package; loading image while the old service stays running.", flush=True)
    run(["docker", "load", "--input", str(archive)])
    image = json.loads(run(["docker", "image", "inspect", manifest["image"]], capture=True))[0]
    require(image["Id"] in expected_ids, "Loaded image ID does not match any verified archive identity")
    require(image["Os"] + "/" + image["Architecture"] == manifest["platform"], "Loaded image platform differs from package metadata")

    backup.mkdir(parents=True, mode=0o700, exist_ok=True)
    rollback_image = "dsa-image-rollback:" + stamp if old else None
    if old:
        run(["docker", "tag", old["Image"], rollback_image])
    require(not override.is_symlink(), "Image override must not be a symlink")
    previous = override.read_bytes() if override.exists() else None
    if managed:
        template = context["runtime"]
        rollback = {"services": {service: {"image": rollback_image, "pull_policy": "never"}}} if old else None
    else:
        if previous is not None:
            (backup / "previous-override.json").write_bytes(previous)
        template = json.loads(previous) if previous is not None else {"services": {service: {}}}
        require(isinstance(template, dict) and isinstance(template.get("services"), dict), "Invalid existing image override")
        template["services"].setdefault(service, {})
        require(isinstance(template["services"][service], dict), "Invalid service override")
        rollback = copy.deepcopy(template)
        rollback["services"][service]["image"] = rollback_image
        rollback["services"][service]["pull_policy"] = "never"
    replacement = copy.deepcopy(template)
    replacement["services"][service]["image"] = manifest["image"]
    replacement["services"][service]["pull_policy"] = "never"
    rollback_path = backup / "rollback.override.json"
    if rollback:
        write_json(rollback_path, rollback)
    candidate = backup / ("new.override.yaml" if managed else "new.override.json")
    write_override(candidate, replacement, managed)
    if not managed:
        run(base + ["-f", str(candidate), "config", "--quiet"])
    check_base = list(base)
    if managed:
        check_base[check_base.index(str(compose_file))] = str(context["pending"])
    run(check_base + ["-f", str(candidate), "run", "--rm", "--no-deps",
                      "-T", "--user", "dsa", "--entrypoint", "python", service, "-c", AUTH_PROBE])
    up = ["up", "-d", "--no-deps", "--no-build", "--force-recreate",
          "--wait", "--wait-timeout", "180", service]
    recovery_base = context["old_base"] if managed else base
    if old:
        if managed:
            recovery_command = shlex.join(recovery_base + ["-f", str(rollback_path)] + up)
        else:
            recovery_command = ("cp -- " + shlex.quote(str(rollback_path)) + " " + shlex.quote(str(override))
                                + " && " + shlex.join(base + ["-f", str(override)] + up))
        (backup / "rollback-command.txt").write_text(recovery_command + "\n", encoding="utf-8")
        print("Manual rollback command:\n" + recovery_command, flush=True)
    print("[2/3] Recreating only " + service + " with the uploaded image.", flush=True)
    try:
        if managed:
            context["pending"].replace(compose_file)
        write_override(override, replacement, managed)
        start_service(base, override, up, service, expected_ids)
    except (Exception, KeyboardInterrupt):
        print("Update failed; attempting to restore the previous deployment.", file=sys.stderr, flush=True)
        if managed:
            if (backup / "previous-compose.yml").exists():
                shutil.copy2(backup / "previous-compose.yml", compose_file)
            if previous is not None:
                override.write_bytes(previous)
            elif override.exists():
                override.unlink()
        else:
            write_json(override, rollback)
        try:
            if old:
                start_service(recovery_base, rollback_path, up, service, {old["Image"]})
            else:
                # No previous deployment exists; stop only the newly created service.
                run(base + ["-f", str(candidate), "stop", service])
        except (Exception, KeyboardInterrupt):
            print("Automatic recovery failed. Consult the private backup and rollback command.", file=sys.stderr)
        raise
    print("[3/3] Service passed Compose startup and HTTP health checks. Active override: " + str(override))
    if managed:
        print("Managed base Compose: " + str(compose_file))
        print("Old root compose.yaml is no longer used; archive it after confirming Nginx access.")
        print("Keep deployment.env, state/ and .image-update.override.yaml when moving to another host.")
        print("Other services such as Nginx or a legacy proxy were not stopped or recreated.")
    if old:
        print("Old image retained as " + rollback_image + "; rollback does not undo application data changes.")


def main():
    parser = argparse.ArgumentParser(description="Update an existing Compose service from image.tar + image.json.")
    parser.add_argument("root", type=Path)
    parser.add_argument("compose_file", nargs="?", type=Path)
    parser.add_argument("service", nargs="?", default="server")
    args = parser.parse_args()
    require(sys.version_info >= (3, 9), "Python 3.9 or later is required")
    os.umask(0o077)
    # Prevent concurrent updates using the same upload directory.
    with (args.root / ".image-update.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        def interrupted(*_):
            raise KeyboardInterrupt()
        signal.signal(signal.SIGTERM, interrupted)
        update(args.root, args.compose_file, args.service)


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print("ERROR:", error, file=sys.stderr)
        sys.exit(1)
PYTHON
