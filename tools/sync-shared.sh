#!/usr/bin/env bash
# sync-shared.sh —— 把仓库根的 shared/ 同步进 client/shared 和 server/shared。
# shared/ 是跨端数据的唯一数据源；两个 Godot 工程各保留一份副本，通过 res://shared 访问。
# 用法（Linux/macOS）：  ./tools/sync-shared.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/shared"

if [ ! -d "$SRC" ]; then
	echo "找不到源目录: $SRC" >&2
	exit 1
fi

for DST in "$ROOT/client/shared" "$ROOT/server/shared"; do
	rm -rf "$DST"
	cp -r "$SRC" "$DST"
	echo "已同步 shared -> $DST"
done
echo "完成。"
