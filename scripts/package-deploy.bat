@echo off
setlocal DisableDelayedExpansion
if not "%~1"=="" goto usage
set "PACKAGE_PYTHON="
set "PACKAGE_PYTHON_ARGS="
if exist "%~dp0..\.venv\Scripts\python.exe" (
    set "PACKAGE_PYTHON=%~dp0..\.venv\Scripts\python.exe"
    goto run
)
if exist "%~dp0..\venv\Scripts\python.exe" (
    set "PACKAGE_PYTHON=%~dp0..\venv\Scripts\python.exe"
    goto run
)
py -3 -c "import sys; sys.exit(sys.version_info < (3, 8))" >nul 2>&1
if not errorlevel 1 (
    set "PACKAGE_PYTHON=py"
    set "PACKAGE_PYTHON_ARGS=-3"
    goto run
)
python -c "import sys; sys.exit(sys.version_info < (3, 8))" >nul 2>&1
if not errorlevel 1 (
    set "PACKAGE_PYTHON=python"
    goto run
)
echo ERROR: Python 3.8 or later is required. Activate the project environment or install Python.
pause
exit /b 1

:usage
echo No arguments are needed. Double-click package-deploy.bat.
pause
exit /b 1

:run
"%PACKAGE_PYTHON%" %PACKAGE_PYTHON_ARGS% -I -c "import pathlib,sys; p=pathlib.Path(sys.argv[1]); s=p.read_text(encoding='utf-8'); code=s.split('\n# BEGIN_PACKAGE_PYTHON\n',1)[1]; exec(compile(code,str(p),'exec'))" "%~f0" "%~dp0.."
set "PACKAGE_EXIT_CODE=%ERRORLEVEL%"
echo.
pause
exit /b %PACKAGE_EXIT_CODE%

# BEGIN_PACKAGE_PYTHON
import fnmatch
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile
import tempfile


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def include(relative):
    parts = relative.parts
    leaf = parts[-1]
    if parts[0] in {
        ".git", ".github", ".agents", ".claude", ".codex", ".aws", ".tmp",
        ".reviews", "data", "logs", "reports", "longbridge_tokens", "dist", "build", "static",
    }:
        return False
    if any(part in {
        "node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache",
        ".ruff_cache", ".cache",
    } for part in parts):
        return False
    if leaf == "CLAUDE.md":
        return False
    if leaf != ".env.example" and (leaf == ".env" or leaf.startswith(".env.") or leaf.endswith(".env")):
        return False
    if re.search(r"\.(pyc|pyo|log|db|sqlite|sqlite3)(-|$)", leaf):
        return False
    if leaf in {".admin_password_hash", ".session_secret", ".llm_usage_hmac_secret"}:
        return False
    return not (fnmatch.fnmatch(leaf, "litellm_config*.yaml") or fnmatch.fnmatch(leaf, "litellm_config*.yml"))


def validate_file(root, relative):
    if relative.is_absolute() or not relative.parts or ".." in relative.parts:
        raise RuntimeError("Invalid source path: " + str(relative))
    source = root / relative
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink() or (
            current.exists()
            and getattr(current.lstat(), "st_file_attributes", 0)
            & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
        ):
            raise RuntimeError("Links cannot be packaged: " + str(relative))
    source.resolve().relative_to(root)
    if not source.exists():
        return None  # A tracked file deleted in the working tree stays deleted.
    if not source.is_file():
        raise RuntimeError("Expected a regular source file: " + str(relative))
    return source


def main(root):
    root = root.resolve()
    remote = git(root, "remote", "get-url", "origin").decode("utf-8").strip().rstrip("/")
    project = re.split(r"[/\\:]", remote)[-1]
    project = re.sub(r"\.git$", "", project)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", project):
        raise RuntimeError("Cannot determine a valid project name from Git origin")
    names = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
    selected = {}
    for name in names:
        if not name:
            continue
        relative = Path(name.decode("utf-8"))
        if include(relative):
            source = validate_file(root, relative)
            if source is not None:
                selected[relative] = source
    for required in ("main.py", "requirements.txt", "docker/Dockerfile", "scripts/upgrade-docker.sh"):
        if Path(required) not in selected:
            raise RuntimeError("Missing required source file: " + required)
    output_dir = root / "dist"
    output_dir.mkdir(exist_ok=True)
    if output_dir.is_symlink() or output_dir.resolve() != root / "dist":
        raise RuntimeError("Output directory must not redirect outside the repository")
    archive = output_dir / (project + ".tar.gz")
    descriptor, temporary_name = tempfile.mkstemp(prefix="." + project + "-", suffix=".partial", dir=output_dir)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            # Store file contents, including hard-linked files, so the installer never receives links.
            with tarfile.open(fileobj=output, mode="w:gz", dereference=True) as package:
                for relative, source in sorted(selected.items()):
                    package.add(source, arcname=project + "/source/" + relative.as_posix(), recursive=False)
                package.add(selected[Path("scripts/upgrade-docker.sh")],
                            arcname=project + "/upgrade-docker.sh", recursive=False)
        temporary.replace(archive)
    finally:
        if temporary.exists():
            temporary.unlink()
    print("Package created:", archive)
    print("Source files:", len(selected))
    print("Upload this archive beside compose.yaml and deployment.env; do not extract it first.")
    print("Run the current upgrade-docker.sh on the server without arguments.")


if __name__ == "__main__":
    try:
        main(Path(sys.argv[2]))
    except (Exception, KeyboardInterrupt) as error:
        print("ERROR:", error, file=sys.stderr)
        sys.exit(1)
