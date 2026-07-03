# Star Glory MMO

Godot 4.6 multiplayer action RPG prototype with a shared client/server codebase.

This repository contains the source project only. Local exports, Godot caches,
save files, signing keys, and server secrets are intentionally ignored.

## Project Layout

```text
starworldmmo/
  client/   Godot client project: rendering, input, UI, skills, local feedback
  server/   Godot headless authoritative server: accounts, saves, monsters, AOI
  shared/   Shared data source: monsters, skills, world data, protocol constants
  tools/    Sync and deployment helper scripts
  docs/     Change notes and operation docs
```

`client/shared/` and `server/shared/` are synced copies of `shared/`.
After changing anything under `shared/`, run the sync script before building or
running either project.

## Requirements

- Godot 4.6
- Windows PowerShell or a POSIX shell
- UDP port `9000` open for multiplayer traffic

## Quick Start

### 1. Sync Shared Data

Windows:

```powershell
.\tools\sync-shared.ps1
```

Linux/macOS:

```bash
bash tools/sync-shared.sh
```

### 2. Start Server

Windows:

```powershell
cd server
.\run-server.ps1 -Port 9000 -Godot "C:\Godot\Godot_v4.6-stable_win64.exe"
```

Linux:

```bash
cd server
chmod +x run-server.sh
./run-server.sh 9000
```

You should see a log similar to:

```text
[Net] 服务器已监听端口 9000
```

### 3. Start Client

Open `client/project.godot` in Godot 4.6 and run the project.

For local testing, connect to:

```text
Host: 127.0.0.1
Port: 9000
```

Use two different accounts in two client instances to test multiplayer.

## Server Config

Do not commit `server/server.cfg`; it may contain passwords, tokens, and local
paths. It is ignored by Git.

Create it from the template:

```powershell
Copy-Item server\server.example.cfg server\server.cfg
```

or:

```bash
cp server/server.example.cfg server/server.cfg
```

Then edit local secrets:

```ini
super_admin_user="huaqadmin"
super_admin_password="your-local-password"
super_admin_level=3
admin_api_token="your-local-admin-token"
```

The committed template keeps password and token fields empty.

## GM Admin

The fixed highest GM account is configured by `server.cfg`:

```ini
super_admin_user="huaqadmin"
super_admin_level=3
```

When `super_admin_password` is set locally, the server creates or resets that
account on startup and restores GM level 3.

GM panel features:

- View players by id, account, name, level, equipment tier, online state, HP,
  and instance id.
- Edit selected player name, level, and equipment tier.
- Apply selected-player effects: full status, +10 levels, max skills, god mode,
  and speed x2.
- L1 can view player lists.
- L2 can edit and apply player effects.
- L3 can adjust monster strength and drop rate.

## Important Gameplay Changes

- Protocol version is `31`.
- Monster sync uses AOI so clients receive only visible-range monsters.
- Meteor and Fire Rain aiming markers use circular ground projection.
- GM level edits recalculate base growth stats.
- 2048 boots speed uses diminishing returns instead of raw exponential scaling.
- Server/client RPC method sets must stay aligned.

## Verification

Run these checks before pushing changes:

```powershell
godot --headless --no-header --path client --quit-after 2
godot --headless --no-header --path server --quit-after 2
```

RPC method set check:

```powershell
$client = Select-String -Path client\scripts\net\NetworkClient.gd -Pattern 'func (req_|rpc_)\w+' -AllMatches | ForEach-Object { $_.Matches.Value -replace '^func ', '' } | Sort-Object -Unique
$server = Select-String -Path server\net\ServerNetwork.gd -Pattern 'func (req_|rpc_)\w+' -AllMatches | ForEach-Object { $_.Matches.Value -replace '^func ', '' } | Sort-Object -Unique
Compare-Object $client $server
```

No output from `Compare-Object` means the method sets match.

## Deployment Notes

The `tools/deploy_server.py` helper can sync and deploy the headless server to a
remote Linux host. See `server/README.md` and `docs/GM_ADMIN_SYNC_NOTES.md` for
additional notes.

## Repository Hygiene

Ignored by design:

- `server/server.cfg`
- Godot `.godot/` caches
- Android build intermediates
- exported `.exe`, `.apk`, `.pck`
- signing keys
- local save files
- large local reference media

Keep secrets out of commits. Use `server/server.example.cfg` for shared defaults.
