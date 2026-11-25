#!/usr/bin/env bash
# Install an uploaded deployment archive, preserving production configuration and data.
set -Eeuo pipefail
umask 077

if (($#)); then
    if [[ $# == 1 && "$1" == --help ]]; then
        cat <<'HELP'
Usage: bash upgrade-docker.sh
Place this script beside the existing compose.yaml and deployment.env.
Upload exactly one project-name.tar.gz archive beside them (legacy upgrade.zip is also accepted).
The archive must contain the same deployment/source layout, optionally in one wrapper directory.
The script validates/extracts/builds first, then stops server, snapshots mounted data,
replaces the deployment, restores configuration, and recreates server.
The complete old directory is retained in a private sibling backup directory.
Requires Linux, Python 3, and Docker Compose v2 with --wait-timeout support.
HELP
        exit 0
    fi
    printf 'ERROR: No arguments are needed. Use bash upgrade-docker.sh\n' >&2
    exit 1
fi
command -v python3 >/dev/null || { printf 'ERROR: python3 is required\n' >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
script_file="$script_dir/$(basename -- "$0")"
exec python3 -I - "$script_dir" "$script_file" <<'PYTHON'
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import uuid
import zipfile


SERVICE = "server"
WAIT_SECONDS = 180


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, cwd, capture=False):
    result = subprocess.run(
        [str(arg) for arg in args], cwd=str(cwd), check=True, text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout.strip() if capture else None


def compose(root, project=None, override=None):
    args = [
        "docker", "compose", "--project-directory", str(root),
        "-f", str(root / "compose.yaml"), "--env-file", str(root / "deployment.env"),
    ]
    if project:
        args += ["-p", project]
    if override:
        args += ["-f", str(override)]
    return args


def relative_inside(path, root, allow_root=False):
    path = Path(os.path.abspath(path))
    try:
        relative = path.relative_to(root)
    except ValueError:
        return None
    require(relative.parts or allow_root, "A mount path must not cover the entire deployment: " + str(path))
    current = root
    for part in relative.parts:
        current = current / part
        require(not current.is_symlink(), "Symlinked configured paths are not supported: " + str(current))
    return relative


def safe_archive_path(name, destination):
    require("\\" not in name and "\x00" not in name, "Unsafe archive name: " + repr(name))
    path = PurePosixPath(name)
    require(not path.is_absolute() and ".." not in path.parts, "Archive path escapes deployment: " + name)
    require(not any(":" in part for part in path.parts), "Unsafe archive name: " + name)
    return destination.joinpath(*path.parts)


def extract_archive(archive, destination):
    """Extract only regular files/directories; never follow archive links."""
    destination.mkdir(mode=0o700)
    seen = set()
    directories = []

    def prepare(name, is_directory):
        target = safe_archive_path(name, destination)
        if target == destination:
            require(is_directory, "Invalid archive root entry")
            return None
        key = target.relative_to(destination).as_posix()
        require(key not in seen, "Duplicate archive entry: " + name)
        seen.add(key)
        if is_directory:
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
        return target

    def write_file(name, stream, mode):
        target = prepare(name, False)
        with target.open("xb") as output:
            shutil.copyfileobj(stream, output)
        target.chmod((mode & 0o777) | 0o600)

    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as source:
            require(sum(item.file_size for item in source.infolist()) < shutil.disk_usage(destination).free,
                    "Not enough free space to extract the archive")
            for item in source.infolist():
                mode = item.external_attr >> 16
                file_type = stat.S_IFMT(mode)
                require(file_type in (0, stat.S_IFREG, stat.S_IFDIR),
                        "Links and special files are not allowed: " + item.filename)
                if item.is_dir():
                    target = prepare(item.filename, True)
                    if target:
                        directories.append((target, mode))
                else:
                    require(file_type != stat.S_IFDIR, "Invalid directory entry: " + item.filename)
                    with source.open(item) as stream:
                        write_file(item.filename, stream, mode or 0o644)
    else:
        with tarfile.open(archive, "r:*") as source:
            members = source.getmembers()
            require(sum(item.size for item in members) < shutil.disk_usage(destination).free,
                    "Not enough free space to extract the archive")
            for item in members:
                require(item.isfile() or item.isdir(), "Links and special files are not allowed: " + item.name)
                if item.isdir():
                    target = prepare(item.name, True)
                    if target:
                        directories.append((target, item.mode))
                else:
                    with source.extractfile(item) as stream:
                        write_file(item.name, stream, item.mode)
    for target, mode in sorted(directories, key=lambda item: len(item[0].parts), reverse=True):
        target.chmod((mode & 0o777) | 0o700)


def find_package_root(extracted, context_relative):
    candidates = [extracted] + [path for path in extracted.iterdir() if path.is_dir()]
    matches = [
        path for path in candidates
        if (path / context_relative / "main.py").is_file()
        and (path / context_relative / "requirements.txt").is_file()
    ]
    require(len(matches) == 1, "New package must contain the existing source layout (main.py and requirements.txt)")
    return matches[0]


def preserve_owner(source, destination):
    if os.name == "posix":
        old = source.lstat()
        new = destination.lstat()
        if (old.st_uid, old.st_gid) != (new.st_uid, new.st_gid):
            os.chown(destination, old.st_uid, old.st_gid, follow_symlinks=False)


def copy_file(source, destination):
    source, destination = Path(source), Path(destination)
    shutil.copy2(source, destination, follow_symlinks=False)
    preserve_owner(source, destination)


def copy_path(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir() and not source.is_symlink():
        shutil.copytree(source, destination, symlinks=True, copy_function=copy_file)
        for directory, _, _ in os.walk(source, followlinks=False):
            old = Path(directory)
            preserve_owner(old, destination / old.relative_to(source))
    else:
        copy_file(source, destination)


def minimal_paths(paths):
    result = []
    for path in sorted(set(paths), key=lambda item: (len(item.parts), str(item))):
        if not any(path == parent or parent in path.parents for parent in result):
            result.append(path)
    return result


def restore_paths(old, staged, paths):
    """Replace only validated paths inside the new staging tree."""
    require(old != staged and old not in staged.parents and staged not in old.parents,
            "Old and staged directories must be separate")
    require(old.is_absolute() and staged.is_absolute() and staged == staged.resolve(),
            "Restoration requires a resolved absolute staging directory")
    for relative in minimal_paths(paths):
        require(not relative.is_absolute() and relative.parts and ".." not in relative.parts,
                "Invalid preserved path: " + str(relative))
        source, destination = old / relative, staged / relative
        if not source.exists() and not source.is_symlink():
            continue
        resolved_parent = destination.parent.resolve()
        require(resolved_parent == staged or staged in resolved_parent.parents,
                "Restoration destination escapes staging: " + str(destination))
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination)
        elif destination.exists() or destination.is_symlink():
            destination.unlink()
        copy_path(source, destination)


def exchange_directories(root, staged, previous):
    """Remove all old program files from the live path without deleting the recovery copy."""
    require(root.is_absolute() and staged.is_absolute() and previous.is_absolute(),
            "Directory replacement requires absolute paths")
    require(root != root.parent and not root.is_symlink(), "Unsafe deployment directory")
    require(root not in staged.parents and root not in previous.parents,
            "Staging and backup must be outside the deployment")
    require(root != staged and root != previous and staged != previous, "Replacement paths overlap")
    require(staged not in previous.parents and previous not in staged.parents,
            "Staging and recovery paths must not contain each other")
    require(staged not in root.parents and previous not in root.parents,
            "Replacement paths must not contain the deployment")
    require(not previous.exists() and not previous.is_symlink(), "Previous backup already exists")
    require(staged.is_dir() and not staged.is_symlink(), "Invalid staged deployment")
    require(root == root.resolve() and staged == staged.resolve()
            and previous.parent == previous.parent.resolve(), "Replacement paths must be resolved")
    root.rename(previous)
    try:
        staged.rename(root)
    except BaseException:
        previous.rename(root)
        raise


def write_manifest(backup, manifest, state):
    manifest["state"] = state
    temporary = backup / "manifest.tmp"
    temporary.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(backup / "manifest.json")


def create_and_start(root, project, runtime_files, backup, before_start):
    base = compose(root, project)
    run(base + ["up", "--no-start", "--no-deps", "--no-build", "--pull", "never",
                "--force-recreate", SERVICE], root)
    ids = run(base + ["ps", "-a", "-q", SERVICE], root, True).splitlines()
    require(len(ids) == 1, "Expected exactly one recreated server container")
    for item in runtime_files:
        run(["docker", "cp", "-a", str(backup / item["backup"]),
             ids[0] + ":" + item["path"]], root)
    before_start()
    run(base + ["up", "-d", "--no-deps", "--no-build", "--pull", "never",
                "--wait", "--wait-timeout", str(WAIT_SECONDS), SERVICE], root)


def main(root, script):
    require(sys.platform.startswith("linux"), "Run this installer on the Linux deployment server")
    import fcntl

    def interrupted(signum, frame):
        raise KeyboardInterrupt("Upgrade interrupted by signal " + str(signum))

    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    root = root.resolve()
    require(root != root.parent and root != Path.home().resolve(), "Unsafe deployment directory")
    require(script.parent.resolve() == root, "Place the script in the deployment directory")
    for name in ("compose.yaml", "deployment.env"):
        require((root / name).is_file() and not (root / name).is_symlink(), "Missing regular configuration file: " + name)
    archives = sorted(path for path in root.iterdir()
                      if path.is_file() and (path.name.endswith(".tar.gz") or path.name == "upgrade.zip"))
    require(len(archives) == 1, "Upload exactly one project-name.tar.gz (or legacy upgrade.zip) beside the script")
    archive = archives[0]
    require(not archive.is_symlink(), "The uploaded archive must not be a symlink")
    require(shutil.which("docker"), "docker is not installed")

    workspace = root.parent / ("." + root.name + "-upgrades")
    require(not workspace.is_symlink(), "Backup directory must not be a symlink")
    workspace.mkdir(mode=0o700, exist_ok=True)
    require(workspace.stat().st_uid == os.geteuid(), "Backup directory belongs to another user")
    workspace.chmod(0o700)
    lock_fd = os.open(workspace / "upgrade.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another upgrade is already running")
        install(root, script, archive, workspace)


def install(root, script, archive, workspace):
    endpoint = os.environ.get("DOCKER_HOST") or run(
        ["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], root, True)
    require(endpoint.startswith("unix://"), "A local Unix-socket Docker daemon is required")
    run(["docker", "info"], root, True)
    require("--wait-timeout" in run(["docker", "compose", "up", "--help"], root, True),
            "Update Docker Compose v2 to support --wait-timeout")
    require("--no-env-resolution" in run(["docker", "compose", "config", "--help"], root, True),
            "Update Docker Compose v2 to support --no-env-resolution")
    base = compose(root)
    config = json.loads(run(base + ["config", "--format", "json"], root, True))
    services = config.get("services", {})
    require(set(services) == {SERVICE}, "Full replacement supports the confirmed single server service only")
    service = services[SERVICE]
    build = service.get("build")
    require(isinstance(build, dict) and build.get("context"), "server must use a local build context")
    require(not build.get("additional_contexts"), "Additional build contexts need an explicit migration plan")
    project = config["name"]
    base = compose(root, project)
    ids = run(base + ["ps", "-a", "-q", SERVICE], root, True).splitlines()
    require(len(ids) == 1, "Expected exactly one existing server container")
    container = json.loads(run(["docker", "inspect", ids[0]], root, True))[0]
    require(container["State"]["Running"], "Start the existing server before upgrading so runtime configuration can be inspected")
    require(container["Config"]["Labels"].get("com.docker.compose.project") == project,
            "Compose project does not match the running container")
    image_refs = run(base + ["config", "--images", SERVICE], root, True).splitlines()
    require(len(image_refs) == 1 and "@" not in image_refs[0] and not image_refs[0].startswith("sha256:"),
            "Expected one mutable local build image reference")
    image_ref, old_image = image_refs[0], container["Image"]
    require(container["Config"]["Image"] == image_ref, "Configured image does not match the running server")

    context_relative = relative_inside(build["context"], root, allow_root=True)
    require(context_relative is not None, "Build context must be inside the deployment")
    dockerfile_relative = None
    if not build.get("dockerfile_inline"):
        dockerfile = Path(build.get("dockerfile", "Dockerfile"))
        dockerfile = dockerfile if dockerfile.is_absolute() else root / context_relative / dockerfile
        dockerfile_relative = relative_inside(dockerfile, root)
        require(dockerfile_relative is not None and dockerfile.is_file(), "Build recipe must be a local file")

    preserved = [Path("compose.yaml"), Path("deployment.env"), Path(script.name)]
    if dockerfile_relative:
        preserved.append(dockerfile_relative)
    for name in (".env", "nbkj-nginx"):
        if (root / name).exists():
            preserved.append(Path(name))
    unresolved = json.loads(run(base + ["config", "--no-env-resolution", "--format", "json"], root, True))
    referenced = []
    for item in unresolved["services"][SERVICE].get("env_file", []):
        referenced.append(item["path"] if isinstance(item, dict) else item)
    for category in ("secrets", "configs"):
        for item in config.get(category, {}).values():
            if item.get("file"):
                referenced.append(item["file"])
    for mount in service.get("volumes", []):
        if mount.get("type") == "bind":
            referenced.append(mount["source"])
    for path in referenced:
        relative = relative_inside(path, root)
        if relative is not None:
            preserved.append(relative)
    preserved = minimal_paths(preserved)
    require(not any(path == context_relative or path in context_relative.parents for path in preserved),
            "A preserved mount contains the build context; this layout cannot be replaced automatically")

    runtime_query = (
        "import json,os,pathlib;"
        "p=pathlib.Path(os.environ.get('ENV_FILE') or '.env').resolve();"
        "d=pathlib.Path(os.environ.get('DATABASE_PATH') or 'data/stock_analysis.db').resolve().parent;"
        "print(json.dumps({'path':str(p),'exists':p.is_file(),'data_directory':str(d)}))"
    )
    runtime = json.loads(run(["docker", "exec", ids[0], "python", "-c", runtime_query], root, True))
    mounts = container.get("Mounts", [])
    require(all(item["Type"] in ("bind", "volume") or not item.get("RW") for item in mounts),
            "Writable ephemeral mounts cannot be backed up automatically")
    require(any(
        runtime["data_directory"] == item["Destination"]
        or runtime["data_directory"].startswith(item["Destination"].rstrip("/") + "/")
        for item in mounts if item["Type"] in ("bind", "volume")
    ), "Persist DATABASE_PATH in a bind mount or Docker volume before replacing the deployment")
    if runtime["exists"]:
        runtime["mounted"] = any(
            runtime["path"] == item["Destination"]
            or runtime["path"].startswith(item["Destination"].rstrip("/") + "/")
            for item in mounts
        )
        if not runtime["mounted"]:
            require(str(PurePosixPath(runtime["path"]).parent) in
                    (container["Config"].get("WorkingDir") or "/", "/"),
                    "Persist ENV_FILE in a volume when it is outside the container working directory")

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    backup = workspace / stamp
    backup.mkdir(mode=0o700)
    print("Deployment:", root, flush=True)
    print("Backup:", backup, flush=True)
    digest = hashlib.sha256()
    with archive.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    manifest = {
        "deployment": str(root), "archive": archive.name, "archive_sha256": digest.hexdigest(),
        "project": project, "image_reference": image_ref, "previous_image_id": old_image,
        "preserved": [str(path) for path in preserved], "external_mounts": [], "runtime_files": [],
    }
    write_manifest(backup, manifest, "validating-package")
    extracted = backup / "extracted"
    extract_archive(archive, extracted)
    staged = find_package_root(extracted, context_relative)
    require(not any(path.name.endswith(".tar.gz") or path.name == "upgrade.zip" for path in staged.iterdir()),
            "The new package must not contain another upgrade archive")
    configuration = [Path("compose.yaml"), Path("deployment.env"), Path(script.name)]
    if dockerfile_relative:
        configuration.append(dockerfile_relative)
    for relative in configuration:
        copy_path(root / relative, backup / "configuration" / relative)
    restore_paths(root, staged, configuration)
    staged.chmod(stat.S_IMODE(root.stat().st_mode))
    preserve_owner(root, staged)
    stage_build = dict(build)
    stage_build["context"] = str(staged / context_relative)
    if dockerfile_relative:
        stage_build["dockerfile"] = str(staged / dockerfile_relative)
    build_image = "dsa-local-upgrade:" + stamp.lower()
    override = backup / "build.override.json"
    override.write_text(json.dumps({"services": {SERVICE: {"build": stage_build, "image": build_image}}}), encoding="utf-8")
    manifest["built_image"] = build_image
    write_manifest(backup, manifest, "building")
    print("Building the new package; the existing server remains running.", flush=True)
    run(compose(root, project, override) + ["build", "--pull", SERVICE], root)

    stopped = False
    switched = False
    startup_attempted = False
    previous = backup / "previous"
    try:
        write_manifest(backup, manifest, "stopping")
        stopped = True
        run(base + ["stop", SERVICE], root)
        write_manifest(backup, manifest, "snapshotting")
        restore_paths(root, staged, preserved)
        for index, mount in enumerate(mounts):
            source = mount.get("Source", "")
            if mount["Type"] == "bind" and relative_inside(source, root) is not None:
                continue
            if mount["Type"] not in ("bind", "volume"):
                require(not mount.get("RW"), "Writable ephemeral mounts cannot be backed up automatically")
                continue
            snapshot = "external-mounts/" + str(index)
            (backup / "external-mounts").mkdir(exist_ok=True)
            run(["docker", "cp", "-a", ids[0] + ":" + mount["Destination"], str(backup / snapshot)], root)
            manifest["external_mounts"].append({
                "type": mount["Type"], "source": source, "destination": mount["Destination"],
                "writable": mount.get("RW", False), "backup": snapshot,
            })
            write_manifest(backup, manifest, "snapshotting")
        if runtime["exists"] and not runtime["mounted"]:
            snapshot = "runtime.env"
            run(["docker", "cp", "-a", ids[0] + ":" + runtime["path"], str(backup / snapshot)], root)
            manifest["runtime_files"].append({"path": runtime["path"], "backup": snapshot})
        write_manifest(backup, manifest, "switching")
        exchange_directories(root, staged, previous)
        switched = True
        run(["docker", "image", "tag", build_image, image_ref], root)

        def mark_starting():
            nonlocal startup_attempted
            startup_attempted = True
            write_manifest(backup, manifest, "starting-new-server")

        create_and_start(root, project, manifest["runtime_files"], backup, mark_starting)
        run(base + ["ps", SERVICE], root)
        write_manifest(backup, manifest, "completed")
        print("Upgrade complete. Verify Web/API and nginx access.", flush=True)
        print("Full previous deployment and volume snapshots retained at:", backup, flush=True)
    except BaseException:
        if not startup_attempted:
            print("New application has not started; restoring the old deployment.", file=sys.stderr, flush=True)
            try:
                if switched:
                    root.rename(backup / "failed-release")
                    previous.rename(root)
                    run(["docker", "image", "tag", old_image, image_ref], root)
                    create_and_start(root, project, manifest["runtime_files"], backup, lambda: None)
                elif stopped:
                    run(["docker", "start", ids[0]], root)
                write_manifest(backup, manifest, "failed-old-service-restored")
            except BaseException as rollback_error:
                write_manifest(backup, manifest, "failed-restore-needs-attention")
                print("Automatic pre-start restoration failed:", rollback_error, file=sys.stderr)
        else:
            write_manifest(backup, manifest, "failed-after-start")
            print("New code may have written data. No automatic downgrade was attempted.", file=sys.stderr)
        print("Recovery manifest and snapshots:", backup, file=sys.stderr, flush=True)
        raise


if __name__ == "__main__":
    try:
        main(Path(sys.argv[1]), Path(sys.argv[2]))
    except (Exception, KeyboardInterrupt) as error:
        print("ERROR:", error, file=sys.stderr)
        sys.exit(1)
PYTHON
