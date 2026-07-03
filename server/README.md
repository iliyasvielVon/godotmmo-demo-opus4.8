# Star Glory MMO —— 专用服务器

这是一个 **Godot 4.6 无头（headless）权威服务器**，与 `../client` 是两个独立的 Godot 工程，
通过仓库根的 `shared/`（怪物/技能/世界/协议数据）保持数据一致。服务器用内置 ENet 联机，
跨平台：同一套代码在 **Windows 11 x64** 与 **Ubuntu 22.04 / 24.04** 上都能跑。

## 它负责什么（共享世界基础版）

- 账号登录（用户名 + 密码，密码 SHA-256 加盐存储）与按账号的角色存档持久化。
- 怪物的**唯一权威**：生成、简易 AI（索敌/追击/攻击）、血量、死亡、重生。
- 全局世界解锁进度（所有玩家共享同一进度）。
- 把所有玩家、怪物状态定时广播给每个客户端，使大家进同一个世界、互相可见、可一起打同一只怪。

战斗为“偏信任客户端”模型：客户端上报对怪物造成的伤害，服务器对怪物血量/死亡判定为权威；
玩家自身血量与拾取（个人掉落）在客户端结算。适合模板 / 局域网 / 小规模。代码中已标注后续
转“全权威 + AOI 兴趣管理”的扩展点。

## 目录

```
server/
├── project.godot          # 服务器工程（autoload: GameData / Accounts / Net）
├── main/Main.tscn         # 主场景（根节点挂 ServerMain.gd）
├── main/ServerMain.gd     # 世界模拟与主循环
├── net/ServerNetwork.gd   # ENet + RPC（autoload "Net"）
├── net/AccountDB.gd       # 账号与存档（autoload "Accounts"）
├── sim/ServerMonster.gd   # 轻量权威怪物
├── shared/                # ← 由 tools/sync-shared 生成（不要手改）
├── server.cfg             # 端口 / 最大人数 / 数据目录
└── run-server.{sh,ps1,bat}
```

## 安装 Godot 4.6

服务器只需 Godot **标准编辑器版**即可（用 `--headless` 跑），无需图形界面。

### Ubuntu 22.04 / 24.04
```bash
sudo apt-get update && sudo apt-get install -y unzip wget
cd /opt
sudo wget https://github.com/godotengine/godot/releases/download/4.6-stable/Godot_v4.6-stable_linux.x86_64.zip
sudo unzip Godot_v4.6-stable_linux.x86_64.zip
sudo ln -sf /opt/Godot_v4.6-stable_linux.x86_64 /usr/local/bin/godot
godot --version    # 验证
```
（无桌面环境的服务器也能跑，因为我们用 `--headless`；如缺少依赖可装 `libfontconfig1`。）

### Windows 11 x64
到 https://godotengine.org/download/windows/ 下载 **Godot 4.6 (Standard)**，解压得到
`Godot_v4.6-stable_win64.exe`。

## 运行

> 首次运行前无需手动同步：`run-server` 脚本会自动调用 `tools/sync-shared` 把 `shared/` 拷进来。

### Ubuntu
```bash
cd server
chmod +x run-server.sh            # 仅首次
./run-server.sh 9000              # 端口可选，默认 9000
# 或指定 Godot 路径：  GODOT=/opt/Godot_v4.6-stable_linux.x86_64 ./run-server.sh
```

### Windows（PowerShell）
```powershell
cd server
.\run-server.ps1 -Port 9000 -Godot "C:\Godot\Godot_v4.6-stable_win64.exe"
# 若已把 godot 加入 PATH，可省略 -Godot
```

### Windows（cmd）
```bat
cd server
set GODOT=C:\Godot\Godot_v4.6-stable_win64.exe
run-server.bat 9000
```

启动成功会看到：
```
[Accounts] 数据目录: ... （已注册账号 0 个）
[Net] 服务器已监听端口 9000（最大 64 人）。
[Server] 世界就绪：怪物 N 只，地图半径 155。等待玩家连接……
```

## 放行端口

ENet 走 **UDP**。把服务器监听端口（默认 9000）在防火墙 / 安全组放行 UDP：
- Ubuntu: `sudo ufw allow 9000/udp`
- Windows: 高级防火墙新建“入站规则”→ UDP → 9000。
- 云服务器：在安全组同样放行 UDP 9000。

客户端连接时填服务器的公网/局域网 IP 和该端口。

## 打包成自包含二进制（可选）

开发期直接用上面的 `--headless` 方式即可。若想产出不依赖编辑器的服务器可执行文件：

1. 用 Godot 编辑器打开本 `server` 工程，`Editor > Manage Export Templates` 安装 4.6 模板。
2. `Project > Export`：
   - 新建 **Linux** 预设，勾选 **Runnable** 与 **Dedicated Server**，导出 `build/server.x86_64`。
   - 新建 **Windows Desktop** 预设，同样勾选 Dedicated Server，导出 `build/server.exe`。
3. 部署时把导出产物 + `shared/`（已被打进 pck）一起拷贝；运行：
   - Linux: `./server.x86_64 --server --port 9000`
   - Windows: `server.exe --server --port 9000`

> 注：导出预设 `export_presets.cfg` 与 Godot 版本/模板强相关，故未随仓库提供，请在编辑器内生成。

## 区域热更新（不停服更新某区域）

服务器把世界按 `region_size`（默认 64，见 `shared/data/world.json`）划成网格区域，区域 id 为
`"cx_cz"`（玩家所在区块坐标，如中心区是 `"0_0"`）。通过**热控制文件**即可在不重启、不影响其他
玩家的前提下，把某些区域置于"更新维护"状态：

1. 在数据目录（见下方"数据与存档"，默认 `user://data`）下创建/编辑 `region_locks.json`：
   ```json
   { "locked": ["1_0", "1_-1"] }
   ```
   服务器每 2 秒自动读取一次（无需重启）。检测到变化即：
   - **把这些区域里的玩家强制弹出**到最靠近世界中心的相邻未锁定区域；
   - **广播锁定列表**，所有客户端在该区域显示红色维护屏障，并**禁止玩家进入**；
   - 其他区域的玩家完全不受影响，照常游玩。
2. 现在可以安全地更新该区域的内容（替换 `client/scenes/world/chunks/chunk_cx_cz.tscn`
   等区块资源、调整刷怪数据……）。
3. 更新完成后，把对应 id 从 `region_locks.json` 的 `locked` 列表移除（或清空文件 / 删除文件）。
   服务器下次读取即解锁，玩家可重新进入，客户端重新加载该区块的最新资源。

> 说明：`region_locks.json` 默认不存在 = 没有任何锁定。位置/进入限制由服务器权威兜底，
> 客户端也会本地阻挡进入（无形墙 + 提示），双保险。

## 数据与存档

- `accounts.json`：用户名 → {salt, hash, name}。首次用某用户名登录即自动注册。
- `saves/<用户名>.json`：该账号的角色存档（等级/经验/装备/技能等）。
- 位置由 `server.cfg` 的 `data_dir` 决定，留空则在 Godot 用户目录 `user://data`。
  备份服务器只需备份这个目录。
