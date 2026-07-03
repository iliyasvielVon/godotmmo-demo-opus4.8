# GM Admin And Sync Notes

This document records the synced client/server changes for the current Star Glory MMO build.

## Git Scope

Commit only project sources and lightweight documentation:

- `client/`
- `server/`
- `shared/`
- `tools/`
- `docs/`
- root `.gitignore`

Do not commit local exports, Android build intermediates, Godot caches, signing keys, saves, videos, archives, or `server/server.cfg`.

## Server Config

`server/server.cfg` is local-only because it can contain:

- `super_admin_password`
- `admin_api_token`
- local data paths

Use `server/server.example.cfg` as the template:

1. Copy `server/server.example.cfg` to `server/server.cfg`.
2. Fill the local GM password and admin API token.
3. Restart the server.

The fixed highest GM account is configured as:

```ini
super_admin_user="huaqadmin"
super_admin_level=3
```

The password is intentionally not committed.

## Implemented Gameplay/Admin Changes

- Added a GM player management panel.
- GM can view player id, account, name, online state, level, equipment tier, HP, and instance id.
- GM L1 can view player lists.
- GM L2 can edit selected player name, level, and equipment tier.
- GM L2 can apply selected-player effects: full status, +10 levels, max skills, god mode toggle, and speed x2 toggle.
- Level edits now recalculate base growth stats instead of changing only the level number.
- Max skills and level changes persist to server saves.
- Online targets receive immediate RPC updates.
- Offline targets can receive persistent save edits; instant effects require the target to be online.
- Protocol version is `31` across client/server/shared copies.

## Balance Changes

Boots speed from 2048 equipment no longer scales with the raw exponential multiplier.
Speed now uses a diminishing-return curve so high tiers still improve movement but do not explode at the same rate as damage or defense stats.

## Verification

Run these checks after a fresh sync:

```powershell
godot --headless --no-header --path client --quit-after 2
godot --headless --no-header --path server --quit-after 2
```

Also compare client/server RPC method sets after adding or removing network methods.
