#!/usr/bin/env bash
# 启动 Star Glory MMO 服务器（Linux / Ubuntu 22.04 / 24.04）。
# 用法：  ./run-server.sh [端口]
# 需要 Godot 4.6（编辑器版或导出模板）。可用环境变量 GODOT 指定二进制路径：
#   GODOT=/opt/godot/godot ./run-server.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${1:-9000}"
GODOT_BIN="${GODOT:-godot}"

# 先同步 shared/（保证 res://shared 与仓库根一致）
if [ -f "$HERE/../tools/sync-shared.sh" ]; then
	bash "$HERE/../tools/sync-shared.sh"
fi

if ! command -v "$GODOT_BIN" >/dev/null 2>&1 && [ ! -x "$GODOT_BIN" ]; then
	echo "找不到 Godot 可执行文件 '$GODOT_BIN'。请安装 Godot 4.6，或用 GODOT=/路径/godot 指定。" >&2
	exit 1
fi

# 释放端口：若旧服务器还占着该 UDP 端口，先停掉它（只针对该端口，不影响其他进程）。
if command -v fuser >/dev/null 2>&1; then
	fuser -k "${PORT}/udp" >/dev/null 2>&1 || true
	sleep 0.3
fi

echo "启动服务器：端口 $PORT"
exec "$GODOT_BIN" --headless --path "$HERE" -- --server --port "$PORT"
