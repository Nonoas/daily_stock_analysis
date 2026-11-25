@echo off
setlocal DisableDelayedExpansion
if not "%~1"=="" goto usage
pushd "%~dp0.."
if errorlevel 1 exit /b 1

set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "LOCAL_PYTHON="
if exist ".venv\Scripts\python.exe" set "LOCAL_PYTHON=.venv\Scripts\python.exe"
if defined LOCAL_PYTHON goto prepare
if exist "venv\Scripts\python.exe" set "LOCAL_PYTHON=venv\Scripts\python.exe"
if defined LOCAL_PYTHON goto prepare

echo ERROR: No project Python environment found.
echo Run these commands from the repository root first:
echo   py -3 -m venv .venv
echo   .venv\Scripts\python.exe -m pip install -r requirements.txt
goto failed

:prepare
echo [1/2] Checking Python dependencies and preparing the Web UI...
echo Frontend dependencies and assets are managed by src.webui_frontend.
"%LOCAL_PYTHON%" -c "import logging, sys; import fastapi, uvicorn; from src.config import setup_env; setup_env(); logging.basicConfig(level=logging.INFO); from src.webui_frontend import prepare_webui_frontend_assets; sys.exit(0 if prepare_webui_frontend_assets() else 1)"
if errorlevel 1 goto failed

echo [2/2] Starting the local server. Press Ctrl+C to stop.
echo Use the local URL printed below. The port follows your existing configuration.
"%LOCAL_PYTHON%" main.py --serve-only --host 127.0.0.1
if errorlevel 1 goto failed
popd
exit /b 0

:failed
echo.
echo ERROR: Local startup failed. See the error above.
echo For missing Python packages, run the project Python with: -m pip install -r requirements.txt
echo For frontend build errors, check Node.js/npm and the npm output above.
popd
pause
exit /b 1

:usage
echo Usage: start-local.cmd
echo No arguments are needed. Configuration is read from the existing .env file.
pause
exit /b 1
