#!/usr/bin/env bash
# 单机模式启动（无需服务器/登录），方便本地测试。
# 用法：  ./run-solo.sh [--load]   （--load 读取本地存档；默认开新档）
# 用环境变量 GODOT 指定 Godot 4.6 可执行文件路径。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT_BIN="${GODOT:-godot}"
FLAG="--solo"
if [ "${1:-}" = "--load" ]; then FLAG="--solo-load"; fi

# 保证 res://shared 存在（GameData autoload 需要）
if [ -f "$HERE/../tools/sync-shared.sh" ]; then
	bash "$HERE/../tools/sync-shared.sh"
fi

echo "启动单机模式（$FLAG），无需服务器。"
exec "$GODOT_BIN" --path "$HERE" -- "$FLAG"
