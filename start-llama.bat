@echo off
REM ============================================================
REM  start-llama.bat -- portable pack launcher
REM  llama.cpp router server: one port, two models on demand.
REM    qwen3.5-9b    text   -> DeepSeek Harness
REM    qwen3-vl-4b   vision -> modlens (mmproj)
REM
REM  Path-independent: models.ini is regenerated from
REM  models.ini.template using this folder's own location, so the
REM  pack works wherever you unzip it.
REM  Port and API key live in config.bat (auto-created on run 1).
REM ============================================================
setlocal EnableExtensions
set "PACK=%~dp0"
set "PACK=%PACK:~0,-1%"
cd /d "%PACK%" || (
  echo REFUSE: cannot enter "%PACK%"
  pause
  exit /b 6
)
set "BIN=%PACK%\engine"
set "TPL=%PACK%\models.ini.template"
set "INI=%PACK%\models.ini"
set "MODEL=%PACK%\models\Qwen3.5-9B-Q4_K_M.gguf"
set "VMODEL=%PACK%\models\Qwen3-VL-4B-Instruct\Qwen3VL-4B-Instruct-Q4_K_M.gguf"
set "VPROJ=%PACK%\models\Qwen3-VL-4B-Instruct\mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf"

if not exist "%BIN%\llama-server.exe" (
  echo REFUSE: llama-server.exe not found in "%BIN%"
  pause
  exit /b 4
)
if not exist "%TPL%" (
  echo REFUSE: models.ini.template not found "%TPL%"
  pause
  exit /b 3
)
if not exist "%MODEL%" (
  echo REFUSE: text model not found "%MODEL%"
  pause
  exit /b 3
)
if not exist "%VMODEL%" (
  echo REFUSE: vision model not found "%VMODEL%"
  pause
  exit /b 3
)
if not exist "%VPROJ%" (
  echo REFUSE: mmproj not found "%VPROJ%"
  echo   Without mmproj the vision model cannot read images.
  pause
  exit /b 3
)

REM ---- first run creates config.bat with a random key ----
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PACK%\scripts\ensure-config.ps1" -Root "%PACK%"

REM ---- regenerate models.ini for this location ----
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PACK%\scripts\render-ini.ps1" -Root "%PACK%"
if errorlevel 1 (
  echo REFUSE: could not render models.ini
  pause
  exit /b 5
)

if exist "%PACK%\config.bat" call "%PACK%\config.bat"
if not defined PORT set PORT=2210
set "KEYARG="
if defined API_KEY set "KEYARG=--api-key %API_KEY%"

setlocal EnableDelayedExpansion
netstat -ano | findstr ":!PORT! " | findstr "LISTENING" >nul 2>nul
if not errorlevel 1 (
  echo [ALREADY RUNNING] port !PORT! is busy. Close that server first.
  pause
  exit /b 4
)

if defined API_KEY (
  echo [auth] API key ENABLED - clients must send it as bearer token
) else (
  echo [auth] no API key - anyone on this machine can call the API
)
echo [router] http://127.0.0.1:%PORT%/v1
echo [router] models: qwen3.5-9b ^(text^)  qwen3-vl-4b ^(vision^)
echo [router] nothing loads until the first request - 0 MiB VRAM is normal.
"!BIN!\llama-server.exe" ^
  --host 127.0.0.1 --port !PORT! ^
  !KEYARG! ^
  --models-preset "!INI!" ^
  --models-max 1 ^
  --models-memory-margin 256 ^
  --no-webui
endlocal

echo [engine exited] errorlevel=%ERRORLEVEL%
pause
