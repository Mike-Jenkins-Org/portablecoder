@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "REPO_ROOT=%SCRIPT_DIR%.."
set "PORTABLE_NODE=%REPO_ROOT%\runtime\node\node.exe"

if not exist "%PORTABLE_NODE%" goto :try_system_node
:run_portable
"%PORTABLE_NODE%" "%SCRIPT_DIR%pcoder.cjs" %*
exit /b %errorlevel%

:try_system_node
where node >nul 2>nul
if not %errorlevel% equ 0 goto :auto_bootstrap
node "%SCRIPT_DIR%pcoder.cjs" %*
exit /b %errorlevel%

:auto_bootstrap
rem No Node anywhere. Download a portable one via PowerShell, then continue.
rem The guard stops a failed bootstrap from looping.
if defined PCODER_NODE_BOOTSTRAPPED goto :no_node
if "%PCODER_AUTO_BOOTSTRAP%"=="0" goto :no_node
set "PCODER_NODE_BOOTSTRAPPED=1"

rem Same resolution order as resolveWindowsShellTool() in pcoder.cjs, including
rem the absolute System32 fallback: `where` needs a sane PATH, and a broken PATH
rem is exactly the situation this branch exists to recover from.
set "PS_EXE="
if exist "%REPO_ROOT%\runtime\powershell\pwsh.exe" set "PS_EXE=%REPO_ROOT%\runtime\powershell\pwsh.exe"
if defined PS_EXE goto :have_ps
where pwsh >nul 2>nul && set "PS_EXE=pwsh"
if defined PS_EXE goto :have_ps
where powershell >nul 2>nul && set "PS_EXE=powershell"
if defined PS_EXE goto :have_ps
if not defined SystemRoot set "SystemRoot=C:\Windows"
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PS_EXE goto :no_node

:have_ps

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%runtime\bootstrap-node.ps1"
if not %errorlevel% equ 0 goto :bootstrap_failed
if not exist "%PORTABLE_NODE%" goto :bootstrap_failed
echo.
goto :run_portable

:bootstrap_failed
echo Error: automatic Node.js bootstrap failed.
echo Install Node.js (winget install OpenJS.NodeJS.LTS) and re-run, or copy a
echo bootstrapped runtime\node folder from another machine.
exit /b 1

:no_node
echo Error: node not found. Bundle runtime\node or install node in PATH.
echo Run: powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%runtime\bootstrap-node.ps1"
exit /b 1
