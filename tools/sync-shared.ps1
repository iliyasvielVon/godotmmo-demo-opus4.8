# sync-shared.ps1 -- copy repo-root shared/ into client/shared and server/shared.
# shared/ is the single source of truth for cross-side data; each Godot project keeps
# its own copy accessed via res://shared.
# Usage (Windows / PowerShell):   .\tools\sync-shared.ps1
# NOTE: kept ASCII-only on purpose. Windows PowerShell 5.1 reads .ps1 files using the
# system ANSI codepage, so non-ASCII (e.g. Chinese) here would be mojibake and break parsing.
$ErrorActionPreference = "Stop"

$root   = Split-Path -Parent $PSScriptRoot
$src    = Join-Path $root "shared"
$targets = @(
	(Join-Path $root "client\shared"),
	(Join-Path $root "server\shared")
)

if (-not (Test-Path $src)) { throw "Source folder not found: $src" }

foreach ($dst in $targets) {
	if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
	Copy-Item -Recurse -Force $src $dst
	Write-Host "synced shared -> $dst"
}
Write-Host "done."
