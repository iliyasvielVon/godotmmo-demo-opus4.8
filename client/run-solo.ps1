# Launch Star Glory in SINGLE-PLAYER mode (no server, no login) for quick local testing.
# Usage:   .\run-solo.ps1 [-Load] [-Godot "C:\path\to\Godot_v4.6-stable_win64.exe"]
#   -Load : load the existing local save instead of starting a new game.
# NOTE: ASCII-only on purpose (Windows PowerShell 5.1 reads .ps1 with the system ANSI codepage).
param(
	[switch]$Load,
	[string]$Godot = $env:GODOT
)
$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
if (-not $Godot -or $Godot -eq "") {
	$cmd = Get-Command godot -ErrorAction SilentlyContinue
	if ($cmd) { $Godot = $cmd.Source } else {
		throw "Godot not found. Pass -Godot, e.g.: .\run-solo.ps1 -Godot 'C:\Godot\Godot_v4.6-stable_win64.exe'"
	}
}

# Ensure res://shared exists (GameData autoload reads it).
$sync = Join-Path $here "..\tools\sync-shared.ps1"
if (Test-Path $sync) { & $sync }

$flag = if ($Load) { "--solo-load" } else { "--solo" }
Write-Host "Launching single-player ($flag) -- no server needed."
& $Godot --path $here -- $flag
