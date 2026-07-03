extends Node

# ServerMain —— 权威世界（场景根 "World"）。负责：读配置、起网络、生成与同步怪物、
# 全局世界解锁、把怪物攻击转成对玩家的伤害事件、定时广播玩家/怪物快照。
# 战斗结算偏信任客户端：客户端上报对怪物造成的伤害，服务器为怪物血量/死亡/重生的唯一权威。

const ServerMonsterScript = preload("res://sim/ServerMonster.gd")
const EQUIP_BASE_COUNT := 8       # 与 client/scripts/systems/EquipmentManager.gd 的 base_items 数量保持一致
const DROP_TTL_MS := 120000       # 掉落物 120 秒无人拾取则自动消失

var rng := RandomNumberGenerator.new()
var monsters: Dictionary = {}          # id -> ServerMonster
var spawners: Array = []               # 运行期刷怪点（含 _timer/_alive）
var next_id: int = 1
var drops: Dictionary = {}              # 共享掉落物：drop_id -> {pos, exp_ms}
var pending_meteors: Array = []         # Boss 冲锋命中后延时落下的缩小天星 [{t,pos,dmg,level,boss_id}]
const MINI_METEOR_R := 3.5
const SUMMON_KINDS := ["wisp", "wolf", "archer", "healer"]   # 空军/步兵/炮兵/奶妈
const MAX_WORLD_MONSTERS := 96
const MAX_SUMMONED_MONSTERS := 24
const SUMMON_TTL := 45.0
const BEAST_TIDE_T := 18.0
const BEAST_TIDE_EMIT := 1.5
const BEAST_TIDE_RANGE := 18.0
const HEAL_INTERVAL := 1.5
const HEAL_R := 10.0
const HEAL_PCT := 0.06
# GM 全局调参
var gm_monster_mult: float = 1.0   # 怪物强度倍率（影响新怪与即时缩放）
var gm_drop_mult: float = 1.0      # 掉落率倍率
# 操作台占用：同一时段仅一个管理员，高等级可硬抢。
var gm_console_user: int = 0
var gm_console_level: int = 0
const GM_EQUIP_TYPES: Array[String] = ["weapon", "offhand", "helmet", "chest", "legs", "boots", "shoulder", "gloves", "belt", "necklace", "ring"]
# 副本：空区域(远处)，按实例隔离同步。
# 副本定义：等级门 + 内部怪物布局（小怪/精英）+ Boss + 隐藏Boss。wl 决定难度/经验。
var DUNGEONS: Array = [
	{"id": 1, "name": "迷雾林窟", "level_req": 5, "wl": 2, "spawn": Vector3(0, 0.5, 4000),
		"mobs": [{"kind": "slime", "n": 6}, {"kind": "wolf", "n": 3, "elite": true}],
		"boss": "boss", "hidden": "boss_storm"},
	{"id": 2, "name": "幽影深渊", "level_req": 15, "wl": 5, "spawn": Vector3(300, 0.5, 4000),
		"mobs": [{"kind": "wolf", "n": 6}, {"kind": "archer", "n": 3, "elite": true}, {"kind": "mage", "n": 2, "elite": true}],
		"boss": "boss_warlord", "hidden": "boss_titan"},
	{"id": 3, "name": "星界王座", "level_req": 25, "wl": 8, "spawn": Vector3(600, 0.5, 4000),
		"mobs": [{"kind": "wisp", "n": 6}, {"kind": "skyseraph", "n": 2, "elite": true}, {"kind": "archer", "n": 3}],
		"boss": "boss_titan", "hidden": "skyseraph"},
	{"id": 4, "name": "星莹矿洞", "level_req": 20, "wl": 6, "spawn": Vector3(900, 0.5, 4000),
		"mobs": [{"kind": "wisp", "n": 6}, {"kind": "mage", "n": 3, "elite": true}, {"kind": "orbdrifter", "n": 2}],
		"boss": "boss_storm", "hidden": "skyseraph"},
]
const DUNGEON_HIDDEN_CHANCE := 0.5    # Boss 被击杀后出现隐藏 Boss 的概率
const DUNGEON_RANGE := 5              # 记录准入范围：[level_req, level_req+5]，越界成员不计记录并衰减掉落
var dungeon_instances: Dictionary = {}  # inst -> {did, enter_ms, members:{pid}, monster_ids:[], boss_mid, hidden_mid, cleared, hidden_done}
var next_drop_id: int = 1

# 区域热更新：被锁定的区域（"cx_cz" 字符串）里玩家被弹出且禁止进入；由 data/region_locks.json 热控制。
const REGION_FILE := "region_locks.json"
var data_dir: String = ""
var region_size: float = 64.0
var region_locks: Array = []
var _region_check_timer: float = 1.0

var map_radius: float = 155.0
var unlocked_radius: float = 58.0
var unlock_stage: int = 0
var kills: int = 0
var boss_defeated: bool = false
var spawn_point: Vector3 = Vector3(0, 0.05, 7.0)
var _last_bcast_radius: float = -999.0

var _player_snap_accum: float = 0.0
var _monster_snap_accum: float = 0.0
var _player_snap_interval: float = 0.05
var _monster_snap_interval: float = 0.083

# AOI 兴趣区：每个客户端只接收其水平半径内的玩家/怪物；迟滞避免边界抖动（进入 R，离开 R+H）。
var _aoi_radius: float = 90.0
var _aoi_hys: float = 12.0

func _ready() -> void:
	rng.randomize()
	var cfg := _load_cfg()
	var port: int = _arg_int("--port", int(cfg.get("port", GameData.proto("default_port", 9000))))
	var max_players: int = int(cfg.get("max_players", GameData.proto("max_players", 64)))
	data_dir = _resolve_data_dir(String(cfg.get("data_dir", "")))
	Accounts.setup(data_dir)
	_apply_fixed_super_admin(String(cfg.get("super_admin_user", "huaqadmin")), String(cfg.get("super_admin_password", "")), int(cfg.get("super_admin_level", 3)))

	Net.world = self
	if not Net.start_server(port, max_players):
		push_error("[Server] 启动失败，退出。")
		get_tree().quit(1)
		return

	_player_snap_interval = 1.0 / maxf(1.0, float(GameData.proto("player_state_hz", 20)))
	_monster_snap_interval = 1.0 / maxf(1.0, float(GameData.proto("monster_snapshot_hz", 12)))
	_aoi_radius = float(GameData.proto("aoi_radius", 90.0))
	_aoi_hys = float(GameData.proto("aoi_hysteresis", 12.0))

	_load_world()
	_spawn_initial_monsters()
	_init_outposts()
	_init_world_nodes()
	_load_world_state()   # 恢复全服建造/加固进度 + 贡献榜 + 节点采集态
	# 服务器管理控制台（窗口模式=2D 面板；无头=HTTP API）。
	var admin_console := preload("res://main/AdminConsole.gd").new()
	admin_console.name = "AdminConsole"
	add_child(admin_console)
	print("[Server] 世界就绪：怪物 %d 只，地图半径 %.0f。等待玩家连接……" % [monsters.size(), map_radius])

# ---------------- 配置 ----------------

func _load_cfg() -> Dictionary:
	var out: Dictionary = {}
	var cf := ConfigFile.new()
	if cf.load("res://server.cfg") == OK:
		for key in ["port", "max_players", "data_dir", "super_admin_user", "super_admin_password", "super_admin_level"]:
			if cf.has_section_key("server", key):
				out[key] = cf.get_value("server", key)
	return out

func _apply_fixed_super_admin(user: String, password: String, level: int) -> void:
	var key: String = user.strip_edges()
	if key == "":
		return
	var lv: int = maxi(1, level)
	if password != "":
		Accounts.ensure_account_password(key, password, key)
	Accounts.set_fixed_admin(key, lv)
	print("[Admin] 固定最高管理员账号: %s = L%d" % [key, lv])

func _resolve_data_dir(configured: String) -> String:
	if configured.strip_edges() != "":
		return ProjectSettings.globalize_path(configured) if configured.begins_with("res://") or configured.begins_with("user://") else configured
	return ProjectSettings.globalize_path("user://data")

func _arg_int(flag: String, fallback: int) -> int:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	var idx: int = args.find(flag)
	if idx >= 0 and idx + 1 < args.size():
		return int(args[idx + 1])
	return fallback

# ---------------- 世界数据 ----------------

func _load_world() -> void:
	var w: Dictionary = GameData.world
	map_radius = float(w.get("map_radius", 155.0))
	unlocked_radius = float(w.get("initial_unlocked_radius", 58.0))
	spawn_point = _to_vec3(w.get("player_spawn", [0, 0.05, 7.0]))
	region_size = float(w.get("region_size", 64.0))

func _to_vec3(arr: Variant) -> Vector3:
	if arr is Array and (arr as Array).size() >= 3:
		var a: Array = arr
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO

func player_spawn() -> Vector3:
	return spawn_point

# ---------------- 刷怪 ----------------

func _spawn_initial_monsters() -> void:
	var specs: Array = GameData.world.get("spawners", [])
	for spec_v: Variant in specs:
		var spec: Dictionary = (spec_v as Dictionary).duplicate(true)
		spec["_timer"] = 0.0
		spec["_alive"] = [] as Array
		spawners.append(spec)
		var initial: int = int(spec.get("max", 4)) / 2 + 1
		for i in range(initial):
			_spawner_spawn_one(spawners.size() - 1)
	var boss: Dictionary = GameData.world.get("boss_spawn", {})
	if not boss.is_empty():
		_spawn_monster(String(boss.get("kind", "boss")), _to_vec3(boss.get("pos", [0, 0, 0])), false, -1)
	_spawn_resident_bosses()

# 常驻 Boss：固定位置、等级恒定、击杀后定时重生（与客户端单机一致）。
const RESIDENT_RESPAWN := 16.0
var resident_specs: Array = []   # [{pos, wl, mid, respawn}]
func _spawn_resident_bosses() -> void:
	var defs: Array = [
		{"pos": Vector3(122, 0.3, 118), "wl": 3, "kind": "boss"},
		{"pos": Vector3(-128, 0.3, 120), "wl": 5, "kind": "boss_storm"},
		{"pos": Vector3(118, 0.3, -130), "wl": 7, "kind": "boss_warlord"},
		{"pos": Vector3(-120, 0.3, -128), "wl": 9, "kind": "boss_titan"},
	]
	for d: Dictionary in defs:
		var spec: Dictionary = {"pos": d["pos"], "wl": int(d["wl"]), "kind": String(d["kind"]), "mid": 0, "respawn": 0.0}
		resident_specs.append(spec)
		_spawn_one_resident(spec)

func _spawn_one_resident(spec: Dictionary) -> void:
	var m: ServerMonsterScript = _spawn_monster(String(spec.get("kind", "boss")), spec["pos"], false, -1, int(spec["wl"]), true)
	m.name = "常驻·" + m.name
	spec["mid"] = m.id
	spec["respawn"] = 0.0

func _update_residents(delta: float) -> void:
	for spec: Dictionary in resident_specs:
		var mid: int = int(spec["mid"])
		var alive: bool = mid != 0 and monsters.has(mid) and not (monsters[mid] as ServerMonsterScript).dead
		if not alive:
			spec["respawn"] = float(spec["respawn"]) - delta
			if float(spec["respawn"]) <= 0.0:
				_spawn_one_resident(spec)

func _live_world_monster_count(include_boss: bool = true) -> int:
	var n: int = 0
	for mid: int in monsters.keys():
		var m: ServerMonsterScript = monsters.get(mid, null)
		if m == null or m.dead or m.inst != 0:
			continue
		if not include_boss and (m.is_boss or m.resident):
			continue
		n += 1
	return n

func _summoned_monster_count() -> int:
	var n: int = 0
	for mid: int in monsters.keys():
		var m: ServerMonsterScript = monsters.get(mid, null)
		if m != null and not m.dead and m.is_summoned:
			n += 1
	return n

func _spawner_spawn_one(spawner_index: int) -> void:
	if _live_world_monster_count(false) >= MAX_WORLD_MONSTERS:
		return
	var spec: Dictionary = spawners[spawner_index]
	var kinds: Array = spec.get("kinds", ["slime"])
	var kind: String = String(kinds[rng.randi_range(0, kinds.size() - 1)])
	var c: Vector3 = _to_vec3(spec.get("pos", [0, 0, 0]))
	var spread: float = float(spec.get("spread", 12.0))
	var pos: Vector3 = c + Vector3(rng.randf_range(-spread, spread), 0.3, rng.randf_range(-spread, spread))
	# 世界等级越高，精英出现率越高（与客户端一致）。
	var elite_chance: float = float(spec.get("elite_chance", 0.0)) + 0.05 * float(_world_level() - 1)
	var make_elite: bool = rng.randf() < elite_chance
	var m: ServerMonsterScript = _spawn_monster(kind, pos, make_elite, spawner_index)
	(spec["_alive"] as Array).append(m)

# 服务器世界等级：无玩家等级可依，按累计击杀作为进度代理（保留兼容，掉落用）。
func _world_level() -> int:
	return clampi(1 + int(kills / 8), 1, 8)

# 与客户端一致的按距离分档区域（强度档位 tier + 怪物等级范围）。
const SRV_REGIONS := [
	{"r": 58.0, "lmin": 1, "lmax": 8, "tier": 1},
	{"r": 95.0, "lmin": 8, "lmax": 16, "tier": 2},
	{"r": 130.0, "lmin": 16, "lmax": 26, "tier": 3},
	{"r": 160.0, "lmin": 26, "lmax": 36, "tier": 5},
	{"r": 99999.0, "lmin": 36, "lmax": 45, "tier": 6},
]
func _pos_region(pos: Vector3) -> Dictionary:
	var d: float = Vector2(pos.x, pos.z).length()
	for rg_v: Variant in SRV_REGIONS:
		var rg: Dictionary = rg_v
		if d <= float(rg["r"]):
			return rg
	return SRV_REGIONS[SRV_REGIONS.size() - 1]

func _spawn_monster(kind: String, pos: Vector3, make_elite: bool, spawner_index: int, wl_override: int = -1, resident: bool = false, inst: int = 0) -> ServerMonsterScript:
	var m: ServerMonsterScript = ServerMonsterScript.new()
	var data: Dictionary = GameData.monster_data(kind).duplicate(true)
	var rg: Dictionary = _pos_region(pos)
	data["world_level"] = wl_override if wl_override >= 0 else int(rg["tier"])   # 强度档位按区域固定
	if bool(data.get("boss", false)):
		data["level"] = int(rg["lmax"]) + 2
	else:
		data["level"] = rng.randi_range(int(rg["lmin"]), int(rg["lmax"]))
	data["resident"] = resident
	# 世界等级提高后，精英有概率获得弱化版究极（服务器权威 roll）。
	if make_elite and int(data["world_level"]) >= 4 and rng.randf() < 0.30:
		data["ultimate"] = rng.randi() % 4
		data["weak_ult"] = true
	m.setup(data, next_id, pos, make_elite, spawner_index)
	m.inst = inst
	# GM 怪物强度倍率作用于新刷怪。
	if gm_monster_mult != 1.0:
		m.max_hp = maxi(1, int(float(m.max_hp) * gm_monster_mult))
		m.hp = float(m.max_hp)
		m.attack = maxi(1, int(float(m.attack) * gm_monster_mult))
	next_id += 1
	monsters[m.id] = m
	return m

func _update_spawners(delta: float) -> void:
	for i in range(spawners.size()):
		var spec: Dictionary = spawners[i]
		var alive: Array = spec["_alive"]
		for j in range(alive.size() - 1, -1, -1):
			var m: ServerMonsterScript = alive[j]
			if m == null or m.dead:
				alive.remove_at(j)
		spec["_timer"] = float(spec["_timer"]) - delta
		if alive.size() < int(spec.get("max", 4)) and float(spec["_timer"]) <= 0.0:
			spec["_timer"] = float(spec.get("respawn", 7.0))
			_spawner_spawn_one(i)

# ---------------- 战斗 / 死亡 ----------------

func apply_monster_damage(mid: int, amount: int, attacker_id: int) -> void:
	var m: ServerMonsterScript = monsters.get(mid, null)
	if m == null or m.dead:
		return
	# 让其他玩家也看到这次伤害飘字（施法者本地已显示，排除之）
	Net.broadcast_monster_damaged(mid, amount, m.pos, attacker_id)
	if m.take_damage(amount, attacker_id):
		_on_monster_died(m)

# Boss 连招 AOE：对范围内玩家与「其他怪物」（友伤）结算伤害；排除 Boss 自身。
func _combo_aoe(boss_id: int, center: Vector3, radius: float, amount: int) -> void:
	for pid: int in Net.authed_ids():
		var pp: Vector3 = Net.players[pid]["pos"]
		if float(Net.players[pid].get("hp", 0.0)) > 0.0 and Vector2(pp.x - center.x, pp.z - center.z).length() <= radius:
			Net.send_hit_player(pid, amount)
	for mid2: int in monsters.keys():
		if mid2 == boss_id:
			continue
		var m2: ServerMonsterScript = monsters.get(mid2, null)
		if m2 == null or m2.dead:
			continue
		if Vector2(m2.pos.x - center.x, m2.pos.z - center.z).length() <= radius:
			apply_monster_damage(mid2, amount, 0)

# Boss 冲锋命中：范围内玩家浮空+即时 0.1s 眩晕（服务器权威），并排程 0.5s 后命中点落缩小天星；其他怪友伤。
func _combo_charge(boss: ServerMonsterScript, center: Vector3, radius: float, amount: int) -> void:
	for pid: int in Net.authed_ids():
		var pp: Vector3 = Net.players[pid]["pos"]
		if float(Net.players[pid].get("hp", 0.0)) > 0.0 and Vector2(pp.x - center.x, pp.z - center.z).length() <= radius:
			Net.send_hit_player(pid, amount)
			Net.send_player_control(pid, center, 3.0, 5.0, 0.1, false, 0.0, 0.0)
			pending_meteors.append({"t": 0.5, "pos": pp, "dmg": int(float(boss.attack + 10) * boss.ult_power), "level": boss.world_level, "boss_id": boss.id})
	for mid2: int in monsters.keys():
		if mid2 == boss.id:
			continue
		var m2: ServerMonsterScript = monsters.get(mid2, null)
		if m2 == null or m2.dead:
			continue
		if Vector2(m2.pos.x - center.x, m2.pos.z - center.z).length() <= radius:
			apply_monster_damage(mid2, amount, 0)

# Boss 召唤军团：身后刷出四类小兵（独立血量/经验/掉落，经 AOI 自动下发），高世界等级偶混 Boss。
func _do_summon(boss_id: int, ev: Dictionary) -> void:
	var behind: Vector3 = ev["behind"]
	var back: Vector3 = ev["back"]
	var wl: int = int(ev["wl"])
	var count: int = int(ev["count"])
	var speed_mul: float = float(ev["speed_mul"])
	var boss_chance: float = float(ev["boss_chance"])
	for kind: String in SUMMON_KINDS:
		for i in range(count):
			if _summoned_monster_count() >= MAX_SUMMONED_MONSTERS:
				continue
			if _live_world_monster_count(false) >= MAX_WORLD_MONSTERS:
				continue
			var spawn_kind: String = kind
			if boss_chance > 0.0 and rng.randf() < boss_chance:
				spawn_kind = "boss"
			var off: Vector3 = back * rng.randf_range(0.0, 4.0) + Vector3(rng.randf_range(-4.0, 4.0), 0.0, rng.randf_range(-4.0, 4.0))
			var pos: Vector3 = behind + off
			pos.y = 0.3
			var m: ServerMonsterScript = _spawn_monster(spawn_kind, pos, false, -1, wl, false)
			m.is_summoned = true
			m.summon_ttl = SUMMON_TTL
			m.speed *= speed_mul
	Net.broadcast_monster_combo(boss_id, {"kind": "summon", "center": ev["center"], "seed": int(ev["seed"])})

func start_beast_tide(owner_id: int, center: Vector3) -> void:
	if not Net.players.has(owner_id):
		return
	var pp: Vector3 = Net.players[owner_id].get("pos", Vector3.ZERO)
	if Vector2(center.x - pp.x, center.z - pp.z).length() > BEAST_TIDE_RANGE:
		var dir := Vector2(center.x - pp.x, center.z - pp.z)
		if dir.length() < 0.1:
			dir = Vector2(0, -1)
		dir = dir.normalized() * BEAST_TIDE_RANGE
		center = Vector3(pp.x + dir.x, pp.y, pp.z + dir.y)
	center.y = 0.3
	beast_tides.append({"center": center, "timer": BEAST_TIDE_T, "emit": 0.0, "trib": false, "owner": owner_id})
	Net.broadcast_system("%s 使用妖兽令展开空间黑洞，妖兽兽潮开始涌出。" % String(Net.players[owner_id].get("name", "有人")))

func _update_beast_tides(delta: float) -> void:
	for i in range(beast_tides.size() - 1, -1, -1):
		var tide: Dictionary = beast_tides[i]
		tide["timer"] = float(tide["timer"]) - delta
		tide["emit"] = float(tide["emit"]) - delta
		var center: Vector3 = tide["center"]
		if not bool(tide.get("trib", false)) and rng.randf() < delta * 0.035:
			tide["trib"] = true
			_combo_aoe(0, center + Vector3(0, 0.6, 0), 8.5, 90 + 18 * _world_level())
			Net.broadcast_system("空间黑洞引发天劫！中心区域遭到雷劫轰击。")
		if float(tide["emit"]) <= 0.0 and float(tide["timer"]) > 0.0:
			tide["emit"] = BEAST_TIDE_EMIT
			_emit_beast_tide(center)
		if float(tide["timer"]) <= 0.0:
			beast_tides.remove_at(i)

func _emit_beast_tide(center: Vector3) -> void:
	if _live_world_monster_count(false) >= MAX_WORLD_MONSTERS:
		return
	var kinds := ["wolf", "wisp", "archer", "mage"]
	for i in range(2):
		if _live_world_monster_count(false) >= MAX_WORLD_MONSTERS or _summoned_monster_count() >= MAX_SUMMONED_MONSTERS:
			return
		var ang: float = rng.randf() * TAU
		var rr: float = rng.randf_range(2.0, 6.0)
		var pos: Vector3 = center + Vector3(cos(ang) * rr, 0.0, sin(ang) * rr)
		pos.y = 0.3
		var m: ServerMonsterScript = _spawn_monster(kinds[rng.randi_range(0, kinds.size() - 1)], pos, rng.randf() < 0.12, -1, _world_level(), false)
		m.is_summoned = true
		m.summon_ttl = SUMMON_TTL

# 奶妈：贴近最近友军移动 + 周期治疗范围内怪物（封顶）+ 加速光环；治疗光环广播给可见者。
func _update_healer(h: ServerMonsterScript, delta: float) -> void:
	if h.dead:
		return
	# 移动：靠近最近的非奶妈友军。
	var ally: ServerMonsterScript = null
	var bd: float = INF
	for mid2: int in monsters.keys():
		var m2: ServerMonsterScript = monsters[mid2]
		if m2 == null or m2.dead or m2 == h or m2.is_healer:
			continue
		var d: float = Vector2(m2.pos.x - h.pos.x, m2.pos.z - h.pos.z).length()
		if d < bd:
			bd = d
			ally = m2
	if ally != null and bd > 4.0:
		var dir := Vector2(ally.pos.x - h.pos.x, ally.pos.z - h.pos.z).normalized()
		h.pos.x += dir.x * h.speed * delta
		h.pos.z += dir.y * h.speed * delta
	# 治疗 + 加速光环（节流）。
	h.heal_timer = max(0.0, h.heal_timer - delta)
	if h.heal_timer <= 0.0:
		h.heal_timer = HEAL_INTERVAL
		for mid2: int in monsters.keys():
			var m2: ServerMonsterScript = monsters[mid2]
			if m2 == null or m2.dead:
				continue
			if Vector2(m2.pos.x - h.pos.x, m2.pos.z - h.pos.z).length() <= HEAL_R:
				m2.hp = min(float(m2.max_hp), m2.hp + float(m2.max_hp) * HEAL_PCT)
				m2.speed_buff_mult = 1.25
				m2.speed_buff_timer = 2.0
		Net.broadcast_monster_combo(h.id, {"kind": "heal_pulse", "center": h.pos, "radius": HEAL_R, "seed": 0})

# 巨兵天罚——矩形(沿 dir, 长 len, 宽 width)命中判定。
func _in_beam(p: Vector3, origin: Vector3, dir: Vector3, length: float, width: float) -> bool:
	var v := Vector3(p.x - origin.x, 0, p.z - origin.z)
	var along: float = v.dot(dir)
	if along < 0.0 or along > length:
		return false
	return (v - dir * along).length() <= width * 0.5

func _beam_along(p: Vector3, origin: Vector3, dir: Vector3) -> float:
	return Vector3(p.x - origin.x, 0, p.z - origin.z).dot(dir)

# 砸落：矩形内玩家+其他怪 伤害 + 击飞。
func _giant_slam(boss_id: int, origin: Vector3, dir: Vector3, length: float, width: float, amount: int) -> void:
	for pid: int in Net.authed_ids():
		var pp: Vector3 = Net.players[pid]["pos"]
		if float(Net.players[pid].get("hp", 0.0)) > 0.0 and _in_beam(pp, origin, dir, length, width):
			Net.send_hit_player(pid, amount)
			Net.send_player_control(pid, pp - dir, 4.0, 6.0, 0.0, false, 0.0, 0.0)
	for mid2: int in monsters.keys():
		if mid2 == boss_id:
			continue
		var m2: ServerMonsterScript = monsters.get(mid2, null)
		if m2 == null or m2.dead:
			continue
		if _in_beam(m2.pos, origin, dir, length, width):
			apply_monster_damage(mid2, amount, 0)

# 激光每跳：矩形内目标按沿向排序贯穿衰减（玩家+其他怪）。
func _giant_beam(boss_id: int, origin: Vector3, dir: Vector3, length: float, width: float, base: int) -> void:
	var targets: Array = []   # [{kind, id, along}]
	for pid: int in Net.authed_ids():
		var pp: Vector3 = Net.players[pid]["pos"]
		if float(Net.players[pid].get("hp", 0.0)) > 0.0 and _in_beam(pp, origin, dir, length, width):
			targets.append({"player": pid, "along": _beam_along(pp, origin, dir)})
	for mid2: int in monsters.keys():
		if mid2 == boss_id:
			continue
		var m2: ServerMonsterScript = monsters.get(mid2, null)
		if m2 == null or m2.dead:
			continue
		if _in_beam(m2.pos, origin, dir, length, width):
			targets.append({"monster": mid2, "along": _beam_along(m2.pos, origin, dir)})
	targets.sort_custom(func(a, b): return float(a["along"]) < float(b["along"]))
	for i in range(targets.size()):
		var dmg: int = int(maxf(float(base) * 0.3, float(base) * pow(0.8, float(i))))
		var t: Dictionary = targets[i]
		if t.has("player"):
			Net.send_hit_player(int(t["player"]), dmg)
		else:
			apply_monster_damage(int(t["monster"]), dmg, 0)

# 雷霆引导完成：对范围内（仍带标记）玩家锁定雷击 + 减速（服务器权威）。
func _lightning_strike(boss_id: int, center: Vector3, radius: float, amount: int, slow: float, slow_dur: float) -> void:
	for pid: int in Net.authed_ids():
		var pp: Vector3 = Net.players[pid]["pos"]
		if float(Net.players[pid].get("hp", 0.0)) > 0.0 and Vector2(pp.x - center.x, pp.z - center.z).length() <= radius:
			Net.send_hit_player(pid, amount)
			Net.send_player_control(pid, center, 0.0, 0.0, 0.0, false, slow, slow_dur)

func _update_pending_meteors(delta: float) -> void:
	for i in range(pending_meteors.size() - 1, -1, -1):
		var pm: Dictionary = pending_meteors[i]
		pm["t"] = float(pm["t"]) - delta
		if float(pm["t"]) <= 0.0:
			pending_meteors.remove_at(i)
			_fire_mini_meteor(pm)

# 缩小天星落地：范围内玩家伤害+浮空+落地眩晕(0.1+0.05×等级)，其他怪友伤；向可见客户端广播表现。
func _fire_mini_meteor(pm: Dictionary) -> void:
	var center: Vector3 = pm["pos"]
	var dmg: int = int(pm["dmg"])
	var level: int = int(pm["level"])
	var boss_id: int = int(pm["boss_id"])
	var stun: float = 0.1 + 0.05 * float(level)
	for pid: int in Net.authed_ids():
		var pp: Vector3 = Net.players[pid]["pos"]
		if float(Net.players[pid].get("hp", 0.0)) > 0.0 and Vector2(pp.x - center.x, pp.z - center.z).length() <= MINI_METEOR_R:
			Net.send_hit_player(pid, dmg)
			Net.send_player_control(pid, center, 4.0, 5.2, stun, true, 0.0, 0.0)
	for mid2: int in monsters.keys():
		if mid2 == boss_id:
			continue
		var m2: ServerMonsterScript = monsters.get(mid2, null)
		if m2 == null or m2.dead:
			continue
		if Vector2(m2.pos.x - center.x, m2.pos.z - center.z).length() <= MINI_METEOR_R:
			apply_monster_damage(mid2, dmg, 0)
	Net.broadcast_monster_combo(boss_id, {"kind": "mini_meteor", "center": center, "seed": randi()})

# ---------------- 管理员（GM）执行 ----------------
func admin_action(action: String, args: Dictionary, _lvl: int, by_id: int) -> void:
	match action:
		"console_open":
			if gm_console_user == 0 or gm_console_user == by_id:
				gm_console_user = by_id
				gm_console_level = _lvl
				Net.send_console(by_id, "grant", "")
			elif _lvl > gm_console_level:
				# 高权限硬抢：踢掉当前占用者。
				Net.send_console(gm_console_user, "kicked", Net.player_name(by_id))
				gm_console_user = by_id
				gm_console_level = _lvl
				Net.send_console(by_id, "grant", "")
			else:
				Net.send_console(by_id, "deny", Net.player_name(gm_console_user))
			return
		"console_close":
			if gm_console_user == by_id:
				gm_console_user = 0
				gm_console_level = 0
			return
		"player_list":
			if Net.has_method("send_admin_players"):
				Net.send_admin_players(by_id, _gm_player_list())
			return
		"set_player":
			_gm_set_player(args, _lvl, by_id)
			return
		"player_effect":
			_gm_player_effect(args, _lvl, by_id)
			return
		"kill_area":
			var center: Vector3 = args.get("center", Vector3.ZERO)
			var radius: float = float(args.get("radius", 14.0))
			var n: int = 0
			for mid: int in monsters.keys():
				var m: ServerMonsterScript = monsters.get(mid, null)
				if m == null or m.dead:
					continue
				if Vector2(m.pos.x - center.x, m.pos.z - center.z).length() <= radius:
					_on_monster_died(m)
					n += 1
			_gm_echo(by_id, "已抹杀附近 %d 只怪物。" % n)
		"reset_monsters":
			for mid: int in monsters.keys():
				var m: ServerMonsterScript = monsters[mid]
				if m == null or m.dead:
					continue
				m.hp = float(m.max_hp)
				m.pos = m.home_pos
				m.combo_active = false
				m.lightning_active = false
				m.judg_active = false
				m.combo_cd = 8.0
				m.speed_buff_mult = 1.0
				m.speed_buff_timer = 0.0
			_gm_echo(by_id, "已重置所有怪物的位置与状态。")
		"monster_strength":
			var mult: float = clampf(float(args.get("mult", 1.0)), 0.1, 50.0)
			var ratio: float = mult / maxf(0.0001, gm_monster_mult)
			for mid: int in monsters.keys():
				var m: ServerMonsterScript = monsters[mid]
				if m == null or m.dead:
					continue
				m.max_hp = maxi(1, int(float(m.max_hp) * ratio))
				m.hp = clampf(m.hp * ratio, 1.0, float(m.max_hp))
				m.attack = maxi(1, int(float(m.attack) * ratio))
			gm_monster_mult = mult
			_gm_echo(by_id, "怪物强度倍率设为 ×%.2f（已应用到当前怪物及新刷怪）。" % mult)
		"drop_rate":
			gm_drop_mult = clampf(float(args.get("mult", 1.0)), 0.0, 50.0)
			_gm_echo(by_id, "掉落率倍率设为 ×%.2f。" % gm_drop_mult)

func _gm_echo(id: int, text: String) -> void:
	if Net.has_method("send_system"):
		Net.send_system(id, "[GM] " + text)

func _gm_player_list() -> Array:
	var out: Array = []
	var online_by_user: Dictionary = _gm_online_by_user()
	var fallback_id: int = 1
	var users: Array = Accounts.accounts.keys()
	users.sort()
	for user_v: Variant in users:
		var user: String = String(user_v)
		var rec: Dictionary = Accounts.accounts.get(user, {})
		var save: Dictionary = Accounts.load_save(user)
		var eq: Dictionary = _save_equip_info(save)
		var peer_id: int = int(online_by_user.get(user.to_lower(), 0))
		var p: Dictionary = Net.players.get(peer_id, {}) if peer_id != 0 else {}
		if not p.is_empty():
			var live_tier: int = int(p.get("equip_tier", 0))
			if live_tier > 0:
				eq["tier"] = live_tier
				eq["max"] = maxi(int(eq.get("max", 0)), live_tier)
		var ordinal: int = int(rec.get("ordinal", 0))
		if ordinal <= 0:
			ordinal = fallback_id
		fallback_id += 1
		out.append({
			"id": ordinal,
			"peer_id": peer_id,
			"online": peer_id != 0,
			"user": user,
			"name": String(p.get("name", rec.get("name", user)) if not p.is_empty() else rec.get("name", user)),
			"level": int(p.get("level", save.get("level", 1)) if not p.is_empty() else save.get("level", 1)),
			"equip_tier": int(eq.get("tier", 0)),
			"equip_max": int(eq.get("max", 0)),
			"hp": int(round(float(p.get("hp", 0.0)))) if not p.is_empty() else 0,
			"max_hp": int(p.get("max_hp", 0)) if not p.is_empty() else 0,
			"admin_level": int(p.get("admin_level", Accounts.admin_level(user))),
			"instance_id": int(p.get("instance_id", 0)) if not p.is_empty() else 0,
		})
	out.sort_custom(func(a: Variant, b: Variant) -> bool:
		var ad: Dictionary = a as Dictionary
		var bd: Dictionary = b as Dictionary
		if bool(ad.get("online", false)) != bool(bd.get("online", false)):
			return bool(ad.get("online", false))
		return int(ad.get("id", 0)) < int(bd.get("id", 0))
	)
	return out

func _gm_set_player(args: Dictionary, admin_level: int, by_id: int) -> void:
	var user: String = String(args.get("user", "")).strip_edges().to_lower()
	if user == "":
		user = _gm_user_by_id(int(args.get("id", 0)))
	if user == "" or not Accounts.accounts.has(user):
		_gm_echo(by_id, "目标玩家不存在。")
		return
	var tid: int = int(_gm_online_by_user().get(user, 0))
	var p: Dictionary = Net.players.get(tid, {}) if tid != 0 else {}
	var by_user: String = String(Net.players.get(by_id, {}).get("user", "")).to_lower()
	var target_admin: int = int(p.get("admin_level", Accounts.admin_level(user)))
	if target_admin >= admin_level and user != by_user:
		_gm_echo(by_id, "不能调整同级或更高权限的 GM。")
		return
	var save: Dictionary = Accounts.load_save(user)
	var update: Dictionary = {}
	var changed: Array[String] = []
	if args.has("name"):
		var nick: String = String(args.get("name", "")).strip_edges()
		if nick != "":
			var r: Dictionary = Accounts.set_profile(user, nick, "")
			if bool(r.get("ok", false)):
				if not p.is_empty():
					p["name"] = String(r.get("name", nick))
				update["name"] = String(r.get("name", nick))
				changed.append("名字")
	if args.has("level"):
		var lvl: int = clampi(int(args.get("level", int(p.get("level", save.get("level", 1))))), 1, 999)
		if not p.is_empty():
			p["level"] = lvl
		_save_set_level(save, lvl)
		update["level"] = lvl
		changed.append("等级")
	if args.has("equip_tier"):
		var tier: int = clampi(int(args.get("equip_tier", 0)), 0, 60)
		_save_set_equip_tier(save, tier)
		if not p.is_empty():
			p["equip_tier"] = tier
		update["equip_tier"] = tier
		changed.append("装等")
	Accounts.store_save(user, save)
	if tid != 0 and not update.is_empty() and Net.has_method("send_player_admin_update"):
		Net.send_player_admin_update(tid, update)
	if update.has("name") and Net.has_method("broadcast_roster"):
		Net.broadcast_roster()
	if not changed.is_empty():
		_gm_echo(by_id, "已调整 %s：%s。" % [String(update.get("name", p.get("name", user) if not p.is_empty() else user)), "、".join(PackedStringArray(changed))])
		if tid != 0 and tid != by_id:
			_gm_echo(tid, "你的角色信息已被 GM 调整：%s。" % "、".join(PackedStringArray(changed)))
	if Net.has_method("send_admin_players"):
		Net.send_admin_players(by_id, _gm_player_list())

func _gm_player_effect(args: Dictionary, admin_level: int, by_id: int) -> void:
	var target: Dictionary = _gm_target(args, admin_level, by_id)
	if not bool(target.get("ok", false)):
		_gm_echo(by_id, String(target.get("msg", "目标玩家不存在。")))
		return
	var user: String = String(target["user"])
	var tid: int = int(target.get("tid", 0))
	var p: Dictionary = target.get("player", {})
	var save: Dictionary = Accounts.load_save(user)
	var update: Dictionary = {}
	var changed: String = ""
	var persist: bool = false
	match String(args.get("effect", "")):
		"heal":
			save["hp"] = 999999
			save["mp"] = 999999
			if not p.is_empty():
				p["hp"] = float(p.get("max_hp", 1.0))
				p["mp"] = float(p.get("max_mp", 0.0))
			update["heal_full"] = true
			changed = "满状态"
			persist = true
		"level_add":
			var current_level: int = int(p.get("level", save.get("level", 1))) if not p.is_empty() else int(save.get("level", 1))
			var lvl: int = clampi(current_level + int(args.get("delta", 10)), 1, 999)
			_save_set_level(save, lvl)
			if not p.is_empty():
				p["level"] = lvl
			update["level"] = lvl
			changed = "+10级至 Lv.%d" % lvl
			persist = true
		"max_skills":
			_save_max_skills(save)
			update["max_skills"] = true
			changed = "满技能"
			persist = true
		"god_toggle":
			if tid == 0:
				_gm_echo(by_id, "目标离线，不能切换即时无敌。")
				return
			var god_on: bool = not bool(p.get("gm_godmode", false))
			p["gm_godmode"] = god_on
			update["godmode"] = god_on
			changed = "无敌%s" % ("开启" if god_on else "关闭")
		"speed_toggle":
			if tid == 0:
				_gm_echo(by_id, "目标离线，不能切换即时移速。")
				return
			var speed_on: bool = float(p.get("gm_speed_mult", 1.0)) <= 1.01
			p["gm_speed_mult"] = 2.0 if speed_on else 1.0
			update["gm_speed_mult"] = float(p["gm_speed_mult"])
			changed = "移速×2%s" % ("开启" if speed_on else "关闭")
		_:
			_gm_echo(by_id, "未知玩家效果。")
			return
	if persist:
		Accounts.store_save(user, save)
	if tid != 0 and not update.is_empty() and Net.has_method("send_player_admin_update"):
		Net.send_player_admin_update(tid, update)
	_gm_echo(by_id, "已对 %s 应用：%s。" % [String(p.get("name", user) if not p.is_empty() else user), changed])
	if tid != 0 and tid != by_id:
		_gm_echo(tid, "GM 已对你应用：%s。" % changed)
	if Net.has_method("send_admin_players"):
		Net.send_admin_players(by_id, _gm_player_list())

func _gm_target(args: Dictionary, admin_level: int, by_id: int) -> Dictionary:
	var user: String = String(args.get("user", "")).strip_edges().to_lower()
	if user == "":
		user = _gm_user_by_id(int(args.get("id", 0)))
	if user == "" or not Accounts.accounts.has(user):
		return {"ok": false, "msg": "目标玩家不存在。"}
	var tid: int = int(_gm_online_by_user().get(user, 0))
	var p: Dictionary = Net.players.get(tid, {}) if tid != 0 else {}
	var by_user: String = String(Net.players.get(by_id, {}).get("user", "")).to_lower()
	var target_admin: int = int(p.get("admin_level", Accounts.admin_level(user)))
	if target_admin >= admin_level and user != by_user:
		return {"ok": false, "msg": "不能调整同级或更高权限的 GM。"}
	return {"ok": true, "user": user, "tid": tid, "player": p}

func _gm_online_by_user() -> Dictionary:
	var out: Dictionary = {}
	for pid: int in Net.authed_ids():
		var p: Dictionary = Net.players.get(pid, {})
		var user: String = String(p.get("user", "")).to_lower()
		if user != "":
			out[user] = pid
	return out

func _gm_user_by_id(id: int) -> String:
	for user_v: Variant in Accounts.accounts.keys():
		var user: String = String(user_v)
		var rec: Dictionary = Accounts.accounts.get(user, {})
		if int(rec.get("ordinal", 0)) == id:
			return user.to_lower()
	return ""

func _save_equip_info(save: Dictionary) -> Dictionary:
	var inv: Dictionary = save.get("inventory", {}) if save.get("inventory", {}) is Dictionary else {}
	var pages: Dictionary = inv.get("pages", {}) if inv.get("pages", {}) is Dictionary else {}
	var total: int = 0
	var count: int = 0
	var max_tier: int = 0
	for t: String in GM_EQUIP_TYPES:
		var arr: Array = pages.get(t, []) if pages.get(t, []) is Array else []
		var best: int = 0
		for v: Variant in arr:
			best = maxi(best, int(v))
		if best > 0:
			total += best
			count += 1
			max_tier = maxi(max_tier, best)
	return {"tier": int(round(float(total) / float(count))) if count > 0 else 0, "max": max_tier}

func _save_set_level(save: Dictionary, lvl: int) -> void:
	var growth: int = maxi(0, lvl - 1)
	save["level"] = lvl
	save["next_exp"] = _gm_next_exp_for_level(lvl)
	save["exp"] = mini(int(save.get("exp", 0)), maxi(0, int(save["next_exp"]) - 1))
	save["level_cap"] = maxi(int(save.get("level_cap", 20)), lvl)
	save["base_hp"] = 280 + 24 * growth
	save["base_mp"] = 180 + 14 * growth
	save["base_atk"] = 18 + 2 * growth
	save["base_mag"] = 14 + 2 * growth
	save["base_def"] = 3 + growth
	save["base_tough"] = 6 + growth

func _save_max_skills(save: Dictionary) -> void:
	var levels: Dictionary = save.get("skill_levels", {}) if save.get("skill_levels", {}) is Dictionary else {}
	var order: Array = GameData.skills.get("order", [])
	var max_level: int = int(GameData.skills.get("max_level", 5))
	for sid_v: Variant in order:
		levels[String(sid_v)] = max_level
	save["skill_levels"] = levels

func _save_set_equip_tier(save: Dictionary, tier: int) -> void:
	var inv: Dictionary = save.get("inventory", {}) if save.get("inventory", {}) is Dictionary else {}
	var pages: Dictionary = inv.get("pages", {}) if inv.get("pages", {}) is Dictionary else {}
	var caps: Dictionary = inv.get("caps", {}) if inv.get("caps", {}) is Dictionary else {}
	for t: String in GM_EQUIP_TYPES:
		pages[t] = ([tier] if tier > 0 else [])
		caps[t] = maxi(int(caps.get(t, 2)), 2)
	inv["pages"] = pages
	inv["caps"] = caps
	if not inv.has("items"):
		inv["items"] = []
	save["inventory"] = inv

func _gm_next_exp_for_level(lvl: int) -> int:
	var nx: int = 80
	for _i in range(maxi(0, lvl - 1)):
		nx = int(float(nx) * 1.32 + 30.0)
	return nx

# 玩家断线：若占着操作台则释放。
func admin_player_left(id: int) -> void:
	if gm_console_user == id:
		gm_console_user = 0
		gm_console_level = 0

# ---------------- 副本 ----------------
func _dungeon_by_id(id: int) -> Dictionary:
	for d: Dictionary in DUNGEONS:
		if int(d["id"]) == id:
			return d
	return {}

func dungeon_action(action: String, arg: int, pid: int) -> void:
	var p: Dictionary = Net.players.get(pid, {})
	if p.is_empty():
		return
	match action:
		"enter":
			# 仅做准入校验 + 队伍频道告知 + 给队长确认弹窗；真正进入由 enter_confirm 触发。
			if int(p.get("instance_id", 0)) != 0:
				return
			var d: Dictionary = _dungeon_by_id(arg)
			if d.is_empty():
				Net.send_system(pid, "副本不存在。")
				return
			var party_id: int = int(p.get("party_id", 0))
			if party_id != 0 and Net.party_leader(party_id) != pid:
				Net.send_system(pid, "只有队长可以开启副本。")
				return
			if int(p.get("level", 1)) < int(d["level_req"]):
				Net.send_system(pid, "等级不足：开启「%s」需队长 Lv.%d。" % [d["name"], int(d["level_req"])])
				return
			var info: Dictionary = _dungeon_party_info(pid, d)
			var lo: int = int(d["level_req"])
			var hi: int = lo + DUNGEON_RANGE
			var summary: String = "「%s」准入记录范围 Lv.%d–%d。成员：%s。掉落率 ×%d%%%s" % [
				String(d["name"]), lo, hi, "、".join(PackedStringArray(info["names"])),
				int(round(float(info["drop_factor"]) * 100.0)),
				"（全员达标，计入记录）" if bool(info["eligible"]) else "（有成员越界，不计入记录）"]
			if party_id != 0:
				Net.send_party(party_id, "[副本]", summary)
			Net.send_dungeon(pid, "confirm", {"id": int(d["id"]), "name": String(d["name"]),
				"lo": lo, "hi": hi, "drop_pct": int(round(float(info["drop_factor"]) * 100.0)),
				"eligible": bool(info["eligible"]), "summary": summary})
		"enter_confirm":
			if int(p.get("instance_id", 0)) != 0:
				return
			var d2: Dictionary = _dungeon_by_id(arg)
			if d2.is_empty():
				return
			var pid2: int = int(p.get("party_id", 0))
			if pid2 != 0 and Net.party_leader(pid2) != pid:
				return
			if int(p.get("level", 1)) < int(d2["level_req"]):
				return
			var inst: int = (100000 + pid2) if pid2 != 0 else (200000 + pid)
			if not dungeon_instances.has(inst):
				_dungeon_create(inst, d2)
			# 把队长 + 全体在线队员一并拉入同一实例。
			var ids: Array = [pid] if pid2 == 0 else Net.party_members(pid2)
			for mid_v: Variant in ids:
				var mid: int = int(mid_v)
				var mp: Dictionary = Net.players.get(mid, {})
				if mp.is_empty() or not mp.get("authed", false):
					continue
				if int(mp.get("instance_id", 0)) != 0:
					continue
				(dungeon_instances[inst]["members"] as Dictionary)[mid] = true
				mp["instance_id"] = inst
				mp["dungeon_id"] = int(d2["id"])
				mp["dungeon_enter_ms"] = Time.get_ticks_msec()
				mp["pos"] = d2["spawn"]
				(mp["seen_players"] as Dictionary).clear()
				(mp["seen_monsters"] as Dictionary).clear()
				Net.send_dungeon(mid, "enter", {"instance_id": inst, "spawn": d2["spawn"], "name": String(d2["name"]), "dungeon_id": int(d2["id"])})
		"leave", "force_leave":
			_dungeon_leave(pid, action == "force_leave")

func _on_monster_died(m: ServerMonsterScript) -> void:
	monsters.erase(m.id)
	if m.inst != 0:
		_dungeon_on_monster_died(m)        # 副本怪：不计大世界进度
	elif m.resident:
		# 常驻 Boss：安排重生，不计入世界进度。
		for spec: Dictionary in resident_specs:
			if int(spec["mid"]) == m.id:
				spec["mid"] = 0
				spec["respawn"] = RESIDENT_RESPAWN
	elif m.is_boss:
		boss_defeated = true
	else:
		kills += 1
	Net.broadcast_monster_died({
		"id": m.id, "killer": m.last_attacker, "exp": m.exp_reward,
		"pos": m.pos, "boss": m.is_boss, "name": m.name, "rank": m.rank, "elite": m.elite,
		"drops": _dungeon_scale_drops(m, _roll_drops(m)),
	})

func _expire_summoned_monster(m: ServerMonsterScript) -> void:
	monsters.erase(m.id)
	Net.broadcast_monster_died({
		"id": m.id, "killer": 0, "exp": 0,
		"pos": m.pos, "boss": false, "name": m.name, "rank": m.rank, "elite": m.elite,
		"drops": [], "expired": true,
	})

# ---------------- 副本生命周期 ----------------
func _dungeon_create(inst: int, d: Dictionary) -> void:
	var spawn: Vector3 = d["spawn"]
	var wl: int = int(d.get("wl", 3))
	var ids: Array = []
	for grp_v: Variant in d.get("mobs", []):
		var grp: Dictionary = grp_v
		var elite: bool = bool(grp.get("elite", false))
		for i in range(int(grp.get("n", 1))):
			var off := Vector3(rng.randf_range(-16, 16), 0, rng.randf_range(-16, 16))
			ids.append(_spawn_monster(String(grp["kind"]), spawn + off, elite, -1, wl, false, inst).id)
	var boss: ServerMonsterScript = _spawn_monster(String(d["boss"]), spawn + Vector3(0, 0, -12), false, -1, wl + 1, false, inst)
	ids.append(boss.id)
	dungeon_instances[inst] = {"did": int(d["id"]), "enter_ms": Time.get_ticks_msec(), "members": {},
		"monster_ids": ids, "boss_mid": boss.id, "hidden_mid": 0, "cleared": false, "hidden_done": false}

# 统计队伍在准入范围 [lo,hi] 内/外人数，给出名字列表、是否全员达标、掉落率系数。
# 掉落率：每有一名越界成员 ×0.5；全员越界则清零。
func _dungeon_party_info(pid: int, d: Dictionary) -> Dictionary:
	var lo: int = int(d["level_req"])
	var hi: int = lo + DUNGEON_RANGE
	var party_id: int = int(Net.players[pid].get("party_id", 0))
	var ids: Array = [pid] if party_id == 0 else Net.party_members(party_id)
	var names: Array = []
	var out_cnt: int = 0
	var total: int = 0
	for mid_v: Variant in ids:
		var mp: Dictionary = Net.players.get(int(mid_v), {})
		if mp.is_empty() or not mp.get("authed", false):
			continue
		total += 1
		var lv: int = int(mp.get("level", 1))
		var ok: bool = lv >= lo and lv <= hi
		names.append("%s(Lv.%d%s)" % [String(mp.get("name", "")), lv, "" if ok else "✗"])
		if not ok:
			out_cnt += 1
	var factor: float = 0.0 if (total > 0 and out_cnt >= total) else pow(0.5, out_cnt)
	return {"names": names, "out": out_cnt, "total": total, "drop_factor": factor, "eligible": (out_cnt == 0 and total > 0)}

func _dungeon_drop_factor(inst: int) -> float:
	if not dungeon_instances.has(inst):
		return 1.0
	var di: Dictionary = dungeon_instances[inst]
	var d: Dictionary = _dungeon_by_id(int(di["did"]))
	var lo: int = int(d.get("level_req", 1))
	var hi: int = lo + DUNGEON_RANGE
	var out_cnt: int = 0
	var total: int = 0
	for mid_v: Variant in (di["members"] as Dictionary).keys():
		var mp: Dictionary = Net.players.get(int(mid_v), {})
		if mp.is_empty():
			continue
		total += 1
		var lv: int = int(mp.get("level", 1))
		if lv < lo or lv > hi:
			out_cnt += 1
	if total == 0:
		return 1.0
	if out_cnt >= total:
		return 0.0
	return pow(0.5, out_cnt)

# 副本掉落按越界人数衰减（联机权威）。
func _dungeon_scale_drops(m: ServerMonsterScript, drops: Array) -> Array:
	if m.inst == 0:
		return drops
	var f: float = _dungeon_drop_factor(m.inst)
	if f >= 1.0:
		return drops
	if f <= 0.0:
		return []
	var kept: Array = []
	for dd_v: Variant in drops:
		if rng.randf() < f:
			kept.append(dd_v)
	return kept

func _dungeon_leave(pid: int, force: bool) -> void:
	var p: Dictionary = Net.players.get(pid, {})
	if p.is_empty() or int(p.get("instance_id", 0)) == 0:
		return
	var inst: int = int(p["instance_id"])
	var clear: float = float(Time.get_ticks_msec() - int(p.get("dungeon_enter_ms", 0))) / 1000.0
	p["instance_id"] = 0
	p["pos"] = spawn_point
	(p["seen_players"] as Dictionary).clear()
	(p["seen_monsters"] as Dictionary).clear()
	Net.send_dungeon(pid, "leave", {"clear_seconds": snappedf(clear, 0.1), "force": force, "dungeon_id": int(p.get("dungeon_id", 0))})
	_dungeon_member_removed(inst, pid)

# 断线时清理（由 ServerNetwork 调用）。
func dungeon_player_left(pid: int) -> void:
	var p: Dictionary = Net.players.get(pid, {})
	if p.is_empty():
		return
	var inst: int = int(p.get("instance_id", 0))
	if inst != 0:
		_dungeon_member_removed(inst, pid)

func _dungeon_member_removed(inst: int, pid: int) -> void:
	if not dungeon_instances.has(inst):
		return
	var di: Dictionary = dungeon_instances[inst]
	(di["members"] as Dictionary).erase(pid)
	if (di["members"] as Dictionary).is_empty():
		for mid_v: Variant in di["monster_ids"]:
			monsters.erase(int(mid_v))
		dungeon_instances.erase(inst)

func _dungeon_on_monster_died(m: ServerMonsterScript) -> void:
	if not dungeon_instances.has(m.inst):
		return
	var di: Dictionary = dungeon_instances[m.inst]
	(di["monster_ids"] as Array).erase(m.id)
	if m.id == int(di["boss_mid"]) and not bool(di["cleared"]):
		di["cleared"] = true
		_dungeon_clear(m.inst, false)
		# 概率出现隐藏 Boss。
		if not bool(di["hidden_done"]) and rng.randf() < DUNGEON_HIDDEN_CHANCE:
			_dungeon_spawn_hidden(m.inst)
	elif int(di["hidden_mid"]) != 0 and m.id == int(di["hidden_mid"]):
		_dungeon_clear(m.inst, true)

func _dungeon_spawn_hidden(inst: int) -> void:
	var di: Dictionary = dungeon_instances[inst]
	var d: Dictionary = _dungeon_by_id(int(di["did"]))
	var hk: String = String(d.get("hidden", ""))
	if hk == "":
		return
	var hm: ServerMonsterScript = _spawn_monster(hk, d["spawn"] as Vector3 + Vector3(0, 0, -14), false, -1, int(d.get("wl", 3)) + 2, false, inst)
	di["hidden_mid"] = hm.id
	(di["monster_ids"] as Array).append(hm.id)
	for mpid: int in (di["members"] as Dictionary).keys():
		Net.send_system(mpid, "⚠ 隐藏 Boss 现身！击败它解锁隐藏首杀！")

# 通关结算：记录(时长/队伍/成员等级/首杀)，并在全服首杀时公告。准入等级+5 以内才计入记录。
func _dungeon_clear(inst: int, hidden: bool) -> void:
	var di: Dictionary = dungeon_instances[inst]
	var d: Dictionary = _dungeon_by_id(int(di["did"]))
	var lvl_req: int = int(d.get("level_req", 1))
	var lvl_hi: int = lvl_req + DUNGEON_RANGE
	var names: Array = []
	var levels: Array = []
	var eligible: bool = true
	for mpid: int in (di["members"] as Dictionary).keys():
		var pp: Dictionary = Net.players.get(mpid, {})
		if pp.is_empty():
			continue
		names.append(String(pp.get("name", "")))
		var lv: int = int(pp.get("level", 1))
		levels.append(lv)
		if lv < lvl_req or lv > lvl_hi:
			eligible = false   # 只要有一人不在准入范围 [lo,hi]，整队不计入记录
	var secs: float = float(Time.get_ticks_msec() - int(di["enter_ms"])) / 1000.0
	var r: Dictionary = Accounts.record_dungeon_clear(int(di["did"]), hidden, secs, names, levels, eligible)
	var btype: String = "隐藏Boss" if hidden else "Boss"
	for mpid2: int in (di["members"] as Dictionary).keys():
		var extra: String = "" if eligible else "（队伍有人超出准入+5级，不计入记录）"
		Net.send_system(mpid2, "%s首杀达成！副本「%s」用时 %.1f 秒。%s" % [btype, String(d["name"]), secs, extra])
		if not hidden:
			Net.send_dungeon(mpid2, "cleared", {"clear_seconds": snappedf(secs, 0.1)})   # 通关：客户端可无惩罚离开
	if bool(r.get("first", false)):
		Net.broadcast_system("[全服首杀] 第%d区·%s·%s首杀：%s（用时 %.1f 秒，等级 %s）" % [
			int(di["did"]), String(d["name"]), btype, "、".join(PackedStringArray(names)), secs, str(levels)])
	if hidden:
		di["hidden_done"] = true

# 服务器用自身 rng 决定全部掉落（装备 base 索引 / 品阶 / 技能书），各客户端据此生成一致物品。
func _roll_drops(m: ServerMonsterScript) -> Array:
	var out: Array = []
	var base_pos: Vector3 = m.pos + Vector3(0, 0.4, 0)
	var wl: int = _world_level()
	if m.is_boss:
		# Boss（含常驻）：多件普通装备 + 吸血主/副武器(ls) + 补给 + 概率掉「背包扩展卷」。
		var bn: int = maxi(0, int(round(float(2 + int(wl / 2)) * gm_drop_mult)))
		for i in range(bn):
			out.append(_make_drop(base_pos + _scatter(), {"kind": "equipment", "tier": 1 + (wl - 1), "ls": false}))
		out.append(_make_drop(base_pos + _scatter(), {"kind": "equipment", "tier": 1 + (wl - 1), "ls": true}))
		if m.resident:
			out.append(_make_drop(base_pos + _scatter(), {"kind": "equipment", "tier": 1 + (wl - 1), "ls": true}))
		out.append(_make_drop(base_pos + _scatter(), {"kind": "potion", "ptype": "hp"}))
		out.append(_make_drop(base_pos + _scatter(), {"kind": "magnet"}))
		if rng.randf() < minf(0.85, 0.5 + 0.08 * float(wl - 1)):
			out.append(_make_drop(base_pos + _scatter(), {"kind": "scroll"}))
		if rng.randf() < 0.35:
			out.append(_make_drop(base_pos + _scatter(), {"kind": "material", "mat": "防御卷轴", "amount": 1}))
		if rng.randf() < 0.18:
			out.append(_make_drop(base_pos + _scatter(), {"kind": "material", "mat": "妖兽令", "amount": 1}))
	else:
		# 小怪：仅低概率掉「装备(非吸血)」或「药水」（其一）；磁铁极低概率。
		var roll: float = rng.randf()
		var equip_chance: float = minf(0.30, 0.16 + 0.02 * float(wl - 1)) * gm_drop_mult
		var potion_chance: float = minf(0.18, 0.10 + 0.015 * float(wl - 1)) * gm_drop_mult
		if roll < equip_chance:
			out.append(_make_drop(base_pos + _scatter(), {"kind": "equipment", "tier": 1 + (wl - 1), "ls": false}))
		elif roll < equip_chance + potion_chance:
			out.append(_make_drop(base_pos + _scatter(), {"kind": "potion", "ptype": ["hp", "mp", "vit"][rng.randi_range(0, 2)]}))
		if rng.randf() < 0.04:
			out.append(_make_drop(base_pos + _scatter(), {"kind": "magnet"}))
	# 技能书掉落
	var book_chance: float = (1.0 if m.is_boss else (0.7 if m.elite else 0.3)) * gm_drop_mult
	if rng.randf() <= book_chance:
		var order: Array = GameData.skills.get("order", [])
		if order.size() > 0:
			var sid: String = String(order[rng.randi_range(0, order.size() - 1)])
			out.append(_make_drop(base_pos + _scatter(), {"kind": "skillbook", "skill_id": sid, "tier": _roll_book_tier(m.rank, m.is_boss)}))
	return out

func _make_drop(pos: Vector3, desc: Dictionary) -> Dictionary:
	var did: int = next_drop_id
	next_drop_id += 1
	var d: Dictionary = desc.duplicate()
	d["id"] = did
	d["pos"] = pos
	drops[did] = {"pos": pos, "exp_ms": Time.get_ticks_msec() + DROP_TTL_MS}
	return d

func _scatter() -> Vector3:
	return Vector3(rng.randf_range(-0.7, 0.7), 0.0, rng.randf_range(-0.7, 0.7))

func _roll_book_tier(rank: int, is_boss: bool) -> int:
	var max_tier: int = clampi(rank, 1, 5)
	if is_boss:
		return rng.randi_range(3, 5)   # Boss 必掉高阶
	var weights: Array = []
	var total: float = 0.0
	for t in range(1, max_tier + 1):
		var w: float = 1.0 / pow(2.0, float(t - 1))
		weights.append(w)
		total += w
	var r: float = rng.randf() * total
	var acc: float = 0.0
	for t in range(1, max_tier + 1):
		acc += float(weights[t - 1])
		if r <= acc:
			return t
	return max_tier

# 客户端请求拾取：先到先得，成功则广播给所有人移除并把物品归属拾取者。
func handle_pickup(drop_id: int, taker_id: int) -> void:
	if drops.has(drop_id):
		drops.erase(drop_id)
		Net.broadcast_drop_taken(drop_id, taker_id)

# ---------------- 区域热更新 ----------------

func _region_of(p: Vector3) -> String:
	return "%d_%d" % [floori(p.x / region_size), floori(p.z / region_size)]

func is_region_locked(p: Vector3) -> bool:
	return region_locks.has(_region_of(p))

# 弹出落点：玩家所在锁定区域 → 取最靠近世界中心且未锁定、在地图内的相邻区域中心。
func eject_pos(p: Vector3) -> Vector3:
	var cx: int = floori(p.x / region_size)
	var cz: int = floori(p.z / region_size)
	var best: Vector3 = spawn_point
	var best_d: float = INF
	for ox in [-1, 0, 1]:
		for oz in [-1, 0, 1]:
			if ox == 0 and oz == 0:
				continue
			var rid: String = "%d_%d" % [cx + ox, cz + oz]
			if region_locks.has(rid):
				continue
			var c: Vector3 = Vector3((cx + ox + 0.5) * region_size, p.y, (cz + oz + 0.5) * region_size)
			var d: float = Vector2(c.x, c.z).length()
			if d > map_radius - 4.0:
				continue
			if d < best_d:
				best_d = d
				best = c
	return best

func _read_region_file() -> Array:
	var path: String = data_dir.path_join(REGION_FILE)
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	var out: Array = []
	if parsed is Dictionary and (parsed.get("locked", null) is Array):
		for r: Variant in parsed["locked"]:
			out.append(String(r))
	return out

func _sig(a: Array) -> String:
	var c: Array = a.duplicate()
	c.sort()
	return "|".join(c)

func _update_region_locks(delta: float) -> void:
	_region_check_timer -= delta
	if _region_check_timer > 0.0:
		return
	_region_check_timer = 2.0
	var nl: Array = _read_region_file()
	if _sig(nl) == _sig(region_locks):
		return
	region_locks = nl
	print("[Server] 区域锁定更新: %s" % str(region_locks))
	Net.broadcast_region_locks(region_locks)
	# 把当前在锁定区域内的玩家弹出
	for pid: int in Net.authed_ids():
		var p: Dictionary = Net.players[pid]
		if is_region_locked(p["pos"]):
			var safe: Vector3 = eject_pos(p["pos"])
			p["pos"] = safe
			Net.send_force_position(pid, safe)

# ---------------- 世界解锁（全局共享） ----------------

func _update_world_unlock(delta: float) -> void:
	var stages: Array = GameData.world.get("unlock_stages", [])
	var target_stage: int = 0
	var target_radius: float = unlocked_radius
	for s_v: Variant in stages:
		var s: Dictionary = s_v
		var ok := true
		if s.has("kills") and kills < int(s["kills"]):
			ok = false
		if s.has("boss_defeated") and bool(s["boss_defeated"]) and not boss_defeated:
			ok = false
		if ok:
			target_stage = max(target_stage, int(s.get("stage", 0)))
	for s_v: Variant in stages:
		var s: Dictionary = s_v
		if int(s.get("stage", -1)) == target_stage:
			target_radius = float(s.get("radius", unlocked_radius))
	var lerp_speed: float = float(GameData.world.get("unlock_lerp_speed", 42.0))
	var new_radius: float = move_toward(unlocked_radius, target_radius, lerp_speed * delta)
	var changed_stage: bool = target_stage != unlock_stage
	unlock_stage = target_stage
	unlocked_radius = new_radius
	# 阶段变化立即广播；半径渐变则按步长节流（避免每帧可靠 RPC 刷屏），到达目标时补一次。
	if changed_stage or absf(unlocked_radius - _last_bcast_radius) >= 1.0 or is_equal_approx(unlocked_radius, target_radius):
		if changed_stage or absf(unlocked_radius - _last_bcast_radius) >= 0.5:
			_last_bcast_radius = unlocked_radius
			Net.broadcast_world_unlock(unlock_stage, unlocked_radius)

# 新玩家加入时下发世界状态（解锁/区域锁）。怪物不再一次性全量下发——改由 AOI 兴趣区
# 按玩家位置流式进入（见 _aoi_monsters）。
func send_world_to(id: int) -> void:
	Net.send_world_unlock_to(id, unlock_stage, unlocked_radius)
	Net.send_region_locks_to(id, region_locks)

# ================= 安全区 / 攻城（服务器权威，与客户端 OutpostSystem 几何一致）=================
# half=半边长（新手村大、其余小）。4 面各中央留门 → 8 段墙。
const OP_DEFS := [
	{"id": 0, "name": "新手村", "center": Vector3(0, 0, 20), "half": 28.0, "level": 1},
	{"id": 1, "name": "西境壁垒", "center": Vector3(-56, 0, -30), "half": 12.0, "level": 2},
	{"id": 2, "name": "东岭关城", "center": Vector3(58, 0, -16), "half": 12.0, "level": 3},
]
const OP_GATE_HALF := 4.0          # 门洞半宽（开口 = 8）
const OP_SEG_HP_BASE := 2000.0     # 城墙血量（高强度）
const OP_SEG_DEF := 15             # 城墙防御（每级）
const SIEGE_HOUR := 20
const DEF_SCROLL_COST := 3
var server_outposts: Array = []
var siege_units: Array = []            # [{mid, op, seg}]
var beast_tides: Array = []            # [{center,timer,emit,trib,owner}]
var _last_siege_day: String = ""
var _siege_sync_t: float = 0.0

# 8 段墙（4 面 × 2 半，中央留门）。每段带拦截屏障（axis 法向、line 墙线、lo/hi 沿墙跨度）。
func _op_segments(center: Vector3, half: float) -> Array:
	var c: Vector3 = center
	var g: float = OP_GATE_HALF
	var m: float = (half + g) * 0.5    # 半墙中心相对边中心的偏移
	return [
		{"axis": "z", "line": c.z - half, "lo": c.x - half, "hi": c.x - g},   # 北-左
		{"axis": "z", "line": c.z - half, "lo": c.x + g, "hi": c.x + half},   # 北-右
		{"axis": "z", "line": c.z + half, "lo": c.x - half, "hi": c.x - g},   # 南-左
		{"axis": "z", "line": c.z + half, "lo": c.x + g, "hi": c.x + half},   # 南-右
		{"axis": "x", "line": c.x - half, "lo": c.z - half, "hi": c.z - g},   # 西-下
		{"axis": "x", "line": c.x - half, "lo": c.z + g, "hi": c.z + half},   # 西-上
		{"axis": "x", "line": c.x + half, "lo": c.z - half, "hi": c.z - g},   # 东-下
		{"axis": "x", "line": c.x + half, "lo": c.z + g, "hi": c.z + half},   # 东-上
	]

func _init_outposts() -> void:
	for d_v: Variant in OP_DEFS:
		var d: Dictionary = d_v
		var lvl: int = int(d["level"])
		var half: float = float(d["half"])
		var segs: Array = []
		var si: int = 0
		for sd_v: Variant in _op_segments(d["center"], half):
			var sd: Dictionary = sd_v
			segs.append({"id": si, "axis": sd["axis"], "line": float(sd["line"]), "lo": float(sd["lo"]), "hi": float(sd["hi"]),
				"pos": Vector3((sd["lo"] + sd["hi"]) * 0.5 if sd["axis"] == "z" else sd["line"], 2.0, sd["line"] if sd["axis"] == "z" else (sd["lo"] + sd["hi"]) * 0.5),
				"hp": OP_SEG_HP_BASE * float(lvl), "max_hp": OP_SEG_HP_BASE * float(lvl), "defense": OP_SEG_DEF * lvl, "breached": false})
			si += 1
		server_outposts.append({"id": int(d["id"]), "center": d["center"] as Vector3, "half": half,
			"level": lvl, "name": String(d["name"]), "breached": 0, "build_points": 0,
			"reinforce": 0, "defense_scrolls": 0, "segs": segs})

# 完好城墙拦截地面怪：跨越墙线则回退该轴（空中怪/已破损段除外）。
func _wall_block(m: ServerMonsterScript, old_pos: Vector3) -> void:
	if m.flying:
		return   # 空中怪不受城墙阻挡（可越墙）
	for op_v: Variant in server_outposts:
		var op: Dictionary = op_v
		if (Vector2(m.pos.x - (op["center"] as Vector3).x, m.pos.z - (op["center"] as Vector3).z)).length() > float(op["half"]) + 6.0:
			continue
		for seg_v: Variant in op["segs"]:
			var seg: Dictionary = seg_v
			if bool(seg["breached"]):
				continue
			var line: float = float(seg["line"])
			var old_v: float
			var new_v: float
			var perp: float
			if String(seg["axis"]) == "z":
				old_v = old_pos.z; new_v = m.pos.z; perp = m.pos.x
			else:
				old_v = old_pos.x; new_v = m.pos.x; perp = m.pos.z
			# 跨越了墙线且落在墙跨度内（含身位余量）→ 挡回。
			if (old_v - line) * (new_v - line) < 0.0 and perp >= float(seg["lo"]) - 0.8 and perp <= float(seg["hi"]) + 0.8:
				if String(seg["axis"]) == "z":
					m.pos.z = old_v
				else:
					m.pos.x = old_v
				return

func _outpost_safe(pos: Vector3) -> bool:
	for op_v: Variant in server_outposts:
		var op: Dictionary = op_v
		var c: Vector3 = op["center"]
		var h: float = float(op["half"])
		if int(op["breached"]) == 0 and absf(pos.x - c.x) <= h and absf(pos.z - c.z) <= h:
			return true
	return false

func _outpost_state() -> Array:
	var out: Array = []
	for op_v: Variant in server_outposts:
		var op: Dictionary = op_v
		var segs: Array = []
		for seg_v: Variant in op["segs"]:
			var seg: Dictionary = seg_v
			segs.append({"id": int(seg["id"]), "hp": int(seg["hp"]), "max": int(seg["max_hp"]), "breached": bool(seg["breached"])})
		out.append({"op": int(op["id"]), "segs": segs, "build_points": int(op.get("build_points", 0)),
			"reinforce": int(op.get("reinforce", 0)), "defense_scrolls": int(op.get("defense_scrolls", 0))})
	return out

func send_outposts_to(id: int) -> void:
	Net.send_outpost_state_to(id, _outpost_state())

func _broadcast_outposts() -> void:
	Net.broadcast_outpost_state(_outpost_state())

func _update_siege(delta: float) -> void:
	if server_outposts.is_empty():
		return
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var day_key: String = "%04d-%02d-%02d" % [int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0))]
	if int(dt.get("hour", -1)) == SIEGE_HOUR and _last_siege_day != day_key:
		_last_siege_day = day_key
		_try_daily_siege()
	# 清理死亡攻城怪
	for i in range(siege_units.size() - 1, -1, -1):
		if not monsters.has(int((siege_units[i] as Dictionary)["mid"])):
			siege_units.remove_at(i)
	var changed: bool = false
	for op_v: Variant in server_outposts:
		var op: Dictionary = op_v
		for seg_v: Variant in op["segs"]:
			var seg: Dictionary = seg_v
			if bool(seg["breached"]):
				continue
			var dps: float = 0.0
			for u_v: Variant in siege_units:
				var u: Dictionary = u_v
				if int(u["op"]) != int(op["id"]) or int(u["seg"]) != int(seg["id"]):
					continue
				var m: ServerMonsterScript = monsters.get(int(u["mid"]), null)
				if m != null and m.pos.distance_to(seg["pos"] as Vector3) < 16.0:
					dps += maxf(2.0, float(m.attack) - float(seg["defense"]))
			if dps > 0.0:
				seg["hp"] = float(seg["hp"]) - dps * delta
				changed = true
				if float(seg["hp"]) <= 0.0:
					_breach_seg(op, seg)
	_siege_sync_t -= delta
	if changed and _siege_sync_t <= 0.0:
		_siege_sync_t = 1.0
		_broadcast_outposts()

func _pick_siege_outpost() -> Dictionary:
	if Net.authed_ids().is_empty():
		return {}
	var op: Dictionary = {}
	var bd: float = 1.0e9
	for op_v: Variant in server_outposts:
		var o: Dictionary = op_v
		for pid: int in Net.authed_ids():
			var d: float = (Net.players[pid].get("pos", Vector3.ZERO) as Vector3).distance_to(o["center"] as Vector3)
			if d < bd:
				bd = d; op = o
	return op

func _try_daily_siege() -> void:
	var op: Dictionary = _pick_siege_outpost()
	if op.is_empty():
		return
	if int(op.get("defense_scrolls", 0)) >= DEF_SCROLL_COST:
		op["defense_scrolls"] = int(op.get("defense_scrolls", 0)) - DEF_SCROLL_COST
		Net.broadcast_system("据点「%s」消耗防御卷轴×%d，已抵御今晚 20:00 的怪物攻城。本次无击杀奖励。" % [String(op["name"]), DEF_SCROLL_COST])
		_broadcast_outposts()
		_save_world_state()
		return
	_spawn_siege_wave(op)

func _spawn_siege_wave(op: Dictionary = {}) -> void:
	if op.is_empty():
		op = _pick_siege_outpost()
	if op.is_empty():
		return
	var seg: Dictionary = (op["segs"] as Array)[randi() % (op["segs"] as Array).size()]   # 随机一段墙攻打
	var lvl: int = int(op["level"])
	var n: int = 6 + lvl * 2
	var outward: Vector3 = (seg["pos"] as Vector3) - (op["center"] as Vector3)
	outward.y = 0.0
	outward = outward.normalized() if outward.length() > 0.1 else Vector3(0, 0, -1)
	var side: Vector3 = Vector3(-outward.z, 0, outward.x)
	var kinds := ["wolf", "slime", "archer", "mage"]
	for i in range(n):
		if _live_world_monster_count(false) >= MAX_WORLD_MONSTERS:
			break
		var pos: Vector3 = (seg["pos"] as Vector3) + outward * randf_range(4.0, 9.0) + side * randf_range(-8.0, 8.0)
		pos.y = 0.0
		var mon: ServerMonsterScript = _spawn_monster(kinds[randi() % kinds.size()], pos, false, -1, maxi(1, lvl + 1))
		siege_units.append({"mid": mon.id, "op": int(op["id"]), "seg": int(seg["id"])})
	Net.broadcast_system("⚔ 集群攻城！怪物正在猛攻「%s」，守住城墙！" % String(op["name"]))

func _breach_seg(op: Dictionary, seg: Dictionary) -> void:
	if bool(seg["breached"]):
		return
	seg["breached"] = true
	seg["hp"] = 0.0
	op["breached"] = int(op["breached"]) + 1
	Net.broadcast_system("💥「%s」的城墙被攻破！走到缺口按 E 重建。" % String(op["name"]))
	_broadcast_outposts()

func rebuild_wall(op_id: int, seg_id: int, pid: int) -> void:
	if op_id < 0 or op_id >= server_outposts.size():
		return
	var op: Dictionary = server_outposts[op_id]
	if seg_id < 0 or seg_id >= (op["segs"] as Array).size():
		return
	var seg: Dictionary = (op["segs"] as Array)[seg_id]
	if not bool(seg["breached"]):
		return
	# 校验玩家确实在缺口附近，防作弊。
	var ppos: Vector3 = Net.players.get(pid, {}).get("pos", Vector3(9999, 0, 9999))
	if ppos.distance_to(seg["pos"] as Vector3) > 7.0:
		return
	seg["breached"] = false
	seg["hp"] = float(seg["max_hp"])
	op["breached"] = maxi(0, int(op["breached"]) - 1)
	Net.broadcast_system("🧱「%s」的城墙已重建，安全恢复。" % String(op["name"]))
	_broadcast_outposts()

# ================= 全服共享材料节点（先到先得，采集后定时重生）=================
var world_nodes: Dictionary = {}        # id -> {id, pos, mat}
var _node_respawn: Dictionary = {}      # id -> {pos, mat, at(unix秒)}
var _next_node_id: int = 1
var _world_dirty: bool = false          # 世界状态待落盘（节点采集态）
var _world_save_t: float = 0.0
const NODE_RESPAWN_SEC := 30
const WORLD_SAVE_INTERVAL := 10.0

func _now_sec() -> int:
	return int(Time.get_unix_time_from_system())

func _init_world_nodes() -> void:
	var rng2 := RandomNumberGenerator.new(); rng2.seed = 909
	for ring: float in [70.0, 110.0, 148.0]:
		for i in range(6):
			var a: float = TAU * float(i) / 6.0 + rng2.randf_range(-0.3, 0.3)
			var r: float = ring + rng2.randf_range(-12.0, 12.0)
			var sp := Vector3(cos(a) * r, 0.3, sin(a) * r)
			var mat: String = "星莹水晶" if Vector2(sp.x, sp.z).length() > 100.0 else "寒霜晶矿"
			world_nodes[_next_node_id] = {"id": _next_node_id, "pos": sp, "mat": mat}
			_next_node_id += 1

func _world_nodes_array() -> Array:
	var out: Array = []
	for nid: int in world_nodes.keys():
		var nd: Dictionary = world_nodes[nid]
		out.append({"id": int(nd["id"]), "pos": nd["pos"], "mat": String(nd["mat"])})
	return out

func send_world_nodes_to(id: int) -> void:
	Net.send_world_nodes_to(id, _world_nodes_array())

func _ore_chunk_amount() -> int:
	var r: float = rng.randf()
	if r < 0.20:
		return 1
	if r < 0.80:
		return 2
	return 3

func gather_node(node_id: int, pid: int) -> void:
	if not world_nodes.has(node_id):
		return
	var nd: Dictionary = world_nodes[node_id]
	var ppos: Vector3 = Net.players.get(pid, {}).get("pos", Vector3(9999, 0, 9999))
	if ppos.distance_to(nd["pos"] as Vector3) > 5.5:
		return   # 防作弊
	var mat: String = String(nd["mat"])
	_node_respawn[node_id] = {"pos": nd["pos"], "mat": mat, "at": _now_sec() + NODE_RESPAWN_SEC}
	world_nodes.erase(node_id)
	_world_dirty = true
	Net.send_gather_result(pid, mat, _ore_chunk_amount())
	Net.broadcast_world_nodes(_world_nodes_array())

func _update_world_nodes(delta: float) -> void:
	_check_period_rollover()   # 周界到了就结算发奖(int 比较,开销可忽略)
	if not _node_respawn.is_empty():
		var now: int = _now_sec()
		var changed: bool = false
		for nid: int in _node_respawn.keys():
			if now >= int((_node_respawn[nid] as Dictionary)["at"]):
				var rd: Dictionary = _node_respawn[nid]
				world_nodes[nid] = {"id": nid, "pos": rd["pos"], "mat": rd["mat"]}
				_node_respawn.erase(nid)
				changed = true
		if changed:
			_world_dirty = true
			Net.broadcast_world_nodes(_world_nodes_array())
	if _world_dirty:
		_world_save_t += delta
		if _world_save_t >= WORLD_SAVE_INTERVAL:
			_world_save_t = 0.0
			_save_world_state()

# ================= 全服建造贡献榜（每周结算发奖）=================
var outpost_contrib: Dictionary = {}    # user(小写) -> {name, points}  当期(本周)
var contrib_period: int = -1            # 当前周期(自纪元的周序号)
var pending_rewards: Dictionary = {}    # user(小写) -> [{mat, amount}]  离线也能领,登录发放
const PERIOD_SEC := 604800              # 一周
# 每周榜奖励(名次 → 物品),points>0 才有资格。
const REWARD_RANK1 := [["星莹水晶", 25], ["宠物蛋", 5], ["宠物技能书", 3]]
const REWARD_RANK23 := [["星莹水晶", 15], ["宠物蛋", 3], ["宠物技能书", 1]]
const REWARD_RANK410 := [["星莹水晶", 8], ["宠物蛋", 1]]

func _current_period() -> int:
	return int(_now_sec() / PERIOD_SEC)

func _reward_for_rank(rank: int) -> Array:
	if rank == 1: return REWARD_RANK1
	if rank <= 3: return REWARD_RANK23
	if rank <= 10: return REWARD_RANK410
	return []

# 周期结算:给上期 Top 玩家发奖(入 pending),清空当期,推进周期。
func _do_period_rollover(new_period: int) -> void:
	var entries: Array = []
	for u: String in outpost_contrib.keys():
		var rec: Dictionary = outpost_contrib[u]
		if int(rec["points"]) > 0:
			entries.append({"user": u, "name": String(rec["name"]), "points": int(rec["points"])})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["points"]) > int(b["points"]))
	var rank: int = 1
	var winners: Array = []
	for e_v: Variant in entries:
		var e: Dictionary = e_v
		var reward: Array = _reward_for_rank(rank)
		if reward.is_empty():
			break
		var uw: String = String(e["user"])
		var items: Array = pending_rewards.get(uw, [])
		for r_v: Variant in reward:
			var r: Array = r_v
			items.append({"mat": String(r[0]), "amount": int(r[1])})
		pending_rewards[uw] = items
		winners.append("%d.%s" % [rank, String(e["name"])])
		rank += 1
	if not winners.is_empty():
		Net.broadcast_system("🏆 建造贡献周榜结算！上榜:%s。奖励已发放,登录自动领取。" % "、".join(PackedStringArray(winners)))
	outpost_contrib = {}
	contrib_period = new_period
	_save_world_state()

func _check_period_rollover() -> void:
	var cur: int = _current_period()
	if contrib_period < 0:
		contrib_period = cur
		return
	if cur != contrib_period:
		_do_period_rollover(cur)

# 登录时取走某账号的待发奖励(发放后清空并落盘)。
func take_pending_rewards(user: String) -> Array:
	var uw: String = user.to_lower()
	if not pending_rewards.has(uw):
		return []
	var items: Array = pending_rewards[uw]
	pending_rewards.erase(uw)
	_save_world_state()
	return items

func _add_contrib(pid: int, pts: int) -> void:
	var user: String = String(Net.players.get(pid, {}).get("user", "")).to_lower()
	if user == "":
		return
	var name: String = String(Net.players.get(pid, {}).get("name", user))
	if not outpost_contrib.has(user):
		outpost_contrib[user] = {"name": name, "points": 0}
	outpost_contrib[user]["name"] = name
	outpost_contrib[user]["points"] = int(outpost_contrib[user]["points"]) + pts

func leaderboard_array() -> Dictionary:
	var arr: Array = []
	var total: int = 0
	for user: String in outpost_contrib.keys():
		var rec: Dictionary = outpost_contrib[user]
		total += int(rec["points"])
		arr.append({"name": String(rec["name"]), "points": int(rec["points"])})
	arr.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["points"]) > int(b["points"]))
	if arr.size() > 10:
		arr = arr.slice(0, 10)
	var ends_in: int = (_current_period() + 1) * PERIOD_SEC - _now_sec()
	return {"total": total, "top": arr, "ends_in": ends_in}

func send_leaderboard_to(id: int) -> void:
	Net.send_leaderboard(id, leaderboard_array())

# 玩家向据点捐献材料 → 建造点数;先补破损墙,再加固(全服共享)。
func deposit_material(op_id: int, mat: String, amount: int, pid: int) -> void:
	if op_id < 0 or op_id >= server_outposts.size() or amount <= 0:
		return
	var op: Dictionary = server_outposts[op_id]
	if mat == "防御卷轴":
		op["defense_scrolls"] = int(op.get("defense_scrolls", 0)) + amount
		var scroll_pn: String = String(Net.players.get(pid, {}).get("name", "有人"))
		Net.broadcast_system("%s 向「%s」补充防御卷轴×%d（库存 %d）。" % [scroll_pn, String(op["name"]), amount, int(op["defense_scrolls"])])
		_broadcast_outposts()
		_save_world_state()
		return
	var pts: int = amount * (3 if mat == "星莹水晶" else 1)
	op["build_points"] = int(op.get("build_points", 0)) + pts
	_add_contrib(pid, pts)
	var rebuilt: int = 0
	for seg_v: Variant in op["segs"]:
		var seg: Dictionary = seg_v
		if bool(seg["breached"]) and int(op["build_points"]) >= 20:
			op["build_points"] = int(op["build_points"]) - 20
			seg["breached"] = false; seg["hp"] = float(seg["max_hp"])
			op["breached"] = maxi(0, int(op["breached"]) - 1)
			rebuilt += 1
	while int(op["build_points"]) >= 120:
		op["build_points"] = int(op["build_points"]) - 120
		op["reinforce"] = int(op.get("reinforce", 0)) + 1
		for seg_v2: Variant in op["segs"]:
			var seg2: Dictionary = seg_v2
			seg2["max_hp"] = float(seg2["max_hp"]) * 1.3
			seg2["hp"] = float(seg2["max_hp"])
		Net.broadcast_system("🏰「%s」城墙加固至 +%d！全服更坚固。" % [String(op["name"]), int(op["reinforce"])])
	var pn: String = String(Net.players.get(pid, {}).get("name", "有人"))
	Net.broadcast_system("🧱 %s 向「%s」捐献 %s×%d（建造点 %d）%s" % [pn, String(op["name"]), mat, amount, int(op["build_points"]), ("，重建 %d 段" % rebuilt if rebuilt > 0 else "")])
	_broadcast_outposts()
	_save_world_state()   # 建造进度/贡献即时落盘

# ================= 全服世界状态持久化（据点进度 + 贡献榜 + 节点采集态）=================
func _save_world_state() -> void:
	_world_dirty = false
	var ops: Dictionary = {}
	for op_v: Variant in server_outposts:
		var op: Dictionary = op_v
		ops[str(int(op["id"]))] = {"build_points": int(op.get("build_points", 0)),
			"reinforce": int(op.get("reinforce", 0)), "defense_scrolls": int(op.get("defense_scrolls", 0))}
	var taken: Dictionary = {}
	for nid: int in _node_respawn.keys():
		taken[str(nid)] = int((_node_respawn[nid] as Dictionary)["at"])
	Accounts.store_world_state({"outposts": ops, "contrib": outpost_contrib, "nodes_taken": taken,
		"period": contrib_period, "pending": pending_rewards, "last_siege_day": _last_siege_day})

func _load_world_state() -> void:
	var ws: Dictionary = Accounts.load_world_state()
	if ws.is_empty():
		return
	# 据点建造/加固进度
	var st: Dictionary = (ws.get("outposts", {}) as Dictionary)
	for op_v: Variant in server_outposts:
		var op: Dictionary = op_v
		var key: String = str(int(op["id"]))
		if not st.has(key):
			continue
		var rec: Dictionary = st[key]
		op["build_points"] = int(rec.get("build_points", 0))
		op["defense_scrolls"] = int(rec.get("defense_scrolls", 0))
		var reinforce: int = int(rec.get("reinforce", 0))
		op["reinforce"] = reinforce
		if reinforce > 0:
			var mult: float = pow(1.3, float(reinforce))
			for seg_v: Variant in op["segs"]:
				var seg: Dictionary = seg_v
				seg["max_hp"] = float(seg["max_hp"]) * mult
				seg["hp"] = float(seg["max_hp"])
	# 贡献榜 + 周期 + 待发奖励
	outpost_contrib = {}
	for user: Variant in (ws.get("contrib", {}) as Dictionary).keys():
		var cr: Dictionary = (ws["contrib"] as Dictionary)[user]
		outpost_contrib[String(user)] = {"name": String(cr.get("name", user)), "points": int(cr.get("points", 0))}
	contrib_period = int(ws.get("period", -1))
	_last_siege_day = String(ws.get("last_siege_day", ""))
	pending_rewards = {}
	for u2: Variant in (ws.get("pending", {}) as Dictionary).keys():
		var lst: Array = []
		for it_v: Variant in ((ws["pending"] as Dictionary)[u2] as Array):
			var it: Dictionary = it_v
			lst.append({"mat": String(it.get("mat", "")), "amount": int(it.get("amount", 0))})
		pending_rewards[String(u2)] = lst
	_check_period_rollover()   # 若跨过了周界(如停服期间),补结算
	# 节点采集态（被采过、尚未重生的节点保持消失，到点自然重生）
	var taken: Dictionary = (ws.get("nodes_taken", {}) as Dictionary)
	for nid_s: Variant in taken.keys():
		var nid: int = int(nid_s)
		if world_nodes.has(nid):
			var nd: Dictionary = world_nodes[nid]
			_node_respawn[nid] = {"pos": nd["pos"], "mat": String(nd["mat"]), "at": int(taken[nid_s])}
			world_nodes.erase(nid)
	print("[Server] 已恢复全服世界状态（据点进度/贡献榜/节点采集态）。")

# ---------------- 主循环 ----------------

func _physics_process(delta: float) -> void:
	_update_spawners(delta)
	_update_residents(delta)
	_update_siege(delta)
	_update_world_nodes(delta)
	_update_beast_tides(delta)

	# 怪物 AI + 命中玩家事件（含 Boss 连招的 AOE 友伤 / 表现广播）
	for mid: int in monsters.keys():
		if not monsters.has(mid):
			continue   # 本帧内被连招/召唤/AOE 击杀而移除的怪，跳过（keys() 是快照）
		var m: ServerMonsterScript = monsters[mid]
		if m.is_summoned and m.summon_ttl > 0.0:
			m.summon_ttl -= delta
			if m.summon_ttl <= 0.0:
				_expire_summoned_monster(m)
				continue
		var _old_pos: Vector3 = m.pos
		var events: Array = m.tick(delta, Net.players, unlocked_radius)
		_wall_block(m, _old_pos)   # 完好城墙拦截地面怪
		for ev_v: Variant in events:
			var ev: Dictionary = ev_v
			match String(ev.get("type", "")):
				"hit_player":
					# 安全区免伤：目标处于无破损据点内则不结算。
					if not _outpost_safe(Net.players.get(int(ev["target"]), {}).get("pos", Vector3.ZERO)):
						Net.send_hit_player(int(ev["target"]), int(ev["amount"]))
					Net.broadcast_monster_action(m.id, m.pos)
				"aoe":
					_combo_aoe(m.id, ev["center"], float(ev["radius"]), int(ev["amount"]))
				"charge_hit":
					_combo_charge(m, ev["center"], float(ev["radius"]), int(ev["amount"]))
				"combo_start":
					Net.broadcast_monster_combo(m.id, {"center": ev["center"], "seed": int(ev["seed"])})
				"lightning_start":
					Net.broadcast_monster_combo(m.id, {"kind": "lightning", "center": ev["center"], "radius": float(ev["radius"]), "duration": float(ev["duration"]), "seed": int(ev["seed"])})
				"lightning_strike":
					_lightning_strike(m.id, ev["center"], float(ev["radius"]), int(ev["amount"]), float(ev["slow"]), float(ev["slow_dur"]))
				"summon":
					_do_summon(m.id, ev)
				"barrage":
					Net.broadcast_monster_combo(m.id, {"kind": "barrage", "sub": int(ev["sub"]), "center": ev["origin"], "target": ev["target"], "seed": int(ev["seed"]), "atk": int(ev["atk"])})
				"danmaku":
					Net.broadcast_monster_combo(m.id, {"kind": "danmaku", "pat": String(ev["pat"]), "center": ev["origin"], "target": ev["target"], "seed": int(ev["seed"]), "atk": int(ev["atk"])})
				"giant_start":
					Net.broadcast_monster_combo(m.id, {"kind": "giant", "center": ev["origin"], "dir": ev["dir"], "len": float(ev["len"]), "width": float(ev["width"]), "charge_t": float(ev["charge_t"]), "slam_t": float(ev["slam_t"]), "beam_t": float(ev["beam_t"]), "seed": int(ev["seed"])})
				"giant_slam":
					_giant_slam(m.id, ev["origin"], ev["dir"], float(ev["len"]), float(ev["width"]), int(ev["amount"]))
				"giant_beam":
					_giant_beam(m.id, ev["origin"], ev["dir"], float(ev["len"]), float(ev["width"]), int(ev["amount"]))
		if m.is_healer:
			_update_healer(m, delta)

	_update_pending_meteors(delta)
	_update_world_unlock(delta)
	_update_region_locks(delta)

	# 掉落物过期清理（taker=0 表示无人拾取，仅让客户端移除）
	var now_ms: int = Time.get_ticks_msec()
	for did: int in drops.keys():
		if now_ms >= int((drops[did] as Dictionary).get("exp_ms", 0)):
			drops.erase(did)
			Net.broadcast_drop_taken(did, 0)

	# 定时快照（按 AOI 兴趣区逐客户端裁剪：进入流式下发、离开发 despawn）。
	_player_snap_accum += delta
	if _player_snap_accum >= _player_snap_interval:
		_player_snap_accum = 0.0
		_aoi_players()
	_monster_snap_accum += delta
	if _monster_snap_accum >= _monster_snap_interval:
		_monster_snap_accum = 0.0
		_aoi_monsters()

# 玩家 AOI：每个客户端只收到其半径内其他玩家的完整状态快照；离开范围者发 despawn。
func _aoi_players() -> void:
	var ids: Array = Net.authed_ids()
	if ids.is_empty():
		return
	var vis: Array = Net.visible_ids()   # 含挨打代理（可被看见，但不收包）
	for pid: int in ids:
		var ppos: Vector3 = Net.players[pid]["pos"]
		var pinst: int = int(Net.players[pid].get("instance_id", 0))
		var seen: Dictionary = Net.players[pid]["seen_players"]
		var now: Dictionary = {}
		var states: Array = []
		for oid: int in vis:
			if oid == pid:
				continue
			if int(Net.players[oid].get("instance_id", 0)) != pinst:
				continue   # 不同实例（大世界/副本）互不可见
			var opos: Vector3 = Net.players[oid]["pos"]
			var d: float = Vector2(opos.x - ppos.x, opos.z - ppos.z).length()
			var limit: float = (_aoi_radius + _aoi_hys) if seen.has(oid) else _aoi_radius
			if d <= limit:
				now[oid] = true
				states.append(Net.player_state_dict(oid))
		var gone: Array = []
		for sid: int in seen.keys():
			if not now.has(sid):
				gone.append(sid)
		Net.players[pid]["seen_players"] = now
		if not gone.is_empty():
			Net.send_players_despawn_to(pid, gone)
		if not states.is_empty():
			Net.send_players_snapshot_to(pid, states)

# 怪物 AOI：新进入范围的怪先发完整定义(to_def)，可见期间发高频快照(to_snapshot)；离开发 despawn。
func _aoi_monsters() -> void:
	var ids: Array = Net.authed_ids()
	if ids.is_empty():
		return
	for pid: int in ids:
		var ppos: Vector3 = Net.players[pid]["pos"]
		var seen: Dictionary = Net.players[pid]["seen_monsters"]
		var now: Dictionary = {}
		var enter_defs: Array = []
		var snaps: Array = []
		# 只同步「同实例」的怪物（大世界玩家见大世界怪、副本玩家见本副本怪）。
		var pinst: int = int(Net.players[pid].get("instance_id", 0))
		for mid: int in monsters.keys():
			var m: ServerMonsterScript = monsters[mid]
			if m.inst != pinst:
				continue
			var d: float = Vector2(m.pos.x - ppos.x, m.pos.z - ppos.z).length()
			var limit: float = (_aoi_radius + _aoi_hys) if seen.has(mid) else _aoi_radius
			if d <= limit:
				now[mid] = true
				if not seen.has(mid):
					enter_defs.append(m.to_def())
				snaps.append(m.to_snapshot())
		var gone: Array = []
		for sid: int in seen.keys():
			if not now.has(sid):
				gone.append(sid)
		Net.players[pid]["seen_monsters"] = now
		# 顺序：先可靠下发定义，再 despawn，最后高频快照。
		if not enter_defs.is_empty():
			Net.send_monster_defs_to(pid, enter_defs)
		if not gone.is_empty():
			Net.send_monsters_despawn_to(pid, gone)
		if not snaps.is_empty():
			Net.send_monsters_snapshot_to(pid, snaps)
