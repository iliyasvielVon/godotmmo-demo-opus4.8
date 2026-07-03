# Star Glory Godot 4.6.2 - Fire Rain + Seamless World Update

这是一个 Godot 4.6.2 原创 3D 动作 RPG 原型工程。素材为程序化生成低多边形模型，不包含未授权 IP 资源。

## 运行

1. 使用 Godot 4.6.2-stable 打开 `project.godot`。
2. 按 F5 运行。

## 操作

- WASD：移动
- 左 Shift：地面按住奔跑，释放取消；空中无效
- Space：跳跃；奔跑起跳保留水平惯性
- 右键拖动：旋转镜头
- 鼠标滚轮：缩放镜头
- 左键 / 1：星斩
- 2：焰弹
- 3：霜环
- 4：闪现
- 5：天星
- 6：火焰雨
- E：拾取最近装备
- M：打开/关闭大地图
- R：复活

## 本版新增/调整

- 技能移动逻辑重做：
  - 天星、火焰雨为升空硬直，释放期间不能移动。
  - 星斩、焰弹、霜环、闪现释放期间仍可移动。
  - 焰弹蓄力期间可侧移、后退、奔跑，同时鼠标继续控制发射方向。
- 新增技能：火焰雨。
  - 角色升空并锁定指定范围。
  - 范围内持续降下火焰雨。
  - 命中造成火焰伤害，并附带持续灼烧状态。
- 新增无缝大世界解锁：
  - 世界一次性加载，不切场景。
  - 初始只开放中心区域。
  - 击杀 4 只普通怪解锁第一圈。
  - 击杀 8 只普通怪解锁西北赤色王座通路。
  - 击败 Boss 后全域解锁。
  - 小地图/大地图会显示当前解锁半径。
- 强化伤害飘字：
  - 字号更大、描边更粗、视觉更接近二次元战斗反馈。
  - 灼烧伤害显示为“灼烧 -X”。
- 保留上一版内容：
  - 角色陷地修正。
  - 左 Shift 奔跑。
  - 跑跳惯性。
  - 陨石实体坠落、强制击退、落地碎裂。
  - 障碍物真实碰撞。
  - 技能独立 `.tscn`，方便可视化修改。

## 技能场景文件

- `scenes/skills/StarSlash.tscn`
- `scenes/skills/Fireball.tscn`
- `scenes/skills/FrostRing.tscn`
- `scenes/skills/Blink.tscn`
- `scenes/skills/Meteor.tscn`
- `scenes/skills/FireRain.tscn`

## 脚本结构

- `scripts/Main.gd`：世界、UI、地图解锁、伤害计算、技能调度
- `scripts/Player.gd`：玩家移动、奔跑、跳跃、施法动作、装备系统
- `scripts/Monster.gd`：怪物 AI、灼烧状态、受击/击退
- `scripts/Projectile.gd`：投射物
- `scripts/Pickup.gd`：装备掉落
- `scripts/MapView.gd`：小地图/大地图
- `scripts/skills/*.gd`：各技能逻辑

## 静态检查

本包已检查：

- `.gd` 文件括号/字符串配对
- `.tscn` 引用脚本路径存在
- 火焰雨新增场景与脚本路径一致
- 技能 UI 顺序与玩家技能字典一致

注意：当前环境没有 Godot 可执行程序，无法实际按 F5 运行，只能做工程文件与脚本级静态检查。
