# Start the Star Glory MMO server (Windows 11 / PowerShell).
# Usage:   .\run-server.ps1 [-Port 9000] [-Godot "C:\path\to\Godot_v4.6-stable_win64.exe"]
# NOTE: ASCII-only on purpose (Windows PowerShell 5.1 reads .ps1 with the system ANSI codepage).
param(
	[int]$Port = 9000,
	[string]$Godot = $env:GODOT
)
$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
if (-not $Godot -or $Godot -eq "") {
	$cmd = Get-Command godot -ErrorAction SilentlyContinue
	if ($cmd) { $Godot = $cmd.Source } else {
		throw "Godot not found. Pass -Godot, e.g.: .\run-server.ps1 -Godot 'C:\Godot\Godot_v4.6-stable_win64.exe'"
	}
}

# Free the UDP port if a previous server instance still holds it.
# This ONLY stops whichever process owns this exact port (the old server) --
# other Godot editors/projects do not own it and are left untouched.
try {
	$owners = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue |
		Select-Object -ExpandProperty OwningProcess -Unique
	foreach ($ownerPid in $owners) {
		if ($ownerPid -and $ownerPid -ne $PID) {
			$proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
			if ($proc) {
				Write-Host "Port $Port is held by PID $ownerPid ($($proc.ProcessName)); stopping it..."
				Stop-Process -Id $ownerPid -Force
				Start-Sleep -Milliseconds 500
			}
		}
	}
} catch {
	Write-Host "Note: could not auto-check port $Port ($($_.Exception.Message)). Continuing..."
}

# Sync shared/ first
$sync = Join-Path $here "..\tools\sync-shared.ps1"
if (Test-Path $sync) { & $sync }

Write-Host "Starting server on port $Port"
& $Godot --headless --path $here -- --server --port $Port
