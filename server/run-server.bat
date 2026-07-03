@echo off
REM Start the Star Glory MMO server (Windows / cmd).
REM Usage:   run-server.bat [port]
REM Set env var GODOT to your Godot 4.6 executable, e.g.:
REM   set GODOT=C:\Godot\Godot_v4.6-stable_win64.exe
REM NOTE: ASCII-only on purpose (cmd uses the OEM codepage; non-ASCII would be mojibake).

setlocal
set PORT=%1
if "%PORT%"=="" set PORT=9000
if "%GODOT%"=="" set GODOT=godot

REM Free the UDP port: stop only the process that owns this exact port (the old server).
for /f "tokens=4" %%a in ('netstat -ano -p UDP ^| findstr ":%PORT% "') do taskkill /F /PID %%a >nul 2>&1

REM Sync shared/ (needs PowerShell)
powershell -ExecutionPolicy Bypass -File "%~dp0..\tools\sync-shared.ps1"

echo Starting server on port %PORT%
"%GODOT%" --headless --path "%~dp0" -- --server --port %PORT%
endlocal
