extends Node3D

const PlayerScene = preload("res://scripts/Player.gd")
const MonsterScene = preload("res://scripts/Monster.gd")
const ProjectileScene = preload("res://scripts/Projectile.gd")
const MapViewScene = preload("res://scripts/MapView.gd")
const TurretScene = preload("res://scenes/world/buildings/turret/Turret.tscn")
const TotemScene = preload("res://scripts/HateTotem.gd")
const OreNodeScene = preload("res://scripts/OreNode.gd")
const OutpostSystemScene = preload("res://scripts/systems/OutpostSystem.gd")
const TerrainSystemScene = preload("res://scripts/systems/TerrainSystem.gd")
const ShelterSystemScene = preload("res://scripts/systems/ShelterSystem.gd")
const QuestSystemScene = preload("res://scripts/systems/QuestSystem.gd")
const AchievementSystemScene = preload("res://scripts/systems/AchievementSystem.gd")
const PetSystemScene = preload("res://scripts/systems/PetSystem.gd")
const DroneSystemScene = preload("res://scripts/systems/DroneSystem.gd")

# 联机：远端玩家施法时，按技能映射动作 pose 与闪光颜色做表现。
const _SKILL_POSE := {
	"star_slash": "slash", "fireball": "fireball_charge", "frost_ring": "frost",
	"blink": "blink", "meteor": "meteor", "fire_rain": "fire_rain"
}
const _SKILL_COLOR := {
	"star_slash": Color(0.7, 0.95, 1.0, 1), "fireball": Color(1.0, 0.55, 0.25, 1),
	"frost_ring": Color(0.5, 0.85, 1.0, 1), "blink": Color(0.8, 0.7, 1.0, 1),
	"meteor": Color(1.0, 0.5, 0.2, 1), "fire_rain": Color(1.0, 0.45, 0.2, 1)
}

var forced_bullet_type: String = ""   # UI 强制全场炮塔弹种；"" = 各炮塔用自身随机种
var autosave_timer: float = 12.0      # 周期自动存档
const MAX_LOCAL_MONSTERS := 72
const MAX_SUMMONED_MONSTERS := 18
const SUMMON_TTL := 45.0

# 系统管理器（世界级单例，作为 Main 子节点）。
var combat: CombatManager
var skills: SkillManager
var equipment: EquipmentManager
var inv: InventoryManager

var rng := RandomNumberGenerator.new()
var map_radius: float = 185.0
var unlocked_world_radius: float = 58.0
var unlock_stage: int = 0
var boundary_notice_timer: float = 0.0
var player: StarGloryPlayer = null
var monsters: Array[StarGloryMonster] = []
var pickups: Array[StarGloryPickup] = []
var kills: int = 0
var boss_defeated: bool = false
var play_seconds: float = 0.0          # 累计游戏时长（秒），跨存档持续累加
var boss_records: Array = []           # 单机 Boss 击杀记录：[{boss_name,fight_seconds,play_seconds,world_level,stats,...}]
var total_spawned: int = 0
var world_level: int = 1               # 内部保留（不再显示/不再由Boss推进）；怪物强度改由区域档位驱动
var level_cap: int = 20                 # 当前等级上限：到上限需通关对应单人副本才能继续升级
var gate_boss: StarGloryMonster = null  # 常驻世界Boss引用（不再作为升级闸门）
const LEVEL_GATE_STEP := 3

func _live_monster_count(include_boss: bool = true) -> int:
	var n: int = 0
	for m_v: Variant in monsters:
		var m: StarGloryMonster = m_v as StarGloryMonster
		if m == null or not is_instance_valid(m) or m.dead:
			continue
		if not include_boss and m.is_boss:
			continue
		n += 1
	return n

func _summoned_monster_count() -> int:
	var n: int = 0
	for m_v: Variant in monsters:
		var m: StarGloryMonster = m_v as StarGloryMonster
		if m != null and is_instance_valid(m) and not m.dead and m.is_summoned:
			n += 1
	return n

# 按距离分档的区域：固定「准入等级」+「怪物等级范围」+ 强度档位 tier（越远越强）。
const REGIONS := [
	{"name": "新手村·近郊", "r": 58.0, "entry": 1, "lmin": 1, "lmax": 8, "tier": 1},
	{"name": "晨曦草原", "r": 95.0, "entry": 8, "lmin": 8, "lmax": 16, "tier": 2},
	{"name": "幽影林地", "r": 130.0, "entry": 16, "lmin": 16, "lmax": 26, "tier": 3},
	{"name": "霜寒边境", "r": 160.0, "entry": 26, "lmin": 26, "lmax": 36, "tier": 5},
	{"name": "星界深渊", "r": 99999.0, "entry": 36, "lmin": 36, "lmax": 45, "tier": 6},
]
# 等级卡关：到达 cap 需通关指定单人副本(dungeon id)才能升到 next。
const LEVEL_GATES := [
	{"cap": 20, "dungeon": 2, "next": 30},
	{"cap": 30, "dungeon": 3, "next": 40},
	{"cap": 40, "dungeon": 4, "next": 50},
]

func region_of(pos: Vector3) -> Dictionary:
	var d: float = Vector2(pos.x, pos.z).length()
	for rg_v: Variant in REGIONS:
		var rg: Dictionary = rg_v
		if d <= float(rg["r"]):
			return rg
	return REGIONS[REGIONS.size() - 1]

func region_tier(pos: Vector3) -> int:
	return int(region_of(pos)["tier"])

var _disc_tex: Texture2D = null
# 圆盘贴图（供落点 Decal 用：软边实心圆 + 边缘环），生成一次缓存。
func ground_marker_texture() -> Texture2D:
	if _disc_tex != null:
		return _disc_tex
	var s: int = 64
	var img: Image = Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c: float = float(s) * 0.5
	for y in range(s):
		for x in range(s):
			var d: float = Vector2(float(x) - c + 0.5, float(y) - c + 0.5).length() / (float(s) * 0.5)
			var a: float = 0.0
			if d <= 1.0:
				a = clampf(1.0 - d, 0.0, 1.0) * 0.45
				if d > 0.8:
					a += 0.55   # 边缘环加强，轮廓更清晰
			img.set_pixel(x, y, Color(1, 1, 1, clampf(a, 0.0, 1.0)))
	_disc_tex = ImageTexture.create_from_image(img)
	return _disc_tex

# (x,z) 处的水面高度（在湖内返回水面 y，否则极低值）。玩家浮力用。
func water_surface_at(x: float, z: float) -> float:
	if terrain_system != null and terrain_system.has_method("lake_surface_at"):
		return terrain_system.lake_surface_at(x, z)
	return -1.0e9

# 安全区等级：联机=据点加固等级(服务器同步)，单机=庇护所等级。无人机等级上限用它。
func safe_zone_level() -> int:
	return maxi(1, safe_zone_reinforce if Net.online else shelter_level)

# 常驻 Boss 概率掉落宠物蛋/技能书。
func _pet_boss_roll() -> void:
	if inv == null:
		return
	if rng.randf() < 0.30:
		inv.add_material("宠物蛋", Color(0.85, 0.6, 1.0, 1), 1)
		flash_message("🥚 Boss 掉落：宠物蛋 ×1！（按 O 抽卡）")
	if rng.randf() < 0.30:
		inv.add_material("宠物技能书", Color(0.9, 0.8, 0.4, 1), 1)
		flash_message("📘 Boss 掉落：宠物技能书 ×1！")

# 副本通关必得宠物蛋。
func _pet_dungeon_reward() -> void:
	if inv != null:
		inv.add_material("宠物蛋", Color(0.85, 0.6, 1.0, 1), 1)
		flash_message("🥚 副本奖励：宠物蛋 ×1！（按 O 抽卡）")

# 通关对应单人副本 → 解锁更高升级上限。
func _maybe_unlock_level_cap(dungeon_id: int) -> void:
	for g_v: Variant in LEVEL_GATES:
		var g: Dictionary = g_v
		if level_cap == int(g["cap"]) and dungeon_id == int(g["dungeon"]):
			var old_cap: int = level_cap
			level_cap = int(g["next"])
			flash_message("🎉 主线【突破等级上限】完成！通关守关副本，等级上限 Lv.%d → Lv.%d，可继续升级了！" % [old_cap, level_cap])
			if has_method("spawn_skill_flash") and player != null and is_instance_valid(player):
				spawn_skill_flash(player.global_position + Vector3(0, 1.2, 0), Color(1.0, 0.9, 0.4, 1), 3.0, 0.7)
			_bt_notified_cap = -1   # 允许下一档上限再次提示
			if player != null and is_instance_valid(player):
				player._cap_warned = false
			return
# 常驻 Boss 领域：每 5 级解锁一个；未达等级强入受罚（减速/禁技/扣血/外推）。
var resident_zones: Array = []          # [{center,radius,req,wl,boss,barrier,respawn}]
const ZONE_DRAIN := 16.0
const ZONE_PUSH := 7.0
const RESIDENT_RESPAWN := 16.0
var magnet_timer: float = 0.0          # 磁铁生效剩余时间：>0 时自动吸取周边道具
var _pickup_count: int = 0             # 批量拾取合并提示计数
var _pickup_msg_timer: float = 0.0
var _backpack_dirty: bool = false      # 背包需刷新（每帧最多刷一次，避免逐件重建）
const MAGNET_DURATION := 12.0          # 磁铁持续时间（秒）
const MAGNET_RADIUS := 11.0            # 磁铁吸取范围（米）
const MAGNET_PULL_SPEED := 16.0        # 道具被吸向玩家的速度（米/秒）
const MAGNET_COLLECT_DIST := 1.6       # 吸到此距离内即拾取
const AUTO_PICKUP_RADIUS := 9.0        # 始终生效的吸取范围（增强）：进此范围即被吸向玩家
const AUTO_PICKUP_PULL := 15.0         # 吸力（米/秒，增强）
const AUTO_PICKUP_COLLECT := 1.8       # 吸到此距离内即拾取（联机先到先得）
var spawners: Array[Dictionary] = []   # 固定刷怪点（可重生）
var beast_tides: Array = []            # 妖兽令黑洞 [{center,timer,emit,node,trib}]

# 联机：远端实体傀儡（按服务器快照渲染）。net_id -> 节点。
var net_players: Dictionary = {}       # peer_id -> StarGloryPlayer 傀儡
var net_monsters: Dictionary = {}      # 怪物 net_id -> StarGloryMonster 傀儡
var net_drops: Dictionary = {}         # 共享掉落物 drop_id -> StarGloryPickup
# 区域热更新（联机）：锁定区域的可视屏障 + 本地禁入。
var region_size: float = 64.0
var region_barriers: Dictionary = {}   # region_id -> MeshInstance3D
var _last_safe_pos: Vector3 = Vector3.ZERO

var world_root: Node3D
var unlock_ring: MeshInstance3D
var entity_root: Node3D
var outpost_system: Node = null   # 安全区/攻城系统
var shelter_system: Node = null   # 个人庇护所
var shelter_level: int = 0        # 庇护所等级（存档）
var quest_system: Node = null     # 任务系统
var achievement_system: Node = null   # 成就系统
var pet_system: Node = null           # 宠物系统
var drone_system: Node = null         # 无人机系统
var safe_zone_reinforce: int = 0      # 安全区(据点)加固等级，联机由服务器同步
var terrain_system: Node = null   # 草地山林/雪山地形
var world_env: Environment = null
var _base_fog_density: float = 0.012
var cold_overlay: ColorRect = null
var _cold_a: float = 0.0

func terrain_height(x: float, z: float) -> float:
	if terrain_system != null:
		return terrain_system.height_at(x, z)
	return 0.0
var effect_root: Node3D
var projectile_root: Node3D
var streamer: WorldStreamer
var camera: Camera3D
var cam_yaw: float = 0.0
var cam_pitch: float = 0.25
var cam_distance: float = 9.5
var right_mouse_down: bool = false
var first_person: bool = false

# 镜头参数：俯仰可达近乎垂直（看天/看地），第一人称视点在头部高度。
const PITCH_LIMIT := deg_to_rad(89.0)
const FP_EYE_HEIGHT := 1.92
const FP_FORWARD_NUDGE := 0.34

var ui_layer: CanvasLayer
# 聊天窗（公屏/系统/队伍/私聊）
var chat_panel: Panel = null
var chat_log: RichTextLabel = null
var chat_input: LineEdit = null
var chat_btn: Button = null
var chat_tab_btns: Dictionary = {}      # channel -> Button
var chat_lines: Array = []              # [{channel, bb}]，封顶
var chat_active: String = "public"
var chat_typing: bool = false           # 聊天输入聚焦中（Player 据此屏蔽移动按键）
const CHAT_CHANNELS := ["public", "system", "party", "whisper"]
const CHAT_NAMES := {"public": "公屏", "system": "系统", "party": "队伍", "whisper": "私聊"}
const CHAT_COLORS := {"public": "#E6F2FF", "system": "#FFD94D", "party": "#66BFFF", "whisper": "#F28CFF"}
# 头像预设（8 种颜色圆点；无图片资源，用彩色●表示头像）。
const AVATAR_COLORS := ["#4FC3F7", "#81C784", "#BA68C8", "#FFB74D", "#E57373", "#F06292", "#4DD0E1", "#FFF176"]

func _avatar_bb(avatar: int) -> String:
	if avatar < 0 or avatar >= AVATAR_COLORS.size():
		return ""
	return "[color=%s]●[/color] " % AVATAR_COLORS[avatar]
# 管理员操作台（GM，仅联机）
var admin_console: Node3D = null
var admin_panel: Panel = null
var admin_panel_open: bool = false
var admin_btn: Button = null
var admin_title: Label = null
var admin_str_input: LineEdit = null
var admin_drop_input: LineEdit = null
var admin_player_list_box: VBoxContainer = null
var admin_player_detail: RichTextLabel = null
var admin_edit_name: LineEdit = null
var admin_edit_level: LineEdit = null
var admin_edit_equip: LineEdit = null
var admin_player_selected_id: int = 0
var admin_player_selected: Dictionary = {}
var admin_action_btns: Array = []       # [{node:Button, need:int}]
var admin_godmode: bool = false
var admin_speed_on: bool = false
var _admin_base_speed: float = 0.0
const ADMIN_CONSOLE_POS := Vector3(4, 0, 7)
# 副本（仅联机）
# 入口 + 单机副本内容（mobs/boss/hidden/wl 与服务器 DUNGEONS 对齐；联机时内容由服务器权威）。
const DUNGEON_DEFS := [
	{"id": 1, "name": "迷雾林窟", "level_req": 5, "pos": Vector3(-10, 0, 7), "wl": 2, "spawn": Vector3(0, 0.5, 4000),
		"mobs": [{"kind": "slime", "n": 6}, {"kind": "wolf", "n": 3, "elite": true}], "boss": "boss", "hidden": "boss_storm"},
	{"id": 2, "name": "幽影深渊", "level_req": 15, "pos": Vector3(-16, 0, 7), "wl": 5, "spawn": Vector3(300, 0.5, 4000),
		"mobs": [{"kind": "wolf", "n": 6}, {"kind": "archer", "n": 3, "elite": true}, {"kind": "mage", "n": 2, "elite": true}], "boss": "boss_warlord", "hidden": "boss_titan"},
	{"id": 3, "name": "星界王座", "level_req": 25, "pos": Vector3(-22, 0, 7), "wl": 8, "spawn": Vector3(600, 0.5, 4000),
		"mobs": [{"kind": "wisp", "n": 6}, {"kind": "skyseraph", "n": 2, "elite": true}, {"kind": "archer", "n": 3}], "boss": "boss_titan", "hidden": "skyseraph"},
	{"id": 4, "name": "星莹矿洞", "level_req": 20, "pos": Vector3(26, 0, -96), "wl": 6, "spawn": Vector3(900, 0.5, 4000), "theme": "cave",
		"mobs": [{"kind": "wisp", "n": 6}, {"kind": "mage", "n": 3, "elite": true}, {"kind": "orbdrifter", "n": 2}], "boss": "boss_storm", "hidden": "skyseraph"},
]
var in_dungeon: bool = false
var dungeon_root: Node3D = null         # 副本入口物体的容器
var _dungeon_portals: Dictionary = {}   # 副本 id -> 入口 Node3D（用于按突破任务控制显隐）
var dungeon_floor: StaticBody3D = null  # 进入后临时地板
var dungeon_cave_root: Node3D = null    # 星莹矿洞内部装饰
var _cave_prev_ambient_e: float = 0.9
var _cave_prev_ambient_c: Color = Color(0.52, 0.58, 0.78, 1)
var dungeon_panel: Panel = null
var dungeon_label: Label = null
var dungeon_exit_btn: Button = null
var dungeon_confirm: Panel = null
var dungeon_enter_panel: Panel = null
var dungeon_enter_label: Label = null
var _pending_dungeon_id: int = 0
var dungeon_name: String = ""
var dungeon_id: int = 0
var dungeon_cleared: bool = false
var dungeon_enter_ms: int = 0
# 单机副本本地状态
var sp_dungeon_active: bool = false
var sp_dungeon_def: Dictionary = {}
var sp_dungeon_monsters: Array = []
var sp_dungeon_boss: StarGloryMonster = null
var sp_dungeon_hidden: StarGloryMonster = null
var sp_dungeon_boss_pos: Vector3 = Vector3.ZERO   # 守关 Boss 位置（结算门在此生成）
var sp_dungeon_boss_dead: bool = false
var sp_dungeon_portal: Node3D = null              # 结算传送门（单机/联机通用）
var _dungeon_spawn_pos: Vector3 = Vector3.ZERO    # 副本出生点（联机结算门定位）
var _mp_clear_info: Dictionary = {}               # 联机通关信息（待结算）
var _mp_clear_applied: bool = false
var sp_dungeon_hidden_done: bool = false
var dungeon_records: Array = []         # 通关记录 [{name, clear_seconds, unix}]，随存档持久化
var hud_label: RichTextLabel
var equip_label: Label
var equip_panel: ColorRect
var message_label: Label
# 任务/技能 合并的可收缩 Tab 面板（放在原技能详情框位置）。
var hud_tab_bg: ColorRect
var hud_tab_scroll: ScrollContainer
var hud_tab_vbox: VBoxContainer
var hud_tab_btn_quest: Button
var hud_tab_btn_skill: Button
var hud_tab_collapse: Button
var _hud_tab: int = 0            # 0=任务 1=技能
var _hud_collapsed: bool = false
var _hud_tab_t: float = 0.0      # Tab 内容刷新节流
var help_label: Label
var hotbar_root: Control
var skill_slots: Dictionary = {}
var mini_map: Control
var big_map: Control
# 选点导航
var has_nav: bool = false
var nav_target: Vector3 = Vector3.ZERO
var nav_beacon: Node3D = null
var _quest_nav_active: bool = false   # 当前导航点来自任务追踪
# 顶部中央方向标度（罗盘）：指示导航点方位
var compass_root: Control
var compass_marker: Label
var compass_dist: Label
var message_timer: float = 0.0
var backpack_panel: Panel = null
var backpack_title: Label = null
var preview_box: Panel = null                  # 角色预览格
var backpack_stats: Label = null               # 左下属性显示区
var bp_tab: String = "equip"                   # 当前标签：equip / items
var bp_tab_equip_btn: Button = null
var bp_tab_items_btn: Button = null
var bp_equip_view: Control = null              # 装备标签内容
var bp_items_view: Control = null              # 道具标签内容
var bp_page_btns: Dictionary = {}              # etype -> Button（11 个分页/装备格）
var bp_selected_page: String = "weapon"        # 当前选中的装备分页
var bp_grid: GridContainer = null              # 右侧：当前分页的 2048 网格
var bp_grid_head: Label = null
var bp_expand_btn: Button = null
var bp_items_grid: GridContainer = null        # 道具标签的格子
const DEATH_DROP_CHANCE := 0.25   # 死亡丢失一件装备的概率
# 死亡 / 复活
var death_panel: Control = null
var death_msg_label: Label = null
var death_revive_btn: Button = null
var death_diag_label: Label = null
var _death_handled: bool = false
# 个人档案 / 排行榜
var profile_panel: Control = null
var profile_text: RichTextLabel = null
var local_player_name: String = "冒险者"
var _run_recorded: bool = false
# 暂停菜单 / 战斗状态 / 退出
var pause_panel: Control = null
var pause_status_label: Label = null
var pause_force_btn: Button = null
var profile_edit_panel: Control = null
var profile_nick_edit: LineEdit = null
var profile_avatar_b64: String = ""
var profile_avatar_preview: TextureRect = null
var _profile_avatar_dialog: FileDialog = null
var _combat_timer: float = 0.0          # >0 视为「战斗中」（受击/出手刷新）
var _pending_quit: String = ""          # "menu" / "exit"：等服务器脱战裁决后执行
var _force_kind: String = ""            # 强制退出时要执行的动作
# 触屏控件（仅单机）。用「按手指索引」的原始触摸事件实现真多点触控（可同时移动+跳+攻击）。
var touch_root: Control = null
var joy_base: Control = null
var joy_knob: Control = null
var joy_active: bool = false
const JOY_RADIUS := 118.0
var _touch_btn_nodes: Dictionary = {}   # role -> {node:Panel, col:Color}
var _finger_role: Dictionary = {}       # 触摸 index -> 角色("joy"/"cam"/"attack"/"jump"/"q"/"e")
var _step_timer: float = 0.0            # 玩家脚步音节流
# 手机端技能瞄准：先点技能格选定，再点屏幕选择释放位置。
var _aim_skill: String = ""
var _mobile_aim_active: bool = false
var _mobile_aim_screen: Vector2 = Vector2.ZERO
# 快捷药剂（血z/蓝x/体c）+ 拖拽给单位使用
var _quick_slots: Dictionary = {}      # ptype -> {node:Panel, label:Label}
var _potion_drag: String = ""          # 正在拖拽的药剂 ptype
var _potion_hover: Node = null         # 拖拽悬停的单位
var _select_ring: MeshInstance3D = null
var vignette: TextureRect = null       # 边界预警红黑暗角
var hurt_overlay: ColorRect = null     # 受击红闪（打击感）
var _hurt_a: float = 0.0               # 当前受击红闪强度
var _cam_trauma: float = 0.0           # 镜头震动创伤值 [0,1]
var _vig_a: float = 0.0                # 暗角当前强度（平滑）

func _ready() -> void:
	rng.randomize()
	Audio.play_music("game")
	if not AdService.ad_finished.is_connected(_on_any_ad_finished):
		AdService.ad_finished.connect(_on_any_ad_finished)   # 联机广告观看次数上报
	_setup_systems()
	_setup_world()
	_spawn_player()
	streamer.setup(self)
	if Net.online:
		_net_setup()
	else:
		_spawn_monsters()
		_spawn_buildings()
	_build_ui()
	if Net.online:
		# 联机：始终使用「服务器返回的存档」，忽略本地单机存档（空存档则为全新角色）。
		SaveSystem.pending_load = false
		_apply_save(Net.login_save)
		_apply_resume(Net.login_save.get("_resume", {}))   # 重连：恢复下线/托管时的位置与状态
		flash_message("已连接服务器，欢迎来到星辉荣耀大世界：与其他玩家共同探索、并肩作战。")
	elif SaveSystem.pending_load and SaveSystem.has_save():
		_apply_save(SaveSystem.load_data())
		SaveSystem.pending_load = false
		flash_message("已读取存档，欢迎回来。")
	else:
		flash_message("星辉荣耀原型启动：WASD 移动，Shift 奔跑，1-6 释放技能；大世界会随主线逐步解锁。")

# 重连恢复：把玩家放回下线/托管时的位置，并恢复血/蓝/耐力。
func _apply_resume(res: Variant) -> void:
	if not (res is Dictionary) or not (res as Dictionary).has("pos") or player == null or not is_instance_valid(player):
		return
	var pa: Array = (res as Dictionary)["pos"]
	if pa.size() >= 3:
		player.global_position = Vector3(float(pa[0]), maxf(0.2, float(pa[1])), float(pa[2]))
		player.velocity = Vector3.ZERO
	player.hp = clampf(float((res as Dictionary).get("hp", player.hp)), 0.0, float(player.max_hp))
	player.mp = clampf(float((res as Dictionary).get("mp", player.mp)), 0.0, float(player.max_mp))
	player.stamina = clampf(float((res as Dictionary).get("st", player.stamina)), 0.0, float(player.max_stamina))
	if player.hp <= 0.0:
		player.hp = float(player.max_hp) * 0.3   # 避免带 0 血复活直接又死
	flash_message("已恢复到下线时的位置与状态。")

func _notification(what: int) -> void:
	# 关闭窗口（X）：联机战斗中禁止退出；否则自动存档后退出。
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if Net.online and in_combat():
			flash_message("战斗中无法退出游戏，请脱战后再退出。")
			return
		_autosave()
		get_tree().quit()

func _setup_systems() -> void:
	combat = CombatManager.new()
	combat.name = "CombatManager"
	add_child(combat)
	combat.setup(self)

	skills = SkillManager.new()
	skills.name = "SkillManager"
	add_child(skills)
	skills.setup(self)

	equipment = EquipmentManager.new()
	equipment.name = "EquipmentManager"
	add_child(equipment)
	equipment.setup(self)

	inv = InventoryManager.new()
	inv.name = "InventoryManager"
	add_child(inv)
	inv.setup(self)

func _mat(color: Color, emission: float = 0.0, alpha: float = 1.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var final_color := color
	final_color.a = alpha
	mat.albedo_color = final_color
	mat.roughness = 0.68
	mat.metallic = 0.0
	if alpha < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emission > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = emission
	return mat

func _setup_world() -> void:
	world_root = Node3D.new()
	world_root.name = "World"
	add_child(world_root)
	entity_root = Node3D.new()
	entity_root.name = "Entities"
	add_child(entity_root)
	projectile_root = Node3D.new()
	projectile_root.name = "Projectiles"
	add_child(projectile_root)
	effect_root = Node3D.new()
	effect_root.name = "Effects"
	add_child(effect_root)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.045, 0.055, 0.10, 1)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.52, 0.58, 0.78, 1)
	environment.ambient_light_energy = 0.9
	environment.fog_enabled = true
	environment.fog_density = 0.012
	environment.fog_light_color = Color(0.25, 0.32, 0.50, 1)
	env.environment = environment
	world_env = environment
	_base_fog_density = environment.fog_density
	world_root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.name = "StarlightSun"
	sun.rotation_degrees = Vector3(-48, -38, 0)
	sun.light_energy = 2.2
	sun.shadow_enabled = true
	world_root.add_child(sun)

	var fill := OmniLight3D.new()
	fill.name = "CrystalFillLight"
	fill.position = Vector3(0, 14, 0)
	fill.light_color = Color(0.45, 0.75, 1.0, 1)
	fill.light_energy = 1.1
	fill.omni_range = 95
	world_root.add_child(fill)

	streamer = WorldStreamer.new()
	streamer.name = "WorldStreamer"
	world_root.add_child(streamer)

	terrain_system = TerrainSystemScene.new()   # 草地山林 + 蒙德雪山（一片）
	terrain_system.name = "TerrainSystem"
	world_root.add_child(terrain_system)
	terrain_system.setup(self)

	_create_unlock_ring()

func _create_unlock_ring() -> void:
	var ring_mesh: TorusMesh = TorusMesh.new()
	ring_mesh.inner_radius = 0.985
	ring_mesh.outer_radius = 1.0
	unlock_ring = MeshInstance3D.new()
	unlock_ring.name = "WorldUnlockBoundary"
	unlock_ring.mesh = ring_mesh
	unlock_ring.rotation.x = PI / 2.0
	unlock_ring.position = Vector3(0, 0.10, 0)
	unlock_ring.material_override = _mat(Color(1.0, 0.70, 0.18, 0.64), 1.4, 0.64)
	world_root.add_child(unlock_ring)

func _update_unlock_ring() -> void:
	if unlock_ring == null or not is_instance_valid(unlock_ring):
		return
	var r: float = get_unlocked_radius()
	unlock_ring.scale = Vector3(r, r, r)
	unlock_ring.rotation.z += 0.006
	unlock_ring.visible = r < map_radius - 1.0

func _spawn_player() -> void:
	player = PlayerScene.new()
	player.name = "Player"
	player.main = self
	player.map_radius = map_radius
	player.global_position = Vector3(0, 0.05, 7.0)
	entity_root.add_child(player)

	camera = Camera3D.new()
	camera.name = "FollowCamera"
	camera.fov = 62.0
	camera.near = 0.05
	camera.far = 260.0
	camera.current = true
	add_child(camera)
	_update_camera(0.0)

func _spawn_monsters() -> void:
	# 固定刷怪点：散布全图，按上限持续重生；elite_chance 概率刷精英。
	var specs: Array[Dictionary] = [
		{"pos": Vector3(44, 0, 20), "kinds": ["slime"], "max": 5, "spread": 14.0, "respawn": 6.0, "elite_chance": 0.08},
		{"pos": Vector3(-44, 0, 20), "kinds": ["wolf"], "max": 4, "spread": 16.0, "respawn": 7.0, "elite_chance": 0.12},
		{"pos": Vector3(45, 0, -28), "kinds": ["mage", "archer"], "max": 4, "spread": 14.0, "respawn": 8.0, "elite_chance": 0.12},
		{"pos": Vector3(86, 0, 28), "kinds": ["slime", "wisp"], "max": 5, "spread": 18.0, "respawn": 7.0, "elite_chance": 0.14},
		{"pos": Vector3(-82, 0, 38), "kinds": ["wolf", "archer"], "max": 5, "spread": 18.0, "respawn": 7.0, "elite_chance": 0.16},
		{"pos": Vector3(82, 0, -76), "kinds": ["mage", "wisp"], "max": 5, "spread": 20.0, "respawn": 8.0, "elite_chance": 0.2},
		{"pos": Vector3(-40, 0, -55), "kinds": ["wolf", "wisp", "archer"], "max": 5, "spread": 20.0, "respawn": 8.0, "elite_chance": 0.22},
		{"pos": Vector3(40, 0, -100), "kinds": ["skyseraph"], "max": 5, "spread": 30.0, "respawn": 8.0, "elite_chance": 0.0},
		{"pos": Vector3(-95, 0, -70), "kinds": ["skyseraph"], "max": 4, "spread": 28.0, "respawn": 9.0, "elite_chance": 0.0},
		{"pos": Vector3(-120, 0, 40), "kinds": ["orbweaver", "lanewright", "veilcaller", "spiralmancer"], "max": 6, "spread": 30.0, "respawn": 9.0, "elite_chance": 0.0},
		{"pos": Vector3(110, 0, 60), "kinds": ["orbdrifter", "starcantor", "spiralmancer"], "max": 5, "spread": 28.0, "respawn": 9.0, "elite_chance": 0.0},
	]
	for spec: Dictionary in specs:
		spec["_timer"] = 0.0
		spec["_alive"] = [] as Array
		spawners.append(spec)
		# 初始填满一半，避免一开始空场。
		var initial: int = int(spec["max"]) / 2 + 1
		for i in range(initial):
			_spawner_spawn_one(spec)
		# 每个刷怪区中心放一个可击毁的「仇恨图腾」。
		_spawn_hate_totem((spec["pos"] as Vector3) + Vector3(0, 0.0, 0))
	# 关卡大Boss 不再固定预生成，改由升级闸门按需在玩家附近召唤（见 _update_gate）。

func _spawn_hate_totem(pos: Vector3) -> void:
	var t: StarGloryTotem = TotemScene.new()
	t.main = self
	t.global_position = pos
	entity_root.add_child(t)

func _spawner_spawn_one(spec: Dictionary) -> void:
	var kinds: Array = spec["kinds"]
	var kind: String = String(kinds[rng.randi_range(0, kinds.size() - 1)])
	var c: Vector3 = spec["pos"] as Vector3
	var spread: float = float(spec["spread"])
	var pos: Vector3 = c + Vector3(rng.randf_range(-spread, spread), 0.3, rng.randf_range(-spread, spread))
	# 世界等级越高，精英（必带技能、更强）出现率越高。
	var elite_chance: float = float(spec.get("elite_chance", 0.0)) + 0.05 * float(get_world_level() - 1)
	var make_elite: bool = rng.randf() < elite_chance
	if _live_monster_count(false) >= MAX_LOCAL_MONSTERS:
		return
	var m: StarGloryMonster = _spawn_monster(kind, pos, make_elite)
	if m != null:
		(spec["_alive"] as Array).append(m)

func _update_spawners(delta: float) -> void:
	for spec: Dictionary in spawners:
		var alive: Array = spec["_alive"]
		# 剔除已死/失效
		for i in range(alive.size() - 1, -1, -1):
			var m: Variant = alive[i]
			if m == null or not is_instance_valid(m) or (m as StarGloryMonster).dead:
				alive.remove_at(i)
		spec["_timer"] = float(spec["_timer"]) - delta
		if alive.size() < int(spec["max"]) and float(spec["_timer"]) <= 0.0:
			spec["_timer"] = float(spec["respawn"])
			_spawner_spawn_one(spec)

func _monster_data(kind: String) -> Dictionary:
	match kind:
		"slime":
			return {"kind": "slime", "name": "星尘史莱姆", "hp": 58, "attack": 9, "defense": 0, "speed": 3.0, "detect": 13.0, "range": 1.25, "interval": 1.25, "exp": 24, "rank": 1, "color": Color(0.95, 0.25, 0.55, 1)}
		"wolf":
			return {"kind": "wolf", "name": "影牙狼", "hp": 92, "attack": 14, "defense": 2, "speed": 5.0, "detect": 20.0, "range": 1.55, "interval": 1.05, "exp": 36, "rank": 2, "can_dash": true, "color": Color(0.42, 0.46, 0.62, 1)}
		"mage":
			return {"kind": "mage", "name": "秘法使魔", "hp": 76, "attack": 13, "defense": 1, "speed": 3.5, "detect": 22.0, "range": 7.5, "interval": 1.8, "exp": 42, "rank": 2, "ranged": true, "color": Color(0.42, 0.2, 0.85, 1)}
		"archer":
			return {"kind": "archer", "name": "流星游侠", "hp": 70, "attack": 15, "defense": 1, "speed": 4.2, "detect": 24.0, "range": 10.0, "interval": 1.5, "exp": 40, "rank": 2, "ranged": true, "color": Color(0.5, 0.78, 0.5, 1)}
		"wisp":
			return {"kind": "wisp", "name": "浮空幽光", "hp": 64, "attack": 12, "defense": 0, "speed": 4.6, "detect": 24.0, "range": 11.0, "interval": 1.6, "exp": 44, "rank": 2, "ranged": true, "flying": true, "hover": 2.4, "color": Color(0.45, 0.85, 1.0, 1)}
		"healer":
			return {"kind": "healer", "name": "魔灵奶妈", "hp": 120, "attack": 6, "defense": 1, "speed": 4.0, "detect": 18.0, "range": 2.0, "interval": 2.0, "exp": 50, "rank": 3, "healer": true, "color": Color(0.4, 1.0, 0.6, 1)}
		"skyseraph":
			return {"kind": "skyseraph", "name": "幻翼弹幕使", "hp": 320, "attack": 22, "defense": 2, "speed": 6.6, "detect": 32.0, "range": 17.0, "interval": 2.2, "exp": 130, "rank": 4, "ranged": true, "flying": true, "hover": 7.0, "caster": true, "barrage": true, "color": Color(0.92, 0.4, 1.0, 1)}
		"orbweaver":
			return {"kind": "orbweaver", "name": "织球妖", "hp": 190, "attack": 15, "defense": 2, "speed": 3.6, "detect": 28.0, "range": 16.0, "interval": 3.0, "exp": 92, "rank": 3, "ranged": true, "danmaku": ["charge_orb"], "color": Color(0.6, 0.35, 1.0, 1)}
		"lanewright":
			return {"kind": "lanewright", "name": "地脉炮手", "hp": 175, "attack": 14, "defense": 2, "speed": 3.4, "detect": 28.0, "range": 16.0, "interval": 2.6, "exp": 88, "rank": 3, "ranged": true, "danmaku": ["ground_lanes"], "color": Color(1.0, 0.55, 0.2, 1)}
		"veilcaller":
			return {"kind": "veilcaller", "name": "帷幕咏者", "hp": 180, "attack": 14, "defense": 2, "speed": 3.6, "detect": 28.0, "range": 16.0, "interval": 2.6, "exp": 90, "rank": 3, "ranged": true, "danmaku": ["curtain"], "color": Color(0.3, 0.9, 0.85, 1)}
		"orbdrifter":
			return {"kind": "orbdrifter", "name": "浮华光球", "hp": 155, "attack": 13, "defense": 1, "speed": 4.2, "detect": 26.0, "range": 14.0, "interval": 2.4, "exp": 84, "rank": 3, "ranged": true, "flying": true, "hover": 4.2, "danmaku": ["slow_orbs"], "color": Color(0.4, 0.9, 1.0, 1)}
		"spiralmancer":
			return {"kind": "spiralmancer", "name": "螺旋术士", "hp": 210, "attack": 16, "defense": 2, "speed": 3.6, "detect": 30.0, "range": 16.0, "interval": 2.8, "exp": 105, "rank": 4, "ranged": true, "caster": true, "danmaku": ["spiral", "laser_fan"], "color": Color(1.0, 0.4, 0.75, 1)}
		"starcantor":
			return {"kind": "starcantor", "name": "星咏者", "hp": 185, "attack": 15, "defense": 2, "speed": 4.0, "detect": 28.0, "range": 15.0, "interval": 2.4, "exp": 98, "rank": 4, "ranged": true, "flying": true, "hover": 5.2, "danmaku": ["star_rain"], "color": Color(1.0, 0.9, 0.4, 1)}
		"boss":
			return {"kind": "boss", "name": "荣耀守门人", "boss": true, "ultimate": 0, "hp": 820, "attack": 25, "defense": 5, "speed": 3.6, "detect": 28.0, "range": 2.5, "interval": 1.25, "exp": 240, "rank": 6, "danmaku": ["laser_web", "hollow_rings", "laser_fan"], "color": Color(0.62, 0.12, 0.10, 1)}
		"boss_storm":
			return {"kind": "boss_storm", "name": "雷霆领主", "boss": true, "ultimate": 1, "hp": 820, "attack": 25, "defense": 5, "speed": 3.6, "detect": 28.0, "range": 2.5, "interval": 1.25, "exp": 240, "rank": 6, "danmaku": ["cross_grid", "spiral", "star_rain"], "color": Color(0.35, 0.6, 1.0, 1)}
		"boss_warlord":
			return {"kind": "boss_warlord", "name": "军团统帅", "boss": true, "ultimate": 2, "hp": 820, "attack": 25, "defense": 5, "speed": 3.6, "detect": 28.0, "range": 2.5, "interval": 1.25, "exp": 240, "rank": 6, "danmaku": ["curved_arrows", "dome", "cage"], "color": Color(0.7, 0.5, 0.2, 1)}
		"boss_titan":
			return {"kind": "boss_titan", "name": "天罚巨像", "boss": true, "ultimate": 3, "hp": 820, "attack": 25, "defense": 5, "speed": 3.6, "detect": 28.0, "range": 2.5, "interval": 1.25, "exp": 240, "rank": 6, "danmaku": ["spiral", "hollow_rings", "laser_web", "curved_arrows", "cage", "laser_fan", "star_rain", "charge_orb", "ground_lanes", "curtain", "slow_orbs", "dome", "cross_grid"], "color": Color(0.8, 0.85, 1.0, 1)}
		_:
			return {"kind": "slime", "name": "未知魔物", "hp": 50, "attack": 8, "exp": 20, "rank": 1}

func _spawn_monster(kind: String, pos: Vector3, make_elite: bool = false, wl_override: int = -1, level_override: int = -1) -> StarGloryMonster:
	var monster: StarGloryMonster = MonsterScene.new()
	monster.name = "%s_%02d" % [kind.capitalize(), total_spawned]
	monster.main = self
	var data: Dictionary = _monster_data(kind)
	var rg: Dictionary = region_of(pos)
	var wl: int = wl_override if wl_override >= 0 else int(rg["tier"])   # 强度档位按区域固定
	data["world_level"] = wl
	# 区域固定怪物等级（在该区间随机；Boss 用更高一点的上限）。
	if bool(data.get("boss", false)):
		data["level"] = int(rg["lmax"]) + 2
	else:
		data["level"] = rng.randi_range(int(rg["lmin"]), int(rg["lmax"]))
	if level_override >= 0:
		data["level"] = level_override   # 守关副本 Boss：等级=突破关卡等级
	if make_elite:
		data["elite"] = true
		# 世界等级提高后，精英有概率获得「弱化版」究极技能。
		if wl >= 4 and rng.randf() < 0.30:
			data["ultimate"] = rng.randi() % 4
			data["weak_ult"] = true
	# 世界等级越高，带技能的怪物越多：非精英怪也有递增概率成为施法者（Boss/精英本就会放技能）。
	if not make_elite and not bool(data.get("boss", false)):
		var caster_chance: float = clampf(0.10 * float(wl - 1), 0.0, 0.6)
		if rng.randf() < caster_chance:
			data["caster"] = true
	monster.setup(data)
	var ty: float = terrain_height(pos.x, pos.z)   # 山地：抬到地表上方落下，避免卡进山体
	if ty > 0.1:
		pos.y = ty + 1.5
	monster.global_position = pos
	entity_root.add_child(monster)
	monsters.append(monster)
	total_spawned += 1
	return monster

func _spawn_buildings() -> void:
	# 代码生成几座炮塔便于测试；其 .tscn 也可在编辑器里直接拖进区块场景摆放。
	for pos: Vector3 in [Vector3(22, 0, -8), Vector3(-26, 0, 6), Vector3(58, 0, 40)]:
		var turret: StarGloryTurret = TurretScene.instantiate() as StarGloryTurret
		turret.main = self
		turret.world_level = get_world_level()
		turret.global_position = pos
		entity_root.add_child(turret)
	_spawn_resident_bosses()

# 在世界上摆若干「台子」做成常驻 Boss 领域；每 5 级解锁一个。
# 单机自己生成常驻 Boss；联机由服务器生成（客户端只建台子/屏障/门禁，Boss 走傀儡）。
func _spawn_resident_bosses() -> void:
	_build_resident_zones(not Net.online)

func _build_resident_zones(spawn_boss: bool) -> void:
	if not resident_zones.is_empty():
		return
	var defs: Array = [
		{"pos": Vector3(122, 0.3, 118), "radius": 22.0, "req": 5, "wl": 3, "kind": "boss"},
		{"pos": Vector3(-128, 0.3, 120), "radius": 24.0, "req": 10, "wl": 5, "kind": "boss_storm"},
		{"pos": Vector3(118, 0.3, -130), "radius": 26.0, "req": 15, "wl": 7, "kind": "boss_warlord"},
		{"pos": Vector3(-120, 0.3, -128), "radius": 28.0, "req": 20, "wl": 9, "kind": "boss_titan"},
	]
	for d: Dictionary in defs:
		var c: Vector3 = d["pos"]
		_build_platform(c, float(d["radius"]) * 0.55)
		var barrier: MeshInstance3D = _build_zone_barrier(c, float(d["radius"]))
		var z: Dictionary = {"center": c, "radius": float(d["radius"]), "req": int(d["req"]), "wl": int(d["wl"]), "kind": String(d["kind"]), "boss": null, "barrier": barrier, "respawn": 0.0}
		resident_zones.append(z)
		if spawn_boss:
			_spawn_zone_boss(z)

func _spawn_zone_boss(z: Dictionary) -> void:
	var b: StarGloryMonster = _spawn_monster(String(z.get("kind", "boss")), (z["center"] as Vector3) + Vector3(0, 0.3, 0), false, int(z["wl"]))
	b.resident = true
	b.monster_name = "常驻·" + b.monster_name
	z["boss"] = b
	z["respawn"] = 0.0

func _build_platform(center: Vector3, radius: float) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius * 1.06
	mesh.height = 0.6
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat(Color(0.22, 0.2, 0.28, 1), 0.0)
	mi.position = center + Vector3(0, 0.3, 0)
	world_root.add_child(mi)
	# 实体碰撞：玩家可站上去。
	var body := StaticBody3D.new()
	body.position = center + Vector3(0, 0.3, 0)
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = 0.6
	shape.shape = cyl
	body.add_child(shape)
	world_root.add_child(body)

func _build_zone_barrier(center: Vector3, radius: float) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 32
	mesh.rings = 16
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.12, 0.14, 0.82)   # 较不透明：从外看不见里面
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.9, 0.2, 0.2, 1)
	mat.emission_energy_multiplier = 0.5
	mi.mesh.material = mat
	mi.position = center + Vector3(0, radius * 0.5, 0)
	world_root.add_child(mi)
	return mi

var _conn_lost_handled: bool = false
# 心跳超时/断线：提示并返回登录菜单。
func _on_connection_lost() -> void:
	if _conn_lost_handled:
		return
	_conn_lost_handled = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)   # 恢复鼠标，避免回菜单后不显示光标
	flash_message("与服务器失去连接，正在返回菜单…")
	get_tree().create_timer(1.5).timeout.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/Menu.tscn"))

# 每帧：常驻Boss重生 + 领域屏障显隐 + 未解锁强入惩罚。
func _update_zones(delta: float) -> void:
	if in_dungeon:
		return   # 副本内不跑大世界领域逻辑
	if player == null or not is_instance_valid(player) or player.hp <= 0.0:
		if player != null and is_instance_valid(player):
			player.zone_blocked = false
		return
	var blocked: bool = false
	for z: Dictionary in resident_zones:
		# 常驻 Boss 重生只在单机本地处理（联机由服务器生成傀儡）。
		if not Net.online:
			var boss: StarGloryMonster = z["boss"]
			if boss == null or not is_instance_valid(boss) or boss.dead:
				z["respawn"] = float(z["respawn"]) - delta
				if float(z["respawn"]) <= 0.0:
					_spawn_zone_boss(z)
		var locked: bool = player.level < int(z["req"])
		var barrier: MeshInstance3D = z["barrier"]
		if barrier != null and is_instance_valid(barrier):
			barrier.visible = locked
		var to: Vector3 = player.global_position - (z["center"] as Vector3)
		to.y = 0.0
		var d: float = to.length()
		if locked and d < float(z["radius"]):
			blocked = true
			player.hp = max(0.0, player.hp - ZONE_DRAIN * delta)
			var out: Vector3 = to.normalized() if d > 0.2 else Vector3(0, 0, 1)
			player.global_position += out * ZONE_PUSH * delta
			if boundary_notice_timer <= 0.0:
				boundary_notice_timer = 1.2
				flash_message("禁制领域：需达到 Lv.%d 才能进入（当前 Lv.%d）！" % [int(z["req"]), player.level])
	player.zone_blocked = blocked

# ---------------- 联机：在线世界编排 ----------------

func _net_setup() -> void:
	# 本地玩家：把引用交给网络层用于上报状态。怪物与世界解锁由服务器驱动。
	Net.local_player = player
	if not Net.connection_lost.is_connected(_on_connection_lost):
		Net.connection_lost.connect(_on_connection_lost)
	unlock_stage = Net.world_stage
	unlocked_world_radius = Net.world_radius
	region_size = float(GameData.world.get("region_size", 64.0))
	_last_safe_pos = player.global_position if player != null else Vector3.ZERO
	# 联机：常驻 Boss 由服务器生成（傀儡渲染）；客户端只建台子/屏障/门禁。
	_build_resident_zones(false)

func _net_process(delta: float) -> void:
	# 世界解锁进度（全局共享，服务器权威）
	unlock_stage = Net.world_stage
	unlocked_world_radius = Net.world_radius
	_net_region_update()
	# 本地玩家受到的怪物伤害结算（服务器把命中下发到这里）
	if Net.pending_player_damage > 0 and player != null and is_instance_valid(player):
		var dmg: int = Net.pending_player_damage
		Net.pending_player_damage = 0
		if player.hp > 0.0:
			player.take_damage(dmg, null)
	# 离开 AOI 的玩家：移除其傀儡（须在对账前，避免刚移除又被重建）。
	while not Net.player_despawn_queue.is_empty():
		_despawn_net_player(int(Net.player_despawn_queue.pop_front()))
	_reconcile_net_players()
	# 先结算死亡（带飘字/掉落），再对账存活怪物，避免重复释放。
	while not Net.death_queue.is_empty():
		on_net_monster_died(Net.death_queue.pop_front() as Dictionary)
	# 离开 AOI 的怪物：移除其傀儡。
	while not Net.monster_despawn_queue.is_empty():
		_despawn_net_monster(int(Net.monster_despawn_queue.pop_front()))
	_reconcile_net_monsters()
	# 其他玩家施法表现
	while not Net.cast_queue.is_empty():
		_play_remote_cast(Net.cast_queue.pop_front() as Dictionary)
	# 服务器权威控制本地玩家：浮空 + 眩晕（on_landing 则落地后眩晕）。
	while not Net.player_control_queue.is_empty():
		var ce: Dictionary = Net.player_control_queue.pop_front()
		if player != null and is_instance_valid(player):
			if float(ce.get("launch", 0.0)) > 0.0:
				player.apply_forced_knockback(ce.get("from", player.global_position), float(ce.get("launch", 0.0)), float(ce.get("vertical", 5.0)), 0.2)
			if player.buff != null:
				var stun: float = float(ce.get("stun", 0.0))
				if stun > 0.0:
					if bool(ce.get("on_landing", false)):
						player.buff.queue_stun_on_landing(stun)
					else:
						player.buff.apply_stun(stun)
				var sp: float = float(ce.get("slow_power", 0.0))
				if sp > 0.0:
					player.buff.apply_slow(sp, float(ce.get("slow_dur", 1.0)))
	# 聊天消息 + 队伍更新。
	while not Net.chat_queue.is_empty():
		var cm: Dictionary = Net.chat_queue.pop_front()
		_append_chat(String(cm.get("channel", "public")), String(cm.get("from", "")), String(cm.get("text", "")), String(cm.get("avatar", "")))
	if Net.party_dirty:
		Net.party_dirty = false
		_refresh_party_tab()
	if Net.admin_dirty:
		Net.admin_dirty = false
		_refresh_admin_panel()
		if Net.admin_level > 0:
			flash_message("[GM] 管理员已登录（等级 %d）。靠近操作台按 E 打开。" % Net.admin_level)
	if Net.admin_players_dirty:
		Net.admin_players_dirty = false
		_refresh_admin_players()
	while not Net.outpost_queue.is_empty():
		var ov: Array = Net.outpost_queue.pop_front()
		if outpost_system != null:
			outpost_system.apply_server_state(ov)
		var mr: int = 0
		for op_v: Variant in ov:
			mr = maxi(mr, int((op_v as Dictionary).get("reinforce", 0)))
		safe_zone_reinforce = mr   # 供无人机等级上限用
	_update_world_nodes()
	if Net.leaderboard_dirty:
		Net.leaderboard_dirty = false
		_refresh_leaderboard()
	while not Net.rewards_queue.is_empty():
		_grant_rewards(Net.rewards_queue.pop_front())
	while not Net.dungeon_queue.is_empty():
		var dv: Dictionary = Net.dungeon_queue.pop_front()
		var dinfo: Dictionary = dv.get("info", {}) as Dictionary
		match String(dv.get("state", "")):
			"enter": _enter_dungeon(dinfo)
			"leave": _leave_dungeon(dinfo)
			"confirm":
				_pending_dungeon_id = int(dinfo.get("id", 0))
				if dungeon_enter_label != null:
					dungeon_enter_label.text = "开启副本「%s」？\n准入记录范围 Lv.%d–%d。\n\n%s\n\n确认后将带领全体在线队员进入。" % [
						String(dinfo.get("name", "副本")), int(dinfo.get("lo", 1)), int(dinfo.get("hi", 1)),
						String(dinfo.get("summary", ""))]
				if dungeon_enter_panel != null:
					dungeon_enter_panel.visible = true
			"cleared":
				# 联机：Boss 已死 → 生成结算传送门，走进按 E 结算（与单机一致）。
				_mp_clear_info = dinfo
				_spawn_dungeon_portal(_dungeon_spawn_pos + Vector3(0, 0, -12))
				flash_message("⚔ 守关 Boss 已击败！走入传送门按 E 结算并突破。")
	while not Net.admin_console_queue.is_empty():
		var ac: Dictionary = Net.admin_console_queue.pop_front()
		match String(ac.get("state", "")):
			"grant":
				_open_admin_panel()
			"deny":
				flash_message("操作台正被「%s」使用，权限不足无法抢占。" % String(ac.get("who", "")))
			"kicked":
				admin_panel_open = false   # 服务器已转交，仅本地收起，不再回发 close
				if admin_panel != null:
					admin_panel.visible = false
				flash_message("操作台被「%s」抢占。" % String(ac.get("who", "")))
	# Boss 连招表现：派发给对应 Boss 傀儡播放（标记/虚影/冲击；位移由快照驱动）。
	while not Net.monster_combo_queue.is_empty():
		var cev: Dictionary = Net.monster_combo_queue.pop_front()
		var bm: StarGloryMonster = net_monsters.get(int(cev.get("mid", 0)), null) as StarGloryMonster
		if bm != null and is_instance_valid(bm) and bm.has_method("play_combo_visual"):
			bm.play_combo_visual(cev.get("info", {}) as Dictionary)
	# 他人造成的伤害飘字
	while not Net.damage_queue.is_empty():
		var dinfo: Dictionary = Net.damage_queue.pop_front()
		flash_damage((dinfo.get("pos", Vector3.ZERO) as Vector3) + Vector3(0, 1.2, 0), str(int(dinfo.get("amount", 0))), Color(0.95, 0.85, 0.55, 1))
	# 怪物出手表现
	while not Net.action_queue.is_empty():
		var act: Dictionary = Net.action_queue.pop_front()
		var am: StarGloryMonster = net_monsters.get(int(act.get("mid", 0)), null) as StarGloryMonster
		if am != null and is_instance_valid(am) and am.has_method("net_play_attack"):
			am.net_play_attack()
	# 掉落物被拾取/过期
	while not Net.drop_taken_queue.is_empty():
		_on_net_drop_taken(Net.drop_taken_queue.pop_front() as Dictionary)

func _reconcile_net_players() -> void:
	for id: int in Net.players_state.keys():
		if id == Net.my_id:
			continue
		var s: Dictionary = Net.players_state[id]
		var pup: StarGloryPlayer = net_players.get(id, null) as StarGloryPlayer
		if pup == null or not is_instance_valid(pup):
			pup = PlayerScene.new()
			pup.is_puppet = true
			pup.display_name = String(Net.roster.get(id, "玩家"))
			pup.main = self
			pup.map_radius = map_radius
			pup.global_position = s.get("pos", Vector3.ZERO)
			entity_root.add_child(pup)
			net_players[id] = pup
		var ppos: Vector3 = s.get("pos", pup.global_position)
		var pty: float = terrain_height(ppos.x, ppos.z)
		if pty > 0.1 and ppos.y < pty:
			ppos.y = pty
		pup.net_set_target(ppos)
		pup.net_yaw = float(s.get("yaw", 0.0))
		pup.hp = float(s.get("hp", pup.hp))
		pup.max_hp = int(s.get("max_hp", pup.max_hp))
		pup.mp = float(s.get("mp", pup.mp))
		pup.max_mp = int(s.get("max_mp", pup.max_mp))
		pup.stamina = float(s.get("st", pup.stamina))
		pup.max_stamina = int(s.get("max_st", pup.max_stamina))
		pup.level = int(s.get("level", pup.level))
		pup.set_puppet_flying(bool(s.get("flying", false)))
	# 移除已离线玩家（AOI 离开由 _despawn_net_player 处理；此处兜底彻底离线者）
	for id: int in net_players.keys():
		if not Net.roster.has(id):
			var pup: Node = net_players[id]
			net_players.erase(id)
			if is_instance_valid(pup):
				pup.queue_free()

# 玩家离开本端 AOI：移除傀儡（仍在线，只是超出可见范围；重新进入会再次流式创建）。
func _despawn_net_player(id: int) -> void:
	var pup: Node = net_players.get(id, null)
	if pup != null:
		net_players.erase(id)
		if is_instance_valid(pup):
			pup.queue_free()

# 怪物离开本端 AOI：移除傀儡。
func _despawn_net_monster(id: int) -> void:
	var m: Node = net_monsters.get(id, null)
	if m != null:
		net_monsters.erase(id)
		monsters.erase(m)
		if is_instance_valid(m):
			m.queue_free()

func _reconcile_net_monsters() -> void:
	# 创建服务器已声明但本地还没有的怪物傀儡
	for id: int in Net.monster_defs.keys():
		if net_monsters.has(id) and is_instance_valid(net_monsters[id]):
			continue
		var def: Dictionary = Net.monster_defs[id]
		var m: StarGloryMonster = MonsterScene.new()
		m.main = self
		m.name = "NetMonster_%d" % id
		m.setup_puppet(def)
		var st: Variant = Net.monsters_state.get(id, null)
		var spawn_pos: Vector3 = (st as Dictionary).get("pos", Vector3.ZERO) if st != null else def.get("pos", Vector3.ZERO)
		m.global_position = spawn_pos
		entity_root.add_child(m)
		net_monsters[id] = m
		monsters.append(m)
	# 用最新快照更新位置/血量
	for id: int in Net.monsters_state.keys():
		var m: StarGloryMonster = net_monsters.get(id, null) as StarGloryMonster
		if m == null or not is_instance_valid(m):
			continue
		var st: Dictionary = Net.monsters_state[id]
		var mpos: Vector3 = st.get("pos", m.global_position)
		var mty: float = terrain_height(mpos.x, mpos.z)   # 服务器无地形：傀儡贴到本地地表
		if mty > 0.1:
			mpos.y = mty + (m.hover_height if m.flying else 0.0)   # 飞行怪悬停于地表之上
		m.net_set_target(mpos)
		m.hp = float(st.get("hp", m.hp))
	# 清理服务器已移除（定义消失）的孤儿
	for id: int in net_monsters.keys():
		if not Net.monster_defs.has(id):
			var m: Node = net_monsters[id]
			net_monsters.erase(id)
			monsters.erase(m)
			if is_instance_valid(m):
				m.queue_free()

func on_net_monster_died(info: Dictionary) -> void:
	var id: int = int(info.get("id", 0))
	var pos: Vector3 = info.get("pos", Vector3.ZERO)
	var expired: bool = bool(info.get("expired", false))
	var is_boss_m: bool = bool(info.get("boss", false))
	var m: StarGloryMonster = net_monsters.get(id, null) as StarGloryMonster
	if not expired:
		if is_boss_m:
			boss_defeated = true
			flash_message("胜利：荣耀守门人已被击败！全域大世界即将解锁。")
		else:
			kills += 1
	spawn_skill_flash(pos + Vector3(0, 0.8, 0), Color(1.0, 0.7, 0.3, 1), 1.8, 0.4)
	# 经验归击杀者；掉落物由服务器统一决定并对所有人可见（共享世界）。
	if not expired and int(info.get("killer", 0)) == Net.my_id and player != null and is_instance_valid(player):
		player.gain_exp(int(info.get("exp", 0)))
		flash_message("击败 %s，获得 %d EXP" % [String(info.get("name", "魔物")), int(info.get("exp", 0))])
		if quest_system != null:
			quest_system.on_kill(is_boss_m)   # 任务:击杀计数（仅本地击杀）
		if achievement_system != null:
			achievement_system.on_kill(is_boss_m)
		if is_boss_m:
			_pet_boss_roll()
	for desc_v: Variant in info.get("drops", []):
		_spawn_net_drop(desc_v as Dictionary)
	if m != null:
		net_monsters.erase(id)
		monsters.erase(m)
		if is_instance_valid(m):
			m.queue_free()

# 播放其他玩家的施法表现：动作 pose + 在本地纯表现复现整套技能特效（含弹道/陨石/火雨），
# 不重复造成伤害（伤害由施法者本地结算并上报服务器）。
func _play_remote_cast(info: Dictionary) -> void:
	var cid: int = int(info.get("caster", 0))
	var pup: StarGloryPlayer = net_players.get(cid, null) as StarGloryPlayer
	if pup == null or not is_instance_valid(pup):
		return
	var sid: String = String(info.get("skill_id", ""))
	var dir: Vector3 = info.get("dir", Vector3(0, 0, -1))
	var level: int = int(info.get("level", 0))
	var tgt: Vector3 = info.get("pos", Vector3.ZERO)   # 落点型技能（天星/火焰雨）同步过来的真实落点
	var pose: String = String(_SKILL_POSE.get(sid, ""))
	if pup.anim != null and pose != "":
		pup.anim.play_pose(pose, 0.6)
	if skills != null:
		skills.cast_remote(pup, sid, dir, level, tgt)

# 区域热更新：刷新屏障、消费强制弹出、阻止进入锁定区域。
func _net_region_update() -> void:
	if Net.region_locks_dirty:
		Net.region_locks_dirty = false
		_rebuild_region_barriers()
	if player == null or not is_instance_valid(player):
		return
	# 服务器强制弹出
	if Net.force_pos != null:
		player.global_position = Net.force_pos
		player.velocity = Vector3.ZERO
		_last_safe_pos = player.global_position
		Net.force_pos = null
		flash_message("该区域正在更新维护，你已被移动到附近的安全区域。")
		return
	# 本地禁入锁定区域：踏入则拉回上一安全位置（形成无形墙）
	if _is_region_locked(player.global_position):
		player.global_position = _last_safe_pos
		player.velocity.x = 0.0
		player.velocity.z = 0.0
		if boundary_notice_timer <= 0.0:
			boundary_notice_timer = 1.25
			flash_message("前方区域正在更新维护，暂不可进入。")
	else:
		_last_safe_pos = player.global_position

func _region_of(p: Vector3) -> String:
	return "%d_%d" % [floori(p.x / region_size), floori(p.z / region_size)]

func _is_region_locked(p: Vector3) -> bool:
	return Net.region_locks.has(_region_of(p))

func _rebuild_region_barriers() -> void:
	for rid: Variant in region_barriers.keys():
		var n: Node = region_barriers[rid]
		if is_instance_valid(n):
			n.queue_free()
	region_barriers.clear()
	for rid_v: Variant in Net.region_locks:
		var rid: String = String(rid_v)
		var parts: PackedStringArray = rid.split("_")
		if parts.size() != 2:
			continue
		var cx: int = int(parts[0])
		var cz: int = int(parts[1])
		var center: Vector3 = Vector3((float(cx) + 0.5) * region_size, 9.0, (float(cz) + 0.5) * region_size)
		var mesh := BoxMesh.new()
		mesh.size = Vector3(region_size, 18.0, region_size)
		var mi := MeshInstance3D.new()
		mi.name = "RegionBarrier_%s" % rid
		mi.mesh = mesh
		mi.position = center
		mi.material_override = _mat(Color(0.92, 0.22, 0.22, 0.15), 0.7, 0.15)
		effect_root.add_child(mi)
		region_barriers[rid] = mi

# 按服务器下发的掉落描述生成共享掉落物（所有人可见、内容一致）。
func _spawn_net_drop(desc: Dictionary) -> void:
	var did: int = int(desc.get("id", 0))
	if did <= 0 or net_drops.has(did):
		return
	var dpos: Vector3 = desc.get("pos", Vector3.ZERO)
	var item: Dictionary
	var dkind: String = String(desc.get("kind", "equipment"))
	if dkind == "skillbook":
		item = skills.make_book_item(String(desc.get("skill_id", "")), int(desc.get("tier", 1)))
	elif dkind == "potion":
		item = _make_potion_item(String(desc.get("ptype", "vit")))
	elif dkind == "magnet":
		item = {"kind": "magnet", "name": "星辰磁石", "color": Color(0.95, 0.30, 0.30, 1)}
	elif dkind == "scroll":
		item = _make_scroll_item()
	elif dkind == "material":
		var mat_name: String = String(desc.get("mat", desc.get("name", "")))
		var col: Color = Color(0.95, 0.85, 0.45, 1) if mat_name == "防御卷轴" else Color(0.7, 0.25, 1.0, 1)
		item = _make_material_item(mat_name, col, int(desc.get("amount", 1)))
	else:
		# 联机装备掉落：吸血装(ls)→主/副武器，否则随机非武器（吸血只 Boss 掉，与单机一致）。
		var tier: int = clampi(int(desc.get("tier", 1)), 1, 4)
		var gen: Dictionary = inv.gen_weapon(tier) if bool(desc.get("ls", false)) else inv.gen_random(tier)
		item = _make_equipment_item(String(gen["etype"]), int(gen["tier"]))
	var pickup: StarGloryPickup = equipment.make_pickup(dpos, item, did)
	net_drops[did] = pickup

# 掉落物被某人拾取或过期：所有人移除；若拾取者是我，则把物品穿戴/入库。
func _on_net_drop_taken(info: Dictionary) -> void:
	var did: int = int(info.get("id", 0))
	var taker: int = int(info.get("taker", 0))
	var pickup: StarGloryPickup = net_drops.get(did, null) as StarGloryPickup
	if pickup == null:
		return
	net_drops.erase(did)
	pickups.erase(pickup)
	if taker == Net.my_id and is_instance_valid(pickup) and player != null:
		_apply_collected_item(pickup.item_data)
	if is_instance_valid(pickup):
		pickup.queue_free()

func _build_ui() -> void:
	ui_layer = CanvasLayer.new()
	ui_layer.name = "HUD"
	add_child(ui_layer)
	_build_vignette()

	var panel := ColorRect.new()
	panel.color = Color(0.02, 0.025, 0.055, 0.78)
	panel.position = Vector2(14, 12)
	panel.size = Vector2(376, 224)
	ui_layer.add_child(panel)

	hud_label = RichTextLabel.new()
	hud_label.bbcode_enabled = true
	hud_label.fit_content = false
	hud_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hud_label.position = Vector2(24, 20)
	hud_label.size = Vector2(352, 208)
	hud_label.scroll_active = false
	ui_layer.add_child(hud_label)

	# 任务/技能 合并 Tab 面板（原技能详情框位置，可收缩）。
	hud_tab_btn_quest = Button.new()
	hud_tab_btn_quest.text = "任务详情"
	hud_tab_btn_quest.position = Vector2(14, 244)
	hud_tab_btn_quest.size = Vector2(118, 28)
	hud_tab_btn_quest.add_theme_font_size_override("font_size", 14)
	hud_tab_btn_quest.pressed.connect(func() -> void: _set_hud_tab(0))
	ui_layer.add_child(hud_tab_btn_quest)

	hud_tab_btn_skill = Button.new()
	hud_tab_btn_skill.text = "技能详情"
	hud_tab_btn_skill.position = Vector2(136, 244)
	hud_tab_btn_skill.size = Vector2(118, 28)
	hud_tab_btn_skill.add_theme_font_size_override("font_size", 14)
	hud_tab_btn_skill.pressed.connect(func() -> void: _set_hud_tab(1))
	ui_layer.add_child(hud_tab_btn_skill)

	hud_tab_collapse = Button.new()
	hud_tab_collapse.text = "收起 ▲"
	hud_tab_collapse.position = Vector2(300, 244)
	hud_tab_collapse.size = Vector2(90, 28)
	hud_tab_collapse.add_theme_font_size_override("font_size", 13)
	hud_tab_collapse.pressed.connect(_toggle_hud_collapse)
	ui_layer.add_child(hud_tab_collapse)

	hud_tab_bg = ColorRect.new()
	hud_tab_bg.color = Color(0.02, 0.025, 0.055, 0.78)
	hud_tab_bg.position = Vector2(14, 274)
	hud_tab_bg.size = Vector2(376, 152)
	ui_layer.add_child(hud_tab_bg)

	hud_tab_scroll = ScrollContainer.new()
	hud_tab_scroll.position = Vector2(18, 278)
	hud_tab_scroll.size = Vector2(368, 144)
	hud_tab_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	ui_layer.add_child(hud_tab_scroll)

	hud_tab_vbox = VBoxContainer.new()
	hud_tab_vbox.custom_minimum_size = Vector2(348, 0)
	hud_tab_vbox.add_theme_constant_override("separation", 3)
	hud_tab_scroll.add_child(hud_tab_vbox)
	_hud_tab_refresh()

	equip_panel = ColorRect.new()
	equip_panel.color = Color(0.02, 0.025, 0.055, 0.78)
	equip_panel.position = Vector2(14, 434)
	equip_panel.size = Vector2(376, 122)
	ui_layer.add_child(equip_panel)

	equip_label = Label.new()
	equip_label.position = Vector2(24, 442)
	equip_label.size = Vector2(350, 102)
	equip_label.add_theme_font_size_override("font_size", 15)
	equip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ui_layer.add_child(equip_label)

	message_label = Label.new()
	message_label.position = Vector2(420, 112)
	message_label.size = Vector2(640, 42)
	message_label.add_theme_font_size_override("font_size", 19)
	message_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.45, 1))
	ui_layer.add_child(message_label)

	_build_compass()

	help_label = Label.new()
	help_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	help_label.offset_left = 20
	help_label.offset_right = -20
	help_label.offset_top = -78
	help_label.offset_bottom = -8
	help_label.text = "WASD移动 | Shift奔跑 | Space跳跃 | 右键拖镜头 | V视角 | 左键/1星斩(地面自动索敌,空中变速射) 2焰弹 3霜环 4闪现 5天星 6火焰雨 | 掉落自动拾取 | E交互 | J任务 K成就 O宠物 T宠物技 L贡献榜 G无人机 | B背包 | P档案/排行 | ZXC药剂 | Q御云 Y妖兽令 | M大地图(点图设导航/点小地图开关) | 阵亡后使用死亡面板复活"
	help_label.add_theme_font_size_override("font_size", 15)
	help_label.add_theme_color_override("font_color", Color(0.78, 0.86, 1.0, 1))
	help_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ui_layer.add_child(help_label)

	_build_skill_hotbar()

	mini_map = MapViewScene.new()
	mini_map.name = "MiniMap"
	mini_map.main = self
	mini_map.big = false
	# 锚定到屏幕右上角（适配安卓宽屏：expand 拉伸下绝对坐标会漂到中间）。
	mini_map.anchor_left = 1.0
	mini_map.anchor_right = 1.0
	mini_map.anchor_top = 0.0
	mini_map.anchor_bottom = 0.0
	mini_map.offset_left = -216.0
	mini_map.offset_right = -16.0
	mini_map.offset_top = 16.0
	mini_map.offset_bottom = 216.0
	ui_layer.add_child(mini_map)

	big_map = MapViewScene.new()
	big_map.name = "BigMap"
	big_map.main = self
	big_map.big = true
	big_map.position = Vector2(330, 92)
	big_map.size = Vector2(620, 520)
	big_map.visible = false
	ui_layer.add_child(big_map)

	_build_backpack()
	_build_death_panel()
	_build_profile_panel()
	_build_pause_menu()
	_build_quick_items()
	_build_chat()
	if Net.online:
		_build_admin_console()
		_build_admin_panel()
	_build_dungeon_entrances()   # 单机/联机都有副本入口
	_build_dungeon_ui()
	outpost_system = OutpostSystemScene.new()   # 安全区/攻城（单机/联机都有）
	add_child(outpost_system)
	outpost_system.setup(self)
	shelter_system = ShelterSystemScene.new()   # 个人庇护所
	add_child(shelter_system)
	shelter_system.setup(self)
	quest_system = QuestSystemScene.new()       # 任务系统
	add_child(quest_system)
	quest_system.setup(self)
	achievement_system = AchievementSystemScene.new()   # 成就系统
	add_child(achievement_system)
	achievement_system.setup(self)
	pet_system = PetSystemScene.new()                   # 宠物系统
	add_child(pet_system)
	pet_system.setup(self)
	drone_system = DroneSystemScene.new()               # 无人机系统
	add_child(drone_system)
	drone_system.setup(self)
	if _is_mobile():
		_build_touch_controls()   # 手机端始终构建触屏控件（单机/联机都要）
		_apply_mobile_layout()    # 手机端 HUD 重排，避免控件互相遮挡

	# 炮塔弹种固定为「各炮塔自身随机」（forced_bullet_type 保持 ""）；选择 UI 已隐藏不显示。

func _build_skill_hotbar() -> void:
	hotbar_root = Control.new()
	hotbar_root.name = "SkillHotbar"
	hotbar_root.position = Vector2(390, 560)
	hotbar_root.size = Vector2(595, 92)
	hotbar_root.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 放行触摸：技能格点击由 _handle_touch 命中处理
	ui_layer.add_child(hotbar_root)
	for i: int in range(SkillManager.ORDER.size()):
		_make_hotbar_slot(SkillManager.ORDER[i], i)
	_make_special_slot("cloud", SkillManager.ORDER.size(), "☁", "7", "御云")

func _make_hotbar_slot(skill_id: String, index: int) -> void:
	if player == null:
		return
	var meta: Dictionary = skills.get_skill_meta(skill_id)
	var slot: ColorRect = ColorRect.new()
	slot.name = "Slot_%s" % skill_id
	slot.position = Vector2(float(index) * 92.0, 0)
	slot.size = Vector2(78, 78)
	slot.color = Color(0.035, 0.045, 0.085, 0.88)
	hotbar_root.add_child(slot)

	var border: ColorRect = ColorRect.new()
	border.name = "Border"
	border.position = Vector2(-2, -2)
	border.size = Vector2(82, 82)
	border.color = Color(0.35, 0.75, 1.0, 0.30)
	slot.add_child(border)
	slot.move_child(border, 0)

	var icon: Label = Label.new()
	icon.name = "Icon"
	icon.position = Vector2(0, 12)
	icon.size = Vector2(78, 34)
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.text = skills.get_icon(skill_id)
	icon.add_theme_font_size_override("font_size", 27)
	icon.add_theme_color_override("font_color", Color(0.92, 0.98, 1.0, 1))
	slot.add_child(icon)

	var key_label: Label = Label.new()
	key_label.name = "Key"
	key_label.position = Vector2(5, 3)
	key_label.size = Vector2(28, 22)
	key_label.text = String(meta.get("key", "?"))
	key_label.add_theme_font_size_override("font_size", 16)
	key_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.36, 1))
	slot.add_child(key_label)

	var name_label: Label = Label.new()
	name_label.name = "Name"
	name_label.position = Vector2(0, 52)
	name_label.size = Vector2(78, 18)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.text = String(meta.get("name", skill_id))
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.add_theme_color_override("font_color", Color(0.82, 0.92, 1.0, 1))
	slot.add_child(name_label)

	var overlay: ColorRect = ColorRect.new()
	overlay.name = "CooldownOverlay"
	overlay.position = Vector2.ZERO
	overlay.size = Vector2(78, 0)
	overlay.color = Color(0.0, 0.0, 0.0, 0.55)
	slot.add_child(overlay)

	var cd_label: Label = Label.new()
	cd_label.name = "CooldownText"
	cd_label.position = Vector2(0, 22)
	cd_label.size = Vector2(78, 28)
	cd_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cd_label.add_theme_font_size_override("font_size", 18)
	cd_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.48, 1))
	slot.add_child(cd_label)

	skill_slots[skill_id] = {"root": slot, "overlay": overlay, "cd_label": cd_label, "border": border, "name": name_label}
	_make_hotbar_tappable(slot)

# 非战斗技能（如御云飞行）的热键格：固定图标/键位/名称，按激活状态高亮。
func _make_special_slot(skill_id: String, index: int, icon_text: String, key_text: String, name_text: String) -> void:
	var slot: ColorRect = ColorRect.new()
	slot.name = "Slot_%s" % skill_id
	slot.position = Vector2(float(index) * 92.0, 0)
	slot.size = Vector2(78, 78)
	slot.color = Color(0.035, 0.045, 0.085, 0.88)
	hotbar_root.add_child(slot)

	var border: ColorRect = ColorRect.new()
	border.name = "Border"
	border.position = Vector2(-2, -2)
	border.size = Vector2(82, 82)
	border.color = Color(0.35, 0.75, 1.0, 0.30)
	slot.add_child(border)
	slot.move_child(border, 0)

	var icon: Label = Label.new()
	icon.position = Vector2(0, 12)
	icon.size = Vector2(78, 34)
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.text = icon_text
	icon.add_theme_font_size_override("font_size", 27)
	icon.add_theme_color_override("font_color", Color(0.92, 0.98, 1.0, 1))
	slot.add_child(icon)

	var key_label: Label = Label.new()
	key_label.position = Vector2(5, 3)
	key_label.size = Vector2(28, 22)
	key_label.text = key_text
	key_label.add_theme_font_size_override("font_size", 16)
	key_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.36, 1))
	slot.add_child(key_label)

	var name_label: Label = Label.new()
	name_label.position = Vector2(0, 52)
	name_label.size = Vector2(78, 18)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.text = name_text
	name_label.add_theme_font_size_override("font_size", 13)
	name_label.add_theme_color_override("font_color", Color(0.82, 0.92, 1.0, 1))
	slot.add_child(name_label)

	skill_slots[skill_id] = {"special": true, "border": border, "root": slot}
	_make_hotbar_tappable(slot)

# 让热键格不拦截原始触摸（手机端由 _touch_begin 命中测试），仅作显示。
func _make_hotbar_tappable(slot: Control) -> void:
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in slot.get_children():
		if c is Control:
			(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE

func _update_skill_hotbar() -> void:
	if player == null:
		return
	for skill_id: String in skill_slots.keys():
		var slot_data: Dictionary = skill_slots[skill_id] as Dictionary
		if slot_data.get("special", false):
			# 御云：激活中高亮青色，否则常态。
			var b: ColorRect = slot_data["border"] as ColorRect
			b.color = Color(0.4, 1.0, 0.85, 0.85) if (skill_id == "cloud" and player.flying_cloud) else Color(0.35, 0.65, 0.9, 0.35)
			continue
		var overlay: ColorRect = slot_data["overlay"] as ColorRect
		var cd_label: Label = slot_data["cd_label"] as Label
		var border: ColorRect = slot_data["border"] as ColorRect
		var meta: Dictionary = skills.get_skill_meta(skill_id)
		var cd: float = float(player.cooldowns.get(skill_id, 0.0))
		var max_cd: float = max(0.01, float(meta.get("cooldown", 1.0)))
		var ratio: float = clamp(cd / max_cd, 0.0, 1.0)
		overlay.position.y = 78.0 * (1.0 - ratio)
		overlay.size.y = 78.0 * ratio
		cd_label.text = "%.1f" % cd if cd > 0.05 else ""
		var enough_mp: bool = player.mp >= float(meta.get("mp", 0.0))
		if cd <= 0.05 and enough_mp:
			border.color = Color(0.35, 0.95, 1.0, 0.60)
		elif not enough_mp:
			border.color = Color(0.7, 0.25, 0.35, 0.42)
		else:
			border.color = Color(0.35, 0.45, 0.65, 0.30)

func _physics_process(delta: float) -> void:
	boundary_notice_timer = max(0.0, boundary_notice_timer - delta)
	play_seconds += delta
	autosave_timer -= delta
	if autosave_timer <= 0.0:
		autosave_timer = 12.0
		_autosave()
	if Net.online:
		_net_process(delta)
	elif not in_dungeon:
		_update_spawners(delta)        # 单机副本内不刷大世界怪
		_update_world_unlocks(delta)
	_update_zones(delta)
	_update_unlock_ring()
	_update_dungeon_ui()
	_sp_dungeon_tick()
	_update_cold(delta)
	_check_fall_death()
	if player != null:
		player.camera_yaw = cam_yaw
		if player.anim != null:
			player.anim.set_head_follow(first_person, cam_yaw, cam_pitch)
	_update_gate()
	_update_beast_tides(delta)
	_update_magnet(delta)
	_update_auto_pickup(delta)
	# 批量拾取：每帧最多刷一次背包 + 合并一条提示。
	if _backpack_dirty and backpack_panel != null and backpack_panel.visible:
		_refresh_backpack()
		_backpack_dirty = false
	if _pickup_msg_timer > 0.0:
		_pickup_msg_timer -= delta
		if _pickup_msg_timer <= 0.0 and _pickup_count > 0:
			flash_message("拾取 %d 件物品（按 B 查看背包）。" % _pickup_count)
			_pickup_count = 0
	_update_nav(delta)
	_update_audio(delta)
	_update_boundary(delta)
	_combat_timer = max(0.0, _combat_timer - delta)
	# GM 无敌：持续续约无敌状态。
	if admin_godmode and player != null and is_instance_valid(player) and player.buff != null:
		player.buff.apply_invuln(1.0)
	# 走远操作台自动收起面板（并释放占用）。
	if admin_panel_open and admin_console != null and player != null and is_instance_valid(player):
		if player.global_position.distance_to(admin_console.global_position) > 6.5:
			_close_admin_panel()
	_update_death()
	_handle_aerial_autofire()
	_handle_touch_attack()
	_update_camera(delta)
	_update_ui(delta)
	_cleanup_invalid_arrays()

# 世界等级是权威计数：每击杀关卡大Boss +1（联机沿用此计数）。
func get_world_level() -> int:
	return world_level

# 升级闸门：玩家达到等级上限后，地图出现一只大Boss；击杀前经验只累计不升级。
# 击杀后由 on_monster_died 解锁（上限 +3、世界等级 +1）。
func _update_gate() -> void:
	# 守关 Boss 闸门已废弃：升级上限改由「通关对应单人副本」解锁（见 _dungeon 通关处理）。
	return

# 在玩家周围一定距离的随机方向生成关卡大Boss（在已解锁半径内），并提示去讨伐。
func _spawn_gate_boss() -> void:
	var ang: float = rng.randf_range(0.0, TAU)
	var dist: float = 42.0
	var ar: float = get_unlocked_radius() - 6.0
	var base: Vector3 = player.global_position
	var bx: float = clamp(base.x + cos(ang) * dist, -ar, ar)
	var bz: float = clamp(base.z + sin(ang) * dist, -ar, ar)
	gate_boss = _spawn_monster("boss", Vector3(bx, 0.3, bz))
	flash_message("关卡大Boss降临！小地图已用★标注——击败它方可突破 Lv.%d，世界等级随之提升。" % level_cap)
	spawn_skill_flash(Vector3(bx, 1.6, bz), Color(1.0, 0.7, 0.2, 1), 4.0, 0.8)

# 御云飞行中长按左键 / 1 → 连续速射普攻（冷却好了就自动再发一枚）。
# 地面与普通跳跃仍是单次三段星斩，不连发。
func _handle_aerial_autofire() -> void:
	if player == null or not is_instance_valid(player) or player.hp <= 0.0:
		return
	if not player.flying_cloud:
		return
	if float(player.cooldowns.get("star_slash", 0.0)) > 0.0 or player.skill_lock_timer > 0.0:
		return
	# 法力不足以支撑速射时停火（避免连发刷“法力不足”提示）。
	if player.mp < float(StarGloryPlayer.AERIAL_SLASH_MP):
		return
	# 仅 PC：鼠标左键/1 键速射；手机端飞行速射走屏幕攻击键（touch_attack），避免任意触摸误触发普攻。
	if not _is_mobile() and (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_key_pressed(KEY_1)):
		player.cast_skill("star_slash")

func get_unlocked_radius() -> float:
	return float(clamp(unlocked_world_radius, 20.0, map_radius))

func _update_world_unlocks(delta: float) -> void:
	# 解锁条件：随世界等级（击杀关卡Boss）推进，或击杀数兜底。
	var target_stage: int = 0
	if world_level >= 2 or kills >= 4:
		target_stage = 1
	if world_level >= 3 or kills >= 10:
		target_stage = 2
	if world_level >= 4 or kills >= 20:
		target_stage = 3
	if target_stage != unlock_stage:
		unlock_stage = target_stage
		match unlock_stage:
			1:
				flash_message("无缝大世界第一圈已解锁：湖区、遗迹和外野开放。")
			2:
				flash_message("西北赤色王座通路已解锁：可以挑战荣耀守门人。")
			3:
				flash_message("全域大世界已解锁：边境封印解除。")
	var target_radius: float = 58.0
	match target_stage:
		0:
			target_radius = 58.0
		1:
			target_radius = 96.0
		2:
			target_radius = 128.0
		3:
			target_radius = map_radius
	unlocked_world_radius = move_toward(unlocked_world_radius, target_radius, 42.0 * delta)

# 收集当前可被攻击的建筑（炮台等：在 building 组、可受伤、未摧毁），供索敌使用。
func _attackable_buildings() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for b in get_tree().get_nodes_in_group("building"):
		var bnode: Node3D = b as Node3D
		if bnode == null or not is_instance_valid(bnode) or not bnode.has_method("take_damage"):
			continue
		if "dead" in bnode and bool(bnode.dead):
			continue
		result.append(bnode)
	return result

# 返回离 from_pos 最近的存活攻击目标（怪物 + 炮台等建筑），无则 null。
func get_nearest_target(from_pos: Vector3) -> Node3D:
	var nearest: Node3D = null
	var best: float = INF
	for node in monsters:
		var m: StarGloryMonster = node as StarGloryMonster
		if m == null or not is_instance_valid(m) or m.dead:
			continue
		var d: float = m.global_position.distance_to(from_pos)
		if d < best:
			best = d
			nearest = m
	for bnode in _attackable_buildings():
		var db: float = bnode.global_position.distance_to(from_pos)
		if db < best:
			best = db
			nearest = bnode
	return nearest

# 朝向锥内的存活攻击目标（怪物 + 炮台等建筑），按距离从近到远排序。
# facing 取水平分量；cos_half 为锥半角余弦（越大锥越窄）。
func get_targets_in_cone(from_pos: Vector3, facing: Vector3, cos_half: float) -> Array[Node3D]:
	var dir: Vector3 = Vector3(facing.x, 0, facing.z)
	if dir.length() < 0.01:
		dir = Vector3(0, 0, -1)
	dir = dir.normalized()
	var candidates: Array[Node3D] = []
	for node in monsters:
		var m: StarGloryMonster = node as StarGloryMonster
		if m != null and is_instance_valid(m) and not m.dead:
			candidates.append(m)
	candidates.append_array(_attackable_buildings())
	var result: Array[Node3D] = []
	for t in candidates:
		var to: Vector3 = t.global_position - from_pos
		var to_h: Vector3 = Vector3(to.x, 0.0, to.z)
		# 上下范围放宽到 ±90°：近乎正上方/正下方的目标（水平距离很小）直接纳入；
		# 其余仍按水平正面锥筛选（正面锥内的高/低目标本就靠 3D 朝向命中，垂直不设限）。
		if to_h.length() < 1.8:
			result.append(t)
		elif to_h.normalized().dot(dir) >= cos_half:
			result.append(t)
	result.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return a.global_position.distance_to(from_pos) < b.global_position.distance_to(from_pos))
	return result

func flash_locked_boundary() -> void:
	if boundary_notice_timer > 0.0:
		return
	boundary_notice_timer = 1.25
	flash_message("前方区域被星界封印阻挡：推进主线即可无缝解锁。")

# ---------------- 边界预警（红黑暗角 + 强制后退） ----------------
func _build_vignette() -> void:
	vignette = TextureRect.new()
	vignette.name = "BoundaryVignette"
	vignette.texture = _vignette_tex()
	vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vignette.stretch_mode = TextureRect.STRETCH_SCALE
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vignette.modulate = Color(1, 1, 1, 0)
	ui_layer.add_child(vignette)
	# 受击红闪叠层（打击感）。
	hurt_overlay = ColorRect.new()
	hurt_overlay.name = "HurtOverlay"
	hurt_overlay.color = Color(0.85, 0.05, 0.08, 0.0)
	hurt_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hurt_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(hurt_overlay)
	# 严寒蓝色叠层。
	cold_overlay = ColorRect.new()
	cold_overlay.name = "ColdOverlay"
	cold_overlay.color = Color(0.55, 0.75, 1.0, 0.0)
	cold_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cold_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(cold_overlay)

func _vignette_tex() -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	g.colors = PackedColorArray([Color(0.25, 0.0, 0.0, 0.0), Color(0.2, 0.0, 0.0, 0.0), Color(0.04, 0.0, 0.0, 0.96)])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(0.5, 0.0)
	gt.width = 256
	gt.height = 256
	return gt

# 接近未解锁边界：屏幕渐变红黑；即将越界则强制扭头后退（参考边界预警手感）。
func _update_boundary(delta: float) -> void:
	if vignette == null or player == null or not is_instance_valid(player):
		return
	# 副本内、或处于草地山林/雪山地形区域内：不受大世界未解锁边界约束（可自由攀爬）。
	if in_dungeon or (terrain_system != null and terrain_system.in_region(player.global_position.x, player.global_position.z)):
		_vig_a = move_toward(_vig_a, 0.0, 4.0 * delta)
		vignette.modulate.a = _vig_a
		return
	var edge: float = get_unlocked_radius()
	var m: float = max(abs(player.global_position.x), abs(player.global_position.z))
	var band: float = 16.0
	var t: float = clampf((m - (edge - band)) / band, 0.0, 1.0)
	_vig_a = move_toward(_vig_a, t, 3.0 * delta)
	vignette.modulate.a = _vig_a
	if t > 0.8 and player.hp > 0.0:
		var inward2: Vector2 = Vector2(-player.global_position.x, -player.global_position.z)
		if inward2.length() > 0.01:
			inward2 = inward2.normalized()
			var iv: Vector3 = Vector3(inward2.x, 0.0, inward2.y)
			player.global_position += iv * 6.0 * delta
			player.face_direction(iv)
		if boundary_notice_timer <= 0.0:
			boundary_notice_timer = 1.5
			flash_message("等级/进度不足，无法离开当前区域。")

func _unhandled_input(event: InputEvent) -> void:
	# 触屏多点：摇杆/动作键/相机各按手指索引独立处理（仅单机构建了触屏控件）。
	if touch_root != null and (event is InputEventScreenTouch or event is InputEventScreenDrag):
		_handle_touch(event)
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			right_mouse_down = event.pressed
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if right_mouse_down else Input.MOUSE_MODE_VISIBLE)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed and not first_person:
			cam_distance = max(5.2, cam_distance - 0.8)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed and not first_person:
			cam_distance = min(18.0, cam_distance + 0.8)
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed and player != null and not _is_mobile():
			# 施法前摇瞄准中：左键点按世界 = 设置落点（不触发普攻）。
			if aim_active:
				set_aim_tap(event.position)
			else:
				# 先看是否点在快捷药剂格上 → 开始拖拽（松手在单位上=给它用，否则给自己）。
				var qp: String = _quick_slot_at(event.position)
				if qp != "":
					_potion_drag = qp
					_update_potion_hover(event.position)
				else:
					# 手机端用屏幕攻击键；左键攻击仅 PC（避免触屏模拟鼠标造成误触发）。
					player.cast_skill("star_slash")
		elif event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and _potion_drag != "":
			_finish_potion_drag()
	elif event is InputEventMouseMotion:
		if _potion_drag != "":
			_update_potion_hover(event.position)
		elif right_mouse_down:
			cam_yaw -= event.relative.x * 0.006
			cam_pitch = clamp(cam_pitch + event.relative.y * 0.004, -PITCH_LIMIT, PITCH_LIMIT)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				player.cast_skill("star_slash")
			KEY_2:
				player.cast_skill("fireball")
			KEY_3:
				player.cast_skill("frost_ring")
			KEY_4:
				player.cast_skill("blink")
			KEY_5:
				player.cast_skill("meteor")
			KEY_6:
				player.cast_skill("fire_rain")
			KEY_7:
				player.toggle_cloud_flight()
			KEY_Q:
				# 非飞行：Q 起飞进入御云（飞行时 Q 用于上升，由飞行分支轮询处理）。
				if not player.flying_cloud:
					player.toggle_cloud_flight()
			KEY_Y:
				_use_beast_token()
			KEY_E:
				if not player.flying_cloud:   # 操作台→任务NPC→庇护所→篝火→采集→重建→副本入口→拾取
					if not _try_open_admin_console() and not _try_npc() and not _try_shelter() and not _try_rest() and not _try_gather() and not _try_world_node() and not _try_rebuild_wall() and not _try_dungeon_settle() and not _try_enter_dungeon():
						pickup_nearest()
			KEY_SPACE:
				if player.flying_cloud:       # 飞行中不能跳，改用 Space 拾取
					pickup_nearest()
			KEY_B:
				_hud_panel_key("backpack")
			KEY_J:
				_hud_panel_key("quest")
			KEY_K:
				_hud_panel_key("achv")
			KEY_O:
				_hud_panel_key("pet")
			KEY_T:
				if pet_system != null:
					pet_system.cast_active()
			KEY_L:
				_hud_panel_key("leaderboard")
			KEY_G:
				_hud_panel_key("drone")
			KEY_P:
				_hud_panel_key("profile")
			KEY_Z:
				_use_potion_self("hp")
			KEY_X:
				_use_potion_self("mp")
			KEY_C:
				_use_potion_self("vit")
			KEY_M:
				toggle_big_map()
			KEY_V:
				first_person = not first_person
				flash_message("镜头切换：%s" % ("第一人称" if first_person else "第三人称俯视"))
			KEY_R:
				flash_message("R 键复活已关闭。阵亡后通过死亡面板看广告原地复活，或接受惩罚返回星门。")
			KEY_ENTER, KEY_KP_ENTER:
				if chat_input != null and not chat_input.has_focus():
					chat_input.grab_focus()
			KEY_ESCAPE:
				_on_escape()

# ---------------- 聊天窗 ----------------
func _build_chat() -> void:
	chat_panel = Panel.new()
	chat_panel.name = "ChatPanel"
	# 右侧、小地图(右上)下方。
	chat_panel.anchor_left = 1.0
	chat_panel.anchor_right = 1.0
	chat_panel.anchor_top = 0.0
	chat_panel.anchor_bottom = 0.0
	chat_panel.offset_left = -266.0
	chat_panel.offset_right = -12.0
	chat_panel.offset_top = 226.0
	chat_panel.offset_bottom = 226.0 + 286.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.10, 0.62)
	sb.set_corner_radius_all(6)
	chat_panel.add_theme_stylebox_override("panel", sb)
	ui_layer.add_child(chat_panel)

	# 频道标签
	var tabs := HBoxContainer.new()
	tabs.position = Vector2(6, 4)
	tabs.add_theme_constant_override("separation", 4)
	chat_panel.add_child(tabs)
	for ch: String in CHAT_CHANNELS:
		var b := Button.new()
		b.text = String(CHAT_NAMES[ch])
		b.toggle_mode = true
		b.add_theme_font_size_override("font_size", 13)
		b.add_theme_color_override("font_color", Color.html(String(CHAT_COLORS[ch])))
		b.custom_minimum_size = Vector2(56, 24)
		b.pressed.connect(_set_chat_channel.bind(ch))
		tabs.add_child(b)
		chat_tab_btns[ch] = b

	# 消息日志
	chat_log = RichTextLabel.new()
	chat_log.bbcode_enabled = true
	chat_log.scroll_active = true
	chat_log.scroll_following = true
	chat_log.position = Vector2(8, 34)
	chat_log.size = Vector2(246, 212)
	chat_log.add_theme_font_size_override("normal_font_size", 13)
	chat_panel.add_child(chat_log)

	# 输入框
	chat_input = LineEdit.new()
	chat_input.placeholder_text = "回车发送 · /w 名字 私聊 · /invite 名字"
	chat_input.position = Vector2(8, 250)
	chat_input.size = Vector2(246, 30)
	chat_input.max_length = 200
	chat_input.add_theme_font_size_override("font_size", 13)
	chat_input.text_submitted.connect(_on_chat_submit)
	chat_input.focus_entered.connect(func() -> void: chat_typing = true)
	chat_input.focus_exited.connect(func() -> void: chat_typing = false)
	chat_panel.add_child(chat_input)

	# 移动端唤起按钮
	if _is_mobile():
		chat_btn = Button.new()
		chat_btn.text = "聊天"
		chat_btn.anchor_left = 1.0
		chat_btn.anchor_right = 1.0
		chat_btn.offset_left = -86.0
		chat_btn.offset_right = -12.0
		chat_btn.offset_top = 226.0 + 286.0 + 6.0
		chat_btn.offset_bottom = 226.0 + 286.0 + 42.0
		chat_btn.pressed.connect(func() -> void: chat_input.grab_focus())
		ui_layer.add_child(chat_btn)

	_set_chat_channel("public")
	_append_chat("system", "", "聊天已就绪。/w 名字 内容 私聊；/invite 名字、/accept、/leave 组队。")

func _set_chat_channel(ch: String) -> void:
	chat_active = ch
	for c: String in chat_tab_btns.keys():
		(chat_tab_btns[c] as Button).button_pressed = (c == ch)
	_refresh_chat()

var _avatar_tex_cache: Dictionary = {}   # base64 -> Texture2D/null

func _avatar_texture(av: String) -> Texture2D:
	if av == "":
		return null
	if _avatar_tex_cache.has(av):
		return _avatar_tex_cache[av]
	var tex: Texture2D = null
	var raw: PackedByteArray = Marshalls.base64_to_raw(av)
	var img := Image.new()
	if raw.size() > 0 and img.load_png_from_buffer(raw) == OK:
		tex = ImageTexture.create_from_image(img)
	_avatar_tex_cache[av] = tex
	return tex

# 无头像者用「按昵称确定的颜色圆点」作头像（默认随机色，不用手选）。
func _dot_color(from_name: String) -> String:
	if from_name == "":
		return AVATAR_COLORS[0]
	return AVATAR_COLORS[absi(hash(from_name)) % AVATAR_COLORS.size()]

func _append_chat(channel: String, from_name: String, text: String, avatar: String = "") -> void:
	chat_lines.append({"channel": channel, "from": from_name, "text": text, "avatar": avatar})
	if chat_lines.size() > 300:
		chat_lines = chat_lines.slice(chat_lines.size() - 300)
	_refresh_chat()

func _refresh_chat() -> void:
	if chat_log == null:
		return
	chat_log.clear()
	for ln: Dictionary in chat_lines:
		if chat_active == "public" or String(ln["channel"]) == chat_active:
			_render_chat_line(ln)

func _render_chat_line(ln: Dictionary) -> void:
	var channel: String = String(ln["channel"])
	var col: String = String(CHAT_COLORS.get(channel, "#E6F2FF"))
	var from_name: String = String(ln.get("from", ""))
	var safe: String = String(ln.get("text", "")).replace("[", "［")
	if channel == "system":
		chat_log.append_text("[color=%s][系统] %s[/color]\n" % [col, safe])
		return
	# 头像：有图片则贴图，否则昵称色圆点。
	var tex: Texture2D = _avatar_texture(String(ln.get("avatar", "")))
	if tex != null:
		chat_log.add_image(tex, 18, 18)
		chat_log.append_text(" ")
	else:
		chat_log.append_text("[color=%s]●[/color] " % _dot_color(from_name))
	var prefix: String = ("[队]" if channel == "party" else ("[私]" if channel == "whisper" else ""))
	if from_name == "":
		chat_log.append_text("[color=%s]%s%s[/color]\n" % [col, prefix, safe])
	else:
		chat_log.append_text("[color=%s]%s[b]%s[/b]: %s[/color]\n" % [col, prefix, from_name, safe])

func _on_chat_submit(text: String) -> void:
	var t: String = text.strip_edges()
	chat_input.clear()
	chat_input.release_focus()
	if t == "":
		return
	if t.begins_with("/w ") or t.begins_with("/W "):
		var rest: String = t.substr(3).strip_edges()
		var sp: int = rest.find(" ")
		if sp <= 0:
			_append_chat("system", "", "用法：/w 名字 内容")
			return
		var name: String = rest.substr(0, sp)
		var msg: String = rest.substr(sp + 1).strip_edges()
		if Net.online:
			Net.send_chat("whisper", msg, name)
		else:
			_append_chat("system", "", "私聊需联机。")
		return
	if t.begins_with("/invite "):
		if Net.online: Net.send_party("invite", t.substr(8).strip_edges())
		else: _append_chat("system", "", "组队需联机。")
		return
	if t == "/accept":
		if Net.online: Net.send_party("accept", "")
		else: _append_chat("system", "", "组队需联机。")
		return
	if t == "/leave":
		if Net.online: Net.send_party("leave", "")
		else: _append_chat("system", "", "组队需联机。")
		return
	# 普通消息：按当前频道发送。
	match chat_active:
		"public":
			if Net.online: Net.send_chat("public", t)
			else: _append_chat("public", local_player_name, t)
		"party":
			if Net.online: Net.send_chat("party", t)
			else: _append_chat("system", "", "队伍需联机。")
		"whisper":
			_append_chat("system", "", "私聊请用：/w 名字 内容")
		_:
			_append_chat("system", "", "系统频道为只读。")

# 手机端 HUD 重排：聊天默认收起（由「聊天」键开关）、隐藏 PC 帮助提示、技能栏左移避让右下键簇。
func _apply_mobile_layout() -> void:
	if help_label != null:
		help_label.visible = false            # PC 按键提示，手机无用且会被遮挡
	if chat_panel != null:
		chat_panel.visible = false            # 默认收起，避免遮住快捷药剂/背包按钮
	if hotbar_root != null:
		hotbar_root.scale = Vector2(0.85, 0.85)   # 缩小并左移，让出右下角键簇空间
		hotbar_root.position = Vector2(300, 566)
	# 「聊天」键：移到右上按钮列（档案下方）、改为开关聊天面板，避免压住攻击键。
	if chat_btn != null:
		chat_btn.anchor_left = 1.0
		chat_btn.anchor_right = 1.0
		chat_btn.anchor_top = 0.0
		chat_btn.anchor_bottom = 0.0
		chat_btn.offset_left = -104.0
		chat_btn.offset_right = -16.0
		chat_btn.offset_top = 392.0
		chat_btn.offset_bottom = 440.0
		for c in chat_btn.pressed.get_connections():
			chat_btn.pressed.disconnect(c["callable"])
		chat_btn.pressed.connect(_toggle_chat)

func _toggle_chat() -> void:
	if chat_panel == null:
		return
	chat_panel.visible = not chat_panel.visible
	if chat_panel.visible:
		chat_panel.move_to_front()
		if chat_input != null:
			chat_input.grab_focus()
	elif chat_input != null:
		chat_input.release_focus()

func _refresh_party_tab() -> void:
	if chat_tab_btns.has("party"):
		var n: int = Net.party_members.size()
		(chat_tab_btns["party"] as Button).text = "队伍(%d)" % n if n > 0 else "队伍"

# ---------------- 管理员操作台（GM） ----------------
func _build_admin_console() -> void:
	admin_console = Node3D.new()
	admin_console.name = "AdminConsole"
	(world_root if world_root != null else self).add_child(admin_console)
	admin_console.global_position = ADMIN_CONSOLE_POS   # 必须在入树后设置全局坐标
	# 底座
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = Vector3(1.6, 0.8, 1.0)
	base.mesh = bm; base.position = Vector3(0, 0.4, 0)
	base.material_override = _mat(Color(0.16, 0.18, 0.24, 1), 0.2)
	admin_console.add_child(base)
	# 斜面板（发光，象征“映射到平面”的操作面）
	var panel := MeshInstance3D.new()
	var pm := BoxMesh.new(); pm.size = Vector3(1.4, 0.9, 0.08)
	panel.mesh = pm; panel.position = Vector3(0, 1.15, 0.1); panel.rotation.x = deg_to_rad(-28)
	panel.material_override = _mat(Color(0.25, 0.85, 1.0, 1), 1.6)
	admin_console.add_child(panel)

func _build_admin_panel() -> void:
	admin_panel = Panel.new()
	admin_panel.name = "AdminPanel"
	admin_panel.position = Vector2(240, 80)
	admin_panel.size = Vector2(780, 540)
	admin_panel.visible = false
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(0.05, 0.07, 0.12, 0.95); sb.set_corner_radius_all(8)
	admin_panel.add_theme_stylebox_override("panel", sb)
	ui_layer.add_child(admin_panel)

	admin_title = Label.new()
	admin_title.text = "GM 操作台"
	admin_title.position = Vector2(16, 12)
	admin_title.add_theme_font_size_override("font_size", 20)
	admin_panel.add_child(admin_title)

	var close := Button.new(); close.text = "关闭"
	close.position = Vector2(690, 10); close.size = Vector2(72, 30)
	close.pressed.connect(_toggle_admin_panel.bind(false))
	admin_panel.add_child(close)

	var y: int = 50
	y = _admin_section("自身（L1）", y)
	y = _admin_button("满血满蓝", 1, func() -> void: _admin_self_full(), y)
	y = _admin_button("无敌：开/关", 1, func() -> void: _admin_toggle_god(), y)
	y = _admin_button("移速 ×2：开/关", 1, func() -> void: _admin_toggle_speed(), y)
	y = _admin_button("自身 +10 级", 1, func() -> void: _admin_levelup(), y)
	y = _admin_button("学满技能", 1, func() -> void: _admin_max_skills(), y)
	y = _admin_section("怪物（L2）", y + 6)
	y = _admin_button("清场（杀附近 30m）", 2, func() -> void: Net.send_admin("kill_area", {"center": player.global_position, "radius": 30.0}), y)
	y = _admin_button("重置怪物（回出生点·满血）", 2, func() -> void: Net.send_admin("reset_monsters", {}), y)
	y = _admin_section("平衡（L3）", y + 6)
	admin_str_input = _admin_field("怪物强度倍率", "1.0", y); y += 34
	y = _admin_button("应用怪物强度", 3, func() -> void: Net.send_admin("monster_strength", {"mult": admin_str_input.text.to_float()}), y)
	admin_drop_input = _admin_field("掉落率倍率", "1.0", y); y += 34
	y = _admin_button("应用掉落率", 3, func() -> void: Net.send_admin("drop_rate", {"mult": admin_drop_input.text.to_float()}), y)
	_build_admin_player_tools()
	_refresh_admin_panel()

func _admin_section(title: String, y: int) -> int:
	var l := Label.new(); l.text = title
	l.position = Vector2(16, y); l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0, 1))
	admin_panel.add_child(l)
	return y + 26

func _admin_button(text: String, need: int, cb: Callable, y: int) -> int:
	var b := Button.new(); b.text = text
	b.position = Vector2(20, y); b.size = Vector2(300, 30)
	b.pressed.connect(cb)
	admin_panel.add_child(b)
	admin_action_btns.append({"node": b, "need": need})
	return y + 34

func _admin_field(label: String, default: String, y: int) -> LineEdit:
	var l := Label.new(); l.text = label
	l.position = Vector2(20, y + 4); l.add_theme_font_size_override("font_size", 13)
	admin_panel.add_child(l)
	var e := LineEdit.new(); e.text = default
	e.position = Vector2(170, y); e.size = Vector2(120, 28)
	e.focus_entered.connect(func() -> void: chat_typing = true)
	e.focus_exited.connect(func() -> void: chat_typing = false)
	admin_panel.add_child(e)
	return e

func _build_admin_player_tools() -> void:
	var title := Label.new()
	title.text = "玩家管理（L1查看 / L2编辑）"
	title.position = Vector2(340, 52)
	title.size = Vector2(300, 24)
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0, 1))
	admin_panel.add_child(title)

	var refresh := Button.new()
	refresh.text = "刷新"
	refresh.position = Vector2(690, 48)
	refresh.size = Vector2(64, 28)
	refresh.pressed.connect(_admin_request_players)
	admin_panel.add_child(refresh)
	admin_action_btns.append({"node": refresh, "need": 1})

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(340, 84)
	scroll.size = Vector2(414, 205)
	admin_panel.add_child(scroll)
	admin_player_list_box = VBoxContainer.new()
	admin_player_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(admin_player_list_box)

	admin_player_detail = RichTextLabel.new()
	admin_player_detail.bbcode_enabled = true
	admin_player_detail.position = Vector2(340, 292)
	admin_player_detail.size = Vector2(414, 60)
	admin_player_detail.text = "[color=#9fb8cf]选择一个玩家。[/color]"
	admin_panel.add_child(admin_player_detail)

	admin_edit_name = _admin_player_field("名字", Vector2(340, 358), "name")
	admin_edit_level = _admin_player_field("等级", Vector2(340, 392), "1")
	admin_edit_equip = _admin_player_field("装等", Vector2(340, 426), "0")

	var apply := Button.new()
	apply.text = "保存名字/等级/装等"
	apply.position = Vector2(340, 460)
	apply.size = Vector2(414, 28)
	apply.pressed.connect(_admin_apply_player)
	admin_panel.add_child(apply)
	admin_action_btns.append({"node": apply, "need": 2})

	_admin_player_effect_button("满状态", "heal", Vector2(340, 500), Vector2(76, 28))
	_admin_player_effect_button("+10级", "level_add", Vector2(424, 500), Vector2(76, 28))
	_admin_player_effect_button("满技能", "max_skills", Vector2(508, 500), Vector2(76, 28))
	_admin_player_effect_button("无敌", "god_toggle", Vector2(592, 500), Vector2(76, 28))
	_admin_player_effect_button("移速", "speed_toggle", Vector2(676, 500), Vector2(76, 28))

func _admin_player_effect_button(text: String, effect: String, pos: Vector2, size: Vector2) -> void:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = size
	b.pressed.connect(_admin_player_effect.bind(effect))
	admin_panel.add_child(b)
	admin_action_btns.append({"node": b, "need": 2})

func _admin_player_field(label: String, pos: Vector2, default_text: String) -> LineEdit:
	var l := Label.new()
	l.text = label
	l.position = pos + Vector2(0, 5)
	l.size = Vector2(70, 24)
	admin_panel.add_child(l)
	var e := LineEdit.new()
	e.text = default_text
	e.position = pos + Vector2(76, 0)
	e.size = Vector2(338, 28)
	e.focus_entered.connect(func() -> void: chat_typing = true)
	e.focus_exited.connect(func() -> void: chat_typing = false)
	admin_panel.add_child(e)
	return e

func _admin_request_players() -> void:
	if Net.online and Net.admin_level >= 1:
		Net.send_admin("player_list", {})

func _refresh_admin_players() -> void:
	if admin_player_list_box == null:
		return
	for c: Node in admin_player_list_box.get_children():
		c.queue_free()
	var selected_still_exists: bool = false
	for row_v: Variant in Net.admin_players:
		var row: Dictionary = row_v as Dictionary
		var pid: int = int(row.get("id", 0))
		if pid == admin_player_selected_id:
			selected_still_exists = true
		var b := Button.new()
		var peer_id: int = int(row.get("peer_id", 0))
		var status: String = ("在线 P%d" % peer_id) if bool(row.get("online", false)) else "离线"
		b.text = "#%d  %s  Lv.%d  装%d  %s  %s" % [
			pid,
			String(row.get("name", "")),
			int(row.get("level", 1)),
			int(row.get("equip_tier", 0)),
			status,
			String(row.get("user", "")),
		]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(392, 28)
		b.pressed.connect(_admin_select_player.bind(row))
		admin_player_list_box.add_child(b)
	if not selected_still_exists:
		admin_player_selected_id = 0
		admin_player_selected = {}
	if admin_player_selected_id == 0 and not Net.admin_players.is_empty():
		_admin_select_player(Net.admin_players[0] as Dictionary)
	else:
		_update_admin_player_detail()

func _admin_select_player(row: Dictionary) -> void:
	admin_player_selected = row.duplicate(true)
	admin_player_selected_id = int(row.get("id", 0))
	if admin_edit_name != null:
		admin_edit_name.text = String(row.get("name", ""))
	if admin_edit_level != null:
		admin_edit_level.text = str(int(row.get("level", 1)))
	if admin_edit_equip != null:
		admin_edit_equip.text = str(int(row.get("equip_tier", 0)))
	_update_admin_player_detail()

func _update_admin_player_detail() -> void:
	if admin_player_detail == null:
		return
	if admin_player_selected_id == 0:
		admin_player_detail.text = "[color=#9fb8cf]暂无玩家。[/color]"
		return
	var r: Dictionary = admin_player_selected
	var peer_id: int = int(r.get("peer_id", 0))
	var status: String = ("在线 / 连接 %d" % peer_id) if bool(r.get("online", false)) else "离线"
	admin_player_detail.text = "[b]#%d %s[/b]\n账号: %s  状态: %s  管理级: %d  副本: %d\n等级: %d  装等: %d(最高%d)  HP: %d/%d" % [
		admin_player_selected_id,
		String(r.get("name", "")),
		String(r.get("user", "")),
		status,
		int(r.get("admin_level", 0)),
		int(r.get("instance_id", 0)),
		int(r.get("level", 1)),
		int(r.get("equip_tier", 0)),
		int(r.get("equip_max", 0)),
		int(r.get("hp", 0)),
		int(r.get("max_hp", 0)),
	]

func _admin_apply_player() -> void:
	if admin_player_selected_id == 0:
		flash_message("[GM] 先选择一个玩家。")
		return
	if Net.admin_level < 2:
		flash_message("[GM] 编辑玩家需要管理员等级 2。")
		return
	Net.send_admin("set_player", {
		"id": admin_player_selected_id,
		"user": String(admin_player_selected.get("user", "")),
		"name": admin_edit_name.text.strip_edges(),
		"level": clampi(admin_edit_level.text.to_int(), 1, 999),
		"equip_tier": clampi(admin_edit_equip.text.to_int(), 0, 60),
	})

func _admin_player_effect(effect: String) -> void:
	if admin_player_selected_id == 0:
		flash_message("[GM] 先选择一个玩家。")
		return
	if Net.admin_level < 2:
		flash_message("[GM] 调整指定玩家需要管理员等级 2。")
		return
	Net.send_admin("player_effect", {
		"id": admin_player_selected_id,
		"user": String(admin_player_selected.get("user", "")),
		"effect": effect,
	})

func _refresh_admin_panel() -> void:
	if admin_panel == null:
		return
	var lv: int = Net.admin_level
	if admin_title != null:
		admin_title.text = "GM 操作台 · 等级 %d" % lv
	for e: Dictionary in admin_action_btns:
		(e["node"] as Button).disabled = lv < int(e["need"])
	# 管理员才显示快捷按钮。
	if admin_btn == null and lv > 0:
		admin_btn = Button.new(); admin_btn.text = "GM"
		admin_btn.position = Vector2(12, 12); admin_btn.size = Vector2(54, 30)
		admin_btn.pressed.connect(_toggle_admin_panel.bind(true))
		ui_layer.add_child(admin_btn)
	if admin_btn != null:
		admin_btn.visible = lv > 0

# 靠近操作台按 E：管理员→请求占用（服务器仲裁后才开面板）；非管理员→提示。
func _try_open_admin_console() -> bool:
	if not Net.online or admin_console == null or player == null:
		return false
	if player.global_position.distance_to(admin_console.global_position) > 5.0:
		return false
	if Net.admin_level <= 0:
		flash_message("操作台：需要管理员权限。")
		return true   # 吃掉 E，不触发拾取
	if admin_panel_open:
		_close_admin_panel()
	else:
		Net.send_admin("console_open", {})
	return true

func _open_admin_panel() -> void:
	if admin_panel == null:
		return
	admin_panel_open = true
	admin_panel.visible = true
	admin_panel.move_to_front()
	_refresh_admin_panel()
	_admin_request_players()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _close_admin_panel() -> void:
	if not admin_panel_open:
		if admin_panel != null:
			admin_panel.visible = false
		return
	admin_panel_open = false
	if admin_panel != null:
		admin_panel.visible = false
	if Net.online:
		Net.send_admin("console_close", {})

# 旧入口：true=请求开（走服务器），false=关。
func _toggle_admin_panel(open: bool) -> void:
	if open:
		Net.send_admin("console_open", {})
	else:
		_close_admin_panel()

func _admin_self_full() -> void:
	if player == null: return
	player.hp = float(player.max_hp); player.mp = float(player.max_mp)

func _admin_toggle_god() -> void:
	admin_godmode = not admin_godmode
	flash_message("[GM] 无敌：%s" % ("开" if admin_godmode else "关"))

func _admin_toggle_speed() -> void:
	if player == null: return
	admin_speed_on = not admin_speed_on
	player.gm_speed_mult = 2.0 if admin_speed_on else 1.0
	player.recalculate_stats()
	flash_message("[GM] 移速×2：%s" % ("开" if admin_speed_on else "关"))

func _admin_levelup() -> void:
	if player == null: return
	for _i in range(10):
		player.level += 1
		player.next_level_exp = int(float(player.next_level_exp) * 1.32 + 30.0)
		player.base_max_hp += 24
		player.base_max_mp += 14
		player.base_attack += 2
		player.base_magic += 2
		player.base_defense += 1
		player.base_toughness += 1
	player.recalculate_stats()
	player.hp = float(player.max_hp); player.mp = float(player.max_mp)
	flash_message("[GM] 自身 +10 级 → Lv.%d" % player.level)

func _admin_max_skills() -> void:
	for id: String in SkillManager.ORDER:
		skills.skill_levels[id] = SkillManager.MAX_LEVEL
	flash_message("[GM] 已学满全部技能。")

# ---------------- 副本 ----------------
# 守关(突破)副本的入口专属标识文字。
func _dungeon_gate_label(id: int) -> String:
	for g_v: Variant in LEVEL_GATES:
		var g: Dictionary = g_v
		if int(g["dungeon"]) == id:
			return "\n★突破 Lv.%d→%d" % [int(g["cap"]), int(g["next"])]
	return ""

func _build_dungeon_entrances() -> void:
	dungeon_root = Node3D.new()
	dungeon_root.name = "DungeonEntrances"
	(world_root if world_root != null else self).add_child(dungeon_root)
	for d: Dictionary in DUNGEON_DEFS:
		var portal := Node3D.new()
		dungeon_root.add_child(portal)
		var pos: Vector3 = d["pos"] as Vector3
		pos.y = terrain_height(pos.x, pos.z)   # 山壁上的洞口贴到地表
		portal.global_position = pos
		_dungeon_portals[int(d["id"])] = portal
		if String(d.get("theme", "")) == "cave":
			# 星莹矿洞：山壁上的岩石洞口 + 幽蓝水晶。
			var mouth := MeshInstance3D.new()
			var mm := CylinderMesh.new(); mm.top_radius = 1.9; mm.bottom_radius = 2.4; mm.height = 0.4
			mouth.mesh = mm; mouth.rotation.x = PI * 0.5; mouth.position = Vector3(0, 2.2, 0)
			mouth.material_override = _mat(Color(0.03, 0.05, 0.09, 1), 0.0)
			portal.add_child(mouth)
			var rock := MeshInstance3D.new()
			var rt := TorusMesh.new(); rt.inner_radius = 2.2; rt.outer_radius = 3.0
			rock.mesh = rt; rock.position = Vector3(0, 2.2, 0)
			rock.material_override = _mat(Color(0.32, 0.34, 0.4, 1), 0.0)
			portal.add_child(rock)
			for ci in range(6):
				var cry := MeshInstance3D.new()
				var pm := PrismMesh.new(); pm.size = Vector3(0.4, 1.4, 0.4)
				cry.mesh = pm
				cry.material_override = _mat(Color(0.4, 0.85, 1.0, 1), 2.4)
				var a := TAU * float(ci) / 6.0
				cry.position = Vector3(cos(a) * 2.6, 0.7 + randf() * 0.6, sin(a) * 2.6)
				cry.rotation.z = randf_range(-0.3, 0.3)
				portal.add_child(cry)
			var clbl := Label3D.new()
			clbl.text = "💎 星莹矿洞（Lv.%d）%s\n按 E 进入" % [int(d["level_req"]), _dungeon_gate_label(int(d["id"]))]
			clbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			clbl.position = Vector3(0, 4.4, 0); clbl.font_size = 28; clbl.outline_size = 6
			clbl.modulate = Color(0.5, 0.9, 1.0, 1)
			portal.add_child(clbl)
			continue
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new(); tm.inner_radius = 1.2; tm.outer_radius = 1.6
		ring.mesh = tm; ring.position = Vector3(0, 1.4, 0)
		ring.material_override = _mat(Color(0.55, 0.35, 1.0, 1), 1.8)
		portal.add_child(ring)
		var lbl := Label3D.new()
		lbl.text = "副本入口\n%s（Lv.%d）%s\n按 E 进入" % [String(d["name"]), int(d["level_req"]), _dungeon_gate_label(int(d["id"]))]
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.position = Vector3(0, 3.0, 0)
		lbl.font_size = 28
		lbl.outline_size = 6
		lbl.modulate = Color(0.8, 0.7, 1.0, 1)
		portal.add_child(lbl)

var gather_nodes: Array = []   # 可采集节点 [{node,item,amount,persistent}]

func register_gather(node: Node3D, item: Dictionary, amount: int, persistent: bool) -> void:
	gather_nodes.append({"node": node, "item": item, "amount": amount, "persistent": persistent})

var world_node_root: Node3D = null
var world_node_meshes: Dictionary = {}   # 全服共享节点 id -> Node3D

# 消费全服节点同步 + 采集回执。
func _update_world_nodes() -> void:
	if Net.world_nodes_dirty:
		Net.world_nodes_dirty = false
		_rebuild_world_nodes()
	while not Net.gather_result_queue.is_empty():
		var g: Dictionary = Net.gather_result_queue.pop_front()
		if inv != null:
			inv.add_material(String(g.get("mat", "")), Color(0.55, 0.9, 1.0, 1), int(g.get("amount", 1)))
		flash_message("采集「%s」×%d，已入背包（全服争抢）。" % [String(g.get("mat", "")), int(g.get("amount", 1))])

func _rebuild_world_nodes() -> void:
	if world_node_root == null:
		world_node_root = Node3D.new()
		(world_root if world_root != null else self).add_child(world_node_root)
	var present: Dictionary = {}
	for nd_v: Variant in Net.world_nodes_data:
		var nd: Dictionary = nd_v
		var id: int = int(nd["id"])
		present[id] = true
		if not world_node_meshes.has(id):
			var node := _make_world_node(nd)
			world_node_meshes[id] = node
			world_node_root.add_child(node)
	for id2: int in world_node_meshes.keys():
		if not present.has(id2):
			var n: Node = world_node_meshes[id2]
			world_node_meshes.erase(id2)
			if is_instance_valid(n):
				(n as Node3D).queue_free()

func _make_world_node(nd: Dictionary) -> Node3D:
	var pos: Vector3 = nd["pos"]
	pos.y = maxf(pos.y, terrain_height(pos.x, pos.z))
	var mat_name: String = String(nd["mat"])
	var col: Color = Color(0.45, 0.95, 1.0, 1) if mat_name == "星莹水晶" else Color(0.82, 0.94, 1.0, 1)
	var root: StarGloryOreNode = OreNodeScene.new()
	root.main = self
	root.mat_name = mat_name
	root.mat_color = col
	root.net_node_id = int(nd["id"])
	root.hp = 90
	root.global_position = pos
	for j in range(3):
		var cr := MeshInstance3D.new()
		var pm := PrismMesh.new(); pm.size = Vector3(0.5, 1.8, 0.5)
		cr.mesh = pm
		var m := StandardMaterial3D.new(); m.albedo_color = col; m.emission_enabled = true; m.emission = col; m.emission_energy_multiplier = 2.8
		cr.material_override = m
		cr.position = Vector3(randf_range(-0.6, 0.6), 0.8, randf_range(-0.6, 0.6))
		cr.rotation = Vector3(randf_range(-0.2, 0.2), randf() * TAU, randf_range(-0.2, 0.2))
		root.add_child(cr)
	var lbl := Label3D.new(); lbl.text = "⛏ %s（攻击打碎）" % mat_name
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED; lbl.font_size = 20; lbl.outline_size = 5
	lbl.modulate = col; lbl.position = Vector3(0, 3.0, 0)
	root.add_child(lbl)
	return root

# 抢采最近的全服共享节点（联机,先到先得）。
func _try_world_node() -> bool:
	return false

var _lb_panel: Control = null
var _lb_label: RichTextLabel = null

func _toggle_leaderboard() -> void:
	if not Net.online:
		flash_message("建造贡献榜为联机功能。")
		return
	if _lb_panel == null:
		_build_leaderboard_panel()
	_lb_panel.visible = not _lb_panel.visible
	if _lb_panel.visible:
		Net.send_leaderboard_req()
		_refresh_leaderboard()

# 发放周榜奖励（登录时）→ 入背包 + 弹窗 + 存档。
func _grant_rewards(items: Array) -> void:
	if inv == null or items.is_empty():
		return
	var parts: Array = []
	for it_v: Variant in items:
		var it: Dictionary = it_v
		inv.add_material(String(it.get("mat", "")), Color(1.0, 0.85, 0.4, 1), int(it.get("amount", 0)))
		parts.append("%s×%d" % [String(it.get("mat", "")), int(it.get("amount", 0))])
	flash_message("获得物品：%s" % "、".join(PackedStringArray(parts)))
	_autosave()

func _fmt_dur(secs: int) -> String:
	if secs <= 0:
		return "即将结算"
	if secs >= 86400:
		return "%d天%d时" % [secs / 86400, (secs % 86400) / 3600]
	return "%d时%d分" % [secs / 3600, (secs % 3600) / 60]

func _refresh_leaderboard() -> void:
	if _lb_label == null:
		return
	var d: Dictionary = Net.leaderboard_data
	var top: Array = d.get("top", [])
	var out: String = "[color=#8fd8ff]每周结算发奖 · 距本期结算：%s[/color]\n[b]全服建造总进度：%d 点[/b]\n\n[b]贡献榜 Top %d[/b]\n" % [_fmt_dur(int(d.get("ends_in", 0))), int(d.get("total", 0)), top.size()]
	if top.is_empty():
		out += "[color=#9fb8cf]暂无贡献，去据点旁按 E 捐材料建/加固安全区！[/color]\n"
	else:
		var rank: int = 1
		for e_v: Variant in top:
			var e: Dictionary = e_v
			var medal: String = ["🥇", "🥈", "🥉"][rank - 1] if rank <= 3 else "%d." % rank
			out += "%s [color=#ffd24a]%s[/color] — %d 点\n" % [medal, String(e.get("name", "?")), int(e.get("points", 0))]
			rank += 1
	_lb_label.text = out

func _build_leaderboard_panel() -> void:
	var layer := CanvasLayer.new(); layer.layer = 62; add_child(layer)
	_lb_panel = Control.new(); _lb_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); layer.add_child(_lb_panel)
	var dim := ColorRect.new(); dim.color = Color(0, 0, 0, 0.6); dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); _lb_panel.add_child(dim)
	var card := Panel.new(); card.set_anchors_and_offsets_preset(Control.PRESET_CENTER); card.position = Vector2(-260, -230); card.size = Vector2(520, 460)
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(0.06, 0.09, 0.10, 0.98); sb.set_border_width_all(2); sb.border_color = Color(0.4, 0.85, 0.8, 0.7); sb.set_corner_radius_all(14)
	card.add_theme_stylebox_override("panel", sb); _lb_panel.add_child(card)
	var title := Label.new(); title.text = "🏰 全服建造贡献榜"; title.position = Vector2(0, 14); title.size = Vector2(520, 34); title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22); title.add_theme_color_override("font_color", Color(0.6, 1.0, 0.9, 1)); card.add_child(title)
	var scroll := ScrollContainer.new(); scroll.position = Vector2(20, 56); scroll.size = Vector2(480, 350); card.add_child(scroll)
	_lb_label = RichTextLabel.new(); _lb_label.bbcode_enabled = true; _lb_label.fit_content = true; _lb_label.custom_minimum_size = Vector2(460, 0)
	_lb_label.add_theme_font_size_override("normal_font_size", 16); scroll.add_child(_lb_label)
	var close := Button.new(); close.text = "关闭 (L)"; close.position = Vector2(200, 410); close.size = Vector2(120, 38)
	close.pressed.connect(func() -> void: _lb_panel.visible = false); card.add_child(close)

# 采集最近的水晶/矿脉 → 放入道具区（材料按名堆叠）。
func _try_gather() -> bool:
	if player == null or not is_instance_valid(player):
		return false
	var best: int = -1
	var bd: float = 1.0e9
	for i in range(gather_nodes.size()):
		var g: Dictionary = gather_nodes[i]
		if not is_instance_valid(g["node"]):
			continue
		var d: float = player.global_position.distance_to((g["node"] as Node3D).global_position)
		if d < bd:
			bd = d; best = i
	if best < 0 or bd > 3.8:
		return false
	var gg: Dictionary = gather_nodes[best]
	var item: Dictionary = gg["item"]
	inv.add_material(String(item["name"]), item["color"] as Color, int(gg["amount"]))
	flash_message("采集「%s」×%d，已放入道具区（按 B 查看）。" % [String(item["name"]), int(gg["amount"])])
	spawn_skill_flash((gg["node"] as Node3D).global_position + Vector3(0, 0.5, 0), item["color"] as Color, 1.6, 0.3)
	(gg["node"] as Node3D).queue_free()
	gather_nodes.remove_at(best)
	return true

func _try_npc() -> bool:
	if quest_system == null or player == null or in_dungeon:
		return false
	return quest_system.try_npc(player.global_position)

func _try_shelter() -> bool:
	if shelter_system == null or player == null or in_dungeon:
		return false
	return shelter_system.try_interact(player.global_position)

func _try_rest() -> bool:
	if terrain_system == null or player == null or in_dungeon:
		return false
	return terrain_system.try_rest(player.global_position)

func _try_rebuild_wall() -> bool:
	if outpost_system == null or player == null or in_dungeon:
		return false
	return outpost_system.try_toggle_rebuild()

func _try_enter_dungeon() -> bool:
	if in_dungeon or player == null:
		return false
	for d: Dictionary in DUNGEON_DEFS:
		var pv: Node3D = _dungeon_portals.get(int(d["id"]), null)
		if pv != null and is_instance_valid(pv) and not pv.visible:
			continue   # 未开放的守关秘境（非当前突破关卡）不可进入
		var dp: Vector3 = d["pos"] as Vector3
		if Vector2(player.global_position.x - dp.x, player.global_position.z - dp.z).length() <= 4.5:
			if Net.online:
				Net.send_dungeon("enter", int(d["id"]))   # 联机：走队长确认流程
			else:
				_sp_enter_dungeon(d)                       # 单机：本地进入
			return true
	return false

# ---------------- 单机副本（本地权威，记录仅存本地存档）----------------
func _sp_enter_dungeon(d: Dictionary) -> void:
	if int(player.level) < int(d["level_req"]):
		flash_message("等级不足：进入「%s」需 Lv.%d。" % [String(d["name"]), int(d["level_req"])])
		return
	var spawn: Vector3 = d.get("spawn", Vector3(0, 0.5, 4000))
	_enter_dungeon({"name": String(d["name"]), "spawn": spawn, "dungeon_id": int(d["id"])})
	sp_dungeon_active = true
	sp_dungeon_def = d
	sp_dungeon_monsters.clear()
	sp_dungeon_hidden = null
	sp_dungeon_hidden_done = false
	sp_dungeon_boss_dead = false
	_clear_dungeon_portal()
	var wl: int = int(d.get("wl", 3))
	for grp_v: Variant in d.get("mobs", []):
		var grp: Dictionary = grp_v
		for i in range(int(grp.get("n", 1))):
			var off := Vector3(rng.randf_range(-16, 16), 0, rng.randf_range(-16, 16))
			sp_dungeon_monsters.append(_spawn_monster(String(grp["kind"]), spawn + off, bool(grp.get("elite", false)), wl))
	# 守关副本 Boss：等级=该突破关卡等级（把常驻 Boss 降到这个等级放进副本）。
	var boss_lvl: int = -1
	for g_v: Variant in LEVEL_GATES:
		if int((g_v as Dictionary)["dungeon"]) == int(d["id"]):
			boss_lvl = int((g_v as Dictionary)["cap"])
	sp_dungeon_boss_pos = spawn + Vector3(0, 0, -12)
	sp_dungeon_boss = _spawn_monster(String(d["boss"]), sp_dungeon_boss_pos, false, wl + 1, boss_lvl)
	sp_dungeon_monsters.append(sp_dungeon_boss)

func _sp_dungeon_tick() -> void:
	if not sp_dungeon_active:
		return
	# Boss 死亡 → 生成结算传送门（走进去按 E 结算突破），不再自动通关。
	if sp_dungeon_boss != null and not is_instance_valid(sp_dungeon_boss):
		sp_dungeon_boss = null
		sp_dungeon_boss_dead = true
		_spawn_dungeon_portal(sp_dungeon_boss_pos)
		flash_message("⚔ 守关 Boss 已击败！走入传送门按 E 结算并突破等级上限。")
		if not sp_dungeon_hidden_done and randf() < 0.5:
			var hk: String = String(sp_dungeon_def.get("hidden", ""))
			if hk != "":
				var sp: Vector3 = sp_dungeon_def.get("spawn", Vector3(0, 0.5, 4000))
				sp_dungeon_hidden = _spawn_monster(hk, sp + Vector3(0, 0, -14), false, int(sp_dungeon_def.get("wl", 3)) + 2)
				sp_dungeon_monsters.append(sp_dungeon_hidden)
				flash_message("⚠ 隐藏 Boss 现身！（可选挑战，结算传送门已开启）")
	# 隐藏 Boss 死亡 → 隐藏首杀记录。
	if sp_dungeon_hidden != null and not is_instance_valid(sp_dungeon_hidden):
		sp_dungeon_hidden = null
		_sp_dungeon_clear(true)

# 结算传送门：Boss 死亡后在其处生成；走进按 E 结算。
func _spawn_dungeon_portal(pos: Vector3) -> void:
	_clear_dungeon_portal()
	var root := Node3D.new()
	root.global_position = Vector3(pos.x, 0.1, pos.z)   # 副本地板高度
	var mat := StandardMaterial3D.new(); mat.albedo_color = Color(0.5, 0.95, 1.0, 1)
	mat.emission_enabled = true; mat.emission = Color(0.4, 0.9, 1.0, 1); mat.emission_energy_multiplier = 3.0
	for i in range(3):
		var ring := MeshInstance3D.new(); var tm := TorusMesh.new(); tm.inner_radius = 1.4 + i * 0.25; tm.outer_radius = 1.7 + i * 0.25
		ring.mesh = tm; ring.material_override = mat; ring.position = Vector3(0, 1.2 + i * 0.5, 0); ring.rotation.x = PI * 0.5
		root.add_child(ring)
	var lt := OmniLight3D.new(); lt.light_color = Color(0.5, 0.95, 1.0, 1); lt.light_energy = 2.5; lt.omni_range = 12.0; lt.position = Vector3(0, 1.5, 0)
	root.add_child(lt)
	var lbl := Label3D.new(); lbl.text = "🌀 结算传送门\n站入按 E 结算突破"; lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.position = Vector3(0, 3.4, 0); lbl.font_size = 30; lbl.outline_size = 6; lbl.modulate = Color(0.6, 0.95, 1.0, 1)
	root.add_child(lbl)
	entity_root.add_child(root)
	sp_dungeon_portal = root

func _clear_dungeon_portal() -> void:
	if sp_dungeon_portal != null and is_instance_valid(sp_dungeon_portal):
		sp_dungeon_portal.queue_free()
	sp_dungeon_portal = null

# E 交互：站在结算传送门里 → 结算(通关+突破) → 离开秘境。单机/联机通用。
func _try_dungeon_settle() -> bool:
	if not in_dungeon or player == null or not is_instance_valid(player):
		return false
	if sp_dungeon_portal == null or not is_instance_valid(sp_dungeon_portal):
		return false
	if player.global_position.distance_to(sp_dungeon_portal.global_position) > 4.0:
		return false
	flash_message("🌀 结算完成，离开秘境。")
	if Net.online:
		_apply_mp_clear()
		Net.send_dungeon("leave", 0)   # 服务器权威离开
	else:
		if not dungeon_cleared:
			_sp_dungeon_clear(false)
		_sp_leave_dungeon(false)
	return true

# 联机通关结算（记录 + 突破上限 + 宠物蛋），仅执行一次。
func _apply_mp_clear() -> void:
	if _mp_clear_applied:
		return
	_mp_clear_applied = true
	dungeon_cleared = true
	dungeon_records.append({"name": dungeon_name, "clear_seconds": float(_mp_clear_info.get("clear_seconds", 0.0)), "unix": int(Time.get_unix_time_from_system())})
	_maybe_unlock_level_cap(dungeon_id)
	_pet_dungeon_reward()

func _sp_dungeon_clear(hidden: bool) -> void:
	if hidden:
		sp_dungeon_hidden_done = true
	var secs: float = float(Time.get_ticks_msec() - dungeon_enter_ms) / 1000.0
	dungeon_cleared = true
	dungeon_records.append({"name": dungeon_name, "clear_seconds": snappedf(secs, 0.1),
		"hidden": hidden, "unix": int(Time.get_unix_time_from_system())})
	flash_message("%s首杀达成！副本「%s」用时 %.1f 秒（已存本地记录）。" % ["隐藏Boss" if hidden else "Boss", dungeon_name, secs])
	if not hidden:
		_maybe_unlock_level_cap(dungeon_id)   # 通关 → 可能解锁升级上限
		_pet_dungeon_reward()

# 坠落深渊：掉到地面（y≈0）下方超过阈值即自动死亡（单机/联机、大世界/副本都生效）。
const FALL_DEATH_Y := -25.0

# 雪山严寒：站在雪线以上且不在篝火旁 → 持续掉血 + 蓝色寒冷叠层 + 视野雾加重（篝火/离开即缓解）。
func _update_cold(delta: float) -> void:
	if terrain_system == null or player == null or not is_instance_valid(player):
		return
	var cold: float = 0.0
	if terrain_system.has_method("cold_level"):
		cold = terrain_system.cold_level(player.global_position)
	var warm: bool = terrain_system.has_method("is_warm") and terrain_system.is_warm(player.global_position)
	var active: float = 0.0 if warm else cold
	if active > 0.05 and player.hp > 0.0:
		player.hp = maxf(1.0, player.hp - float(player.max_hp) * 0.02 * active * delta)   # 严寒掉血（不致死，留 1 血）
	# 叠层 + 雾渐变
	_cold_a = move_toward(_cold_a, active * 0.4, delta * 0.8)
	if cold_overlay != null:
		cold_overlay.color.a = _cold_a
	if world_env != null:
		world_env.fog_density = lerpf(_base_fog_density, 0.05, active)
		if active > 0.05:
			world_env.fog_light_color = Color(0.7, 0.8, 0.95, 1)

func _check_fall_death() -> void:
	if player == null or not is_instance_valid(player) or player.hp <= 0.0:
		return
	if player.global_position.y < FALL_DEATH_Y:
		player.hp = 0.0   # 触发死亡流程（含掉经验/离开副本）
		flash_message("坠入深渊，阵亡。")

func _sp_dungeon_cleanup() -> void:
	for m_v: Variant in sp_dungeon_monsters:
		if is_instance_valid(m_v):
			monsters.erase(m_v)
			(m_v as Node).queue_free()
	sp_dungeon_monsters.clear()
	sp_dungeon_active = false
	sp_dungeon_boss = null
	sp_dungeon_hidden = null
	sp_dungeon_boss_dead = false
	_clear_dungeon_portal()
	sp_dungeon_def = {}

func _build_dungeon_ui() -> void:
	dungeon_panel = Panel.new()
	dungeon_panel.position = Vector2(440, 8)
	dungeon_panel.size = Vector2(400, 44)
	dungeon_panel.visible = false
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(0.06, 0.04, 0.12, 0.8); sb.set_corner_radius_all(6)
	dungeon_panel.add_theme_stylebox_override("panel", sb)
	ui_layer.add_child(dungeon_panel)
	dungeon_label = Label.new()
	dungeon_label.position = Vector2(12, 10)
	dungeon_label.add_theme_font_size_override("font_size", 16)
	dungeon_panel.add_child(dungeon_label)

	# 退出副本按钮：左侧（小地图下方区域）。默认隐藏，进入副本才显示。
	dungeon_exit_btn = Button.new()
	dungeon_exit_btn.text = "退出副本"
	dungeon_exit_btn.position = Vector2(24, 330)
	dungeon_exit_btn.size = Vector2(150, 48)
	dungeon_exit_btn.add_theme_font_size_override("font_size", 20)
	dungeon_exit_btn.add_theme_stylebox_override("normal", _round_btn(Color(0.32, 0.12, 0.14, 0.88), Color(1.0, 0.5, 0.5, 0.9), 12))
	dungeon_exit_btn.add_theme_stylebox_override("hover", _round_btn(Color(0.42, 0.16, 0.18, 0.95), Color(1.0, 0.6, 0.6, 1), 12))
	dungeon_exit_btn.visible = false
	dungeon_exit_btn.pressed.connect(_on_dungeon_exit_pressed)
	ui_layer.add_child(dungeon_exit_btn)

	# 强退确认弹窗。
	dungeon_confirm = Panel.new()
	dungeon_confirm.position = Vector2(380, 260)
	dungeon_confirm.size = Vector2(440, 200)
	dungeon_confirm.visible = false
	var cs2 := StyleBoxFlat.new(); cs2.bg_color = Color(0.07, 0.05, 0.1, 0.97); cs2.set_corner_radius_all(8)
	dungeon_confirm.add_theme_stylebox_override("panel", cs2)
	ui_layer.add_child(dungeon_confirm)
	var ctext := Label.new()
	ctext.text = "强制退出副本？\n\n惩罚：损失约 10% 当前升级经验，\n且本次不计入通关记录。\n（通关 Boss 后退出无惩罚）"
	ctext.position = Vector2(20, 16); ctext.size = Vector2(400, 120)
	ctext.add_theme_font_size_override("font_size", 17)
	dungeon_confirm.add_child(ctext)
	var yes := Button.new(); yes.text = "确认强退"; yes.position = Vector2(40, 150); yes.size = Vector2(160, 38)
	yes.add_theme_color_override("font_color", Color(1.0, 0.6, 0.55, 1))
	yes.pressed.connect(_on_dungeon_force_confirm)
	dungeon_confirm.add_child(yes)
	var no := Button.new(); no.text = "取消"; no.position = Vector2(240, 150); no.size = Vector2(160, 38)
	no.pressed.connect(func() -> void: dungeon_confirm.visible = false)
	dungeon_confirm.add_child(no)

	# 队长开本确认弹窗（含准入范围/掉落率/是否计入记录）。
	dungeon_enter_panel = Panel.new()
	dungeon_enter_panel.position = Vector2(360, 230)
	dungeon_enter_panel.size = Vector2(480, 220)
	dungeon_enter_panel.visible = false
	var es := StyleBoxFlat.new(); es.bg_color = Color(0.05, 0.07, 0.12, 0.97); es.set_corner_radius_all(8)
	dungeon_enter_panel.add_theme_stylebox_override("panel", es)
	ui_layer.add_child(dungeon_enter_panel)
	dungeon_enter_label = Label.new()
	dungeon_enter_label.position = Vector2(20, 16); dungeon_enter_label.size = Vector2(440, 140)
	dungeon_enter_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dungeon_enter_label.add_theme_font_size_override("font_size", 16)
	dungeon_enter_panel.add_child(dungeon_enter_label)
	var go := Button.new(); go.text = "进入副本"; go.position = Vector2(40, 170); go.size = Vector2(180, 38)
	go.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7, 1))
	go.pressed.connect(func() -> void:
		dungeon_enter_panel.visible = false
		Net.send_dungeon("enter_confirm", _pending_dungeon_id))
	dungeon_enter_panel.add_child(go)
	var cancel := Button.new(); cancel.text = "取消"; cancel.position = Vector2(260, 170); cancel.size = Vector2(180, 38)
	cancel.pressed.connect(func() -> void: dungeon_enter_panel.visible = false)
	dungeon_enter_panel.add_child(cancel)

func _on_dungeon_exit_pressed() -> void:
	if not Net.online and sp_dungeon_boss_dead and not dungeon_cleared:
		_sp_dungeon_clear(false)   # Boss 已死：离开即视为结算通关，无惩罚
	if Net.online and sp_dungeon_portal != null and is_instance_valid(sp_dungeon_portal) and not dungeon_cleared:
		_apply_mp_clear()          # 联机：Boss 已死则离开即结算
	if dungeon_cleared:
		if Net.online:
			Net.send_dungeon("leave", 0)   # 已通关：无惩罚直接离开
		else:
			_sp_leave_dungeon(false)
	elif dungeon_confirm != null:
		dungeon_confirm.visible = true

func _on_dungeon_force_confirm() -> void:
	if dungeon_confirm != null:
		dungeon_confirm.visible = false
	if player != null and is_instance_valid(player):
		player.apply_death_penalty()   # 强退惩罚：扣经验
	if Net.online:
		Net.send_dungeon("force_leave", 0)
	else:
		_sp_leave_dungeon(true)

func _sp_leave_dungeon(force: bool) -> void:
	_sp_dungeon_cleanup()
	_leave_dungeon({"force": force, "dungeon_id": dungeon_id})

func _enter_dungeon(info: Dictionary) -> void:
	in_dungeon = true
	dungeon_name = String(info.get("name", "副本"))
	dungeon_id = int(info.get("dungeon_id", 0))
	dungeon_cleared = false
	dungeon_enter_ms = Time.get_ticks_msec()
	if dungeon_exit_btn != null:
		dungeon_exit_btn.visible = true
	var spawn: Vector3 = info.get("spawn", Vector3(0, 0.5, 4000))
	_dungeon_spawn_pos = spawn
	_mp_clear_info = {}
	_mp_clear_applied = false
	sp_dungeon_boss_dead = false
	_clear_dungeon_portal()
	if player != null and is_instance_valid(player):
		player.global_position = spawn + Vector3(0, 0.3, 0)
		player.velocity = Vector3.ZERO
	# 临时地板。
	dungeon_floor = StaticBody3D.new()
	dungeon_floor.position = Vector3(spawn.x, 0.0, spawn.z)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new(); box.size = Vector3(60, 0.4, 60)
	cs.shape = box; cs.position = Vector3(0, -0.2, 0)
	dungeon_floor.add_child(cs)
	var fm := MeshInstance3D.new()
	var pm := BoxMesh.new(); pm.size = Vector3(60, 0.4, 60)
	fm.mesh = pm; fm.position = Vector3(0, -0.2, 0)
	fm.material_override = _mat(Color(0.12, 0.1, 0.18, 1), 0.05)
	dungeon_floor.add_child(fm)
	(world_root if world_root != null else self).add_child(dungeon_floor)
	# 主题=矿洞：搭建水晶矿洞内部（岩壁/顶盖/发光水晶/幽蓝灯光）。
	var theme: String = ""
	for d: Dictionary in DUNGEON_DEFS:
		if int(d["id"]) == dungeon_id:
			theme = String(d.get("theme", ""))
			break
	if theme == "cave":
		_build_cave_interior(spawn)
	# 暂停大世界流式加载。
	if streamer != null and is_instance_valid(streamer):
		streamer.set_process(false)
		streamer.set_physics_process(false)
	if dungeon_panel != null:
		dungeon_panel.visible = true
	flash_message("进入副本：%s。" % dungeon_name)

func _build_cave_interior(spawn: Vector3) -> void:
	dungeon_cave_root = Node3D.new()
	dungeon_cave_root.position = Vector3(spawn.x, 0.0, spawn.z)
	(world_root if world_root != null else self).add_child(dungeon_cave_root)
	var rock: StandardMaterial3D = _mat(Color(0.15, 0.16, 0.21, 1), 0.0)
	var half: float = 30.0
	var wall_h: float = 16.0
	# 顶盖（挡住阳光，营造洞内幽暗）
	var ceil := MeshInstance3D.new()
	var cbm := BoxMesh.new(); cbm.size = Vector3(64, 2, 64)
	ceil.mesh = cbm; ceil.material_override = rock; ceil.position = Vector3(0, wall_h, 0)
	dungeon_cave_root.add_child(ceil)
	# 四面岩壁（带碰撞，围住空间）
	for side: Vector3 in [Vector3(0, 0, -half), Vector3(0, 0, half), Vector3(-half, 0, 0), Vector3(half, 0, 0)]:
		var sz: Vector3 = Vector3(64, wall_h, 2) if absf(side.z) > 0.1 else Vector3(2, wall_h, 64)
		var wall := StaticBody3D.new()
		wall.position = side + Vector3(0, wall_h * 0.5, 0)
		var wcs := CollisionShape3D.new(); var wbs := BoxShape3D.new(); wbs.size = sz; wcs.shape = wbs
		wall.add_child(wcs)
		var wmi := MeshInstance3D.new(); var wbm := BoxMesh.new(); wbm.size = sz; wmi.mesh = wbm; wmi.material_override = rock
		wall.add_child(wmi)
		dungeon_cave_root.add_child(wall)
	# 发光水晶簇 + 少量点光
	var rng := RandomNumberGenerator.new(); rng.seed = 7788
	for i in range(26):
		var cx: float = rng.randf_range(-half + 3.0, half - 3.0)
		var cz: float = rng.randf_range(-half + 3.0, half - 3.0)
		var col: Color = Color(0.4, 0.85, 1.0, 1) if rng.randf() < 0.6 else Color(0.72, 0.5, 1.0, 1)
		for j in range(rng.randi_range(2, 4)):
			var s: float = rng.randf_range(0.8, 2.4)
			var cry := MeshInstance3D.new()
			var pm := PrismMesh.new(); pm.size = Vector3(0.4 * s, 1.6 * s, 0.4 * s)
			cry.mesh = pm; cry.material_override = _mat(col, 2.6)
			cry.position = Vector3(cx + rng.randf_range(-1.2, 1.2), 0.8 * s, cz + rng.randf_range(-1.2, 1.2))
			cry.rotation = Vector3(rng.randf_range(-0.3, 0.3), rng.randf() * TAU, rng.randf_range(-0.3, 0.3))
			dungeon_cave_root.add_child(cry)
		if i % 4 == 0:
			var lt := OmniLight3D.new()
			lt.position = Vector3(cx, 2.2, cz); lt.light_color = col; lt.light_energy = 2.0; lt.omni_range = 15.0
			dungeon_cave_root.add_child(lt)
	# 可采集的星莹水晶矿脉（按 E 采集 → 道具区）。
	for m in range(8):
		var mx: float = rng.randf_range(-24.0, 24.0)
		var mz: float = rng.randf_range(-24.0, 24.0)
		var vein := Node3D.new()
		vein.position = Vector3(mx, 0, mz)
		dungeon_cave_root.add_child(vein)
		for j in range(rng.randi_range(3, 5)):
			var s: float = rng.randf_range(1.4, 2.8)
			var cr := MeshInstance3D.new()
			var pm := PrismMesh.new(); pm.size = Vector3(0.5 * s, 2.0 * s, 0.5 * s)
			cr.mesh = pm; cr.material_override = _mat(Color(0.45, 0.95, 1.0, 1), 3.2)
			cr.position = Vector3(rng.randf_range(-0.8, 0.8), 1.0 * s, rng.randf_range(-0.8, 0.8))
			cr.rotation = Vector3(rng.randf_range(-0.2, 0.2), rng.randf() * TAU, rng.randf_range(-0.2, 0.2))
			vein.add_child(cr)
		var glbl := Label3D.new()
		glbl.text = "⛏ 星莹水晶（按 E 采集）"
		glbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		glbl.position = Vector3(0, 3.6, 0); glbl.font_size = 20; glbl.outline_size = 5
		glbl.modulate = Color(0.5, 0.95, 1.0, 1)
		vein.add_child(glbl)
		var glt := OmniLight3D.new()
		glt.position = Vector3(0, 2.0, 0); glt.light_color = Color(0.45, 0.95, 1.0, 1); glt.light_energy = 2.4; glt.omni_range = 10.0
		vein.add_child(glt)
		register_gather(vein, {"name": "星莹水晶", "color": Color(0.45, 0.95, 1.0, 1)}, rng.randi_range(2, 4), false)
	# 幽蓝环境（进洞变暗、偏蓝；离开时还原）
	if world_env != null:
		_cave_prev_ambient_e = world_env.ambient_light_energy
		_cave_prev_ambient_c = world_env.ambient_light_color
		world_env.ambient_light_energy = 0.35
		world_env.ambient_light_color = Color(0.22, 0.36, 0.56, 1)

func _leave_dungeon(info: Dictionary) -> void:
	in_dungeon = false
	_clear_dungeon_portal()
	var forced: bool = bool(info.get("force", false))
	# 回到大世界副本入口（按副本 id 找入口点），否则回出生点。
	var back: Vector3 = Vector3(0, 0.5, 7)
	for d: Dictionary in DUNGEON_DEFS:
		if int(d["id"]) == dungeon_id:
			back = (d["pos"] as Vector3) + Vector3(2, 0.5, 2)
			break
	if player != null and is_instance_valid(player):
		player.global_position = back
		player.velocity = Vector3.ZERO
	if dungeon_floor != null and is_instance_valid(dungeon_floor):
		dungeon_floor.queue_free()
	dungeon_floor = null
	# 矿洞装饰清理 + 环境还原 + 移除洞内采集点（大世界的采集点保留）。
	gather_nodes = gather_nodes.filter(func(g: Dictionary) -> bool: return bool(g.get("persistent", false)))
	if dungeon_cave_root != null and is_instance_valid(dungeon_cave_root):
		dungeon_cave_root.queue_free()
		if world_env != null:
			world_env.ambient_light_energy = _cave_prev_ambient_e
			world_env.ambient_light_color = _cave_prev_ambient_c
	dungeon_cave_root = null
	if streamer != null and is_instance_valid(streamer):
		streamer.set_process(true)
		streamer.set_physics_process(true)
	if dungeon_panel != null:
		dungeon_panel.visible = false
	if dungeon_exit_btn != null:
		dungeon_exit_btn.visible = false
	if dungeon_confirm != null:
		dungeon_confirm.visible = false
	if forced:
		flash_message("已退出副本「%s」。" % dungeon_name)
	else:
		flash_message("离开副本「%s」。" % dungeon_name)
	dungeon_cleared = false

func _update_dungeon_ui() -> void:
	if in_dungeon and dungeon_label != null:
		var t: float = float(Time.get_ticks_msec() - dungeon_enter_ms) / 1000.0
		dungeon_label.text = "副本：%s   用时 %.1f 秒" % [dungeon_name, t]

func _update_camera(delta: float) -> void:
	if player == null or camera == null:
		return
	# 由 yaw/pitch 直接构造朝向，避免 look_at 在接近垂直时的退化/翻转。
	var basis := Basis.from_euler(Vector3(-cam_pitch, cam_yaw, 0.0))
	var forward := Vector3(-sin(cam_yaw) * cos(cam_pitch), -sin(cam_pitch), -cos(cam_yaw) * cos(cam_pitch))
	var pos: Vector3
	if first_person:
		# 第一人称：相机置于头部高度，沿视线方向前移一点，避免穿到头部模型里。
		pos = player.global_position + Vector3(0, FP_EYE_HEIGHT, 0) + forward * FP_FORWARD_NUDGE
	else:
		# 第三人称：相机沿 -forward 方向环绕目标，距离由滚轮控制。
		var target := player.global_position + Vector3(0, 1.35, 0)
		pos = target - forward * cam_distance
	# 镜头震动（打击感）：创伤平方衰减，扰动位置与朝向。
	if _cam_trauma > 0.0:
		var s: float = _cam_trauma * _cam_trauma
		var rx: float = randf_range(-1.0, 1.0)
		var ry: float = randf_range(-1.0, 1.0)
		var rz: float = randf_range(-1.0, 1.0)
		pos += basis.x * (rx * 0.45 * s) + basis.y * (ry * 0.45 * s)
		basis = basis * Basis.from_euler(Vector3(ry * 0.035 * s, rx * 0.035 * s, rz * 0.05 * s))
		_cam_trauma = maxf(0.0, _cam_trauma - delta * 1.8)
	camera.global_transform = Transform3D(basis, pos)
	if hurt_overlay != null and _hurt_a > 0.0:
		_hurt_a = maxf(0.0, _hurt_a - delta * 1.3)
		hurt_overlay.color.a = _hurt_a

# 施加镜头震动（打击感）。amount 累加到创伤值。
func add_camera_shake(amount: float) -> void:
	_cam_trauma = minf(1.0, _cam_trauma + amount)

# 距玩家较近的爆炸/命中才震屏，避免远处误震。
func shake_at(world_pos: Vector3, amount: float, max_dist: float = 22.0) -> void:
	if player == null or not is_instance_valid(player):
		return
	var d: float = player.global_position.distance_to(world_pos)
	if d < max_dist:
		add_camera_shake(amount * clampf(1.0 - d / max_dist, 0.15, 1.0))

# 受击红闪（打击感）：脉冲叠层 alpha。
func flash_hurt(intensity: float = 0.35) -> void:
	_hurt_a = maxf(_hurt_a, clampf(intensity, 0.0, 0.5))

func _update_ui(delta: float) -> void:
	if player == null or hud_label == null:
		return
	var boss_hp := ""
	for node in monsters:
		var monster: StarGloryMonster = node as StarGloryMonster
		if monster != null and is_instance_valid(monster) and monster.is_boss and not monster.dead:
			boss_hp = "\nBoss %s HP %d/%d" % [monster.monster_name, int(monster.hp), monster.max_hp]
			break
	var rg: Dictionary = region_of(player.global_position)
	var prog := "\n[color=#9fe0ff]区域：%s[/color]  ·  怪物 Lv.%d-%d  ·  准入 Lv.%d  ·  升级上限 Lv.%d" % [String(rg["name"]), int(rg["lmin"]), int(rg["lmax"]), int(rg["entry"]), level_cap]
	hud_label.text = "[b][color=#9cecff]STAR GLORY / 星辉荣耀[/color][/b]\n%s%s%s" % [player.get_status_text(), prog, boss_hp]
	_check_breakthrough_notify()
	_update_dungeon_entrance_vis()
	if not _hud_collapsed and hud_tab_scroll != null:   # 节流刷新 Tab 内容，保留滚动位置
		_hud_tab_t -= delta
		if _hud_tab_t <= 0.0:
			_hud_tab_t = 0.7
			var sv: int = hud_tab_scroll.scroll_vertical
			_rebuild_hud_tab()
			hud_tab_scroll.set_deferred("scroll_vertical", sv)
	_update_skill_hotbar()
	equip_label.text = "装备加成（B 背包查看）\n" + player.equipment_summary()
	_refresh_quick_items()
	if message_timer > 0.0:
		message_timer -= delta
		if message_timer <= 0.0:
			message_label.text = ""

# 任务/技能 Tab 切换 + 收缩。
func _set_hud_tab(i: int) -> void:
	_hud_tab = i
	if _hud_collapsed:          # 点标签时若处于收起状态则自动展开
		_hud_collapsed = false
	if hud_tab_scroll != null:
		hud_tab_scroll.scroll_vertical = 0
	_hud_tab_refresh()

func _toggle_hud_collapse() -> void:
	_hud_collapsed = not _hud_collapsed
	_hud_tab_refresh()

func _hud_tab_refresh() -> void:
	if hud_tab_scroll == null:
		return
	var on := Color(0.5, 0.95, 1.0, 1)
	var off := Color(0.7, 0.75, 0.82, 1)
	hud_tab_btn_quest.add_theme_color_override("font_color", on if _hud_tab == 0 else off)
	hud_tab_btn_skill.add_theme_color_override("font_color", on if _hud_tab == 1 else off)
	hud_tab_collapse.text = "展开 ▼" if _hud_collapsed else "收起 ▲"
	hud_tab_bg.visible = not _hud_collapsed
	hud_tab_scroll.visible = not _hud_collapsed
	if equip_panel != null:
		equip_panel.visible = not _hud_collapsed      # 装备加成随 Tab 一并收起/展开
	if equip_label != null:
		equip_label.visible = not _hud_collapsed
	if not _hud_collapsed:
		_rebuild_hud_tab()

# 重建 Tab 内容：任务=按类别分栏(可收放);技能=技能详情文字。
func _rebuild_hud_tab() -> void:
	if hud_tab_vbox == null:
		return
	if _hud_tab == 0:
		if quest_system != null and quest_system.has_method("build_sections"):
			quest_system.build_sections(hud_tab_vbox)
	else:
		for c in hud_tab_vbox.get_children():
			c.queue_free()
		var lbl := RichTextLabel.new()
		lbl.bbcode_enabled = true; lbl.fit_content = true; lbl.scroll_active = false
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lbl.custom_minimum_size = Vector2(344, 0)
		lbl.add_theme_font_size_override("normal_font_size", 14)
		lbl.text = player.skill_status_text() if player != null and is_instance_valid(player) else ""
		hud_tab_vbox.add_child(lbl)

func _quest_text() -> String:
	var lvl: int = player.level if player != null else 1
	# 找当前等级卡关：到 cap 需通关对应单人副本。
	var gate: Dictionary = {}
	for g_v: Variant in LEVEL_GATES:
		var g: Dictionary = g_v
		if level_cap == int(g["cap"]):
			gate = g
			break
	var gate_line: String = ""
	if not gate.is_empty():
		var dn: String = ""
		for d: Dictionary in DUNGEON_DEFS:
			if int(d["id"]) == int(gate["dungeon"]):
				dn = String(d["name"])
				break
		if lvl >= level_cap:
			gate_line = "★ 已达上限 Lv.%d：通关单人副本「%s」即可突破到 Lv.%d。\n" % [level_cap, dn, int(gate["next"])]
		else:
			gate_line = "升级上限 Lv.%d（到顶后需通关「%s」解锁 Lv.%d）。\n" % [level_cap, dn, int(gate["next"])]
	else:
		gate_line = "升级上限 Lv.%d。\n" % level_cap
	if Net.online:
		return "联机共享世界：与其他玩家并肩探索共斗。\n%s越远的区域怪物等级越高、准入越高。" % gate_line
	return "成长目标：出村打怪升级、收集材料。\n%s越往外走，怪物等级/准入越高（见上方区域条）。" % gate_line

func spawn_projectile(data: Dictionary) -> void:
	var projectile: StarGloryProjectile = ProjectileScene.new()
	projectile.setup(data)
	projectile_root.add_child(projectile)

func get_mouse_aim_direction(from_pos: Vector3) -> Vector3:
	var point: Vector3 = get_mouse_aim_world(from_pos + Vector3(0, 0, -6), from_pos.y)
	var dir: Vector3 = point - from_pos
	dir.y = 0.0
	if dir.length() <= 0.05:
		return Vector3(-sin(cam_yaw), 0, -cos(cam_yaw)).normalized()
	return dir.normalized()

func get_mouse_aim_world(fallback: Vector3, plane_y: float = 0.0) -> Vector3:
	if camera == null:
		return fallback
	# 手机端瞄准时用「点击的屏幕位置」代替鼠标位置。
	var mouse_pos: Vector2 = _mobile_aim_screen if _mobile_aim_active else get_viewport().get_mouse_position()
	var origin: Vector3 = camera.project_ray_origin(mouse_pos)
	var normal: Vector3 = camera.project_ray_normal(mouse_pos)
	if abs(normal.y) < 0.001:
		return fallback
	var t: float = (plane_y - origin.y) / normal.y
	if t < 0.0:
		return fallback
	var point: Vector3 = origin + normal * t
	var allowed_radius: float = get_unlocked_radius()
	point.x = clamp(point.x, -allowed_radius + 2.0, allowed_radius - 2.0)
	point.z = clamp(point.z, -allowed_radius + 2.0, allowed_radius - 2.0)
	point.y = plane_y
	return point

# ---------------- 落点瞄准（天星/火焰雨前摇期间可调） ----------------
# 由技能节点在前摇期间驱动：PC 鼠标移动落点；手机摇杆移动落点；点按世界设置落点。
const AIM_MOVE_SPEED := 22.0
var aim_active: bool = false
var aim_point: Vector3 = Vector3.ZERO
var _aim_tap_pending: bool = false
var _aim_tap_point: Vector3 = Vector3.ZERO

func begin_skill_aim(start_pt: Vector3) -> void:
	aim_active = true
	aim_point = Vector3(start_pt.x, 0.0, start_pt.z)
	_aim_tap_pending = false

func end_skill_aim() -> void:
	aim_active = false
	_aim_tap_pending = false

func update_skill_aim(delta: float) -> Vector3:
	if not aim_active:
		return aim_point
	if _is_mobile():
		# 手机：摇杆方向移动落点（相机系）。
		if player != null and is_instance_valid(player):
			var jm: Vector2 = player.touch_move
			if jm.length() > 0.05:
				var fwd := Vector3(-sin(cam_yaw), 0, -cos(cam_yaw))
				var rgt := Vector3(cos(cam_yaw), 0, -sin(cam_yaw))
				aim_point += (rgt * jm.x + fwd * jm.y) * AIM_MOVE_SPEED * delta
	else:
		# PC：鼠标位置直接取地面点。
		aim_point = get_mouse_aim_world(aim_point, 0.0)
	# 点按世界设置的落点（PC/手机通用）。
	if _aim_tap_pending:
		aim_point = _aim_tap_point
		_aim_tap_pending = false
	var r: float = get_unlocked_radius()
	aim_point.x = clamp(aim_point.x, -r + 2.0, r - 2.0)
	aim_point.z = clamp(aim_point.z, -r + 2.0, r - 2.0)
	aim_point.y = 0.0
	return aim_point

# 点按大世界某处 → 设置落点（屏幕坐标投到地面）。
func set_aim_tap(screen_pos: Vector2) -> void:
	if not aim_active or camera == null:
		return
	var origin: Vector3 = camera.project_ray_origin(screen_pos)
	var normal: Vector3 = camera.project_ray_normal(screen_pos)
	if abs(normal.y) < 0.001:
		return
	var t: float = (0.0 - origin.y) / normal.y
	if t < 0.0:
		return
	_aim_tap_point = origin + normal * t
	_aim_tap_pending = true

func spawn_skill_flash(pos: Vector3, color: Color, radius: float, duration: float) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = max(radius, 0.2)
	mesh.height = max(radius, 0.2) * 2.0
	mesh.radial_segments = 24
	mesh.rings = 12
	var mi := MeshInstance3D.new()
	mi.name = "SkillFlash"
	mi.mesh = mesh
	mi.position = pos
	mi.scale = Vector3.ONE * 0.12
	var mat := _mat(color, 1.6, 0.35)
	mi.material_override = mat
	effect_root.add_child(mi)
	var tween := create_tween()
	tween.tween_property(mi, "scale", Vector3.ONE, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(mat, "albedo_color:a", 0.0, duration)
	tween.tween_callback(mi.queue_free)

func flash_damage(pos: Vector3, text: String, color: Color) -> void:
	var label: Label3D = Label3D.new()
	label.text = "✹ %s" % text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 60
	label.pixel_size = 0.0100
	label.outline_size = 14
	label.outline_modulate = Color(0.08, 0.02, 0.12, 0.95)
	label.modulate = color
	label.no_depth_test = true
	label.position = pos + Vector3(rng.randf_range(-0.18, 0.18), rng.randf_range(0.0, 0.15), rng.randf_range(-0.18, 0.18))
	effect_root.add_child(label)
	var end_pos: Vector3 = label.position + Vector3(rng.randf_range(-0.20, 0.20), 1.55, rng.randf_range(-0.20, 0.20))
	var tween: Tween = create_tween()
	tween.tween_property(label, "scale", Vector3.ONE * 1.24, 0.10).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "scale", Vector3.ONE, 0.12)
	tween.parallel().tween_property(label, "position", end_pos, 0.78).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(label, "modulate:a", 0.0, 0.78).set_delay(0.14)
	tween.tween_callback(label.queue_free)

func flash_message(text: String) -> void:
	if message_label != null:
		message_label.text = text
	message_timer = 3.2
	# 同步进聊天「系统」频道。
	if chat_log != null:
		_append_chat("system", "", text)

# 同伴示警：范围内的敌人把仇恨给到攻击者（同伴被击中→一起追击该玩家）。
func aggro_nearby(pos: Vector3, source: Node, radius: float) -> void:
	if source == null or not is_instance_valid(source):
		return
	var sp: Vector3 = (source as Node3D).global_position
	for node in monsters:
		var m: StarGloryMonster = node as StarGloryMonster
		if m == null or not is_instance_valid(m) or m.dead or m.is_puppet:
			continue
		if m.global_position.distance_to(pos) <= radius:
			m.has_target = true
			m.last_known = sp
			m.hurt_aggro_timer = max(m.hurt_aggro_timer, 6.0)

func on_monster_died(monster: StarGloryMonster) -> void:
	if quest_system != null:
		quest_system.on_kill(monster.is_boss)   # 任务:击杀计数
	if achievement_system != null:
		achievement_system.on_kill(monster.is_boss)
	if monster.is_boss:
		_pet_boss_roll()   # 常驻 Boss 概率掉宠物蛋/技能书
	# 打击感：击杀震屏 + 爆裂闪光（Boss 更强）。
	shake_at(monster.global_position, 0.5 if monster.is_boss else 0.16)
	spawn_skill_flash(monster.global_position + Vector3(0, 0.8, 0), Color(1.0, 0.9, 0.6, 1), 2.6 if monster.is_boss else 1.3, 0.22)
	if monster.is_boss:
		var bpos0: Vector3 = monster.global_position + Vector3(0, 0.4, 0)
		# 单机副本内的 Boss：只给掉落，不动世界等级/关卡闸门（通关由 _sp_dungeon_tick 判定）。
		if in_dungeon and not Net.online:
			var bn0: int = 2 + int(int(sp_dungeon_def.get("wl", 3)) / 2)
			for i in range(bn0):
				_spawn_equipment_drop(bpos0)
			_spawn_lifesteal_gear(bpos0)
			_spawn_potion(bpos0)
			_roll_boss_material_drops(bpos0)
			if player != null:
				player.gain_exp(monster.exp_reward)
			monsters.erase(monster)
			monster.queue_free()
			return
		boss_defeated = true
		_record_boss_kill(monster)
		var bpos: Vector3 = monster.global_position + Vector3(0, 0.4, 0)
		if monster.resident:
			# 常驻 Boss：丰厚掉落（含吸血主/副武器）+ 定时重生，不改世界等级/闸门。
			flash_message("击败常驻 Boss「%s」！掉落吸血装备。" % monster.monster_name)
			for i in range(3):
				_spawn_equipment_drop(bpos)
			_spawn_lifesteal_gear(bpos)
			_spawn_lifesteal_gear(bpos)
			_spawn_potion(bpos, "hp")
			_spawn_magnet(bpos)
			_roll_boss_material_drops(bpos)
			for z: Dictionary in resident_zones:
				if z["boss"] == monster:
					z["boss"] = null
					z["respawn"] = RESIDENT_RESPAWN
		else:
			# 世界 Boss（原守关 Boss 改为大世界常驻，不再推进世界等级/不再作升级闸门）。
			flash_message("击败世界 Boss「%s」！掉落丰厚。" % monster.monster_name)
			var wtier: int = monster.world_level
			var bn: int = 2 + int(wtier / 2)
			for i in range(bn):
				_spawn_equipment_drop(bpos)
			_spawn_lifesteal_gear(bpos)
			_spawn_potion(bpos)
			_spawn_magnet(bpos)
			if rng.randf() < minf(0.85, 0.5 + 0.08 * float(wtier - 1)):
				_spawn_scroll(bpos)
			_roll_boss_material_drops(bpos)
	else:
		kills += 1
		flash_message("击败 %s，获得 %d EXP" % [monster.monster_name, monster.exp_reward])
		var wl: int = get_world_level()
		var dpos: Vector3 = monster.global_position + Vector3(0, 0.4, 0)
		# 小怪：仅低概率掉落「装备」或「药水」（其一），扩展卷只有 Boss 会掉。
		var roll: float = rng.randf()
		var equip_chance: float = minf(0.30, 0.16 + 0.02 * float(wl - 1))
		var potion_chance: float = minf(0.18, 0.10 + 0.015 * float(wl - 1))
		if roll < equip_chance:
			_spawn_equipment_drop(dpos)
		elif roll < equip_chance + potion_chance:
			_spawn_potion(dpos)
		# 磁铁：极低概率（实用道具）。
		if rng.randf() < 0.04:
			_spawn_magnet(dpos)
	skills.maybe_drop_book(monster)
	if player != null:
		player.gain_exp(monster.exp_reward)
	monsters.erase(monster)
	monster.queue_free()

func pickup_nearest() -> void:
	if player == null:
		return
	# 联机：找最近的共享掉落物，向服务器请求拾取（先到先得，由服务器裁决后再移除/入库）。
	if Net.online:
		var n: StarGloryPickup = null
		var nb: float = 999.0
		for node in pickups:
			var p: StarGloryPickup = node as StarGloryPickup
			if p == null or not is_instance_valid(p) or p.net_drop_id < 0:
				continue
			var d: float = p.global_position.distance_to(player.global_position)
			if d < nb:
				nb = d
				n = p
		if n != null and nb <= 3.2:
			Net.send_pickup(n.net_drop_id)
		else:
			flash_message("附近没有可拾取的物品。")
		return
	var nearest: StarGloryPickup = null
	var best: float = 999.0
	for node in pickups:
		var pickup: StarGloryPickup = node as StarGloryPickup
		if pickup == null or not is_instance_valid(pickup):
			continue
		var d: float = pickup.global_position.distance_to(player.global_position)
		if d < best:
			best = d
			nearest = pickup
	if nearest != null and best <= 3.2:
		_collect_pickup_offline(nearest)
	else:
		flash_message("附近没有可拾取的物品。")

# 单机：拾取一个掉落物。技能书直接学习；装备/道具放进背包（装备按 2048 自动合成）。
func _collect_pickup_offline(p: StarGloryPickup) -> void:
	if p == null or not is_instance_valid(p):
		return
	_apply_collected_item(p.item_data)
	pickups.erase(p)
	p.queue_free()

# 把一件拾取物归类放入背包/系统。
func _apply_collected_item(item: Dictionary) -> void:
	var kind: String = String(item.get("kind", "equipment"))
	match kind:
		"equipment":
			var etype: String = String(item.get("etype", InventoryManager.TYPES[0]))
			var tier: int = int(item.get("tier", 1))
			inv.add_equipment(etype, tier)
			_pickup_count += 1; _pickup_msg_timer = 0.5   # 合并提示，避免逐件刷屏卡顿
		"skillbook":
			# 技能书沿用既有学习/升级逻辑（不进 2048 背包）。
			skills.add_book(String(item.get("skill_id", "")), int(item.get("tier", 1)))
		"potion", "magnet", "scroll":
			inv.add_item(item)
			_pickup_count += 1; _pickup_msg_timer = 0.5
		"material":
			inv.add_material(String(item.get("mat", item.get("name", ""))), item.get("color", Color(0.8, 0.9, 1.0, 1)) as Color, int(item.get("amount", 1)))
			_pickup_count += 1; _pickup_msg_timer = 0.5
		_:
			inv.add_item(item)

# 背包内容变化：置脏，由 _process 每帧最多刷新一次（批量拾取时避免逐件重建 UI）。
func _on_inventory_changed() -> void:
	_backpack_dirty = true

# ---------------- 背包 UI（左：角色预览+装备格+属性；右：物品格子） ----------------

func _build_backpack() -> void:
	backpack_panel = Panel.new()
	backpack_panel.name = "Backpack"
	backpack_panel.position = Vector2(268, 96)
	backpack_panel.size = Vector2(744, 512)
	backpack_panel.visible = false
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.05, 0.07, 0.13, 0.97)
	box.set_border_width_all(2)
	box.border_color = Color(0.35, 0.6, 0.9, 0.7)
	box.set_corner_radius_all(12)
	box.shadow_color = Color(0, 0, 0, 0.5)
	box.shadow_size = 16
	backpack_panel.add_theme_stylebox_override("panel", box)
	ui_layer.add_child(backpack_panel)

	backpack_title = Label.new()
	backpack_title.text = "背包"
	backpack_title.position = Vector2(20, 10)
	backpack_title.size = Vector2(300, 30)
	backpack_title.add_theme_font_size_override("font_size", 22)
	backpack_title.add_theme_color_override("font_color", Color(0.72, 0.95, 1.0, 1))
	backpack_panel.add_child(backpack_title)

	# 标签：装备 / 道具
	bp_tab_equip_btn = _tab(Vector2(150, 12), "装备", func() -> void: _show_bp_tab("equip"))
	bp_tab_items_btn = _tab(Vector2(250, 12), "道具", func() -> void: _show_bp_tab("items"))

	var close := Button.new()
	close.text = "关闭 (B)"
	close.position = Vector2(624, 10)
	close.size = Vector2(104, 30)
	close.pressed.connect(_toggle_backpack)
	backpack_panel.add_child(close)

	_build_equip_view()
	_build_items_view()

func _tab(pos: Vector2, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.position = pos
	b.size = Vector2(92, 30)
	b.text = text
	b.add_theme_font_size_override("font_size", 16)
	b.pressed.connect(cb)
	backpack_panel.add_child(b)
	return b

# ===== 装备标签：左=预览+11分页+属性，右=选中分页的 2048 网格 =====
func _build_equip_view() -> void:
	bp_equip_view = Control.new()
	bp_equip_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bp_equip_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backpack_panel.add_child(bp_equip_view)
	_inset(bp_equip_view, Vector2(14, 48), Vector2(426, 450))
	_inset(bp_equip_view, Vector2(450, 48), Vector2(280, 450))

	# 预览格（居中）
	preview_box = Panel.new()
	preview_box.position = Vector2(182, 66)
	preview_box.size = Vector2(110, 176)
	var pbox := StyleBoxFlat.new()
	pbox.bg_color = Color(0.03, 0.05, 0.10, 1)
	pbox.set_border_width_all(1)
	pbox.border_color = Color(0.3, 0.5, 0.8, 0.5)
	pbox.set_corner_radius_all(8)
	preview_box.add_theme_stylebox_override("panel", pbox)
	bp_equip_view.add_child(preview_box)

	# 11 个分页装备格：左 4、右 4、下 3（每个 = 一类装备的 2048 分页选择器）。
	var col_y: Array = [66, 110, 154, 198]
	var lx: float = 182 - 12 - 40
	var rx: float = 182 + 110 + 12
	var left_types: Array = ["helmet", "chest", "shoulder", "gloves"]
	var right_types: Array = ["weapon", "offhand", "necklace", "ring"]
	var bottom_types: Array = ["legs", "belt", "boots"]
	for i in range(4):
		_page_slot(String(left_types[i]), Vector2(lx, col_y[i]))
		_page_slot(String(right_types[i]), Vector2(rx, col_y[i]))
	var by: float = 248.0
	var cx: float = 182 + 55
	for i in range(3):
		_page_slot(String(bottom_types[i]), Vector2(cx - 66 + i * 46, by))

	# 左下：属性（紧凑布局，避免溢出）
	var sh := Label.new()
	sh.text = "角色属性"
	sh.position = Vector2(26, 318)
	sh.add_theme_font_size_override("font_size", 15)
	sh.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4, 1))
	bp_equip_view.add_child(sh)
	backpack_stats = Label.new()
	backpack_stats.position = Vector2(26, 344)
	backpack_stats.size = Vector2(402, 150)
	backpack_stats.add_theme_font_size_override("font_size", 13)
	backpack_stats.add_theme_color_override("font_color", Color(0.82, 0.9, 1.0, 1))
	bp_equip_view.add_child(backpack_stats)

	# 右：当前分页 2048 网格
	bp_grid_head = Label.new()
	bp_grid_head.position = Vector2(462, 54)
	bp_grid_head.size = Vector2(258, 22)
	bp_grid_head.add_theme_font_size_override("font_size", 15)
	bp_grid_head.add_theme_color_override("font_color", Color(0.7, 0.95, 1.0, 1))
	bp_equip_view.add_child(bp_grid_head)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(460, 82)
	scroll.size = Vector2(262, 360)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bp_equip_view.add_child(scroll)
	bp_grid = GridContainer.new()
	bp_grid.columns = 4
	bp_grid.add_theme_constant_override("h_separation", 8)
	bp_grid.add_theme_constant_override("v_separation", 8)
	scroll.add_child(bp_grid)
	bp_expand_btn = Button.new()
	bp_expand_btn.position = Vector2(462, 452)
	bp_expand_btn.size = Vector2(258, 34)
	bp_expand_btn.add_theme_font_size_override("font_size", 14)
	bp_expand_btn.pressed.connect(func() -> void: inv.expand_page(bp_selected_page))
	bp_equip_view.add_child(bp_expand_btn)

# ===== 道具标签 =====
func _build_items_view() -> void:
	bp_items_view = Control.new()
	bp_items_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bp_items_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bp_items_view.visible = false
	backpack_panel.add_child(bp_items_view)
	_inset(bp_items_view, Vector2(14, 48), Vector2(716, 450))
	var h := Label.new()
	h.text = "道具（药水/磁铁/扩展卷）— 点击使用；扩展卷请在「装备」分页点扩展"
	h.position = Vector2(28, 60)
	h.add_theme_font_size_override("font_size", 14)
	h.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0, 1))
	bp_items_view.add_child(h)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(26, 92)
	scroll.size = Vector2(692, 396)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bp_items_view.add_child(scroll)
	bp_items_grid = GridContainer.new()
	bp_items_grid.columns = 12
	bp_items_grid.add_theme_constant_override("h_separation", 6)
	bp_items_grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(bp_items_grid)

func _inset(parent: Node, pos: Vector2, sz: Vector2) -> void:
	var p := Panel.new()
	p.position = pos
	p.size = sz
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.04, 0.055, 0.10, 0.6)
	s.set_border_width_all(1)
	s.border_color = Color(0.25, 0.4, 0.62, 0.4)
	s.set_corner_radius_all(8)
	p.add_theme_stylebox_override("panel", s)
	parent.add_child(p)

# 分页装备格：点击选中该分页（右侧显示其 2048 网格）。
func _page_slot(etype: String, pos: Vector2) -> void:
	var b := Button.new()
	b.position = pos
	b.size = Vector2(40, 40)
	b.add_theme_font_size_override("font_size", 14)
	b.pressed.connect(func() -> void: _select_page(etype))
	bp_equip_view.add_child(b)
	bp_page_btns[etype] = b

func _slot_box(bg: Color, border: Color, w: int = 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_border_width_all(w)
	s.border_color = border
	s.set_corner_radius_all(6)
	return s

func _tier_color(tier: int) -> Color:
	# 2048 阶位配色：低阶冷色 → 高阶暖金。
	var h: float = clampf(0.58 - 0.07 * float(tier - 1), 0.0, 0.58)
	return Color.from_hsv(h, 0.6, 1.0)

func _select_page(etype: String) -> void:
	bp_selected_page = etype
	_refresh_backpack()

func _show_bp_tab(which: String) -> void:
	bp_tab = which
	if bp_equip_view != null:
		bp_equip_view.visible = which == "equip"
	if bp_items_view != null:
		bp_items_view.visible = which == "items"
	_style_bp_tab(bp_tab_equip_btn, which == "equip")
	_style_bp_tab(bp_tab_items_btn, which == "items")
	_refresh_backpack()

func _style_bp_tab(b: Button, active: bool) -> void:
	if b == null:
		return
	if active:
		var box := _slot_box(Color(0.15, 0.28, 0.46, 0.95), Color(0.45, 0.85, 1.0, 1), 2)
		b.add_theme_stylebox_override("normal", box)
		b.add_theme_stylebox_override("hover", box)
		b.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	else:
		b.add_theme_stylebox_override("normal", _slot_box(Color(0.08, 0.10, 0.17, 0.7), Color(0.25, 0.35, 0.5, 0.35)))
		b.add_theme_color_override("font_color", Color(0.55, 0.66, 0.82, 1))

func _toggle_backpack() -> void:
	if backpack_panel == null:
		return
	backpack_panel.visible = not backpack_panel.visible
	if backpack_panel.visible:
		_show_bp_tab(bp_tab)

func _refresh_backpack() -> void:
	if backpack_panel == null or not backpack_panel.visible:
		return
	if backpack_title != null:
		backpack_title.text = "背包"
	if bp_tab == "equip":
		_refresh_page_slots()
		_refresh_preview()
		_refresh_stats()
		_refresh_page_grid()
	else:
		_refresh_items_grid()

# 11 个分页格：显示各类最强装备的 2048 值；当前选中高亮。
func _refresh_page_slots() -> void:
	for etype: String in bp_page_btns.keys():
		var b: Button = bp_page_btns[etype]
		var bt: int = inv.best_tier(etype)
		var selected: bool = etype == bp_selected_page
		var base_col: Color = InventoryManager.TYPE_COLOR.get(etype, Color(0.6, 0.7, 0.9, 1))
		b.tooltip_text = "%s（%s）" % [String(InventoryManager.TYPE_LABEL.get(etype, etype)), ("最强 %d" % inv.value_of(bt)) if bt > 0 else "空"]
		if bt > 0:
			b.text = "%s%d" % [String(InventoryManager.TYPE_TAG.get(etype, "?")), inv.value_of(bt)]
			b.add_theme_color_override("font_color", Color(1, 1, 1, 1))
			b.add_theme_stylebox_override("normal", _slot_box(Color(base_col.r * 0.4, base_col.g * 0.4, base_col.b * 0.4, 0.95), base_col, 2 if selected else 1))
		else:
			b.text = String(InventoryManager.TYPE_TAG.get(etype, "?"))
			b.add_theme_color_override("font_color", Color(0.5, 0.6, 0.78, 1))
			b.add_theme_stylebox_override("normal", _slot_box(Color(0.07, 0.10, 0.16, 0.9), (Color(0.5, 0.8, 1.0, 1) if selected else Color(0.3, 0.45, 0.65, 0.5)), 2 if selected else 1))
		b.add_theme_stylebox_override("hover", _slot_box(Color(base_col.r * 0.5, base_col.g * 0.5, base_col.b * 0.5, 1), Color(1, 1, 1, 1)))

# 右侧：选中分页的 2048 网格（容量格；已有装备显示值；空格留白）。
func _refresh_page_grid() -> void:
	if bp_grid == null:
		return
	for c in bp_grid.get_children():
		c.queue_free()
	var etype: String = bp_selected_page
	var arr: Array = inv.pages.get(etype, [])
	var cap: int = int(inv.caps.get(etype, InventoryManager.INIT_CAP))
	bp_grid_head.text = "%s分页 — 容量 %d/%d（满阶相同自动合成）" % [String(InventoryManager.TYPE_LABEL.get(etype, etype)), arr.size(), cap]
	for i in range(cap):
		var cell := Button.new()
		cell.custom_minimum_size = Vector2(56, 56)
		cell.disabled = true
		cell.focus_mode = Control.FOCUS_NONE
		if i < arr.size():
			var tier: int = int(arr[i])
			cell.text = str(inv.value_of(tier))
			cell.add_theme_font_size_override("font_size", 18)
			var tc: Color = _tier_color(tier)
			cell.add_theme_stylebox_override("disabled", _slot_box(Color(tc.r * 0.5, tc.g * 0.5, tc.b * 0.5, 0.95), tc, 2))
			cell.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 1))
		else:
			cell.text = ""
			cell.add_theme_stylebox_override("disabled", _slot_box(Color(0.06, 0.08, 0.13, 0.7), Color(0.2, 0.28, 0.4, 0.35)))
		bp_grid.add_child(cell)
	var sc: int = inv.scroll_count()
	bp_expand_btn.text = "扩展(+1格)  扩展卷×%d" % sc
	bp_expand_btn.disabled = sc <= 0 or cap >= InventoryManager.MAX_CAP

# 道具网格：每个消耗品一个格子，点击使用。
func _refresh_items_grid() -> void:
	if bp_items_grid == null:
		return
	for c in bp_items_grid.get_children():
		c.queue_free()
	for i in range(inv.items.size()):
		var it: Dictionary = inv.items[i]
		var cell := Button.new()
		cell.custom_minimum_size = Vector2(52, 52)
		cell.text = _consumable_tag(it)
		var cnt: int = int(it.get("count", 1))
		if cnt > 1:
			cell.text += "\n×%d" % cnt
		cell.tooltip_text = "%s ×%d" % [String(it.get("name", "道具")), cnt] if String(it.get("kind", "")) == "material" else "%s（点击使用）" % String(it.get("name", "道具"))
		cell.add_theme_font_size_override("font_size", 16)
		var col: Color = _item_color(it)
		cell.add_theme_stylebox_override("normal", _slot_box(Color(col.r * 0.4, col.g * 0.4, col.b * 0.4, 0.95), col))
		cell.add_theme_stylebox_override("hover", _slot_box(Color(col.r * 0.55, col.g * 0.55, col.b * 0.55, 1), Color(1, 1, 1, 1)))
		cell.add_theme_color_override("font_color", Color(1, 1, 1, 1))
		var idx: int = i
		cell.pressed.connect(func() -> void: inv.use_item(idx))
		bp_items_grid.add_child(cell)

func _consumable_tag(it: Dictionary) -> String:
	match String(it.get("kind", "")):
		"potion":
			return "药"
		"magnet":
			return "磁"
		"scroll":
			return "卷"
		"material":
			return "晶"
		_:
			return "物"

# 角色预览：剪影；躯干/武器/战靴按对应类型最强装备着色。
func _refresh_preview() -> void:
	if preview_box == null:
		return
	for c in preview_box.get_children():
		c.queue_free()
	var armor_c: Color = _page_color("chest", Color(0.4, 0.46, 0.6, 1))
	var weapon_c: Color = _page_color("weapon", Color(0.7, 0.72, 0.8, 1))
	var boots_c: Color = _page_color("boots", Color(0.3, 0.34, 0.42, 1))
	_fig(Vector2(42, 12), Vector2(26, 26), Color(0.85, 0.78, 0.66, 1))   # 头
	_fig(Vector2(33, 42), Vector2(44, 58), armor_c)                       # 躯干
	_fig(Vector2(20, 44), Vector2(12, 48), armor_c)                       # 左臂
	_fig(Vector2(78, 44), Vector2(12, 48), armor_c)                       # 右臂
	_fig(Vector2(38, 102), Vector2(15, 48), Color(0.2, 0.22, 0.3, 1))     # 左腿
	_fig(Vector2(57, 102), Vector2(15, 48), Color(0.2, 0.22, 0.3, 1))     # 右腿
	_fig(Vector2(36, 144), Vector2(19, 13), boots_c)                      # 左靴
	_fig(Vector2(55, 144), Vector2(19, 13), boots_c)                      # 右靴
	_fig(Vector2(90, 38), Vector2(6, 66), weapon_c)                       # 武器
	var lv := Label.new()
	lv.text = "Lv.%d" % (player.level if player != null else 1)
	lv.position = Vector2(0, 158)
	lv.size = Vector2(110, 16)
	lv.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lv.add_theme_font_size_override("font_size", 13)
	lv.add_theme_color_override("font_color", Color(0.8, 0.92, 1.0, 1))
	preview_box.add_child(lv)

func _fig(pos: Vector2, sz: Vector2, color: Color) -> void:
	var r := ColorRect.new()
	r.position = pos
	r.size = sz
	r.color = color
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_box.add_child(r)

func _page_color(etype: String, fallback: Color) -> Color:
	if inv.best_tier(etype) > 0:
		return InventoryManager.TYPE_COLOR.get(etype, fallback)
	return fallback

# 紧凑属性显示（4 行，固定在左下区域内，不溢出）。
func _refresh_stats() -> void:
	if backpack_stats == null or player == null:
		return
	backpack_stats.text = "Lv.%d   升级上限 Lv.%d   最高装等 %d\n经验 %d / %d\n攻击 %d   魔法 %d   防御 %d   韧性 %d\n生命 %d/%d   法力 %d/%d   体力 %d/%d   移速 %.1f\n\n装备：%s" % [
		player.level, level_cap, inv.max_equip_tier(),
		player.exp_points, player.next_level_exp,
		player.attack, player.magic, player.defense, player.toughness,
		int(player.hp), player.max_hp, int(player.mp), player.max_mp, int(player.stamina), player.max_stamina, player.move_speed,
		inv.summary()]
	backpack_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

func _item_color(it: Dictionary) -> Color:
	if it.has("color") and it["color"] is Color:
		return it["color"] as Color
	return Color(0.85, 0.92, 1.0, 1)

# 生成一瓶回复药剂（回 MP 为主，兼回少量 HP；回复量随世界等级提升）。
func _spawn_potion(pos: Vector3, ptype: String = "") -> void:
	if ptype == "":
		ptype = ["hp", "mp", "vit"][rng.randi_range(0, 2)]
	var jitter: Vector3 = Vector3(rng.randf_range(-0.6, 0.6), 0.0, rng.randf_range(-0.6, 0.6))
	equipment.make_pickup(pos + jitter, _make_potion_item(ptype), -1)

# 三类药剂：血(hp)/蓝(mp)/体(hp+mp)。回复量翻倍。
func _make_potion_item(ptype: String) -> Dictionary:
	var wl: int = get_world_level()
	match ptype:
		"hp":
			return {"kind": "potion", "ptype": "hp", "name": "血瓶", "hp": 80 + 24 * (wl - 1), "mp": 0, "color": Color(1.0, 0.3, 0.34, 1)}
		"mp":
			return {"kind": "potion", "ptype": "mp", "name": "蓝瓶", "hp": 0, "mp": 80 + 24 * (wl - 1), "color": Color(0.35, 0.6, 1.0, 1)}
		_:
			return {"kind": "potion", "ptype": "vit", "name": "体瓶", "hp": 60 + 20 * (wl - 1), "mp": 60 + 20 * (wl - 1), "color": Color(0.4, 1.0, 0.6, 1)}

# 饮用药剂：回复法力与生命。
func _consume_potion(item: Dictionary) -> void:
	if player == null or not is_instance_valid(player):
		return
	var mp_add: int = int(item.get("mp", 0))
	var hp_add: int = int(item.get("hp", 0))
	player.mp = min(float(player.max_mp), player.mp + float(mp_add))
	player.hp = min(float(player.max_hp), player.hp + float(hp_add))
	flash_message("饮用%s：回复 MP %d / HP %d" % [String(item.get("name", "药剂")), mp_add, hp_add])
	spawn_skill_flash(player.global_position + Vector3(0, 1.0, 0), Color(0.35, 0.9, 1.0, 1), 1.4, 0.25)

# ---------------- 快捷药剂栏（血Z/蓝X/体C；点击给自己、拖拽给单位） ----------------
func _build_quick_items() -> void:
	# 锚定屏幕右上角、背包按钮左侧一排。Z X C 从左到右。
	var specs: Array = [["hp", "血", "Z", Color(1.0, 0.3, 0.34, 1)], ["mp", "蓝", "X", Color(0.35, 0.6, 1.0, 1)], ["vit", "体", "C", Color(0.4, 1.0, 0.6, 1)]]
	var rights: Array = [-256.0, -184.0, -112.0]
	for i in range(3):
		var sp: Array = specs[i]
		var ptype: String = sp[0]
		var col: Color = sp[3]
		var p := Panel.new()
		p.anchor_left = 1.0
		p.anchor_right = 1.0
		p.anchor_top = 0.0
		p.anchor_bottom = 0.0
		p.offset_right = rights[i]
		p.offset_left = rights[i] - 64.0
		p.offset_top = 228.0
		p.offset_bottom = 316.0
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_theme_stylebox_override("panel", _round_btn(Color(col.r * 0.3, col.g * 0.3, col.b * 0.3, 0.85), col, 12))
		ui_layer.add_child(p)
		var lbl := Label.new()
		lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.add_theme_font_size_override("font_size", 18)
		lbl.add_theme_color_override("font_color", Color(0.96, 0.98, 1.0, 1))
		p.add_child(lbl)
		_quick_slots[ptype] = {"node": p, "label": lbl, "key": String(sp[2]), "char": String(sp[1])}

func _refresh_quick_items() -> void:
	for ptype: String in _quick_slots.keys():
		var d: Dictionary = _quick_slots[ptype]
		var lbl: Label = d["label"]
		lbl.text = "%s %s\nx%d" % [String(d["key"]), String(d["char"]), inv.count_potion(ptype)]

func _quick_slot_at(pos: Vector2) -> String:
	for ptype: String in _quick_slots.keys():
		var p: Panel = (_quick_slots[ptype] as Dictionary)["node"]
		if p != null and p.get_global_rect().has_point(pos):
			return ptype
	return ""

# 直接给自己用一瓶。
func _use_potion_self(ptype: String) -> void:
	_use_potion_on(ptype, player)

func _use_potion_on(ptype: String, target: Node) -> void:
	var it: Dictionary = inv.take_potion(ptype)
	if it.is_empty():
		flash_message("没有%s了。" % _ptype_name(ptype))
		return
	_apply_potion_to(it, target)

func _ptype_name(ptype: String) -> String:
	match ptype:
		"hp": return "血瓶"
		"mp": return "蓝瓶"
		_: return "体瓶"

func _apply_potion_to(item: Dictionary, target: Node) -> void:
	var hp_add: int = int(item.get("hp", 0))
	var mp_add: int = int(item.get("mp", 0))
	if target is StarGloryPlayer:
		var pl: StarGloryPlayer = target
		pl.hp = min(float(pl.max_hp), pl.hp + float(hp_add))
		pl.mp = min(float(pl.max_mp), pl.mp + float(mp_add))
		flash_message("使用%s：回复 HP %d / MP %d" % [String(item.get("name", "药剂")), hp_add, mp_add])
		spawn_skill_flash(pl.global_position + Vector3(0, 1.0, 0), Color(0.4, 1.0, 0.6, 1), 1.4, 0.28)
	elif target is StarGloryMonster:
		var m: StarGloryMonster = target
		if not m.dead:
			var heal: int = hp_add + mp_add
			m.hp = min(float(m.max_hp), m.hp + float(heal))
			flash_message("把%s用在了「%s」身上（回复 %d）。" % [String(item.get("name", "药剂")), m.monster_name, heal])
			spawn_skill_flash(m.global_position + Vector3(0, 1.0, 0), Color(0.4, 1.0, 0.6, 1), 1.4, 0.28)
			# 奶上头反噬：此前一段时间没受伤(hurt_aggro_timer<=0)还被大量治疗 → 转而仇恨奶你的玩家。
			if m.hurt_aggro_timer <= 0.0 and player != null:
				m.heal_acc += float(heal)
				if m.heal_acc >= 120.0:
					m.heal_acc = 0.0
					m.has_target = true
					m.last_known = player.global_position
					m.hurt_aggro_timer = 8.0
					flash_message("被奶上头的「%s」反过来盯上了你！" % m.monster_name)
	Audio.sfx("ui")
	_refresh_quick_items()

# 拖拽：更新当前悬停的单位并高亮。
func _update_potion_hover(pos: Vector2) -> void:
	_potion_hover = _unit_at_screen(pos)
	if _potion_hover != null:
		_show_select_ring(_potion_hover)
	else:
		_hide_select_ring()

func _finish_potion_drag() -> void:
	var ptype: String = _potion_drag
	_potion_drag = ""
	_hide_select_ring()
	var tgt: Node = _potion_hover if (_potion_hover != null and is_instance_valid(_potion_hover)) else player
	_potion_hover = null
	if ptype != "" and tgt != null:
		_use_potion_on(ptype, tgt)

# 屏幕坐标处最近的单位（怪物/玩家），阈值内才算命中。
func _unit_at_screen(screen: Vector2) -> Node:
	if camera == null:
		return null
	var best: Node = null
	var best_d: float = 80.0
	for node in monsters:
		var m: StarGloryMonster = node as StarGloryMonster
		if m == null or not is_instance_valid(m) or m.dead:
			continue
		var wp: Vector3 = m.aim_point()
		if camera.is_position_behind(wp):
			continue
		var d: float = camera.unproject_position(wp).distance_to(screen)
		if d < best_d:
			best_d = d
			best = m
	if player != null and is_instance_valid(player):
		var pw: Vector3 = player.global_position + Vector3(0, 1.1, 0)
		if not camera.is_position_behind(pw):
			var dp: float = camera.unproject_position(pw).distance_to(screen)
			if dp < best_d:
				best = player
	return best

func _ensure_select_ring() -> void:
	if _select_ring != null and is_instance_valid(_select_ring):
		return
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.92
	mesh.outer_radius = 1.08
	_select_ring = MeshInstance3D.new()
	_select_ring.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.9, 0.2, 0.9)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.85, 0.2, 1)
	mat.emission_energy_multiplier = 1.6
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_select_ring.material_override = mat
	_select_ring.rotation.x = PI / 2.0
	_select_ring.visible = false
	effect_root.add_child(_select_ring)

func _show_select_ring(node: Node) -> void:
	_ensure_select_ring()
	var n3: Node3D = node as Node3D
	if n3 == null:
		return
	_select_ring.global_position = n3.global_position + Vector3(0, 0.1, 0)
	_select_ring.visible = true

func _hide_select_ring() -> void:
	if _select_ring != null and is_instance_valid(_select_ring):
		_select_ring.visible = false

# 生成一块磁铁掉落物。
func _spawn_magnet(pos: Vector3) -> void:
	var item: Dictionary = {"kind": "magnet", "name": "星辰磁石", "color": Color(0.95, 0.30, 0.30, 1)}
	var jitter: Vector3 = Vector3(rng.randf_range(-0.6, 0.6), 0.0, rng.randf_range(-0.6, 0.6))
	equipment.make_pickup(pos + jitter, item, -1)

# 构造一件 2048 装备物品（etype 为空则随机）。
func _make_equipment_item(etype: String, tier: int) -> Dictionary:
	if etype == "" or not InventoryManager.TYPES.has(etype):
		etype = InventoryManager.TYPES[rng.randi_range(0, InventoryManager.TYPES.size() - 1)]
	tier = maxi(1, tier)
	var col: Color = InventoryManager.TYPE_COLOR.get(etype, Color(0.8, 0.9, 1.0, 1))
	return {
		"kind": "equipment", "etype": etype, "tier": tier,
		"name": "%s·%d" % [String(InventoryManager.TYPE_LABEL.get(etype, etype)), inv.value_of(tier)],
		"color": col, "slot": "weapon"
	}

func _make_scroll_item() -> Dictionary:
	return {"kind": "scroll", "name": "背包扩展卷", "color": Color(0.95, 0.8, 0.35, 1)}

func _make_material_item(mat_name: String, color: Color, amount: int = 1) -> Dictionary:
	return {"kind": "material", "mat": mat_name, "name": mat_name, "amount": amount, "color": color, "slot": "accessory"}

func _spawn_material_drop(pos: Vector3, mat_name: String, color: Color, amount: int = 1) -> void:
	if equipment == null:
		if inv != null:
			inv.add_material(mat_name, color, amount)
		return
	for i in range(maxi(1, amount)):
		var jitter: Vector3 = Vector3(rng.randf_range(-0.7, 0.7), 0.0, rng.randf_range(-0.7, 0.7))
		equipment.make_pickup(pos + jitter, _make_material_item(mat_name, color, 1), -1)

func _roll_boss_material_drops(pos: Vector3) -> void:
	if rng.randf() < 0.35:
		_spawn_material_drop(pos, "防御卷轴", Color(0.95, 0.85, 0.45, 1), 1)
	if rng.randf() < 0.18:
		_spawn_material_drop(pos, "妖兽令", Color(0.7, 0.25, 1.0, 1), 1)

func _use_beast_token() -> void:
	if player == null or not is_instance_valid(player) or inv == null:
		return
	if not inv.consume_material("妖兽令", 1):
		flash_message("没有妖兽令。击杀攻城 Boss 或世界 Boss 有概率获得。")
		return
	_autosave()
	var forward: Vector3 = -player.global_transform.basis.z
	forward.y = 0.0
	if forward.length() < 0.1:
		forward = Vector3(0, 0, -1)
	var center: Vector3 = player.global_position + forward.normalized() * 11.0
	center.y = terrain_height(center.x, center.z) + 0.25
	var node := _build_beast_hole_visual(center)
	if Net.online:
		Net.send_beast_tide(center)
		beast_tides.append({"center": center, "timer": 18.0, "emit": 99.0, "node": node, "trib": true, "visual_only": true})
	else:
		beast_tides.append({"center": center, "timer": 18.0, "emit": 0.0, "node": node, "trib": false, "visual_only": false})
	flash_message("妖兽令展开空间黑洞：18 秒内持续召唤妖兽兽潮。")

func _build_beast_hole_visual(center: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "BeastTideHole"
	root.global_position = center
	effect_root.add_child(root)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.38, 0.0, 0.75, 0.72)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.7, 0.25, 1.0, 1)
	mat.emission_energy_multiplier = 2.8
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 2.2
	tm.outer_radius = 2.8
	ring.mesh = tm
	ring.material_override = mat
	ring.rotation.x = PI / 2.0
	root.add_child(ring)
	var col := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.2
	cm.bottom_radius = 2.8
	cm.height = 8.0
	col.mesh = cm
	col.material_override = mat
	col.position = Vector3(0, 4.0, 0)
	root.add_child(col)
	return root

func _update_beast_tides(delta: float) -> void:
	for i in range(beast_tides.size() - 1, -1, -1):
		var tide: Dictionary = beast_tides[i]
		tide["timer"] = float(tide["timer"]) - delta
		tide["emit"] = float(tide["emit"]) - delta
		var center: Vector3 = tide["center"]
		var node: Node3D = tide.get("node", null) as Node3D
		if node != null and is_instance_valid(node):
			node.rotate_y(delta * 2.4)
			node.scale = Vector3.ONE * (1.0 + 0.08 * sin(Time.get_ticks_msec() * 0.006))
		if bool(tide.get("visual_only", false)):
			if float(tide["timer"]) <= 0.0:
				if node != null and is_instance_valid(node):
					node.queue_free()
				beast_tides.remove_at(i)
			continue
		if not bool(tide.get("trib", false)) and rng.randf() < delta * 0.035:
			tide["trib"] = true
			spawn_skill_flash(center + Vector3(0, 1.0, 0), Color(0.75, 0.9, 1.0, 1), 9.0, 0.65)
			if combat != null:
				combat.apply_universal_blast(center + Vector3(0, 0.7, 0), 8.5, 90 + 18 * get_world_level(), null, 8.0)
			flash_message("空间黑洞引发天劫！")
		if float(tide["emit"]) <= 0.0 and float(tide["timer"]) > 0.0:
			tide["emit"] = 1.5
			_emit_beast_tide(center)
		if float(tide["timer"]) <= 0.0:
			if node != null and is_instance_valid(node):
				node.queue_free()
			beast_tides.remove_at(i)

func _emit_beast_tide(center: Vector3) -> void:
	if _live_monster_count(false) >= MAX_LOCAL_MONSTERS:
		return
	var kinds := ["wolf", "wisp", "archer", "mage"]
	var n: int = 2
	for i in range(n):
		if _live_monster_count(false) >= MAX_LOCAL_MONSTERS:
			return
		var ang: float = randf() * TAU
		var rr: float = rng.randf_range(2.0, 6.0)
		var pos: Vector3 = center + Vector3(cos(ang) * rr, 0.0, sin(ang) * rr)
		pos.y = terrain_height(pos.x, pos.z) + 0.6
		var m: StarGloryMonster = _spawn_monster(kinds[rng.randi_range(0, kinds.size() - 1)], pos, rng.randf() < 0.12, get_world_level())
		m.is_summoned = true
		m.summon_ttl = 35.0
		spawn_skill_flash(pos + Vector3(0, 0.8, 0), Color(0.75, 0.25, 1.0, 1), 1.2, 0.18)

# 生成一件随机装备掉落（按世界等级偶尔更高阶）。
func _spawn_equipment_drop(pos: Vector3) -> void:
	var gen: Dictionary = inv.gen_random(get_world_level())
	var item: Dictionary = _make_equipment_item(String(gen["etype"]), int(gen["tier"]))
	var jitter: Vector3 = Vector3(rng.randf_range(-0.6, 0.6), 0.0, rng.randf_range(-0.6, 0.6))
	equipment.make_pickup(pos + jitter, item, -1)

# 吸血装备（主/副武器）：仅守关 Boss 与常驻 Boss 掉落。
func _spawn_lifesteal_gear(pos: Vector3) -> void:
	var gen: Dictionary = inv.gen_weapon(get_world_level())
	var item: Dictionary = _make_equipment_item(String(gen["etype"]), int(gen["tier"]))
	var jitter: Vector3 = Vector3(rng.randf_range(-0.6, 0.6), 0.0, rng.randf_range(-0.6, 0.6))
	equipment.make_pickup(pos + jitter, item, -1)

# 生成一张背包扩展卷掉落（仅 Boss 调用）。
func _spawn_scroll(pos: Vector3) -> void:
	var jitter: Vector3 = Vector3(rng.randf_range(-0.6, 0.6), 0.0, rng.randf_range(-0.6, 0.6))
	equipment.make_pickup(pos + jitter, _make_scroll_item(), -1)

# 磁铁生效：开启一段时间的自动吸取。
func _activate_magnet() -> void:
	magnet_timer = MAGNET_DURATION
	flash_message("星辰磁石生效：%d 秒内自动吸取周边 %d 米范围的道具。" % [int(MAGNET_DURATION), int(MAGNET_RADIUS)])
	if player != null and is_instance_valid(player):
		spawn_skill_flash(player.global_position + Vector3(0, 1.0, 0), Color(0.95, 0.4, 0.4, 1), 2.0, 0.35)

# 玩家脚步音：地面行走时按节奏播放（定位 3D，远近自动衰减）。
func _update_audio(delta: float) -> void:
	if player == null or not is_instance_valid(player) or player.hp <= 0.0:
		return
	if player.flying_cloud or not player.is_on_floor():
		_step_timer = 0.0
		return
	var spd: float = Vector2(player.velocity.x, player.velocity.z).length()
	if spd > 1.6:
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer = 0.26 if player.is_running else 0.36
			Audio.sfx_at("step", player.global_position, -5.0, randf_range(0.92, 1.08))
	else:
		_step_timer = 0.0

# 磁铁吸取：把范围内的掉落物吸向玩家，靠近后自动拾取（联机走服务器裁决）。
func _update_magnet(delta: float) -> void:
	if magnet_timer <= 0.0:
		return
	magnet_timer = max(0.0, magnet_timer - delta)
	if player == null or not is_instance_valid(player) or player.hp <= 0.0:
		return
	var ppos: Vector3 = player.global_position
	# 倒序遍历，避免每帧 duplicate() 分配；离线拾取会就地 erase。
	for i in range(pickups.size() - 1, -1, -1):
		var p: StarGloryPickup = pickups[i] as StarGloryPickup
		if p == null or not is_instance_valid(p):
			continue
		var to: Vector3 = ppos - p.global_position
		var d: float = to.length()
		if d > MAGNET_RADIUS:
			continue
		if d <= MAGNET_COLLECT_DIST:
			if Net.online:
				# 联机：共享掉落由服务器裁决拾取（先到先得）；每个掉落只请求一次，避免刷请求。
				if p.net_drop_id >= 0 and not p.has_meta("magnet_req"):
					p.set_meta("magnet_req", true)
					Net.send_pickup(p.net_drop_id)
			else:
				_collect_pickup_offline(p)
		else:
			# 吸向玩家（水平方向；竖直由掉落物自身的漂浮控制）。
			var step: float = min(d, MAGNET_PULL_SPEED * delta)
			var pull: Vector3 = to / d * step
			p.global_position += Vector3(pull.x, 0.0, pull.z)

# 始终生效的自动拾取：走到掉落物附近即自动收取。
# 联机：共享掉落由服务器裁决「先到先得」，每个掉落只请求一次。磁铁生效时交给磁铁逻辑，避免重复。
func _update_auto_pickup(delta: float) -> void:
	if magnet_timer > 0.0:
		return
	if player == null or not is_instance_valid(player) or player.hp <= 0.0:
		return
	var ppos: Vector3 = player.global_position
	# 倒序遍历，避免每帧 duplicate() 分配；离线拾取会就地 erase。
	for i in range(pickups.size() - 1, -1, -1):
		var p: StarGloryPickup = pickups[i] as StarGloryPickup
		if p == null or not is_instance_valid(p):
			continue
		var to: Vector3 = ppos - p.global_position
		var d: float = to.length()
		if d > AUTO_PICKUP_RADIUS:
			continue
		if d <= AUTO_PICKUP_COLLECT:
			if Net.online:
				if p.net_drop_id >= 0 and not p.has_meta("pickup_req") and not p.has_meta("magnet_req"):
					p.set_meta("pickup_req", true)   # 只请求一次，服务器先到先得
					Net.send_pickup(p.net_drop_id)
			else:
				_collect_pickup_offline(p)
		else:
			# 强吸力：把掉落物水平吸向玩家（竖直由其自身漂浮控制）。
			var step: float = min(d, AUTO_PICKUP_PULL * delta)
			var pull: Vector3 = to / d * step
			p.global_position += Vector3(pull.x, 0.0, pull.z)

# ---------------- 大地图 / 选点导航 ----------------
func toggle_big_map() -> void:
	if big_map == null:
		return
	big_map.visible = not big_map.visible
	flash_message("大地图%s" % ("开启（点地图任意处设导航点）" if big_map.visible else "关闭"))

# 在世界坐标处设导航点：地图标记 + 世界里立一道光柱指引；到达自动清除。
func set_nav_target(world: Vector3, silent: bool = false) -> void:
	nav_target = Vector3(world.x, 0.1, world.z)
	has_nav = true
	_build_nav_beacon()
	if not silent:
		_quest_nav_active = false               # 手动设点 → 取消任务追踪
		if quest_system != null and quest_system.has_method("set_tracked"):
			quest_system.set_tracked("")
		flash_message("已设导航点：循光柱/地图标记前往（到达自动清除）。")

func clear_nav() -> void:
	has_nav = false
	if nav_beacon != null and is_instance_valid(nav_beacon):
		nav_beacon.queue_free()
	nav_beacon = null

# 顶部中央方向标度：一条横标尺，中点=正前方；导航点方位越偏，标记越靠边（身后则贴边）。
func _build_compass() -> void:
	compass_root = Control.new()
	compass_root.anchor_left = 0.5; compass_root.anchor_right = 0.5
	compass_root.offset_left = -160.0; compass_root.offset_right = 160.0
	compass_root.offset_top = 8.0; compass_root.offset_bottom = 60.0
	compass_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	compass_root.visible = false
	ui_layer.add_child(compass_root)
	var bar := ColorRect.new(); bar.color = Color(0.02, 0.03, 0.06, 0.72)
	bar.position = Vector2(10, 0); bar.size = Vector2(300, 24)
	compass_root.add_child(bar)
	var tick := ColorRect.new(); tick.color = Color(0.55, 0.95, 1.0, 0.9)
	tick.position = Vector2(159, 0); tick.size = Vector2(2, 24)
	compass_root.add_child(tick)
	var ahead := Label.new(); ahead.text = "前"; ahead.position = Vector2(150, 24); ahead.size = Vector2(20, 16)
	ahead.add_theme_font_size_override("font_size", 11); ahead.add_theme_color_override("font_color", Color(0.6, 0.8, 0.95, 0.8))
	ahead.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	compass_root.add_child(ahead)
	compass_marker = Label.new(); compass_marker.text = "◆"; compass_marker.size = Vector2(24, 24)
	compass_marker.add_theme_font_size_override("font_size", 20); compass_marker.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3, 1))
	compass_marker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	compass_root.add_child(compass_marker)
	compass_dist = Label.new(); compass_dist.size = Vector2(320, 18); compass_dist.position = Vector2(0, 40)
	compass_dist.add_theme_font_size_override("font_size", 13); compass_dist.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5, 1))
	compass_dist.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	compass_root.add_child(compass_dist)

func _update_compass() -> void:
	if compass_root == null:
		return
	if not has_nav or player == null or not is_instance_valid(player) or camera == null:
		compass_root.visible = false
		return
	compass_root.visible = true
	var to: Vector3 = nav_target - player.global_position; to.y = 0.0
	var dist: float = to.length()
	var t2: Vector2 = Vector2(to.x, to.z)
	if t2.length() < 0.01:
		t2 = Vector2(0, -1)
	t2 = t2.normalized()
	var fwd: Vector3 = -camera.global_transform.basis.z
	var right: Vector3 = camera.global_transform.basis.x
	var f2: Vector2 = Vector2(fwd.x, fwd.z).normalized()
	var r2: Vector2 = Vector2(right.x, right.z).normalized()
	var ang: float = acos(clampf(t2.dot(f2), -1.0, 1.0))        # 0=正前，PI=正后
	var signed: float = ang * (1.0 if t2.dot(r2) >= 0.0 else -1.0)
	var frac: float = clampf(signed / (PI * 0.5), -1.0, 1.0)     # ±90°铺满，超出贴边
	compass_marker.position = Vector2(160.0 + frac * 140.0 - 12.0, 0.0)
	var behind: bool = t2.dot(f2) < 0.0
	compass_marker.text = ("◀" if frac < 0 else "▶") if behind else "◆"
	compass_dist.text = "导航 %dm%s" % [int(dist), ("（在身后）" if behind else "")]

# 任务追踪：把追踪任务的目标点持续设为导航点，引导玩家前往。
func _update_quest_track() -> void:
	if quest_system == null or not quest_system.has_method("tracked_waypoint"):
		return
	var wp: Dictionary = quest_system.tracked_waypoint()
	if not bool(wp.get("has", false)):
		if _quest_nav_active:
			_quest_nav_active = false
			clear_nav()
		return
	var pos: Vector3 = wp["pos"]
	if (not has_nav) or (not _quest_nav_active) or nav_target.distance_to(Vector3(pos.x, 0.1, pos.z)) > 4.0:
		set_nav_target(pos, true)   # 静默更新(动态目标随时重定位)
	_quest_nav_active = true

# 追踪任务的世界目标点（按任务类型解算）。
# 当前是否卡在等级上限、需要通关对应守关副本突破；返回该副本信息(含入口坐标)。
# 守关(突破)副本入口只显示"当前突破任务对应等级"的那个；非守关副本常驻显示。
func _update_dungeon_entrance_vis() -> void:
	if _dungeon_portals.is_empty():
		return
	var gate: Dictionary = breakthrough_gate()
	var cur: int = int(gate.get("dungeon", -1)) if not gate.is_empty() else -1
	var gate_ids: Dictionary = {}
	for g_v: Variant in LEVEL_GATES:
		gate_ids[int((g_v as Dictionary)["dungeon"])] = true
	for id_v: Variant in _dungeon_portals.keys():
		var id: int = id_v
		var p: Node3D = _dungeon_portals[id]
		if not is_instance_valid(p):
			continue
		if gate_ids.has(id):
			p.visible = (id == cur)      # 守关秘境：仅当前突破关卡可见
		else:
			p.visible = true             # 普通副本：常驻

var _bt_notified_cap: int = -1
# 到达等级上限时，弹出主线突破任务提示（每个上限只提示一次）。
func _check_breakthrough_notify() -> void:
	var g: Dictionary = breakthrough_gate()
	if g.is_empty() or not bool(g.get("capped", false)):
		return   # 仅在真正卡到上限时提示
	if _bt_notified_cap == int(g["cap"]):
		return
	_bt_notified_cap = int(g["cap"])
	flash_message("⚑ 已达等级上限 Lv.%d！主线任务：通关守关副本「%s」突破到 Lv.%d（任务详情栏可追踪前往）。" % [int(g["cap"]), String(g["name"]), int(g["next"])])

func breakthrough_gate() -> Dictionary:
	# 检测判定：等级达到/超过当前上限才出现突破任务；同一时间只有一档（当前上限对应的那关）。
	if player == null or not is_instance_valid(player) or player.level < level_cap:
		return {}
	for g_v: Variant in LEVEL_GATES:
		var g: Dictionary = g_v
		if level_cap == int(g["cap"]):
			var dn: String = ""
			var dp: Vector3 = Vector3.ZERO
			var lreq: int = 0
			for d: Dictionary in DUNGEON_DEFS:
				if int(d["id"]) == int(g["dungeon"]):
					dn = String(d["name"]); dp = d["pos"]; lreq = int(d["level_req"])
			return {"cap": int(g["cap"]), "next": int(g["next"]), "dungeon": int(g["dungeon"]), "name": dn, "pos": dp, "level_req": lreq, "capped": true}
	return {}

func quest_waypoint(q: Dictionary) -> Dictionary:
	match String(q["type"]):
		"breakthrough":
			var gate: Dictionary = breakthrough_gate()
			return {"has": not gate.is_empty(), "pos": (gate.get("pos", Vector3.ZERO) if not gate.is_empty() else Vector3.ZERO)}
		"leave": return {"has": true, "pos": Vector3(0, 0, -42)}     # 走出新手村
		"level", "kill": return _wp_nearest_monster(false)
		"boss": return _wp_nearest_monster(true)
		"material": return _wp_material(String(q.get("mat_name", "")))
		"shelter": return {"has": true, "pos": Vector3(0, 0, 42)}    # 庇护所地基
		"region": return _wp_region(int(q["target"]))
	return {"has": false, "pos": Vector3.ZERO}

func _wp_nearest_monster(boss_only: bool) -> Dictionary:
	if player == null or not is_instance_valid(player):
		return {"has": false, "pos": Vector3.ZERO}
	var best := Vector3.ZERO
	var bd := 1.0e9
	var found := false
	for mn_v: Variant in monsters:
		var mn: StarGloryMonster = mn_v as StarGloryMonster
		if mn != null and is_instance_valid(mn) and not mn.dead and (not boss_only or mn.is_boss):
			var d: float = player.global_position.distance_to(mn.global_position)
			if d < bd:
				bd = d; best = mn.global_position; found = true
	for mn_v2: Variant in net_monsters.values():
		if is_instance_valid(mn_v2) and not (mn_v2 as Object).get("dead") and (not boss_only or (mn_v2 as Object).get("is_boss")):
			var d2: float = player.global_position.distance_to((mn_v2 as Node3D).global_position)
			if d2 < bd:
				bd = d2; best = (mn_v2 as Node3D).global_position; found = true
	return {"has": found, "pos": best}

func _wp_material(mat: String) -> Dictionary:
	if Net.online and player != null and is_instance_valid(player):
		var best := Vector3.ZERO
		var bd := 1.0e9
		var found := false
		for nd_v: Variant in Net.world_nodes_data:
			var nd: Dictionary = nd_v
			if mat != "" and String(nd.get("mat", "")) != mat:
				continue
			var np: Vector3 = nd["pos"]
			var d: float = player.global_position.distance_to(np)
			if d < bd:
				bd = d; best = np; found = true
		if found:
			return {"has": true, "pos": best}
	# 回退：指向外圈矿区方向
	return {"has": true, "pos": Vector3(70, 0, 55)}

func _wp_region(tier: int) -> Dictionary:
	var prev_r := 0.0
	for rg_v: Variant in REGIONS:
		var rg: Dictionary = rg_v
		var r: float = float(rg["r"])
		if int(rg["tier"]) >= tier:
			var rad: float = (prev_r + minf(r, 210.0)) * 0.5 if r < 9000.0 else prev_r + 28.0
			return {"has": true, "pos": Vector3(0, 0, rad)}
		prev_r = r
	return {"has": false, "pos": Vector3.ZERO}

func _build_nav_beacon() -> void:
	if nav_beacon != null and is_instance_valid(nav_beacon):
		nav_beacon.queue_free()
	nav_beacon = Node3D.new()
	effect_root.add_child(nav_beacon)
	nav_beacon.global_position = nav_target
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.32
	mesh.bottom_radius = 0.32
	mesh.height = 16.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.25, 0.4)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.25, 1)
	mat.emission_energy_multiplier = 1.3
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = Vector3(0, 8.0, 0)
	nav_beacon.add_child(mi)

func _update_nav(_delta: float) -> void:
	_update_quest_track()
	_update_compass()
	if not has_nav or player == null or not is_instance_valid(player):
		return
	if _quest_nav_active:
		return   # 任务追踪的导航点由追踪逻辑管理（动态目标不自动清除）
	var d: float = Vector2(player.global_position.x - nav_target.x, player.global_position.z - nav_target.z).length()
	if d <= 2.5:
		clear_nav()
		flash_message("已到达导航点。")

func respawn_player() -> void:
	if player == null:
		return
	if Net.online:
		Net.request_respawn()
	player.global_position = Vector3(0, 0.05, 7.0)
	player.heal_full()
	_hide_death_panel()
	flash_message("已在星门复活。")
	spawn_skill_flash(player.global_position + Vector3(0, 0.8, 0), Color(0.55, 0.95, 1.0, 1), 2.2, 0.45)

# ---------------- 死亡 / 复活 ----------------

# 每帧检测玩家死亡瞬间：单机弹「看广告复活」窗，联机扣 10 级后弹「返回星门」窗。
func _update_death() -> void:
	if player == null or not is_instance_valid(player):
		return
	if player.hp > 0.0:
		_death_handled = false
		return
	if _death_handled:
		return
	_death_handled = true
	_reset_joystick()
	if backpack_panel != null:
		backpack_panel.visible = false
	# 副本内阵亡：退出副本回到大世界（经验/装备惩罚照常结算）。
	if in_dungeon:
		if Net.online:
			Net.send_dungeon("force_leave", 0)
		else:
			_sp_leave_dungeon(true)
	# 死亡惩罚（单机/联机都生效）：扣 10% 当前升级所需经验 + 概率丢一件装备。
	var lost_exp: int = player.apply_death_penalty()
	var lost_gear: String = ""
	if inv != null and rng.randf() < DEATH_DROP_CHANCE:
		lost_gear = inv.lose_random_equipment()
	var penalty: String = "失去 %d 点经验（等级不变）。" % lost_exp
	if lost_gear != "":
		penalty += "\n死亡丢失装备：%s。" % lost_gear
	if Net.online:
		_show_death_panel(false, "你已阵亡。\n%s" % penalty)
	else:
		_record_run()   # 单机：把本局战绩计入本地排行榜
		_show_death_panel(true, "你已阵亡。\n%s\n观看广告原地复活，或接受惩罚返回星门。" % penalty)

func _show_death_panel(allow_ad: bool, msg: String) -> void:
	if death_panel == null:
		return
	death_msg_label.text = msg
	death_revive_btn.visible = allow_ad
	_refresh_ad_diag()
	death_panel.visible = true

func _refresh_ad_diag() -> void:
	if death_diag_label != null:
		death_diag_label.text = "广告诊断：" + AdService.sdk_status()

# ---------------- 个人档案 / 排行榜 ----------------
func _build_profile_panel() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ProfileLayer"
	layer.layer = 40
	add_child(layer)
	profile_panel = Control.new()
	profile_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	profile_panel.visible = false
	layer.add_child(profile_panel)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	profile_panel.add_child(dim)
	var card := Panel.new()
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.position = Vector2(-300, -240)
	card.size = Vector2(600, 480)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.14, 0.98)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.4, 0.7, 1.0, 0.7)
	sb.set_corner_radius_all(14)
	card.add_theme_stylebox_override("panel", sb)
	profile_panel.add_child(card)
	var title := Label.new()
	title.text = "个人档案 / 排行榜"
	title.position = Vector2(20, 12)
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.7, 0.95, 1.0, 1))
	card.add_child(title)
	profile_text = RichTextLabel.new()
	profile_text.bbcode_enabled = true
	profile_text.position = Vector2(20, 50)
	profile_text.size = Vector2(560, 372)
	profile_text.scroll_active = true
	card.add_child(profile_text)
	var tt_btn := Button.new()
	tt_btn.text = "TapTap 登录"
	tt_btn.position = Vector2(20, 432)
	tt_btn.size = Vector2(160, 36)
	tt_btn.pressed.connect(_on_taptap_login)
	card.add_child(tt_btn)
	var close := Button.new()
	close.text = "关闭 (P)"
	close.position = Vector2(440, 432)
	close.size = Vector2(140, 36)
	close.pressed.connect(_toggle_profile)
	card.add_child(close)

func _on_taptap_login() -> void:
	TapTap.login()
	flash_message("正在唤起 TapTap 登录…（仅安卓真机有效）")
	_refresh_profile()

func _toggle_profile() -> void:
	if profile_panel == null:
		return
	profile_panel.visible = not profile_panel.visible
	if profile_panel.visible:
		_refresh_profile()

func get_player_name() -> String:
	if TapTap.available():
		var n: String = TapTap.nickname()
		if n != "":
			return n
	return local_player_name

func _run_score() -> int:
	if player == null:
		return 0
	var sk_total: int = 0
	for sid: String in skills.skill_levels.keys():
		sk_total += int(skills.skill_levels[sid])
	return player.level * 100 + world_level * 200 + sk_total * 30

func _refresh_profile() -> void:
	if profile_text == null or player == null:
		return
	var sk_lines: Array[String] = []
	for sid: String in SkillManager.ORDER:
		var lv: int = int(skills.skill_levels.get(sid, 0))
		sk_lines.append("%s Lv.%d" % [String(skills.get_skill_meta(sid).get("name", sid)), lv])
	var tt_state: String = "[color=#7fdc7f](TapTap已登录)[/color]" if (TapTap.available() and TapTap.is_logged_in()) else "[color=#888](TapTap未登录)[/color]"
	var s: String = ""
	s += "[b]游戏名[/b]：%s  %s\n" % [get_player_name(), tt_state]
	s += "[b]等级[/b] Lv.%d   升级上限 Lv.%d   经验 %d/%d\n" % [player.level, level_cap, player.exp_points, player.next_level_exp]
	s += "[b]属性[/b]：攻 %d  魔 %d  防 %d  韧 %d  生 %d/%d  法 %d/%d  体力 %d/%d  速 %.1f  吸血 %.0f%%\n" % [player.attack, player.magic, player.defense, player.toughness, int(player.hp), player.max_hp, int(player.mp), player.max_mp, int(player.stamina), player.max_stamina, player.move_speed, player.lifesteal * 100.0]
	s += "[b]装备等级[/b]：%s\n" % inv.summary()
	s += "[b]技能等级[/b]：%s\n" % " ".join(sk_lines)
	s += "\n[b][color=#ffd24a]── 单机排行榜（按战力分）──[/color][/b]\n"
	var my_score: int = _run_score()
	var lb: Array = _load_leaderboard()
	if lb.is_empty():
		s += "[color=#888]暂无记录。阵亡时会自动记录你的本局战绩。[/color]\n"
	else:
		var rank: int = 1
		for rec_v: Variant in lb:
			var rec: Dictionary = rec_v
			var is_me: bool = String(rec.get("name", "")) == get_player_name() and int(rec.get("score", 0)) == my_score
			var mark: String = "[color=#ffd24a]►[/color] " if is_me else "   "
			s += "%s%d. %s  Lv.%d  世界%d  战力 %d\n" % [mark, rank, String(rec.get("name", "?")), int(rec.get("level", 1)), int(rec.get("world", 1)), int(rec.get("score", 0))]
			rank += 1
			if rank > 15:
				break
	s += "\n[color=#9bd]你当前战力：%d（阵亡后自动入榜）[/color]" % my_score
	profile_text.text = s

func _record_run() -> void:
	if Net.online or player == null:
		return
	var lb: Array = _load_leaderboard()
	lb.append({"name": get_player_name(), "level": player.level, "world": world_level, "score": _run_score()})
	lb.sort_custom(func(a: Variant, b: Variant) -> bool: return int((a as Dictionary).get("score", 0)) > int((b as Dictionary).get("score", 0)))
	if lb.size() > 50:
		lb = lb.slice(0, 50)
	_save_leaderboard(lb)

func _leaderboard_path() -> String:
	return "user://leaderboard.json"

func _load_leaderboard() -> Array:
	if not FileAccess.file_exists(_leaderboard_path()):
		return []
	var f := FileAccess.open(_leaderboard_path(), FileAccess.READ)
	if f == null:
		return []
	var txt: String = f.get_as_text()
	f.close()
	var d: Variant = JSON.parse_string(txt)
	return d if d is Array else []

func _save_leaderboard(lb: Array) -> void:
	var f := FileAccess.open(_leaderboard_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(lb))
	f.close()

# ---------------- 战斗状态 / 暂停菜单 / 退出 ----------------
func mark_combat() -> void:
	_combat_timer = 5.0

func in_combat() -> bool:
	return _combat_timer > 0.0

func _build_pause_menu() -> void:
	var layer := CanvasLayer.new()
	layer.name = "PauseLayer"
	layer.layer = 60
	add_child(layer)
	pause_panel = Control.new()
	pause_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pause_panel.visible = false
	layer.add_child(pause_panel)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pause_panel.add_child(dim)
	var card := Panel.new()
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.position = Vector2(-200, -220)
	card.size = Vector2(400, 440)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.14, 0.98)
	sb.set_border_width_all(2)
	sb.border_color = Color(0.45, 0.7, 1.0, 0.7)
	sb.set_corner_radius_all(14)
	card.add_theme_stylebox_override("panel", sb)
	pause_panel.add_child(card)
	var title := Label.new()
	title.text = "菜单"
	title.position = Vector2(0, 18)
	title.size = Vector2(400, 36)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(0.7, 0.95, 1.0, 1))
	card.add_child(title)
	_pause_btn(card, "继续游戏", 70, _toggle_pause)
	if Net.online:
		_pause_btn(card, "修改资料（脱战/安全区）", 124, _open_profile_editor)
	_pause_btn(card, "返回欢迎页", 178, func() -> void: _request_quit("menu"))
	_pause_btn(card, "退出游戏", 232, func() -> void: _request_quit("exit"))
	pause_status_label = Label.new()
	pause_status_label.position = Vector2(20, 292)
	pause_status_label.size = Vector2(360, 60)
	pause_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pause_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pause_status_label.add_theme_font_size_override("font_size", 14)
	pause_status_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.6, 1))
	card.add_child(pause_status_label)
	pause_force_btn = Button.new()
	pause_force_btn.text = "强制退出（战斗中有惩罚）"
	pause_force_btn.position = Vector2(40, 384)
	pause_force_btn.size = Vector2(320, 40)
	pause_force_btn.visible = false
	pause_force_btn.add_theme_color_override("font_color", Color(1.0, 0.6, 0.55, 1))
	pause_force_btn.pressed.connect(_on_force_quit)
	card.add_child(pause_force_btn)
	if not Net.logout_permission.is_connected(_on_logout_permission):
		Net.logout_permission.connect(_on_logout_permission)

# ---------------- 修改个人资料（昵称/头像；仅脱战或安全区，服务器权威校验）----------------
func _open_profile_editor() -> void:
	if profile_edit_panel == null:
		_build_profile_editor()
	if profile_nick_edit != null:
		profile_nick_edit.text = String(Net.roster.get(Net.my_id, ""))
	profile_avatar_b64 = String(Net.roster_avatar.get(Net.my_id, ""))
	_update_profile_preview()
	profile_edit_panel.visible = true

func _update_profile_preview() -> void:
	if profile_avatar_preview != null:
		profile_avatar_preview.texture = _avatar_texture(profile_avatar_b64)

func _pick_profile_avatar() -> void:
	if _profile_avatar_dialog == null:
		_profile_avatar_dialog = FileDialog.new()
		_profile_avatar_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_profile_avatar_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_profile_avatar_dialog.filters = PackedStringArray(["*.png ; PNG 图片", "*.jpg,*.jpeg ; JPEG 图片"])
		_profile_avatar_dialog.file_selected.connect(func(p: String) -> void:
			var img := Image.new()
			if img.load(p) == OK:
				img.resize(64, 64, Image.INTERPOLATE_LANCZOS)
				profile_avatar_b64 = Marshalls.raw_to_base64(img.save_png_to_buffer())
				_avatar_tex_cache[profile_avatar_b64] = ImageTexture.create_from_image(img)
				_update_profile_preview())
		add_child(_profile_avatar_dialog)
	_profile_avatar_dialog.popup_centered(Vector2i(760, 520))

func _build_profile_editor() -> void:
	var layer := CanvasLayer.new(); layer.layer = 62; add_child(layer)
	profile_edit_panel = Control.new()
	profile_edit_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(profile_edit_panel)
	var dim := ColorRect.new(); dim.color = Color(0, 0, 0, 0.65)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	profile_edit_panel.add_child(dim)
	var card := Panel.new()
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.position = Vector2(-210, -170); card.size = Vector2(420, 340)
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(0.06, 0.08, 0.14, 0.98)
	sb.set_border_width_all(2); sb.border_color = Color(0.45, 0.7, 1.0, 0.7); sb.set_corner_radius_all(14)
	card.add_theme_stylebox_override("panel", sb)
	profile_edit_panel.add_child(card)
	var title := Label.new(); title.text = "修改个人资料"
	title.position = Vector2(0, 16); title.size = Vector2(420, 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(0.7, 0.95, 1.0, 1))
	card.add_child(title)
	var nlbl := Label.new(); nlbl.text = "昵称"; nlbl.position = Vector2(24, 62); card.add_child(nlbl)
	profile_nick_edit = LineEdit.new()
	profile_nick_edit.position = Vector2(24, 88); profile_nick_edit.size = Vector2(372, 34)
	profile_nick_edit.placeholder_text = "昵称（留空则不改）"; profile_nick_edit.max_length = 16
	card.add_child(profile_nick_edit)
	var albl := Label.new(); albl.text = "头像（png/jpg，可拖入窗口；留空=随机色）"; albl.position = Vector2(24, 130); card.add_child(albl)
	profile_avatar_preview = TextureRect.new()
	profile_avatar_preview.position = Vector2(24, 158); profile_avatar_preview.custom_minimum_size = Vector2(56, 56); profile_avatar_preview.size = Vector2(56, 56)
	profile_avatar_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	card.add_child(profile_avatar_preview)
	var upb := Button.new(); upb.text = "上传头像"; upb.position = Vector2(96, 158); upb.size = Vector2(140, 40)
	upb.pressed.connect(_pick_profile_avatar); card.add_child(upb)
	var defb := Button.new(); defb.text = "用默认(随机色)"; defb.position = Vector2(248, 158); defb.size = Vector2(148, 40)
	defb.pressed.connect(func() -> void:
		profile_avatar_b64 = ""
		_update_profile_preview()); card.add_child(defb)
	var save := Button.new(); save.text = "保存"; save.position = Vector2(40, 280); save.size = Vector2(160, 40)
	save.pressed.connect(_on_profile_save); card.add_child(save)
	var cancel := Button.new(); cancel.text = "取消"; cancel.position = Vector2(220, 280); cancel.size = Vector2(160, 40)
	cancel.pressed.connect(func() -> void: profile_edit_panel.visible = false); card.add_child(cancel)
	if not get_window().files_dropped.is_connected(_on_profile_files_dropped):
		get_window().files_dropped.connect(_on_profile_files_dropped)

func _on_profile_files_dropped(files: PackedStringArray) -> void:
	if profile_edit_panel == null or not profile_edit_panel.visible or files.is_empty():
		return
	var p: String = files[0]; var pl: String = p.to_lower()
	if pl.ends_with(".png") or pl.ends_with(".jpg") or pl.ends_with(".jpeg"):
		var img := Image.new()
		if img.load(p) == OK:
			img.resize(64, 64, Image.INTERPOLATE_LANCZOS)
			profile_avatar_b64 = Marshalls.raw_to_base64(img.save_png_to_buffer())
			_avatar_tex_cache[profile_avatar_b64] = ImageTexture.create_from_image(img)
			_update_profile_preview()

func _on_profile_save() -> void:
	if Net.online:
		Net.send_set_profile(profile_nick_edit.text.strip_edges(), profile_avatar_b64)
		flash_message("已提交资料修改（需脱战或在安全区，服务器审核）。")
	profile_edit_panel.visible = false

func _pause_btn(card: Control, text: String, y: float, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.position = Vector2(40, y)
	b.size = Vector2(320, 46)
	b.add_theme_font_size_override("font_size", 20)
	b.pressed.connect(cb)
	card.add_child(b)

func _toggle_pause() -> void:
	if pause_panel == null:
		return
	pause_panel.visible = not pause_panel.visible
	if pause_panel.visible:
		pause_force_btn.visible = false
		_pending_quit = ""
		_refresh_pause_status()

func _refresh_pause_status() -> void:
	if pause_status_label == null:
		return
	if not Net.online:
		pause_status_label.text = "单机模式：返回/退出会自动存档。"
	else:
		pause_status_label.text = "状态：%s" % ("战斗中（脱战后才能安全退出）" if in_combat() else "已脱战")

# 请求退出：单机直接执行；联机先本地脱战判定，再请服务器确认。
func _request_quit(kind: String) -> void:
	if not Net.online:
		_do_quit(kind, false)
		return
	if in_combat():
		_force_kind = kind
		pause_status_label.text = "你正在战斗中，脱战后才能安全退出。可强制退出（会受惩罚）。"
		pause_force_btn.visible = true
		return
	# 本地已脱战 → 让服务器判定（按钮保留强制退出作兜底，避免无回包卡死）。
	_pending_quit = kind
	_force_kind = kind
	pause_force_btn.visible = true
	pause_status_label.text = "本地已脱战，正在请求服务器确认是否可安全退出…"
	Net.request_logout_check()

# 服务器脱战裁决回包。
func _on_logout_permission(allowed: bool, reason: String) -> void:
	if _pending_quit == "":
		return
	var kind: String = _pending_quit
	_pending_quit = ""
	if allowed:
		_do_quit(kind, false)
	else:
		pause_status_label.text = "服务器判定仍在战斗中：%s 可强制退出（会受惩罚）。" % reason
		pause_force_btn.visible = true

func _on_force_quit() -> void:
	_do_quit(_force_kind if _force_kind != "" else "exit", true)

func _do_quit(kind: String, forced: bool) -> void:
	if Net.online:
		if not forced:
			Net.send_save(_build_save())   # 安全退出：存档到服务器
		Net.disconnect_from_server()
	else:
		_autosave()
	if kind == "exit":
		get_tree().quit()
	else:
		get_tree().change_scene_to_file("res://scenes/Menu.tscn")

func _hide_death_panel() -> void:
	if death_panel != null:
		death_panel.visible = false

func _on_revive_ad_pressed() -> void:
	if not AdService.is_available():
		return
	death_revive_btn.disabled = true
	if not AdService.ad_finished.is_connected(_on_revive_ad_finished):
		AdService.ad_finished.connect(_on_revive_ad_finished)
	AdService.show_rewarded_ad()

func _on_revive_ad_finished(rewarded: bool) -> void:
	if AdService.ad_finished.is_connected(_on_revive_ad_finished):
		AdService.ad_finished.disconnect(_on_revive_ad_finished)
	death_revive_btn.disabled = false
	_refresh_ad_diag()
	if rewarded:
		_revive_in_place()
	else:
		flash_message("未看完广告，复活取消。")

# 原地满状态复活（看广告奖励）。
func _revive_in_place() -> void:
	if player == null or not is_instance_valid(player):
		return
	player.hp = float(player.max_hp)
	player.mp = float(player.max_mp)
	if player.buff != null:
		player.buff.apply_invuln(2.5)
	_death_handled = false
	_hide_death_panel()
	flash_message("广告复活成功！原地满状态归来。")
	spawn_skill_flash(player.global_position + Vector3(0, 1.0, 0), Color(0.5, 1.0, 0.7, 1), 2.4, 0.5)

# 触屏：按住攻击键时按冷却自动连发普攻（地面/空中通用）。
func _handle_touch_attack() -> void:
	if player == null or not is_instance_valid(player) or player.hp <= 0.0:
		return
	if not player.touch_attack:
		return
	if float(player.cooldowns.get("star_slash", 0.0)) > 0.0 or player.skill_lock_timer > 0.0:
		return
	if player.flying_cloud and player.mp < float(StarGloryPlayer.AERIAL_SLASH_MP):
		return
	player.cast_skill("star_slash")

func _build_death_panel() -> void:
	# 死亡面板放在更高的独立 CanvasLayer，确保盖在触屏控件/快捷栏之上，按钮可点。
	var death_layer := CanvasLayer.new()
	death_layer.name = "DeathLayer"
	death_layer.layer = 50
	add_child(death_layer)
	death_panel = Control.new()
	death_panel.name = "DeathPanel"
	death_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	death_panel.visible = false
	death_layer.add_child(death_panel)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.66)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	death_panel.add_child(dim)
	var card := Panel.new()
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.position = Vector2(-220, -160)
	card.size = Vector2(440, 320)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.06, 0.10, 0.98)
	sb.set_border_width_all(2)
	sb.border_color = Color(1.0, 0.4, 0.4, 0.8)
	sb.set_corner_radius_all(14)
	card.add_theme_stylebox_override("panel", sb)
	death_panel.add_child(card)
	var title := Label.new()
	title.text = "你 阵 亡 了"
	title.position = Vector2(20, 24)
	title.size = Vector2(400, 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5, 1))
	card.add_child(title)
	death_msg_label = Label.new()
	death_msg_label.position = Vector2(28, 80)
	death_msg_label.size = Vector2(384, 110)
	death_msg_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	death_msg_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	death_msg_label.add_theme_font_size_override("font_size", 16)
	death_msg_label.add_theme_color_override("font_color", Color(0.88, 0.9, 1.0, 1))
	card.add_child(death_msg_label)
	death_revive_btn = Button.new()
	death_revive_btn.text = "📺 看广告复活"
	death_revive_btn.position = Vector2(60, 206)
	death_revive_btn.size = Vector2(320, 48)
	death_revive_btn.add_theme_font_size_override("font_size", 20)
	death_revive_btn.pressed.connect(_on_revive_ad_pressed)
	card.add_child(death_revive_btn)
	var respawn_btn := Button.new()
	respawn_btn.text = "接受惩罚返回星门"
	respawn_btn.position = Vector2(60, 262)
	respawn_btn.size = Vector2(320, 40)
	respawn_btn.add_theme_font_size_override("font_size", 16)
	respawn_btn.pressed.connect(respawn_player)
	card.add_child(respawn_btn)
	# 广告链路诊断（真机排查"为什么没出真广告"）。
	death_diag_label = Label.new()
	death_diag_label.anchor_left = 0.0
	death_diag_label.anchor_right = 1.0
	death_diag_label.anchor_top = 1.0
	death_diag_label.anchor_bottom = 1.0
	death_diag_label.offset_left = 12.0
	death_diag_label.offset_right = -12.0
	death_diag_label.offset_top = -52.0
	death_diag_label.offset_bottom = -8.0
	death_diag_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	death_diag_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	death_diag_label.add_theme_font_size_override("font_size", 13)
	death_diag_label.add_theme_color_override("font_color", Color(0.8, 0.85, 0.6, 1))
	death_panel.add_child(death_diag_label)

# ---------------- 触屏控件（仅单机） ----------------
func _build_touch_controls() -> void:
	touch_root = Control.new()
	touch_root.name = "TouchControls"
	touch_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	touch_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(touch_root)

	# 左下虚拟摇杆（更大，锚定到屏幕左下角）。
	var jd: float = JOY_RADIUS * 2.0
	joy_base = Control.new()
	joy_base.anchor_left = 0.0
	joy_base.anchor_right = 0.0
	joy_base.anchor_top = 1.0
	joy_base.anchor_bottom = 1.0
	joy_base.offset_left = 40.0
	joy_base.offset_right = 40.0 + jd
	joy_base.offset_top = -jd - 40.0
	joy_base.offset_bottom = -40.0
	joy_base.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 仅作视觉/命中区域；触摸由原始事件处理
	touch_root.add_child(joy_base)
	var ring := Panel.new()
	ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rs := StyleBoxFlat.new()
	rs.bg_color = Color(0.2, 0.35, 0.55, 0.24)
	rs.set_corner_radius_all(int(JOY_RADIUS))
	rs.set_border_width_all(3)
	rs.border_color = Color(0.5, 0.8, 1.0, 0.55)
	ring.add_theme_stylebox_override("panel", rs)
	joy_base.add_child(ring)
	joy_knob = Panel.new()
	joy_knob.size = Vector2(96, 96)
	joy_knob.position = Vector2(JOY_RADIUS, JOY_RADIUS) - joy_knob.size * 0.5
	joy_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ks := StyleBoxFlat.new()
	ks.bg_color = Color(0.45, 0.8, 1.0, 0.6)
	ks.set_corner_radius_all(48)
	joy_knob.add_theme_stylebox_override("panel", ks)
	joy_base.add_child(joy_knob)

	# 右下按键（锚定屏幕右下角）。下排 跳|攻击；上排 Q E 左移、加速键放在 E 右侧。draw-only，多点识别。
	_touch_pad_br("attack", "攻击", Vector2(40, 40), Vector2(160, 160), Color(1.0, 0.5, 0.3, 1))
	_touch_pad_br("jump", "跳", Vector2(220, 50), Vector2(140, 140), Color(0.5, 0.9, 0.7, 1))
	_touch_pad_br("q", "Q", Vector2(300, 230), Vector2(112, 112), Color(0.6, 0.8, 1.0, 1))
	_touch_pad_br("e", "E", Vector2(168, 230), Vector2(112, 112), Color(0.9, 0.8, 0.5, 1))
	_touch_pad_br("accel", "加速", Vector2(40, 230), Vector2(112, 112), Color(0.55, 1.0, 0.85, 1))

	# 背包按钮：锚定屏幕右上角、小地图下方。
	var bag := Button.new()
	bag.text = "背包"
	bag.focus_mode = Control.FOCUS_NONE
	bag.anchor_left = 1.0
	bag.anchor_right = 1.0
	bag.anchor_top = 0.0
	bag.anchor_bottom = 0.0
	bag.offset_left = -104.0
	bag.offset_right = -16.0
	bag.offset_top = 228.0
	bag.offset_bottom = 316.0
	bag.add_theme_font_size_override("font_size", 24)
	bag.add_theme_stylebox_override("normal", _round_btn(Color(0.18, 0.28, 0.16, 0.8), Color(0.7, 0.95, 0.5, 0.9), 14))
	bag.add_theme_stylebox_override("hover", _round_btn(Color(0.24, 0.36, 0.2, 0.9), Color(0.8, 1.0, 0.6, 1), 14))
	bag.add_theme_stylebox_override("pressed", _round_btn(Color(0.3, 0.45, 0.25, 0.95), Color(1, 1, 1, 1), 14))
	bag.add_theme_color_override("font_color", Color(0.95, 1.0, 0.9, 1))
	bag.pressed.connect(_toggle_backpack)
	touch_root.add_child(bag)

	# 档案/排行榜按钮（背包键下方）。
	var prof := Button.new()
	prof.text = "档案"
	prof.focus_mode = Control.FOCUS_NONE
	prof.anchor_left = 1.0
	prof.anchor_right = 1.0
	prof.anchor_top = 0.0
	prof.anchor_bottom = 0.0
	prof.offset_left = -104.0
	prof.offset_right = -16.0
	prof.offset_top = 324.0
	prof.offset_bottom = 384.0
	prof.add_theme_font_size_override("font_size", 22)
	prof.add_theme_stylebox_override("normal", _round_btn(Color(0.16, 0.2, 0.32, 0.8), Color(0.5, 0.75, 1.0, 0.9), 14))
	prof.add_theme_stylebox_override("hover", _round_btn(Color(0.2, 0.26, 0.4, 0.9), Color(0.6, 0.85, 1.0, 1), 14))
	prof.add_theme_stylebox_override("pressed", _round_btn(Color(0.26, 0.34, 0.5, 0.95), Color(1, 1, 1, 1), 14))
	prof.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0, 1))
	prof.pressed.connect(_toggle_profile)
	touch_root.add_child(prof)

	# 看广告按钮（档案下方）：看完回复少量状态；联机时观看次数上报服务器记录。
	var adb := Button.new()
	adb.text = "📺广告"
	adb.focus_mode = Control.FOCUS_NONE
	adb.anchor_left = 1.0; adb.anchor_right = 1.0; adb.anchor_top = 0.0; adb.anchor_bottom = 0.0
	adb.offset_left = -104.0; adb.offset_right = -16.0; adb.offset_top = 392.0; adb.offset_bottom = 444.0
	adb.add_theme_font_size_override("font_size", 20)
	adb.add_theme_stylebox_override("normal", _round_btn(Color(0.3, 0.24, 0.12, 0.8), Color(1.0, 0.85, 0.4, 0.9), 14))
	adb.add_theme_stylebox_override("hover", _round_btn(Color(0.38, 0.3, 0.16, 0.9), Color(1.0, 0.9, 0.5, 1), 14))
	adb.add_theme_color_override("font_color", Color(1.0, 0.95, 0.8, 1))
	adb.pressed.connect(_on_watch_ad_pressed)
	touch_root.add_child(adb)

func _on_watch_ad_pressed() -> void:
	if not AdService.ad_finished.is_connected(_on_reward_ad_finished):
		AdService.ad_finished.connect(_on_reward_ad_finished)
	AdService.show_rewarded_ad()

func _on_reward_ad_finished(rewarded: bool) -> void:
	if AdService.ad_finished.is_connected(_on_reward_ad_finished):
		AdService.ad_finished.disconnect(_on_reward_ad_finished)
	if rewarded and player != null and is_instance_valid(player):
		player.hp = minf(float(player.max_hp), player.hp + float(player.max_hp) * 0.25)
		player.mp = minf(float(player.max_mp), player.mp + float(player.max_mp) * 0.25)
		if inv != null and not Net.online:
			inv.add_material("防御卷轴", Color(0.95, 0.85, 0.45, 1), 1)
		flash_message("感谢观看广告！已回复部分状态%s。" % ("，并获得防御卷轴×1" if not Net.online else "，防御卷轴由服务器发放"))

# 任意一次「看完」奖励广告：联机时把观看次数上报服务器记录（单机不上报）。
func _on_any_ad_finished(rewarded: bool) -> void:
	if rewarded and Net.online:
		Net.send_ad_view()

func _touch_attack_down() -> void:
	if player != null:
		player.touch_attack = true

func _touch_attack_up() -> void:
	if player != null:
		player.touch_attack = false

func _touch_jump_down() -> void:
	if player != null:
		player.touch_jump = true

func _touch_jump_up() -> void:
	if player != null:
		player.touch_jump = false

func _touch_q_down() -> void:
	if player == null:
		return
	if not player.flying_cloud:
		player.toggle_cloud_flight()
	player.touch_q = true

func _touch_q_up() -> void:
	if player != null:
		player.touch_q = false

func _touch_e_down() -> void:
	if player == null:
		return
	if not player.flying_cloud:
		pickup_nearest()
	player.touch_e = true

func _touch_e_up() -> void:
	if player != null:
		player.touch_e = false

# 右下角的圆形触摸键（draw-only Panel，仅作视觉+命中区域；按下/抬起由原始触摸事件驱动）。
# br = 按键右下角距屏幕右/下边的边距。
func _touch_pad_br(role: String, text: String, br: Vector2, size: Vector2, col: Color) -> void:
	var p := Panel.new()
	p.anchor_left = 1.0
	p.anchor_right = 1.0
	p.anchor_top = 1.0
	p.anchor_bottom = 1.0
	p.offset_right = -br.x
	p.offset_bottom = -br.y
	p.offset_left = -br.x - size.x
	p.offset_top = -br.y - size.y
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var r: int = int(min(size.x, size.y) * 0.5)
	p.add_theme_stylebox_override("panel", _round_btn(Color(col.r * 0.35, col.g * 0.35, col.b * 0.35, 0.78), col, r))
	var lbl := Label.new()
	lbl.text = text
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_font_size_override("font_size", 32)
	lbl.add_theme_color_override("font_color", Color(0.96, 0.98, 1.0, 1))
	p.add_child(lbl)
	touch_root.add_child(p)
	_touch_btn_nodes[role] = {"node": p, "col": col}

func _set_pad_pressed(role: String, pressed: bool) -> void:
	var e: Variant = _touch_btn_nodes.get(role)
	if e == null:
		return
	var p: Panel = (e as Dictionary)["node"]
	var col: Color = (e as Dictionary)["col"]
	var r: int = int(min(p.size.x, p.size.y) * 0.5)
	if pressed:
		p.add_theme_stylebox_override("panel", _round_btn(Color(col.r * 0.6, col.g * 0.6, col.b * 0.6, 0.95), Color(1, 1, 1, 1), r))
	else:
		p.add_theme_stylebox_override("panel", _round_btn(Color(col.r * 0.35, col.g * 0.35, col.b * 0.35, 0.78), col, r))

func _round_btn(bg: Color, border: Color, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_border_width_all(2)
	s.border_color = border
	return s

# ---------- 多点触控：按手指索引分配角色，互不干扰 ----------
func _handle_touch(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_begin(event.index, event.position)
		else:
			_touch_end(event.index)
	elif event is InputEventScreenDrag:
		_touch_drag(event.index, event.position, event.relative)

func _touch_begin(index: int, pos: Vector2) -> void:
	# 0a) 快捷药剂格：开始拖拽（松手在单位上=给它用，否则给自己）
	var qp: String = _quick_slot_at(pos)
	if qp != "":
		_finger_role[index] = "potion"
		_potion_drag = qp
		_update_potion_hover(pos)
		return
	# 0) 技能格：点击选定要释放的技能（御云格直接起飞）
	var sid: String = _hotbar_skill_at(pos)
	if sid != "":
		_finger_role[index] = "none"
		_start_skill_aim(sid)
		return
	# 1) 摇杆区域
	if joy_base != null and joy_base.get_global_rect().has_point(pos):
		_finger_role[index] = "joy"
		joy_active = true
		_set_joystick(pos - (joy_base.global_position + Vector2(JOY_RADIUS, JOY_RADIUS)))
		return
	# 2) 动作键
	for role: String in _touch_btn_nodes.keys():
		var p: Panel = (_touch_btn_nodes[role] as Dictionary)["node"]
		if p != null and p.get_global_rect().has_point(pos):
			_finger_role[index] = role
			_touch_press_role(role)
			return
	# 2.5) 施法前摇瞄准中：空白处点按 = 设置落点（摇杆仍可微调）
	if aim_active:
		_finger_role[index] = "none"
		set_aim_tap(pos)
		return
	# 3) 已选定技能：本次点击作为释放位置
	if _aim_skill != "":
		_finger_role[index] = "none"
		_place_mobile_skill(pos)
		return
	# 4) 其余空白处：仅「屏幕右半部分」的拖动用于转相机；左半部分不控制视野。
	var screen_w: float = get_viewport().get_visible_rect().size.x
	if pos.x >= screen_w * 0.5:
		_finger_role[index] = "cam"
	else:
		_finger_role[index] = "none"

# 命中某个技能热键格则返回其 skill_id（含御云格 "cloud"），否则 ""。
func _hotbar_skill_at(pos: Vector2) -> String:
	for skid: String in skill_slots.keys():
		var d: Dictionary = skill_slots[skid]
		var root: Variant = d.get("root")
		if root != null and (root as Control).get_global_rect().has_point(pos):
			return skid
	return ""

func _start_skill_aim(sid: String) -> void:
	if player == null or not is_instance_valid(player):
		return
	if sid == "cloud":
		_aim_skill = ""
		player.toggle_cloud_flight()
		return
	# 天星/火焰雨：落地型技能 → 点图标选中、点地面释放；再点同图标取消。其余技能点图标即放。
	if sid == "meteor" or sid == "fire_rain":
		if _aim_skill == sid:
			_aim_skill = ""
			flash_message("已取消技能选择。")
			return
		_aim_skill = sid
		var meta: Dictionary = skills.get_skill_meta(sid)
		flash_message("已选「%s」：点地面释放（再次点该技能取消）" % String(meta.get("name", sid)))
	else:
		_aim_skill = ""
		player.cast_skill(sid)   # 普通技能：手指点到图标即释放

func _place_mobile_skill(pos: Vector2) -> void:
	if player == null or not is_instance_valid(player) or _aim_skill == "":
		_aim_skill = ""
		return
	_mobile_aim_active = true
	_mobile_aim_screen = pos
	player.cast_skill(_aim_skill)
	_mobile_aim_active = false
	_aim_skill = ""

func _touch_end(index: int) -> void:
	var role: String = String(_finger_role.get(index, ""))
	_finger_role.erase(index)
	if role == "joy":
		_reset_joystick()
	elif role == "potion":
		_finish_potion_drag()
	elif role in ["attack", "jump", "q", "e", "accel"]:
		_touch_release_role(role)

func _touch_drag(index: int, pos: Vector2, rel: Vector2) -> void:
	var role: String = String(_finger_role.get(index, ""))
	if role == "joy":
		_set_joystick(pos - (joy_base.global_position + Vector2(JOY_RADIUS, JOY_RADIUS)))
	elif role == "potion":
		_update_potion_hover(pos)
	elif role == "cam":
		cam_yaw -= rel.x * 0.006
		cam_pitch = clamp(cam_pitch + rel.y * 0.004, -PITCH_LIMIT, PITCH_LIMIT)

func _touch_press_role(role: String) -> void:
	_set_pad_pressed(role, true)
	match role:
		"attack": _touch_attack_down()
		"jump": _touch_jump_down()
		"q": _touch_q_down()
		"e": _touch_e_down()
		"accel":
			if player != null:
				player.touch_accel = true

func _touch_release_role(role: String) -> void:
	_set_pad_pressed(role, false)
	match role:
		"attack": _touch_attack_up()
		"jump": _touch_jump_up()
		"q": _touch_q_up()
		"e": _touch_e_up()
		"accel":
			if player != null:
				player.touch_accel = false

func _is_mobile() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")

func _set_joystick(v: Vector2) -> void:
	if v.length() > JOY_RADIUS:
		v = v.normalized() * JOY_RADIUS
	if joy_knob != null:
		joy_knob.position = Vector2(JOY_RADIUS, JOY_RADIUS) + v - joy_knob.size * 0.5
	if player != null and is_instance_valid(player):
		player.touch_move = Vector2(v.x, -v.y) / JOY_RADIUS

func _reset_joystick() -> void:
	joy_active = false
	if joy_knob != null:
		joy_knob.position = Vector2(JOY_RADIUS, JOY_RADIUS) - joy_knob.size * 0.5
	if player != null and is_instance_valid(player):
		player.touch_move = Vector2.ZERO

# ESC 万能返回：逐层关闭最上层面板；都没有则开/关暂停菜单。
# ---------------- HUD 面板统一开关（同键再按关闭 / 一次只开一个 / ESC 关闭）----------------
func _panel_open(which: String) -> bool:
	match which:
		"quest": return quest_system != null and quest_system.is_log_open()
		"achv": return achievement_system != null and achievement_system.is_open()
		"pet": return pet_system != null and pet_system.is_open()
		"leaderboard": return _lb_panel != null and _lb_panel.visible
		"drone": return drone_system != null and drone_system.is_open()
		"backpack": return backpack_panel != null and backpack_panel.visible
		"profile": return profile_panel != null and profile_panel.visible
	return false

func _any_hud_panel_open() -> bool:
	if quest_system != null and (quest_system.is_log_open() or quest_system.is_npc_open()): return true
	if achievement_system != null and achievement_system.is_open(): return true
	if pet_system != null and pet_system.is_open(): return true
	if drone_system != null and drone_system.is_open(): return true
	if _lb_panel != null and _lb_panel.visible: return true
	return false

func _close_hud_panels() -> void:
	if quest_system != null:
		quest_system.close_log(); quest_system.close_npc()
	if achievement_system != null: achievement_system.close()
	if pet_system != null: pet_system.close()
	if drone_system != null: drone_system.close()
	if _lb_panel != null: _lb_panel.visible = false
	if backpack_panel != null and backpack_panel.visible: _toggle_backpack()
	if profile_panel != null and profile_panel.visible: _toggle_profile()

func _open_panel(which: String) -> void:
	match which:
		"quest": if quest_system != null: quest_system.toggle_log()
		"achv": if achievement_system != null: achievement_system.toggle()
		"pet": if pet_system != null: pet_system.toggle()
		"leaderboard": _toggle_leaderboard()
		"drone": if drone_system != null: drone_system.toggle()
		"backpack": _toggle_backpack()
		"profile": _toggle_profile()

# 面板热键：已开→关；未开→先关其它再开（一次只开一个）。
func _hud_panel_key(which: String) -> void:
	var was: bool = _panel_open(which)
	_close_hud_panels()
	if not was:
		_open_panel(which)

func _on_escape() -> void:
	if admin_panel_open:
		_close_admin_panel()
		return
	if _any_hud_panel_open():   # ESC 关闭任意 HUD 面板
		_close_hud_panels()
		return
	if chat_typing and chat_input != null:
		chat_input.release_focus()
		return
	if backpack_panel != null and backpack_panel.visible:
		_toggle_backpack()
		return
	if big_map != null and big_map.visible:
		toggle_big_map()
		return
	if profile_panel != null and profile_panel.visible:
		_toggle_profile()
		return
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	right_mouse_down = false
	_toggle_pause()

# GM（管理员）账号仅用于测试，不写存档/不刷记录。
func _is_gm() -> bool:
	return Net.online and Net.admin_level > 0

# 任务系统完成时调用：立即存档一次（否则等下次周期自动存档）。
func _save_quests() -> void:
	_autosave()

func _autosave() -> void:
	if player == null or not is_instance_valid(player):
		return
	if _is_gm():
		return
	var save: Dictionary = _build_save()
	if Net.online:
		Net.send_save(save)
	else:
		SaveSystem.save_game(save)
		TapTap.sync_save(save)   # 单机：把存档（含等级/游戏时长/Boss记录）同步到 TapTap 云存档

# 玩家当前属性快照（击杀 Boss 时记录），用于 TapTap 同步与本地档案。
func _player_stat_snapshot() -> Dictionary:
	return {
		"level": player.level,
		"max_hp": player.max_hp, "max_mp": player.max_mp,
		"attack": player.attack, "magic": player.magic,
		"defense": player.defense, "toughness": player.toughness,
	}

# 记录一次 Boss 击杀：单场战斗时长 + 当时游戏时长 + 击杀时属性；单机时同步到 TapTap。
func _record_boss_kill(monster: StarGloryMonster) -> void:
	if player == null or not is_instance_valid(player):
		return
	if _is_gm():
		return
	var fight_seconds: float = 0.0
	if monster.fight_start_ms > 0:
		fight_seconds = float(Time.get_ticks_msec() - monster.fight_start_ms) / 1000.0
	var rec: Dictionary = {
		"boss_name": monster.monster_name,
		"resident": monster.resident,
		"world_level": world_level,
		"fight_seconds": snappedf(fight_seconds, 0.1),
		"play_seconds": snappedf(play_seconds, 0.1),
		"killed_at_unix": int(Time.get_unix_time_from_system()),
		"stats": _player_stat_snapshot(),
	}
	boss_records.append(rec)
	if boss_records.size() > 50:   # 仅保留最近 50 条，避免存档无限增长
		boss_records = boss_records.slice(boss_records.size() - 50)
	if not Net.online:
		TapTap.sync_solo_stats(rec)

func _item_to_save(it: Dictionary) -> Dictionary:
	var d: Dictionary = it.duplicate(true)
	if d.has("color"):
		var c: Color = d["color"] as Color
		d["color"] = [c.r, c.g, c.b, c.a]
	return d

func _item_from_save(d: Dictionary) -> Dictionary:
	var it: Dictionary = d.duplicate(true)
	if it.has("color") and it["color"] is Array:
		var a: Array = it["color"]
		it["color"] = Color(a[0], a[1], a[2], a[3])
	return it

func _build_save() -> Dictionary:
	var books: Dictionary = {}
	for id: String in skills.books.keys():
		var binv: Dictionary = {}
		for tier: int in skills.books[id].keys():
			binv[str(tier)] = int(skills.books[id][tier])
		books[id] = binv
	return {
		"level": player.level, "exp": player.exp_points, "next_exp": player.next_level_exp,
		"base_hp": player.base_max_hp, "base_mp": player.base_max_mp, "base_atk": player.base_attack,
		"base_mag": player.base_magic, "base_def": player.base_defense, "base_tough": player.base_toughness,
		"hp": player.hp, "mp": player.mp,
		"skill_levels": skills.skill_levels.duplicate(),
		"books": books,
		"kills": kills, "boss_defeated": boss_defeated,
		"play_seconds": play_seconds, "boss_records": boss_records,
		"dungeon_records": dungeon_records,
		"world_level": world_level, "level_cap": level_cap, "shelter_level": shelter_level,
		"quests": quest_system.to_save() if quest_system != null else {},
		"achievements": achievement_system.to_save() if achievement_system != null else {},
		"pets": pet_system.to_save() if pet_system != null else {},
		"drones": drone_system.to_save() if drone_system != null else {},
		"inventory": inv.to_save(),
		"player_name": local_player_name,
		"unlock_stage": unlock_stage, "unlocked_radius": unlocked_world_radius
	}

func _apply_save(data: Dictionary) -> void:
	if data.is_empty() or player == null:
		return
	player.level = int(data.get("level", 1))
	player.exp_points = int(data.get("exp", 0))
	player.next_level_exp = int(data.get("next_exp", 80))
	player.base_max_hp = int(data.get("base_hp", player.base_max_hp))
	player.base_max_mp = int(data.get("base_mp", player.base_max_mp))
	player.base_attack = int(data.get("base_atk", player.base_attack))
	player.base_magic = int(data.get("base_mag", player.base_magic))
	player.base_defense = int(data.get("base_def", player.base_defense))
	player.base_toughness = int(data.get("base_tough", player.base_toughness))
	var sl: Dictionary = data.get("skill_levels", {})
	for id: String in sl.keys():
		skills.skill_levels[id] = int(sl[id])
	var bk: Dictionary = data.get("books", {})
	for id: String in bk.keys():
		var binv: Dictionary = {}
		for tier_str: String in bk[id].keys():
			binv[int(tier_str)] = int(bk[id][tier_str])
		skills.books[id] = binv
	kills = int(data.get("kills", 0))
	boss_defeated = bool(data.get("boss_defeated", false))
	play_seconds = float(data.get("play_seconds", 0.0))
	boss_records = (data.get("boss_records", []) as Array).duplicate(true)
	dungeon_records = (data.get("dungeon_records", []) as Array).duplicate(true)
	# 升级上限：优先读存档；无则按玩家等级取最近的卡关档（保证已升到的等级不被上限卡住）。
	var cap_default: int = 20
	for g_v: Variant in LEVEL_GATES:
		var g: Dictionary = g_v
		if player.level >= int(g["cap"]):
			cap_default = int(g["next"])
	level_cap = int(data.get("level_cap", cap_default))
	world_level = 1
	shelter_level = int(data.get("shelter_level", 0))
	if shelter_system != null and shelter_system.has_method("apply_level"):
		shelter_system.apply_level(shelter_level)
	if quest_system != null and quest_system.has_method("from_save"):
		quest_system.from_save(data.get("quests", {}))
	if achievement_system != null and achievement_system.has_method("from_save"):
		achievement_system.from_save(data.get("achievements", {}))
	if pet_system != null and pet_system.has_method("from_save"):
		pet_system.from_save(data.get("pets", {}))
	if drone_system != null and drone_system.has_method("from_save"):
		drone_system.from_save(data.get("drones", {}))
	# 背包（2048 装备 + 道具）还原（旧版数组存档不兼容，跳过即可）。
	if data.has("inventory") and data["inventory"] is Dictionary:
		inv.from_save(data["inventory"] as Dictionary)
	unlock_stage = int(data.get("unlock_stage", 0))
	unlocked_world_radius = float(data.get("unlocked_radius", unlocked_world_radius))
	local_player_name = String(data.get("player_name", local_player_name))
	player.recalculate_stats()
	player.hp = clamp(float(data.get("hp", player.max_hp)), 1.0, float(player.max_hp))
	player.mp = clamp(float(data.get("mp", player.max_mp)), 0.0, float(player.max_mp))

func _cleanup_invalid_arrays() -> void:
	monsters = monsters.filter(func(m: Variant) -> bool: return m != null and is_instance_valid(m))
	pickups = pickups.filter(func(p: Variant) -> bool: return p != null and is_instance_valid(p))
