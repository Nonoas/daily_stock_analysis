@echo off
setlocal DisableDelayedExpansion
set "IMAGE_PYTHON="
if exist "%~dp0..\.venv\Scripts\python.exe" set "IMAGE_PYTHON=%~dp0..\.venv\Scripts\python.exe"
if defined IMAGE_PYTHON goto run
if exist "%~dp0..\venv\Scripts\python.exe" set "IMAGE_PYTHON=%~dp0..\venv\Scripts\python.exe"
if defined IMAGE_PYTHON goto run
echo ERROR: Create a project .venv or venv with Python 3.10 or later first.
pause
exit /b 1

:run
set "PYTHONUTF8=1"
"%IMAGE_PYTHON%" -I -c "import pathlib,sys; p=pathlib.Path(sys.argv[1]); code=p.read_text(encoding='utf-8').split('\n# BEGIN_IMAGE_PYTHON\n',1)[1]; exec(compile(code,str(p),'exec'))" "%~f0" "%~dp0.." %*
set "IMAGE_EXIT=%ERRORLEVEL%"
pause
exit /b %IMAGE_EXIT%

# BEGIN_IMAGE_PYTHON
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile


def main():
    parser = argparse.ArgumentParser(description="Build and export a Linux Docker image for offline deployment.")
    parser.add_argument("root", type=Path)
    parser.add_argument("platform", nargs="?", default="linux/amd64", choices=["linux/amd64", "linux/arm64"])
    args = parser.parse_args(sys.argv[2:])
    root = args.root.resolve()
    docker = shutil.which("docker")
    if not docker:
        raise RuntimeError("Docker CLI not found. Install/start Docker Desktop with Linux containers.")
    subprocess.run([docker, "info"], check=True, stdout=subprocess.DEVNULL)
    image = "daily_stock_analysis:latest"
    subprocess.run([
        docker, "build", "--platform", args.platform, "-f", str(root / "docker/Dockerfile"),
        "-t", image, str(root),
    ], check=True)
    info = json.loads(subprocess.check_output([docker, "image", "inspect", image]))[0]
    actual = info["Os"] + "/" + info["Architecture"]
    if actual != args.platform:
        raise RuntimeError("Image platform mismatch: " + actual)
    output = root / "dist/docker-image"
    if output.is_symlink() or output.parent.is_symlink() or not output.resolve().is_relative_to(root):
        raise RuntimeError("Output directory must remain inside the repository")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / "image.tar.partial"
    subprocess.run([docker, "save", "--output", str(archive), image], check=True)
    with tarfile.open(archive, "r:*") as package:
        entries = json.load(package.extractfile("manifest.json"))
        matches = [entry for entry in entries if image in entry.get("RepoTags", [])]
        if len(matches) != 1:
            raise RuntimeError("Export must contain exactly one image with the build tag")
        config_bytes = package.extractfile(matches[0]["Config"]).read()
        portable_id = "sha256:" + hashlib.sha256(config_bytes).hexdigest()
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else None
        if digest is None:
            checksum = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                checksum.update(block)
            digest = checksum.hexdigest()
    archive.replace(output / "image.tar")
    # Always deliver the updater with LF endings, even when packaging on Windows.
    updater = (root / "scripts/update-image.sh").read_bytes().replace(b"\r\n", b"\n")
    (output / "update-image.sh").write_bytes(updater)
    compose = (root / "docker/docker-compose.yml").read_bytes().replace(b"\r\n", b"\n")
    (output / "compose.template.yml").write_bytes(compose)
    metadata = output / "image.json.partial"
    metadata.write_text(json.dumps({
        "format": 2, "image": image, "image_id": portable_id, "platform": actual, "sha256": digest,
        "compose_sha256": hashlib.sha256(compose).hexdigest(),
    }, indent=2) + "\n", encoding="utf-8")
    metadata.replace(output / "image.json")
    print("\nPackage ready:", output)
    print("Upload image.tar, image.json, compose.template.yml and update-image.sh to the deployment directory.")
    print("The template is copied from the repository docker/docker-compose.yml; do not edit the exported copy.")
    print("Then run: bash update-image.sh")


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print("ERROR:", error, file=sys.stderr)
        sys.exit(1)
