#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Star Glory MMO —— 服务器一键更新部署脚本。

做的事：
  1) 本地把 repo 根 shared/ 同步进 server/shared/（等价 tools/sync-shared）。
  2) 把 server/ 打包成 tar.gz（排除缓存/运行数据），scp 上传到服务器。
  3) 服务器上解压覆盖到项目目录，(可选)重新导入资源。
  4) 重启 Godot 无头服务端（systemd 或 nohup 两种方式）。

前置：
  - 本机已配置到服务器的免密 SSH：  ssh ubuntu@43.142.159.66  能直接登录。
  - 本机有 ssh / scp（Windows 10/11 自带 OpenSSH 客户端即可）。
  - 服务器上已有 Godot 无头可执行文件（见 CONFIG['godot_bin']）。

用法：
  python tools/deploy_server.py            # 同步+上传+重启
  python tools/deploy_server.py --dry-run  # 只打印将执行的步骤，不真正上传/重启
  python tools/deploy_server.py --no-sync  # 跳过 shared 同步
  python tools/deploy_server.py --no-restart  # 只更新文件，不重启
"""

import os
import sys
import shutil
import tarfile
import argparse
import subprocess
import tempfile

# ===================== 需要你确认/修改的配置 =====================
CONFIG = {
    # 免密 SSH 目标
    "host": "ubuntu@43.142.159.66",
    # 服务器上运行该服务的用户名（systemd 服务以此用户运行）
    "remote_user": "ubuntu",
    # 服务器上放置服务器项目的目录（会被本次内容覆盖更新；不存在会自动创建）
    "remote_dir": "/home/ubuntu/stargloryserver",
    # 服务器上 Godot 无头可执行文件的绝对路径
    "godot_bin": "/usr/local/bin/godot",
    # 启动参数（端口等已在 server.cfg；这里一般不用改）
    "run_args": "--headless",

    # 重启方式：
    #   "systemd" —— systemd 后台常驻（关 SSH 不断、崩溃自动重启、开机自启）。先跑一次 --setup-service。
    #   "nohup"   —— 直接 pkill 旧进程 + nohup 起新进程（无需 systemd）。
    "restart_mode": "systemd",
    "systemd_service": "starglory",     # restart_mode=systemd 时用
    "remote_log": "/home/ubuntu/starglory_server.log",  # nohup 模式日志

    # 上传前是否在服务器上重新导入资源（首次/资源有变动时建议 true）
    "reimport": True,
}


def systemd_unit() -> str:
    return (
        "[Unit]\n"
        "Description=Star Glory MMO Server (Godot headless)\n"
        "After=network.target\n\n"
        "[Service]\n"
        "Type=simple\n"
        "User=%s\n"
        "WorkingDirectory=%s\n"
        "ExecStart=%s %s --path %s\n"
        "Restart=on-failure\n"
        "RestartSec=3\n\n"
        "[Install]\n"
        "WantedBy=multi-user.target\n"
    ) % (CONFIG["remote_user"], CONFIG["remote_dir"], CONFIG["godot_bin"],
         CONFIG["run_args"], CONFIG["remote_dir"])
# 打包时排除：任意层级的缓存目录 + 日志；以及「项目根」的运行期数据目录（不误伤 shared/data）。
CACHE_DIRS = {".godot", ".import", "__pycache__"}
ROOT_RUNTIME_DIRS = {"data", "saves"}   # 仅排除 server/data、server/saves，避免覆盖账号/存档
# ================================================================

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # 仓库根
SERVER_DIR = os.path.join(ROOT, "server")
SHARED_SRC = os.path.join(ROOT, "shared")
SHARED_DST = os.path.join(SERVER_DIR, "shared")


def run(cmd, check=True):
    print(">>", " ".join(cmd) if isinstance(cmd, list) else cmd)
    r = subprocess.run(cmd, shell=isinstance(cmd, str))
    if check and r.returncode != 0:
        sys.exit("命令失败（退出码 %d）：%s" % (r.returncode, cmd))
    return r.returncode


def sync_shared():
    """把 repo 根 shared/ 覆盖进 server/shared/（与 tools/sync-shared 一致）。"""
    if not os.path.isdir(SHARED_SRC):
        sys.exit("找不到 shared 源目录：%s" % SHARED_SRC)
    if os.path.isdir(SHARED_DST):
        shutil.rmtree(SHARED_DST)
    shutil.copytree(SHARED_SRC, SHARED_DST)
    print("已同步 shared -> server/shared")


def _filter(tarinfo):
    parts = tarinfo.name.split("/")   # parts[0] == "server"
    if any(p in CACHE_DIRS for p in parts):
        return None
    if tarinfo.name.endswith(".log"):
        return None
    # 仅排除项目根的运行期数据目录（server/data、server/saves），不影响 shared/data。
    if len(parts) >= 2 and parts[1] in ROOT_RUNTIME_DIRS:
        return None
    return tarinfo


def make_tarball():
    """把 server/ 打包为临时 tar.gz，返回路径。"""
    fd, path = tempfile.mkstemp(prefix="starglory_server_", suffix=".tgz")
    os.close(fd)
    with tarfile.open(path, "w:gz") as tar:
        # arcname="server" → 解压后是 server/...，再 strip 掉一层放进 remote_dir
        tar.add(SERVER_DIR, arcname="server", filter=_filter)
    print("已打包：%s（%.1f KB）" % (path, os.path.getsize(path) / 1024.0))
    return path


def remote_update_cmd():
    rd = CONFIG["remote_dir"]
    gb = CONFIG["godot_bin"]
    cmds = [
        "set -e",
        "mkdir -p '%s'" % rd,
        # 解压：strip 掉顶层 server/，直接覆盖进 remote_dir
        "tar -xzf /tmp/starglory_server.tgz -C '%s' --strip-components=1" % rd,
        "rm -f /tmp/starglory_server.tgz",
    ]
    if CONFIG["reimport"]:
        cmds.append("'%s' --headless --path '%s' --import || true" % (gb, rd))
    return " && ".join(cmds)


def remote_restart_cmd():
    rd = CONFIG["remote_dir"]
    gb = CONFIG["godot_bin"]
    if CONFIG["restart_mode"] == "systemd":
        svc = CONFIG["systemd_service"]
        # 先停服务并杀掉任何路径残留的 godot（防旧实例占端口），再干净启动。
        return " ; ".join([
            "sudo systemctl stop %s || true" % svc,
            "pkill godot || true",
            "sleep 1",
            "sudo systemctl start %s" % svc,
            "sleep 2",
            "systemctl --no-pager -l status %s | head -n 10 || true" % svc,
            "echo [restart-done]",
        ])
    # nohup 方式：杀掉旧进程（按 --path 目录匹配）+ 起新进程
    log = CONFIG["remote_log"]
    return " ; ".join([
        "pkill -f 'godot.*%s' || true" % rd,
        "sleep 1",
        "nohup '%s' %s --path '%s' > '%s' 2>&1 & disown" % (gb, CONFIG["run_args"], rd, log),
        "sleep 2",
        "echo '--- 最近日志 ---'",
        "tail -n 15 '%s' || true" % log,
    ])


def ssh(remote_cmd, dry):
    # 直接把命令交给远端默认 shell（单层解析）；命令里用绝对路径，无需登录 shell。
    full = ["ssh", CONFIG["host"], remote_cmd]
    if dry:
        print("[dry-run] ssh:", remote_cmd)
        return
    run(full)


def setup_service(dry):
    """一次性：把 systemd 单元装到服务器，设为开机自启并启动。需要服务器上 sudo 可用。"""
    svc = CONFIG["systemd_service"]
    fd, path = tempfile.mkstemp(prefix="%s_" % svc, suffix=".service")
    with os.fdopen(fd, "w", newline="\n") as f:
        f.write(systemd_unit())
    try:
        if dry:
            print("[dry-run] 将安装 systemd 服务 %s：\n%s" % (svc, systemd_unit()))
            return
        run(["scp", path, "%s:/tmp/%s.service" % (CONFIG["host"], svc)])
        cmd = " && ".join([
            "sudo mv /tmp/%s.service /etc/systemd/system/%s.service" % (svc, svc),
            "sudo systemctl daemon-reload",
            "sudo systemctl enable %s" % svc,
            "sudo systemctl restart %s" % svc,
            "sleep 1",
            "systemctl --no-pager -l status %s | head -n 12" % svc,
        ])
        ssh(cmd, dry=False)
        print("systemd 服务 %s 已安装并启动（开机自启 + 崩溃自动重启 + 关 SSH 不断）。" % svc)
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="只打印不执行上传/重启")
    ap.add_argument("--no-sync", action="store_true", help="跳过 shared 同步")
    ap.add_argument("--no-restart", action="store_true", help="只更新文件不重启")
    ap.add_argument("--setup-service", action="store_true", help="一次性：安装 systemd 服务（之后用普通部署即可）")
    args = ap.parse_args()

    if not os.path.isdir(SERVER_DIR):
        sys.exit("找不到 server 目录：%s" % SERVER_DIR)

    if args.setup_service:
        # 先把最新代码同步上去，再装服务。
        if not args.no_sync:
            sync_shared()
        tb = make_tarball()
        try:
            if not args.dry_run:
                run(["scp", tb, "%s:/tmp/starglory_server.tgz" % CONFIG["host"]])
                ssh(remote_update_cmd(), dry=False)
            setup_service(args.dry_run)
        finally:
            try:
                os.remove(tb)
            except OSError:
                pass
        return

    if not args.no_sync:
        sync_shared()

    tarball = make_tarball()
    try:
        if args.dry_run:
            print("[dry-run] scp", tarball, "->", CONFIG["host"] + ":/tmp/starglory_server.tgz")
            ssh(remote_update_cmd(), dry=True)
            if not args.no_restart:
                ssh(remote_restart_cmd(), dry=True)
            print("[dry-run] 完成（未真正执行）。")
            return

        run(["scp", tarball, "%s:/tmp/starglory_server.tgz" % CONFIG["host"]])
        ssh(remote_update_cmd(), dry=False)
        if args.no_restart:
            print("文件已更新（未重启）。")
        else:
            ssh(remote_restart_cmd(), dry=False)
            print("部署完成，服务器已重启。")
    finally:
        try:
            os.remove(tarball)
        except OSError:
            pass


if __name__ == "__main__":
    main()
