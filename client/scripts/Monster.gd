class_name StarGloryMonster
extends CharacterBody3D

var main = null
var data: Dictionary = {}
var monster_name: String = "Monster"
var kind: String = "slime"
var is_boss: bool = false
var max_hp: int = 60
var hp: float = 60.0
var attack: int = 8
var defense: int = 0
var speed: float = 3.8
var detect_radius: float = 16.0
var attack_range: float = 1.6
var attack_interval: float = 1.2
var exp_reward: int = 20
var dead: bool = false
var fight_start_ms: int = 0     # Boss 首次被玩家命中的时刻（用于统计单场战斗时长）；0=尚未交战

# v0.3 能力标志
var ranged: bool = false        # 远程：发射投射物
var can_dash: bool = false      # 近战冲刺
var flying: bool = false        # 飞行：免重力、维持悬停高度
var hover_height: float = 2.2   # 飞行悬停高度
var elite: bool = false         # 精英：更强、会放技能、掉更高阶书
var resident: bool = false      # 常驻 Boss：等级恒定、击杀后定时重生、掉吸血装备
var is_caster: bool = false     # 施法者：会周期性释放技能（精英/Boss 必为真，普通怪随世界等级递增）
var rank: int = 1               # 掉落阶位参考（普通1~2，精英+2，Boss更高）
var aim_height: float = 0.95    # 碰撞体中心局部高度，供自动索敌瞄准
var world_level: int = 1        # 世界等级：放大体型/数值/技能频率/危险外观
var monster_level: int = 1      # 怪物等级 = 1 + (世界等级-1)*3
var body_scale: float = 1.0     # 最终体型缩放（精英 × 世界等级）
var special_cd: float = 6.5     # 技能冷却（随世界等级缩短）

var spawn_origin: Vector3 = Vector3.ZERO
var patrol_target: Vector3 = Vector3.ZERO
var attack_timer: float = 0.0
var buff: BuffComponent = null   # 状态系统组件（减速、灼烧 DoT）
var hurt_aggro_timer: float = 0.0
var has_target: bool = false       # 是否已锁定追踪目标
var last_known: Vector3 = Vector3.ZERO   # 失去视野时记录的目标最后位置
var heal_acc: float = 0.0          # 被玩家治疗的累计量（用于"奶上头"反噬仇恨）
var special_timer: float = 3.0
var _audio_step: float = 0.0   # 脚步音节流
var dash_cd_timer: float = 0.0
var dash_active_timer: float = 0.0
var dash_windup_timer: float = 0.0   # 冲刺前摇
var dash_pending: bool = false
var dash_dir: Vector3 = Vector3.ZERO
var cast_windup_timer: float = 0.0   # 远程施法前摇
var cast_pending: bool = false
var boss_skill_toggle: int = 0
var external_velocity: Vector3 = Vector3.ZERO
var external_timer: float = 0.0
var visual: Node3D
var health_bar: HealthBar3D = null
var rng := RandomNumberGenerator.new()

# ---- Boss 连招「天崩冲锋」：跃起→停留→脚下标记→砸地AOE友伤→四虚影→17次冲锋（含残影）----
const BossOnslaughtScene = preload("res://scripts/skills/BossOnslaught.gd")
const MiniMeteorScene = preload("res://scripts/skills/MiniMeteor.gd")
const LightningChannelScene = preload("res://scripts/skills/LightningChannel.gd")
const GiantJudgmentScene = preload("res://scripts/skills/GiantJudgment.gd")
const SkyBarrageScene = preload("res://scripts/skills/SkyBarrage.gd")
const DanmakuSpellScene = preload("res://scripts/skills/DanmakuSpell.gd")
const COMBO_LEAP_T := 0.7
const COMBO_HOVER_T := 0.45
const COMBO_SLAM_T := 0.45
const COMBO_LEAP_H := 7.0
const COMBO_PHANTOM_R := 9.5
const COMBO_CHARGES := 17
const COMBO_CHARGE_T := 0.22
const COMBO_CHARGE_GAP := 0.06
const COMBO_SLAM_R := 6.5
const COMBO_CHARGE_R := 2.6
const COMBO_GROUND_Y := 0.05
var combo_active: bool = false
var combo_phase: int = 0           # 0无 1跃起 2停留 3砸下 4冲锋
var combo_timer: float = 0.0
var combo_start_pos: Vector3 = Vector3.ZERO
var combo_apex: Vector3 = Vector3.ZERO
var combo_center: Vector3 = Vector3.ZERO     # 砸点 = 锁定时玩家脚下
var combo_seed: int = 0
var combo_phantoms: Array = []     # 四道虚影坐标
var combo_charge_idx: int = 0
var combo_from: Vector3 = Vector3.ZERO
var combo_to: Vector3 = Vector3.ZERO
var combo_charge_hit_done: bool = false
var _after_acc: float = 0.0        # 残影节流

# ---- 究极大招按位置分配（0=天崩冲锋 1=雷霆引导 2=召唤军团 3=巨兵天罚）+ 状态 ----
const ULTIMATE_COUNT := 4
const LIGHT_T := 3.5               # 引导时长
const LIGHT_R := 11.0              # 标记/命中范围
var ultimate_id: int = 0
var has_ultimate: bool = false     # 精英弱化版究极（非 Boss 也能放）
var ult_power: float = 1.0         # 究极威力系数（Boss=1.0，精英弱化≈0.5）
const ELITE_ULT_WL := 4            # 世界等级达此值后精英才可能获得究极
var lightning_active: bool = false
var lightning_timer: float = 0.0
# 召唤军团参数
const SUMMON_KINDS := ["wisp", "wolf", "archer", "healer"]   # 空军/步兵/炮兵/奶妈
const SUMMON_BOSS_WL := 6          # 世界等级达此值后召唤名额有概率改为 Boss
# 奶妈治疗/加速光环
const HEAL_INTERVAL := 1.5
const HEAL_R := 10.0
const HEAL_PCT := 0.06
var is_summoned: bool = false      # 由 Boss 召唤出来的（用于防级联召唤）
var summon_ttl: float = 0.0        # 召唤物生命周期，<=0 时按普通怪常驻
var is_healer: bool = false        # 奶妈：不打玩家，治疗+加速友军
var _heal_timer: float = 0.0
# 飞天弹幕精英：三套弹幕循环
var is_barrage: bool = false
var barrage_sub: int = 0
const BARRAGE_CD := 4.5   # 降低释放频率，避免长时间运行时弹幕节点暴涨
# Boss 弹幕术式（参考视频）：一组术式循环施放，与究极连招并行
var danmaku_list: Array = []
var danmaku_idx: int = 0
var danmaku_timer: float = 3.0
const DANMAKU_CD := 7.5
var _los_cache: bool = false        # 视线射线节流缓存
var _los_timer: float = 0.0
# 巨兵天罚（id3）
const JUDG_CHARGE_T := 1.3
const JUDG_SLAM_T := 0.6
const JUDG_BEAM_T := 2.5
const JUDG_BEAM_TICK := 0.3
const JUDG_BEAM_LEN := 18.0
const JUDG_BEAM_W := 5.0
const JUDG_DECAY := 0.8
var judg_active: bool = false
var judg_phase: int = 0            # 1蓄力 2砸落 3激光
var judg_timer: float = 0.0
var judg_dir: Vector3 = Vector3(0, 0, 1)
var judg_origin: Vector3 = Vector3.ZERO
var judg_beam_acc: float = 0.0

# 联机：傀儡怪物只按服务器快照插值显示，AI/受伤判定都在服务器。
var is_puppet: bool = false
var net_id: int = 0
# 快照插值缓冲（同玩家傀儡）：固定渲染延迟 + 历史快照间插值，吸收抖动。
const INTERP_DELAY_MS := 110.0
const BUF_MAX := 24
var _buf: Array = []   # [{t: float(ms), pos: Vector3}]

func setup(monster_data: Dictionary) -> void:
	data = monster_data.duplicate(true)
	monster_name = String(data.get("name", monster_name))
	kind = String(data.get("kind", kind))
	is_boss = bool(data.get("boss", false))
	max_hp = int(data.get("hp", max_hp))
	hp = float(max_hp)
	attack = int(data.get("attack", attack))
	defense = int(data.get("defense", defense))
	speed = float(data.get("speed", speed))
	detect_radius = float(data.get("detect", detect_radius))
	attack_range = float(data.get("range", attack_range))
	attack_interval = float(data.get("interval", attack_interval))
	exp_reward = int(data.get("exp", exp_reward))
	ranged = bool(data.get("ranged", false))
	can_dash = bool(data.get("can_dash", false))
	flying = bool(data.get("flying", false))
	hover_height = float(data.get("hover", hover_height))
	elite = bool(data.get("elite", false))
	is_healer = bool(data.get("healer", false))
	is_barrage = bool(data.get("barrage", false))
	danmaku_list = (data.get("danmaku", []) as Array).duplicate()
	rank = int(data.get("rank", 1))
	if elite:
		# 精英：更强壮、掉更高阶技能书。
		max_hp = int(max_hp * 1.9)
		hp = float(max_hp)
		attack = int(attack * 1.45)
		defense += 2
		exp_reward = int(exp_reward * 2.2)
		monster_name = "精英·" + monster_name
		rank += 2
	if is_boss:
		# Boss = 同级「精英怪」的 2 倍攻击、20 倍血量（技能基于 attack，自动 2 倍）。
		# 基准取代表性同级精英（普通怪 90血/14攻 × 精英倍率 1.9/1.45），与 boss 自身数据无关；
		# 之后再统一过基础增幅与世界等级缩放，从而在各等级都保持 2×/20× 的相对关系。
		max_hp = int(90.0 * 1.9 * 20.0)
		hp = float(max_hp)
		attack = int(14.0 * 1.45 * 2.0)
		defense += 5
	# 世界等级缩放：每提升一级世界等级，怪物等级 +3（lvl_bonus）。
	# 整体增幅（移速除外）：伤害、攻速、技能冷却都更强，并随等级继续提升。
	world_level = int(data.get("world_level", 1))   # 区域强度档位（1-6）
	var wl: int = world_level - 1
	var lvl_bonus: int = wl * 3
	monster_level = int(data.get("level", 1 + lvl_bonus))   # 区域固定等级（显示/视野用）
	# 基础增幅（所有怪物，含档位 1）：伤害 +25%、出手更快。
	attack = int(attack * 1.25)
	attack_interval = maxf(0.4, attack_interval * 0.9)
	if lvl_bonus > 0:
		max_hp = int(max_hp * (1.0 + 0.12 * float(lvl_bonus)))
		hp = float(max_hp)
		# 伤害随档位（增幅后更陡）。
		attack = int(attack * (1.0 + 0.13 * float(lvl_bonus)))
		defense += int(lvl_bonus / 2)
		# 攻速随档位（间隔更短）。
		attack_interval = maxf(0.32, attack_interval * pow(0.955, float(lvl_bonus)))
		exp_reward = int(exp_reward * (1.0 + 0.09 * float(lvl_bonus)))
		rank += wl
	monster_name = "%s Lv.%d" % [monster_name, monster_level]   # 总是显示怪物等级
	# 施法者：精英/Boss 必为真；普通怪由 Main 按世界等级掷出的 caster 标志决定。
	is_caster = elite or is_boss or bool(data.get("caster", false))
	# 技能冷却随「怪物等级」缩短（释放更频繁），下限 1.8s。
	special_cd = maxf(1.8, 6.5 - 0.4 * float(lvl_bonus))
	special_timer = minf(3.0, special_cd)   # 出生后的首次技能预热，保持原有节奏
	# 最终体型：精英 1.35 × 世界等级递增（Boss 体型已很大，仅轻微放大）。
	var wl_scale: float = 1.0 + 0.05 * float(wl)
	body_scale = (1.35 if elite else 1.0) * wl_scale
	# 究极归属：Boss 由种类数据固定；精英可被赋予弱化版究极。
	if is_boss:
		ultimate_id = int(data.get("ultimate", 0))
	if bool(data.get("weak_ult", false)):
		has_ultimate = true
		ult_power = 0.5
		ultimate_id = int(data.get("ultimate", 0))

# 联机傀儡初始化：直接采用服务器已结算好的数值（不再做精英缩放），仅用于渲染。
func setup_puppet(def: Dictionary) -> void:
	is_puppet = true
	net_id = int(def.get("id", 0))
	kind = String(def.get("kind", kind))
	monster_level = int(def.get("level", 1))
	monster_name = "%s Lv.%d" % [String(def.get("name", monster_name)), monster_level]
	is_boss = bool(def.get("boss", false))
	elite = bool(def.get("elite", false))
	resident = bool(def.get("resident", false))
	rank = int(def.get("rank", 1))
	flying = bool(def.get("flying", false))
	hover_height = float(def.get("hover", hover_height))
	max_hp = int(def.get("max_hp", max_hp))
	hp = float(max_hp)
	world_level = int(def.get("world_level", 1))
	var wl_scale: float = 1.0 + 0.05 * float(world_level - 1)
	body_scale = (1.35 if elite else 1.0) * wl_scale
	data = {"kind": kind, "color": GameData.to_color(def.get("color"))}

# 收到新快照：入缓冲；远距跳变直接传送并清缓冲。
func net_set_target(p: Vector3) -> void:
	var now: float = float(Time.get_ticks_msec())
	if _buf.is_empty():
		_buf = [{"t": now, "pos": p}]
		global_position = p
		return
	var lastpos: Vector3 = _buf[_buf.size() - 1]["pos"]
	if lastpos.distance_to(p) < 0.0001:
		return
	if lastpos.distance_to(p) > 6.0 or (now - float(_buf[_buf.size() - 1]["t"])) > 250.0:
		_buf = [{"t": now, "pos": p}]
		global_position = p
		return
	_buf.append({"t": now, "pos": p})
	while _buf.size() > BUF_MAX:
		_buf.pop_front()

func _interp_pos() -> Vector3:
	var n: int = _buf.size()
	if n == 0:
		return global_position
	if n == 1:
		return _buf[0]["pos"]
	var render_t: float = float(Time.get_ticks_msec()) - INTERP_DELAY_MS
	if render_t <= float(_buf[0]["t"]):
		return _buf[0]["pos"]
	var last: Dictionary = _buf[n - 1]
	if render_t >= float(last["t"]):
		return last["pos"]
	for i in range(n - 1):
		var a: Dictionary = _buf[i]
		var b: Dictionary = _buf[i + 1]
		var ta: float = float(a["t"])
		var tb: float = float(b["t"])
		if render_t >= ta and render_t <= tb:
			var span: float = tb - ta
			var alpha: float = 0.0 if span <= 0.0 else clampf((render_t - ta) / span, 0.0, 1.0)
			return (a["pos"] as Vector3).lerp(b["pos"] as Vector3, alpha)
	return last["pos"]

# 服务器广播怪物出手：傀儡端做一个小的攻击表现（前压 + 闪光）。
func net_play_attack() -> void:
	if visual != null:
		var t := create_tween()
		t.tween_property(visual, "scale", visual.scale * 1.12, 0.08)
		t.tween_property(visual, "scale", visual.scale, 0.12)
	if main != null and main.has_method("spawn_skill_flash"):
		main.spawn_skill_flash(global_position + Vector3(0, aim_height, 0), Color(1.0, 0.55, 0.3, 1), 0.9, 0.16)
	# 远程怪（联机傀儡）：生成纯表现投射物飞向最近玩家（伤害由服务器权威结算）。
	if ranged and main != null and main.has_method("spawn_projectile"):
		var tp: Vector3 = _net_nearest_player_pos()
		if tp.x != INF:
			var muzzle: Vector3 = global_position + Vector3(0, aim_height + 0.15, 0)
			var pdir: Vector3 = (tp + Vector3(0, 1.0, 0) - muzzle).normalized()
			main.spawn_projectile({
				"position": muzzle + pdir * 0.7, "direction": pdir, "speed": 16.0,
				"damage": 0, "radius": 0.25, "aoe": 0.0, "color": _projectile_color(),
				"source": self, "target_group": "player", "visual_only": true, "life": 2.5,
			})
		Audio.sfx_at("magic", global_position, -6.0, 1.15)

func _net_nearest_player_pos() -> Vector3:
	var best: Vector3 = Vector3(INF, INF, INF)
	var bd: float = 1.0e9
	if main == null:
		return best
	if main.player != null and is_instance_valid(main.player):
		var d: float = global_position.distance_to((main.player as Node3D).global_position)
		if d < bd:
			bd = d; best = (main.player as Node3D).global_position
	if "net_players" in main:
		for pp_v: Variant in (main.net_players as Dictionary).values():
			if is_instance_valid(pp_v):
				var d2: float = global_position.distance_to((pp_v as Node3D).global_position)
				if d2 < bd:
					bd = d2; best = (pp_v as Node3D).global_position
	return best

func _ready() -> void:
	rng.randomize()
	add_to_group("monster")
	spawn_origin = global_position
	_buf = [{"t": float(Time.get_ticks_msec()), "pos": global_position}]
	patrol_target = spawn_origin + Vector3(rng.randf_range(-5, 5), 0, rng.randf_range(-5, 5))
	_build_collision()
	_build_model()
	buff = BuffComponent.new()
	buff.name = "BuffComponent"
	add_child(buff)
	buff.setup(self, main)
	health_bar = HealthBar3D.new()
	add_child(health_bar)
	health_bar.setup(2.4 if is_boss else 1.2, (aim_height * 2.0 + 0.9) if not is_boss else 4.0)

func _build_collision() -> void:
	var scale_e: float = body_scale
	var shape := CapsuleShape3D.new()
	var collision := CollisionShape3D.new()
	if is_boss:
		shape.radius = 1.0
		shape.height = 2.5
		collision.position = Vector3(0, 1.6, 0)
	elif flying:
		# 飞行怪：身体本身被悬停弹簧抬到 hover_height，所以碰撞体相对身体居中(局部 0)，
		# 不能再叠加 hover_height（否则会变成 2 倍高度，索敌打空）。
		shape.radius = 0.45 * scale_e
		shape.height = 1.1 * scale_e
		collision.position = Vector3(0, 0.0, 0)
	else:
		# 普通怪加高，确保 2 技能火球（指尖高度约 1.1）能命中。
		shape.radius = 0.5 * scale_e
		shape.height = 1.7 * scale_e
		collision.position = Vector3(0, 0.95 * scale_e, 0)
	collision.shape = shape
	add_child(collision)
	# 索敌瞄准点 = 身体原点 + 碰撞中心局部高度（命中实际碰撞体中心，而非脚下）。
	aim_height = collision.position.y

# 自动索敌瞄准点（世界坐标，对准碰撞体中心；飞行怪即其悬停高度处的身体）。
func aim_point() -> Vector3:
	return global_position + Vector3(0, aim_height, 0)

func _mat(color: Color, emission: float = 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.7
	if emission > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = emission
	return mat

func _add_mesh(parent: Node, mesh: Mesh, mat: Material, pos: Vector3, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi

func _box(size: Vector3) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh

func _sphere(radius: float, height: float = -1.0) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = height if height > 0.0 else radius * 2.0
	mesh.radial_segments = 18
	mesh.rings = 9
	return mesh

func _capsule(radius: float, height: float) -> CapsuleMesh:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = 18
	mesh.rings = 6
	return mesh

func _cylinder(top_radius: float, bottom_radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	mesh.radial_segments = 16
	return mesh

func _build_model() -> void:
	visual = Node3D.new()
	visual.name = "MonsterVisual"
	add_child(visual)

	var color: Color = data.get("color", Color(0.85, 0.2, 0.45, 1)) as Color
	# 危险外观：世界等级越高，体色越偏血红、自发光越强。
	var danger: float = clampf(0.12 * float(world_level - 1), 0.0, 0.6)
	color = color.lerp(Color(1.0, 0.08, 0.05, 1), danger)
	var mat := _mat(color, 0.18 + 0.5 * danger)
	var dark := _mat(Color(0.08, 0.07, 0.10, 1))
	var eye := _mat(Color(1.0, 0.95, 0.32, 1), 1.2)
	# Boss 变体（boss_storm/boss_warlord/boss_titan 等）统一用 Boss 外观。
	var model_kind: String = "boss" if is_boss else kind
	match model_kind:
		"slime":
			_add_mesh(visual, _sphere(0.58, 0.78), mat, Vector3(0, 0.55, 0))
			_add_mesh(visual, _sphere(0.10), eye, Vector3(-0.17, 0.72, -0.48))
			_add_mesh(visual, _sphere(0.10), eye, Vector3(0.17, 0.72, -0.48))
		"wolf":
			_add_mesh(visual, _box(Vector3(1.10, 0.52, 0.42)), mat, Vector3(0, 0.72, 0))
			_add_mesh(visual, _box(Vector3(0.50, 0.40, 0.40)), mat, Vector3(0, 0.90, -0.55))
			for x in [-0.36, 0.36]:
				_add_mesh(visual, _box(Vector3(0.13, 0.58, 0.13)), dark, Vector3(x, 0.32, -0.24))
				_add_mesh(visual, _box(Vector3(0.13, 0.58, 0.13)), dark, Vector3(x, 0.32, 0.28))
			_add_mesh(visual, _sphere(0.06), eye, Vector3(-0.12, 0.98, -0.78))
			_add_mesh(visual, _sphere(0.06), eye, Vector3(0.12, 0.98, -0.78))
		"mage":
			_add_mesh(visual, _capsule(0.38, 1.15), mat, Vector3(0, 0.95, 0))
			_add_mesh(visual, _cylinder(0.0, 0.46, 0.70), _mat(Color(0.25, 0.05, 0.35, 1), 0.2), Vector3(0, 1.68, 0))
			_add_mesh(visual, _sphere(0.12), eye, Vector3(-0.12, 1.20, -0.33))
			_add_mesh(visual, _sphere(0.12), eye, Vector3(0.12, 1.20, -0.33))
			_add_mesh(visual, _box(Vector3(0.12, 1.35, 0.12)), _mat(Color(0.9, 0.85, 0.55, 1), 0.3), Vector3(0.55, 0.85, 0), Vector3(0.2, 0.0, 0.0))
		"boss":
			_add_mesh(visual, _capsule(0.95, 2.65), mat, Vector3(0, 1.65, 0))
			_add_mesh(visual, _sphere(0.62), _mat(Color(0.12, 0.10, 0.22, 1), 0.2), Vector3(0, 3.15, 0))
			_add_mesh(visual, _sphere(0.13), eye, Vector3(-0.24, 3.18, -0.54))
			_add_mesh(visual, _sphere(0.13), eye, Vector3(0.24, 3.18, -0.54))
			_add_mesh(visual, _box(Vector3(2.6, 0.22, 0.55)), _mat(Color(0.86, 0.75, 0.48, 1), 0.5), Vector3(0, 2.18, -0.02))
			_add_mesh(visual, _box(Vector3(0.28, 1.3, 0.28)), _mat(Color(0.75, 0.25, 0.18, 1), 0.3), Vector3(-0.9, 1.55, -0.02), Vector3(0.0, 0.0, 0.35))
			_add_mesh(visual, _box(Vector3(0.28, 1.3, 0.28)), _mat(Color(0.75, 0.25, 0.18, 1), 0.3), Vector3(0.9, 1.55, -0.02), Vector3(0.0, 0.0, -0.35))
		"archer":
			_add_mesh(visual, _capsule(0.34, 1.2), mat, Vector3(0, 0.95, 0))
			_add_mesh(visual, _sphere(0.24), _mat(Color(0.95, 0.8, 0.6, 1)), Vector3(0, 1.62, 0))
			# 弓
			_add_mesh(visual, _box(Vector3(0.08, 1.05, 0.08)), _mat(Color(0.5, 0.32, 0.16, 1)), Vector3(0.42, 1.05, -0.1), Vector3(0.0, 0.0, 0.18))
			_add_mesh(visual, _sphere(0.10), eye, Vector3(-0.1, 1.66, -0.2))
			_add_mesh(visual, _sphere(0.10), eye, Vector3(0.1, 1.66, -0.2))
		"wisp":
			# 飞行幽光：悬浮核心 + 两侧光翼，绕身体原点构建（身体本身由弹簧抬到 hover_height）。
			_add_mesh(visual, _sphere(0.42), mat, Vector3(0, 0, 0))
			_add_mesh(visual, _sphere(0.16), eye, Vector3(0, 0.02, -0.34))
			for sx in [-1.0, 1.0]:
				_add_mesh(visual, _box(Vector3(0.7, 0.06, 0.42)), _mat(Color(0.6, 0.85, 1.0, 1), 0.6), Vector3(sx * 0.6, 0.1, 0.05), Vector3(0, 0, sx * 0.5))
		"skyseraph":
			# 飞天弹幕使：发光核心 + 多片幻翼。
			_add_mesh(visual, _sphere(0.55), mat, Vector3(0, 0, 0))
			_add_mesh(visual, _sphere(0.20), eye, Vector3(0, 0.05, -0.45))
			for sx in [-1.0, 1.0]:
				_add_mesh(visual, _box(Vector3(1.1, 0.06, 0.55)), _mat(Color(1.0, 0.55, 1.0, 1), 1.0), Vector3(sx * 0.85, 0.18, 0.0), Vector3(0, 0, sx * 0.65))
				_add_mesh(visual, _box(Vector3(0.85, 0.05, 0.4)), _mat(Color(0.7, 0.9, 1.0, 1), 1.0), Vector3(sx * 0.7, -0.18, 0.1), Vector3(0, 0, sx * 0.4))
		"orbweaver", "lanewright", "veilcaller", "spiralmancer":
			# 弹幕吟唱者（地面）：发光核心 + 环绕碎片。
			_add_mesh(visual, _sphere(0.5), mat, Vector3(0, 1.0, 0))
			_add_mesh(visual, _sphere(0.16), eye, Vector3(0, 1.05, -0.42))
			for a in [0.0, 2.094, 4.188]:
				_add_mesh(visual, _box(Vector3(0.55, 0.1, 0.1)), _mat(Color(1, 1, 1, 0.85), 1.0), Vector3(cos(a) * 0.75, 1.0, sin(a) * 0.75), Vector3(0, a, 0))
		"orbdrifter", "starcantor":
			# 弹幕吟唱者（飞行）：悬浮核心 + 双翼（绕身体原点，身体由弹簧抬到 hover）。
			_add_mesh(visual, _sphere(0.46), mat, Vector3(0, 0, 0))
			_add_mesh(visual, _sphere(0.16), eye, Vector3(0, 0.02, -0.4))
			for sx in [-1.0, 1.0]:
				_add_mesh(visual, _box(Vector3(0.75, 0.06, 0.42)), _mat(Color(1, 1, 0.7, 0.7), 0.7), Vector3(sx * 0.62, 0.1, 0.05), Vector3(0, 0, sx * 0.5))
		_:
			_add_mesh(visual, _capsule(0.5, 1.2), mat, Vector3(0, 0.9, 0))

	# 体型：精英 × 世界等级（Boss 自身已很大，body_scale 仅含轻微世界放大）。
	if not is_boss:
		visual.scale = Vector3.ONE * body_scale
	elif world_level > 1:
		visual.scale = Vector3.ONE * (1.0 + 0.05 * float(world_level - 1))
	if elite:
		# 精英光环
		var ring := TorusMesh.new()
		ring.inner_radius = 0.85
		ring.outer_radius = 1.0
		var halo := _add_mesh(visual, ring, _mat(Color(1.0, 0.85, 0.3, 1), 1.2), Vector3(0, 0.06, 0))
		halo.rotation.x = PI / 2.0
	# 高世界等级：附加血红危险光环，越高越明显。
	if world_level >= 3:
		var dring := TorusMesh.new()
		dring.inner_radius = 1.05
		dring.outer_radius = 1.18
		var dhalo := _add_mesh(visual, dring, _mat(Color(1.0, 0.12, 0.08, 1), 1.4), Vector3(0, 0.04, 0))
		dhalo.rotation.x = PI / 2.0

func _physics_process(delta: float) -> void:
	if is_puppet:
		if dead:
			return
		var prev: Vector3 = global_position
		global_position = _interp_pos()
		var mv: Vector3 = global_position - prev   # 朝移动方向（观感更自然）
		mv.y = 0.0
		if mv.length() > 0.008 and visual != null:
			visual.rotation.y = atan2(-mv.x, -mv.z)
		# 联机傀儡：Boss 冲锋/跃起（快速位移）时本地补残影，无需额外同步。
		if is_boss and mv.length() > 0.22:
			_after_acc -= delta
			if _after_acc <= 0.0:
				_after_acc = 0.04
				spawn_afterimage()
		if health_bar != null:
			health_bar.set_hp(hp, float(max_hp))
		return
	if dead:
		return
	if is_summoned and summon_ttl > 0.0:
		summon_ttl -= delta
		if summon_ttl <= 0.0:
			dead = true
			if main != null:
				if main.has_method("spawn_skill_flash"):
					main.spawn_skill_flash(global_position + Vector3(0, 0.8, 0), Color(0.55, 0.25, 1.0, 1), 1.5, 0.24)
				if "monsters" in main:
					main.monsters.erase(self)
			queue_free()
			return
	if health_bar != null:
		health_bar.set_hp(hp, float(max_hp))
	# Boss 连招进行中：接管移动与表现，跳过常规 AI / 重力 / move_and_slide。
	if combo_active:
		_combo_process(delta, (main.player as StarGloryPlayer) if main != null else null)
		return
	# 雷霆引导：原地站桩引导，跳过常规 AI。
	if lightning_active:
		velocity = Vector3.ZERO
		if not flying and not is_on_floor():
			velocity.y -= 28.0 * delta
		move_and_slide()
		_lightning_process(delta, (main.player as StarGloryPlayer) if main != null else null)
		return
	# 巨兵天罚：原地站桩，跳过常规 AI。
	if judg_active:
		velocity = Vector3.ZERO
		if not flying and not is_on_floor():
			velocity.y -= 28.0 * delta
		move_and_slide()
		_judgment_process(delta, (main.player as StarGloryPlayer) if main != null else null)
		return
	# 冰冻 / 眩晕：生根停摆——清水平速度、跳过 AI/攻击/计时，仅维持悬停或重力。
	if buff != null and (buff.is_frozen() or buff.is_stunned()):
		velocity.x = 0.0
		velocity.z = 0.0
		if flying:
			velocity.y = (hover_height - global_position.y) * 4.0
		elif not is_on_floor():
			velocity.y -= 28.0 * delta
		else:
			velocity.y = -0.05
		_apply_external_velocity(delta)
		move_and_slide()
		return
	# 奶妈：不打玩家，贴近友军 + 周期治疗/加速光环。
	if is_healer:
		_healer_ai(delta)
		return
	attack_timer = max(0.0, attack_timer - delta)
	special_timer -= delta
	danmaku_timer = max(0.0, danmaku_timer - delta)
	_los_timer = max(0.0, _los_timer - delta)
	dash_cd_timer = max(0.0, dash_cd_timer - delta)
	dash_active_timer = max(0.0, dash_active_timer - delta)

	var player: StarGloryPlayer = (main.player as StarGloryPlayer) if main != null else null

	# 冲刺前摇结束 → 执行突进。
	if dash_pending:
		dash_windup_timer = max(0.0, dash_windup_timer - delta)
		if dash_windup_timer <= 0.0:
			dash_pending = false
			_do_dash(player)
	# 远程施法前摇结束 → 开火。
	if cast_pending:
		cast_windup_timer = max(0.0, cast_windup_timer - delta)
		if cast_windup_timer <= 0.0:
			cast_pending = false
			if player != null and is_instance_valid(player) and player.hp > 0.0:
				_shoot_at(player, attack + 6, 14.0, _projectile_color())

	if hurt_aggro_timer > 0.0:
		hurt_aggro_timer -= delta

	var move_dir := Vector3.ZERO
	var busy: bool = dash_pending or dash_active_timer > 0.0 or cast_pending
	var alive_player: bool = player != null and is_instance_valid(player) and player.hp > 0.0
	# 视野扫描：朝向圆锥 + 视线无遮挡才算看见；被打/同伴示警(hurt_aggro)也强制锁定。
	var see: bool = alive_player and _can_see_player(player)
	if see:
		has_target = true
		last_known = player.global_position
	elif hurt_aggro_timer > 0.0 and alive_player:
		has_target = true
		last_known = player.global_position
	# 牵引绳：离领地太远且非受击状态则放弃，回家。
	if has_target and hurt_aggro_timer <= 0.0 and global_position.distance_to(spawn_origin) > detect_radius * 2.6:
		has_target = false

	if busy and player != null:
		var tp: Vector3 = player.global_position - global_position
		if visual != null and tp.length() > 0.05:
			visual.look_at(global_position + Vector3(tp.x, 0, tp.z), Vector3.UP)
	elif has_target and alive_player:
		var to_player: Vector3 = player.global_position - global_position
		to_player.y = 0
		var dist: float = to_player.length()
		if see:
			# 视野内：正常战斗（远程/冲刺/近战）。
			if ranged:
				move_dir = _ranged_move(player, to_player, dist)
			elif can_dash:
				if dist > attack_range and dist < 9.0 and dash_cd_timer <= 0.0:
					_begin_dash_windup(to_player.normalized())
				elif dist > attack_range:
					move_dir = to_player.normalized()
				else:
					_try_attack(player)
			else:
				if dist > attack_range:
					move_dir = to_player.normalized()
				else:
					_try_attack(player)
			# 弹幕术式：与究极连招并行，自有冷却。
			if not danmaku_list.is_empty() and danmaku_timer <= 0.0:
				danmaku_timer = DANMAKU_CD
				_start_danmaku(player)
			if special_timer <= 0.0:
				if is_boss:
					_special_attack(player)
				elif is_barrage:
					special_timer = BARRAGE_CD
					_start_barrage(player)
				elif has_ultimate:
					special_timer = 16.0   # 精英弱化版究极：冷却更长
					_start_ultimate(ultimate_id, player)
				elif is_caster:
					_cast_monster_skill(player)
		else:
			# 失去视野：追到「最后已知位置」，到达后仍看不见就放弃、恢复扫描。
			var to_goal: Vector3 = last_known - global_position
			to_goal.y = 0
			if to_goal.length() > 1.4:
				move_dir = to_goal.normalized()
			else:
				has_target = false
	elif not busy:
		# 无目标：逐渐走回领地并回血。
		var home: Vector3 = spawn_origin - global_position
		home.y = 0
		if home.length() > 2.5:
			move_dir = home.normalized()
		elif hp < float(max_hp):
			hp = min(float(max_hp), hp + float(max_hp) * 0.05 * delta)

	# 冲刺中靠外部速度推进，不再覆盖水平速度。
	var speed_mul: float = buff.get_speed_multiplier()
	if dash_active_timer > 0.0:
		velocity.x = move_toward(velocity.x, 0.0, speed * 2.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, speed * 2.0 * delta)
	elif move_dir.length() > 0.01:
		velocity.x = move_dir.x * speed * speed_mul
		velocity.z = move_dir.z * speed * speed_mul
		_emit_step(delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed * 4.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, speed * 4.0 * delta)
	# 朝向：远程/施法/弹幕怪始终面向目标（否则停下或后撤时视野锥判定失败，
	# 会停止普攻与弹幕术式，表现为「攻击无特效/无弹体」）；其余怪面向移动方向。
	var wants_face_target: bool = has_target and alive_player and player != null and (ranged or is_barrage or not danmaku_list.is_empty())
	if visual != null:
		if wants_face_target:
			var fp: Vector3 = player.global_position - global_position
			if Vector2(fp.x, fp.z).length() > 0.05:
				visual.look_at(global_position + Vector3(fp.x, 0, fp.z), Vector3.UP)
		elif move_dir.length() > 0.01:
			visual.look_at(global_position + Vector3(move_dir.x, 0, move_dir.z), Vector3.UP)

	if flying:
		# 免重力：用弹簧维持「地表以上」悬停高度（山地上按地形抬高，避免飞怪穿进山体）。
		var ground_y: float = 0.0
		if main != null and main.has_method("terrain_height"):
			ground_y = main.terrain_height(global_position.x, global_position.z)
		velocity.y = (ground_y + hover_height - global_position.y) * 4.0
	elif not is_on_floor():
		velocity.y -= 28.0 * delta
	else:
		velocity.y = -0.05
	_apply_external_velocity(delta)
	move_and_slide()

	if main != null:
		global_position.x = clamp(global_position.x, -main.map_radius + 1.0, main.map_radius - 1.0)
		global_position.z = clamp(global_position.z, -main.map_radius + 1.0, main.map_radius - 1.0)
		# 飞行怪硬性兜底：绝不低于地表（避免穿进雪山山体）。
		if flying and main.has_method("terrain_height"):
			var gy: float = main.terrain_height(global_position.x, global_position.z)
			global_position.y = maxf(global_position.y, gy + hover_height * 0.5)

# 冲刺前摇：站定、转向、亮起预备光效，给玩家反应时间。
func _begin_dash_windup(dir: Vector3) -> void:
	dash_pending = true
	dash_windup_timer = 0.5
	dash_cd_timer = 4.5
	dash_dir = dir
	if visual != null:
		visual.look_at(global_position + Vector3(dir.x, 0, dir.z), Vector3.UP)
	if main != null:
		main.spawn_skill_flash(global_position + Vector3(0, 0.9, 0), Color(0.95, 0.55, 1.0, 1), 1.4, 0.5)

# 执行突进：比旧版更慢、距离更短。
func _do_dash(player: Node) -> void:
	dash_active_timer = 0.4
	var dir: Vector3 = dash_dir
	if player != null and is_instance_valid(player):
		var d: Vector3 = player.global_position - global_position
		d.y = 0
		if d.length() > 0.05:
			dir = d.normalized()
	external_velocity = dir * 13.0
	external_timer = 0.4
	if main != null:
		main.spawn_skill_flash(global_position + Vector3(0, 0.6, 0), Color(0.9, 0.5, 1.0, 1), 0.9, 0.14)

# 远程移动：太远逼近、太近风筝后撤、合适距离站定并起手开火。
func _ranged_move(player: Node, to_player: Vector3, dist: float) -> Vector3:
	if dist <= attack_range and attack_timer <= 0.0 and not cast_pending and _attack_height_ok(player):
		_begin_cast_windup()
	if dist > attack_range:
		return to_player.normalized()
	elif dist < attack_range * 0.5:
		return (-to_player).normalized()
	return Vector3.ZERO

func _begin_cast_windup() -> void:
	cast_pending = true
	cast_windup_timer = 0.45
	attack_timer = attack_interval + 0.45
	if main != null:
		var muzzle: Vector3 = global_position + Vector3(0, aim_height + 0.15, 0)
		main.spawn_skill_flash(muzzle, _projectile_color(), 0.6, 0.45)

func apply_forced_knockback(from_pos: Vector3, power: float, vertical_power: float = 3.6, duration: float = 0.34) -> void:
	var away: Vector3 = global_position - from_pos
	away.y = 0.0
	if away.length() <= 0.05:
		away = Vector3(0, 0, 1)
	away = away.normalized()
	var boss_resist: float = 0.45 if is_boss else 1.0
	external_velocity = away * power * boss_resist + Vector3(0, vertical_power * boss_resist, 0)
	external_timer = max(external_timer, duration)

func _apply_external_velocity(delta: float) -> void:
	if external_timer <= 0.0 and external_velocity.length() <= 0.05:
		external_velocity = Vector3.ZERO
		return
	velocity.x += external_velocity.x
	velocity.z += external_velocity.z
	velocity.y += external_velocity.y
	external_timer = max(0.0, external_timer - delta)
	var decay: float = 16.0 * delta
	external_velocity.x = move_toward(external_velocity.x, 0.0, decay)
	external_velocity.z = move_toward(external_velocity.z, 0.0, decay)
	external_velocity.y = move_toward(external_velocity.y, 0.0, decay * 0.65)

# 圆锥视野扫描：朝向左右/上下 ±(45°~75° 随等级) 锥内、长度=索敌范围(随等级变长)、且视线无遮挡。
func _can_see_player(p: Node) -> bool:
	if visual == null:
		return false
	var eye: Vector3 = global_position + Vector3(0, aim_height, 0)
	var tp: Vector3 = (p as Node3D).global_position + Vector3(0, 0.9, 0)
	var to: Vector3 = tp - eye
	var len: float = to.length()
	if len < 0.6:
		return true
	var lf: float = clampf(float(monster_level - 1) / 24.0, 0.0, 1.0)
	if len > detect_radius * lerpf(1.0, 1.6, lf):
		return false
	var half: float = deg_to_rad(lerpf(45.0, 75.0, lf))
	var facing: Vector3 = -visual.global_transform.basis.z
	facing.y = 0.0
	if facing.length() < 0.01:
		facing = Vector3(0, 0, -1)
	facing = facing.normalized()
	var to_h: Vector3 = Vector3(to.x, 0.0, to.z)
	var hd: float = to_h.length()
	if hd > 0.01 and acos(clampf(facing.dot(to_h.normalized()), -1.0, 1.0)) > half:
		return false   # 水平超出锥角
	if atan2(absf(to.y), maxf(hd, 0.01)) > half:
		return false   # 垂直超出锥角
	# 物理射线较贵：节流缓存，每 ~0.2s 才重算一次（大批怪时显著降负载）。
	if _los_timer > 0.0:
		return _los_cache
	_los_cache = _has_line_of_sight(eye, tp)
	_los_timer = 0.2 + randf() * 0.12
	return _los_cache

# 视线：从眼睛到目标做物理射线，若先撞到障碍/建筑(非玩家)则被遮挡。
func _has_line_of_sight(from: Vector3, to: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_bodies = true
	q.exclude = [get_rid()]
	var hit: Dictionary = space.intersect_ray(q)
	if hit.is_empty():
		return true
	return hit.get("collider") == (main.player if main != null else null)

func _patrol_direction() -> Vector3:
	var to_target := patrol_target - global_position
	to_target.y = 0
	if to_target.length() < 1.2:
		var radius: float = 8.0 if not is_boss else 12.0
		patrol_target = spawn_origin + Vector3(rng.randf_range(-radius, radius), 0, rng.randf_range(-radius, radius))
		to_target = patrol_target - global_position
		to_target.y = 0
	return to_target.normalized() if to_target.length() > 0.1 else Vector3.ZERO

# 攻击距离判定计入高差：玩家与本怪垂直差超过 vreach 则够不着（御云/升空可躲地面怪）。
func _attack_height_ok(target: Node) -> bool:
	if not is_instance_valid(target):
		return false
	if ranged:
		return true   # 远程怪不受高度差限制（与服务器一致，避免飞行怪悬停过高时无法出手）
	var vgap: float = absf((target as Node3D).global_position.y - global_position.y)
	var vreach: float = (3.2 if is_boss else 2.4)
	return vgap <= vreach

func _try_attack(player: Node) -> void:
	if attack_timer > 0.0:
		return
	if not _attack_height_ok(player):
		return
	attack_timer = attack_interval
	if ranged:
		_shoot_at(player, attack + 6, 13.0, _projectile_color())
	else:
		player.take_damage(attack, self)
		Audio.sfx_at("mhit", global_position, -3.0)
		if main != null:
			main.spawn_skill_flash(player.global_position + Vector3(0, 0.9, 0), Color(1.0, 0.2, 0.22, 1), 0.9, 0.16)

func _projectile_color() -> Color:
	match kind:
		"archer":
			return Color(0.95, 0.85, 0.4, 1)
		"wisp":
			return Color(0.5, 0.9, 1.0, 1)
		_:
			return Color(0.65, 0.2, 1.0, 1)

# 怪物脚步（地面、移动、靠近玩家时；定位 3D，远近衰减）。
func _emit_step(delta: float) -> void:
	if flying or main == null or main.player == null or not is_instance_valid(main.player):
		return
	if global_position.distance_to(main.player.global_position) > 24.0:
		return
	_audio_step -= delta
	if _audio_step <= 0.0:
		_audio_step = 0.42
		Audio.sfx_at("step", global_position, -9.0, randf_range(0.7, 0.85))

func _shoot_at(player: Node, dmg: int, proj_speed: float, color: Color, spread: float = 0.0) -> void:
	if main == null:
		return
	if spread == 0.0:
		Audio.sfx_at("magic", global_position, -5.0, 1.15)
	var muzzle: Vector3 = global_position + Vector3(0, aim_height + 0.15, 0)
	var base_dir: Vector3 = (player.global_position + Vector3(0, 1.0, 0) - muzzle).normalized()
	var dir: Vector3 = base_dir
	if spread != 0.0:
		dir = base_dir.rotated(Vector3.UP, spread)
	main.spawn_projectile({
		"position": muzzle + dir * 0.7,
		"direction": dir,
		"speed": proj_speed,
		"damage": dmg,
		"radius": 0.25,
		"aoe": 0.0,
		"color": color,
		"source": self,
		"target_group": "player"
	})

# 精英技能：按种类选择一招（远程三连射 / 近战范围冲击 / 自我加速）。
func _cast_monster_skill(player: Node) -> void:
	special_timer = special_cd
	attack_timer = max(attack_timer, 0.8)
	Audio.sfx_at("magic", global_position, -2.0, 0.9)
	if ranged:
		for s in [-0.18, 0.0, 0.18]:
			_shoot_at(player, attack + 4, 13.0, _projectile_color(), s)
		if main != null:
			main.spawn_skill_flash(global_position + Vector3(0, 1.2, 0), _projectile_color(), 1.4, 0.2)
	else:
		# 近战精英：原地范围冲击 + 把自己加速一会。
		if main != null:
			main.combat.apply_player_area_damage(global_position, 4.6, attack + 8)
			main.spawn_skill_flash(global_position + Vector3(0, 0.5, 0), Color(1.0, 0.4, 0.2, 1), 4.4, 0.32)
		buff.apply_slow(-0.4, 2.5)  # 负减速 = 加速（get_speed_multiplier 返回 1.4）

func _special_attack(player: Node) -> void:
	boss_skill_toggle = (boss_skill_toggle + 1) % 4
	# 第 4 招：该 Boss 种类固定的「究极大招」。
	if boss_skill_toggle == 3:
		_start_ultimate(ultimate_id, player)
		return
	special_timer = 5.8
	attack_timer = 1.0
	Audio.sfx_at("fire", global_position, 0.0, 0.7)
	if main == null:
		return
	match boss_skill_toggle:
		0:
			# 荣耀震荡：范围冲击 + 击退
			main.flash_message("Boss 释放：荣耀震荡")
			main.combat.apply_player_area_damage(global_position, 6.4, attack + 18)
			main.spawn_skill_flash(global_position + Vector3(0, 0.5, 0), Color(1.0, 0.18, 0.10, 1), 6.2, 0.45)
			var away: Vector3 = (player.global_position - global_position)
			away.y = 0
			if away.length() > 0.01:
				velocity.x = away.normalized().x * speed * 4.0
				velocity.z = away.normalized().z * speed * 4.0
		1:
			# 焰弹扇形齐射
			main.flash_message("Boss 释放：流焰齐射")
			for s in [-0.32, -0.16, 0.0, 0.16, 0.32]:
				_shoot_at(player, attack + 10, 16.0, Color(1.0, 0.4, 0.12, 1), s)
			main.spawn_skill_flash(global_position + Vector3(0, 1.6, 0), Color(1.0, 0.45, 0.12, 1), 2.0, 0.22)
		2:
			# 落地火环：大范围灼烧
			main.flash_message("Boss 释放：赤色火环")
			main.combat.apply_player_area_damage(global_position, 9.0, attack + 12)
			main.spawn_skill_flash(global_position + Vector3(0, 0.4, 0), Color(1.0, 0.3, 0.06, 1), 9.0, 0.55)

# ================= Boss 连招「天崩冲锋」（单机权威；联机由服务器驱动位移、本端仅表现）=================

func _start_combo(player: Node) -> void:
	if player == null or not is_instance_valid(player):
		special_timer = 4.0
		return
	combo_active = true
	combo_phase = 1
	combo_timer = 0.0
	combo_charge_idx = 0
	combo_phantoms.clear()
	combo_start_pos = global_position
	var pp: Vector3 = (player as Node3D).global_position
	var dir: Vector3 = Vector3(pp.x - global_position.x, 0, pp.z - global_position.z)
	dir = dir.normalized() if dir.length() > 0.05 else Vector3(0, 0, 1)
	if visual != null:
		visual.look_at(global_position + dir, Vector3.UP)
	var apex_xz: Vector2 = Vector2(global_position.x, global_position.z).lerp(Vector2(pp.x, pp.z), 0.5)
	combo_apex = Vector3(apex_xz.x, COMBO_LEAP_H, apex_xz.y)
	special_timer = 14.0
	attack_timer = 1.0
	velocity = Vector3.ZERO
	external_velocity = Vector3.ZERO
	external_timer = 0.0
	if main != null:
		main.flash_message("Boss 释放：天崩冲锋！")
	Audio.sfx_at("fire", global_position, 0.0, 0.7)

func _combo_enter(phase: int) -> void:
	combo_phase = phase
	combo_timer = 0.0

func _combo_process(delta: float, player: StarGloryPlayer) -> void:
	combo_timer += delta
	var pp: Vector3 = player.global_position if (player != null and is_instance_valid(player)) else last_known
	if visual != null and combo_phase != 1:
		var face: Vector3 = Vector3(pp.x - global_position.x, 0, pp.z - global_position.z)
		if face.length() > 0.1:
			visual.look_at(global_position + face.normalized(), Vector3.UP)
	match combo_phase:
		1:  # 跃起：朝玩家方向高高跃起
			var t: float = clampf(combo_timer / COMBO_LEAP_T, 0.0, 1.0)
			var flat: Vector3 = combo_start_pos.lerp(Vector3(combo_apex.x, combo_start_pos.y, combo_apex.z), t)
			global_position = Vector3(flat.x, lerpf(combo_start_pos.y, COMBO_LEAP_H, sin(t * PI * 0.5)), flat.z)
			_combo_afterimage(delta)
			if combo_timer >= COMBO_LEAP_T:
				_combo_enter(2)
		2:  # 停留：空中短暂悬停
			global_position = combo_apex + Vector3(0, sin(combo_timer * 9.0) * 0.1, 0)
			if combo_timer >= COMBO_HOVER_T:
				# 锁定砸点 = 当前目标脚下，起标记/表现（联机由服务器 combo_start 驱动表现）
				combo_center = Vector3(pp.x, COMBO_GROUND_Y, pp.z)
				combo_seed = rng.randi()
				_spawn_onslaught(combo_center, combo_seed)
				_combo_enter(3)
		3:  # 砸下：加速坠向砸点
			var t3: float = clampf(combo_timer / COMBO_SLAM_T, 0.0, 1.0)
			var land: Vector3 = Vector3(combo_center.x, COMBO_GROUND_Y, combo_center.z)
			global_position = combo_apex.lerp(land, t3 * t3)
			_combo_afterimage(delta)
			if combo_timer >= COMBO_SLAM_T:
				_do_slam_damage()
				_build_phantom_positions()
				combo_charge_idx = 0
				_begin_charge(player)
				_combo_enter(4)
		4:  # 连续冲锋：随机虚影→冲锋攻击玩家→落入另一虚影
			var t4: float = clampf(combo_timer / COMBO_CHARGE_T, 0.0, 1.0)
			global_position = combo_from.lerp(combo_to, t4)
			_combo_afterimage(delta)
			if t4 >= 0.5 and not combo_charge_hit_done:
				combo_charge_hit_done = true
				_do_charge_damage(global_position)
			if combo_timer >= COMBO_CHARGE_T + COMBO_CHARGE_GAP:
				combo_charge_idx += 1
				if combo_charge_idx >= COMBO_CHARGES:
					_end_combo()
				else:
					_begin_charge(player)
					combo_timer = 0.0

func _build_phantom_positions() -> void:
	combo_phantoms.clear()
	var base_ang: float = float(combo_seed % 360) * (PI / 180.0)
	for i: int in range(4):
		var a: float = base_ang + TAU * float(i) / 4.0
		combo_phantoms.append(combo_center + Vector3(cos(a), 0, sin(a)) * COMBO_PHANTOM_R)
	# 第 5 道残影 = 天上坠落点（砸点正上方）；冲锋可冲向/冲出高空。
	combo_phantoms.append(combo_center + Vector3(0, COMBO_LEAP_H, 0))

func _begin_charge(player: Node) -> void:
	combo_charge_hit_done = false
	combo_timer = 0.0
	if combo_phantoms.is_empty():
		_end_combo()
		return
	var from_i: int = rng.randi_range(0, combo_phantoms.size() - 1)
	combo_from = combo_phantoms[from_i]   # 保留虚影自身高度（空中残影 y=LEAP_H）
	# 落点虚影：选「让冲锋线穿过玩家」的那个，确保冲锋攻击到玩家。
	var pp: Vector3 = (player as Node3D).global_position if (player != null and is_instance_valid(player)) else combo_center
	var want: Vector3 = Vector3(pp.x - combo_from.x, 0, pp.z - combo_from.z)
	want = want.normalized() if want.length() > 0.05 else Vector3(0, 0, 1)
	var best_i: int = from_i
	var best_dot: float = -2.0
	for i: int in range(combo_phantoms.size()):
		if i == from_i:
			continue
		var d: Vector3 = combo_phantoms[i] - combo_from
		d.y = 0
		if d.length() < 0.05:
			continue
		var dot: float = d.normalized().dot(want)
		if dot > best_dot:
			best_dot = dot
			best_i = i
	combo_to = combo_phantoms[best_i]
	global_position = combo_from   # 瞬移到起始虚影（傀儡端 >6m 自动吸附）

func _do_slam_damage() -> void:
	if main == null or main.combat == null:
		return
	var dmg: int = int(float(attack + 22) * ult_power)
	main.combat.apply_area_damage(combo_center, COMBO_SLAM_R, dmg, self, 0.0, 8.0)  # 友伤：其他怪物/建筑
	main.combat.apply_player_area_damage(combo_center, COMBO_SLAM_R, dmg)

func _do_charge_damage(center: Vector3) -> void:
	if main == null or main.combat == null:
		return
	var dmg: int = int((float(attack) * 0.6 + 2.0) * ult_power)
	main.combat.apply_area_damage(center, COMBO_CHARGE_R, dmg, self)   # 友伤：其他怪物/建筑
	main.combat.apply_player_area_damage(center, COMBO_CHARGE_R, dmg)
	# 命中玩家：硬控浮空 0.1s，0.5s 后在命中点落下缩小天星。
	var pl: StarGloryPlayer = main.player
	if pl != null and is_instance_valid(pl) and pl.hp > 0.0:
		var flat: float = Vector2(pl.global_position.x - center.x, pl.global_position.z - center.z).length()
		if flat <= COMBO_CHARGE_R + 0.8:
			pl.apply_forced_knockback(center, 3.0, 5.0, 0.2)
			if pl.buff != null:
				pl.buff.apply_stun(0.1)
			var hit_pos: Vector3 = pl.global_position
			get_tree().create_timer(0.5).timeout.connect(_spawn_mini_meteor.bind(hit_pos))

func _spawn_mini_meteor(pos: Vector3) -> void:
	if main == null or not is_instance_valid(self):
		return
	var mm: Node3D = MiniMeteorScene.new()
	var root: Node = main.effect_root if main.effect_root != null else main
	root.add_child(mm)
	mm.start(main, self, pos, int(float(attack + 10) * ult_power), world_level, false)

func _end_combo() -> void:
	combo_active = false
	combo_phase = 0
	combo_phantoms.clear()
	global_position.y = COMBO_GROUND_Y
	velocity = Vector3.ZERO

func _combo_afterimage(delta: float) -> void:
	_after_acc -= delta
	if _after_acc <= 0.0:
		_after_acc = 0.04
		spawn_afterimage()

# 联机傀儡：收到连招表现事件后播放纯表现（位移/伤害由服务器权威）。
func play_combo_visual(info: Dictionary) -> void:
	var c: Vector3 = info.get("center", global_position)
	c.y = max(0.0, c.y)
	var root: Node = main.effect_root if (main != null and main.effect_root != null) else main
	if root == null:
		return
	match String(info.get("kind", "combo")):
		"mini_meteor":
			var mm: Node3D = MiniMeteorScene.new()
			root.add_child(mm)
			mm.start(main, self, c, 0, world_level, true)   # visual_only：伤害/控制由服务器结算
		"lightning":
			var lc: Node3D = LightningChannelScene.new()
			root.add_child(lc)
			lc.start(main, self, c, float(info.get("radius", LIGHT_R)), float(info.get("duration", LIGHT_T)), int(info.get("seed", 0)), true)
		"summon":
			if main.has_method("spawn_skill_flash"):
				main.spawn_skill_flash(c + Vector3(0, 0.8, 0), Color(0.7, 0.3, 1.0, 1), 5.0, 0.6)
		"heal_pulse":
			if main.has_method("spawn_skill_flash"):
				main.spawn_skill_flash(c + Vector3(0, 0.8, 0), Color(0.4, 1.0, 0.55, 1), float(info.get("radius", HEAL_R)), 0.4)
		"giant":
			var gj: Node3D = GiantJudgmentScene.new()
			root.add_child(gj)
			gj.start(main, self, c, info.get("dir", Vector3(0, 0, 1)), float(info.get("len", JUDG_BEAM_LEN)), float(info.get("width", JUDG_BEAM_W)), float(info.get("charge_t", JUDG_CHARGE_T)), float(info.get("slam_t", JUDG_SLAM_T)), float(info.get("beam_t", JUDG_BEAM_T)))
		"barrage":
			var bg: Node3D = SkyBarrageScene.new()
			root.add_child(bg)
			bg.start(main, self, int(info.get("sub", 1)), c, info.get("target", c), int(info.get("seed", 0)), int(info.get("atk", attack)), world_level)
		"danmaku":
			var ds2: Node3D = DanmakuSpellScene.new()
			root.add_child(ds2)
			ds2.start(main, self, String(info.get("pat", "spiral")), c, info.get("target", c), int(info.get("seed", 0)), int(info.get("atk", attack)), world_level)
		_:
			_spawn_onslaught(c, int(info.get("seed", 0)))

# Boss 弹幕术式：循环施放术式列表，从怪物处释放，锁定玩家当前位置。
func _start_danmaku(player: Node) -> void:
	if main == null or danmaku_list.is_empty():
		return
	var pat: String = String(danmaku_list[danmaku_idx % danmaku_list.size()])
	danmaku_idx += 1
	var org: Vector3 = global_position + Vector3(0, 1.4, 0)
	var tgt: Vector3 = org + Vector3(0, 0, 1) * 10.0
	if player != null and is_instance_valid(player):
		tgt = (player as Node3D).global_position
	var root: Node = main.effect_root if main.effect_root != null else main
	var ds: Node3D = DanmakuSpellScene.new()
	root.add_child(ds)
	ds.start(main, self, pat, org, tgt, rng.randi(), attack, world_level)
	Audio.sfx_at("magic", global_position, 0.0, 1.0)

# 飞天弹幕：循环三套弹幕，从怪物处释放，锁定玩家当前位置（非追踪）。
func _start_barrage(player: Node) -> void:
	if main == null:
		return
	barrage_sub = (barrage_sub % 3) + 1
	var origin: Vector3 = global_position + Vector3(0, 0.6, 0)
	var tgt: Vector3 = origin + Vector3(0, 0, 1) * 10.0
	if player != null and is_instance_valid(player):
		tgt = (player as Node3D).global_position
	var root: Node = main.effect_root if main.effect_root != null else main
	var bg: Node3D = SkyBarrageScene.new()
	root.add_child(bg)
	bg.start(main, self, barrage_sub, origin, tgt, rng.randi(), attack, world_level)
	Audio.sfx_at("magic", global_position, 0.0, 0.9)

# 统一究极分发（Boss 第4槽 与 精英弱化版 共用）。防级联：被召唤者不开重型大招。
func _start_ultimate(uid: int, player: Node) -> void:
	var ult: int = uid
	if is_summoned and ult >= 2:
		ult = 0
	match ult:
		1: _start_lightning(player)
		2: _start_summon(player)
		3: _start_judgment(player)
		_: _start_combo(player)

# ================= 究极大招：雷霆引导（单机权威） =================

# 按位置确定性分配究极大招（按象限取模），便于不同区域 Boss 差异化。
func _ultimate_for_pos(p: Vector3) -> int:
	var q: int = (0 if p.x >= 0.0 else 1) + (0 if p.z >= 0.0 else 2)
	return q % ULTIMATE_COUNT

func _start_lightning(player: Node) -> void:
	lightning_active = true
	lightning_timer = 0.0
	special_timer = 14.0
	attack_timer = 1.0
	velocity = Vector3.ZERO
	external_velocity = Vector3.ZERO
	external_timer = 0.0
	if main != null:
		main.flash_message("Boss 引导：雷霆审判！范围内将被雷击锁定。")
		var root: Node = main.effect_root if main.effect_root != null else main
		var lc: Node3D = LightningChannelScene.new()
		root.add_child(lc)
		lc.start(main, self, global_position, LIGHT_R, LIGHT_T, rng.randi(), false)
	Audio.sfx_at("magic", global_position, 0.0, 0.7)

func _lightning_process(delta: float, player: StarGloryPlayer) -> void:
	lightning_timer += delta
	if lightning_timer >= LIGHT_T:
		_do_lightning_strike(player)
		lightning_active = false

func _do_lightning_strike(player: StarGloryPlayer) -> void:
	if main == null or main.combat == null:
		return
	# 锁定级雷电：引导越久伤害越高（满引导 = base + growth）；命中范围内玩家 + 减速。
	var dmg: int = int((attack + 10 + float(attack) * 0.9 * clampf(lightning_timer / LIGHT_T, 0.0, 1.0)) * ult_power)
	if player != null and is_instance_valid(player) and player.hp > 0.0:
		var d: float = Vector2(player.global_position.x - global_position.x, player.global_position.z - global_position.z).length()
		if d <= LIGHT_R:
			main.combat.damage(player, dmg, main)
			if player.buff != null:
				player.buff.apply_slow(0.4, 3.0)

# ================= 究极大招：召唤军团（单机权威） =================

func _start_summon(player: Node) -> void:
	special_timer = 16.0
	attack_timer = 1.0
	if main == null:
		return
	var wl: int = world_level
	var count: int = maxi(1, int(clampi(3 + int(wl / 3), 3, 6) * ult_power))
	var summon_wl: int = wl + 1
	var speed_mul: float = minf(1.5, 1.0 + 0.04 * float(wl - 1))
	# 身后方向 = 远离当前目标玩家。
	var back: Vector3 = Vector3(0, 0, 1)
	if player != null and is_instance_valid(player):
		var to_p: Vector3 = Vector3(player.global_position.x - global_position.x, 0, player.global_position.z - global_position.z)
		if to_p.length() > 0.1:
			back = -to_p.normalized()
	main.flash_message("Boss 召唤军团参战！")
	Audio.sfx_at("magic", global_position, 0.0, 0.6)
	var base: Vector3 = global_position + back * 4.0
	for kind: String in SUMMON_KINDS:
		for i in range(count):
			if main.has_method("_summoned_monster_count") and main._summoned_monster_count() >= 18:
				return
			if main.has_method("_live_monster_count") and main._live_monster_count(false) >= 72:
				return
			var spawn_kind: String = kind
			if wl >= SUMMON_BOSS_WL and rng.randf() < 0.15:
				spawn_kind = "boss"
			var off: Vector3 = back * rng.randf_range(0.0, 4.0) + Vector3(rng.randf_range(-4.0, 4.0), 0, rng.randf_range(-4.0, 4.0))
			var pos: Vector3 = base + off
			pos.y = 0.3
			var m: StarGloryMonster = main._spawn_monster(spawn_kind, pos, false, summon_wl)
			if m != null and is_instance_valid(m):
				m.is_summoned = true
				m.summon_ttl = 45.0
				m.speed *= speed_mul
			main.spawn_skill_flash(pos + Vector3(0, 0.6, 0), Color(0.7, 0.3, 1.0, 1), 1.6, 0.4)

# 奶妈 AI：贴近最近友军，周期治疗 + 加速光环（不攻击玩家）。
func _healer_ai(delta: float) -> void:
	_heal_timer = max(0.0, _heal_timer - delta)
	var ally: Node3D = _nearest_ally()
	var move_dir: Vector3 = Vector3.ZERO
	if ally != null:
		var to_a: Vector3 = ally.global_position - global_position
		to_a.y = 0.0
		if to_a.length() > 4.0:
			move_dir = to_a.normalized()
	var sm: float = buff.get_speed_multiplier() if buff != null else 1.0
	if move_dir.length() > 0.01:
		velocity.x = move_dir.x * speed * sm
		velocity.z = move_dir.z * speed * sm
		if visual != null:
			visual.look_at(global_position + move_dir, Vector3.UP)
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed * 4.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, speed * 4.0 * delta)
	if not is_on_floor():
		velocity.y -= 28.0 * delta
	else:
		velocity.y = -0.05
	_apply_external_velocity(delta)
	move_and_slide()
	if main != null:
		global_position.x = clamp(global_position.x, -main.map_radius + 1.0, main.map_radius - 1.0)
		global_position.z = clamp(global_position.z, -main.map_radius + 1.0, main.map_radius - 1.0)
	if _heal_timer <= 0.0:
		_heal_timer = HEAL_INTERVAL
		_do_heal_pulse()

func _nearest_ally() -> Node3D:
	if main == null:
		return null
	var best: Node3D = null
	var bd: float = INF
	for node in main.monsters:
		var m: StarGloryMonster = node as StarGloryMonster
		if m == null or not is_instance_valid(m) or m.dead or m == self or m.is_healer:
			continue
		var d: float = global_position.distance_to(m.global_position)
		if d < bd:
			bd = d
			best = m
	return best

func _do_heal_pulse() -> void:
	if main == null:
		return
	for node in main.monsters:
		var m: StarGloryMonster = node as StarGloryMonster
		if m == null or not is_instance_valid(m) or m.dead or m == self:
			continue
		if global_position.distance_to(m.global_position) <= HEAL_R:
			m.hp = min(float(m.max_hp), m.hp + float(m.max_hp) * HEAL_PCT)
			if m.buff != null:
				m.buff.apply_slow(-0.25, 2.0)   # 负值=加速
	# 自疗
	hp = min(float(max_hp), hp + float(max_hp) * HEAL_PCT)
	main.spawn_skill_flash(global_position + Vector3(0, 0.8, 0), Color(0.4, 1.0, 0.55, 1), HEAL_R, 0.4)

# ================= 究极大招：巨兵天罚（单机权威） =================

func _start_judgment(player: Node) -> void:
	judg_active = true
	judg_phase = 1
	judg_timer = 0.0
	judg_beam_acc = 0.0
	judg_origin = Vector3(global_position.x, 0.0, global_position.z)
	judg_dir = Vector3(0, 0, 1)
	if player != null and is_instance_valid(player):
		var to_p: Vector3 = Vector3(player.global_position.x - global_position.x, 0, player.global_position.z - global_position.z)
		if to_p.length() > 0.1:
			judg_dir = to_p.normalized()
	special_timer = 16.0
	attack_timer = 1.0
	velocity = Vector3.ZERO
	if main != null:
		main.flash_message("Boss 蓄力：巨兵天罚！")
		var root: Node = main.effect_root if main.effect_root != null else main
		var fx: Node3D = GiantJudgmentScene.new()
		root.add_child(fx)
		fx.start(main, self, judg_origin, judg_dir, JUDG_BEAM_LEN, JUDG_BEAM_W, JUDG_CHARGE_T, JUDG_SLAM_T, JUDG_BEAM_T)
	Audio.sfx_at("magic", global_position, 0.0, 0.6)

func _judgment_process(delta: float, player: StarGloryPlayer) -> void:
	judg_timer += delta
	match judg_phase:
		1:  # 蓄力：方向已在起手锁定（与视觉一致），站桩等待。
			if visual != null:
				visual.look_at(global_position + judg_dir, Vector3.UP)
			if judg_timer >= JUDG_CHARGE_T:
				judg_phase = 2
				judg_timer = 0.0
		2:  # 砸落：到时结算击飞。
			if judg_timer >= JUDG_SLAM_T:
				_judg_slam()
				judg_phase = 3
				judg_timer = 0.0
				judg_beam_acc = 0.0
		3:  # 激光：周期贯穿衰减伤害。
			judg_beam_acc -= delta
			if judg_beam_acc <= 0.0:
				judg_beam_acc = JUDG_BEAM_TICK
				_judg_beam_tick()
			if judg_timer >= JUDG_BEAM_T:
				judg_active = false
				judg_phase = 0

# 矩形(沿 judg_dir, 长 JUDG_BEAM_LEN, 宽 JUDG_BEAM_W)内命中判定 + 沿向距离。
func _beam_along(p: Vector3) -> float:
	var v: Vector3 = Vector3(p.x - judg_origin.x, 0, p.z - judg_origin.z)
	return v.dot(judg_dir)

func _beam_hit(p: Vector3) -> bool:
	var v: Vector3 = Vector3(p.x - judg_origin.x, 0, p.z - judg_origin.z)
	var along: float = v.dot(judg_dir)
	if along < 0.0 or along > JUDG_BEAM_LEN:
		return false
	var perp: float = (v - judg_dir * along).length()
	return perp <= JUDG_BEAM_W * 0.5

func _judg_slam() -> void:
	if main == null or main.combat == null:
		return
	var dmg: int = int(float(attack + 20) * ult_power)
	for node in main.monsters.duplicate():
		var m: StarGloryMonster = node as StarGloryMonster
		if m == null or not is_instance_valid(m) or m.dead or m == self:
			continue
		if _beam_hit(m.global_position):
			main.combat.damage(m, dmg, self)
			if is_instance_valid(m) and not m.dead and m.has_method("apply_forced_knockback"):
				m.apply_forced_knockback(m.global_position - judg_dir, 4.0, 6.0, 0.4)
	var pl: StarGloryPlayer = main.player
	if pl != null and is_instance_valid(pl) and pl.hp > 0.0 and _beam_hit(pl.global_position):
		main.combat.damage(pl, dmg, main)
		pl.apply_forced_knockback(pl.global_position - judg_dir, 4.0, 6.0, 0.4)

func _judg_beam_tick() -> void:
	if main == null or main.combat == null:
		return
	# 收集命中目标（玩家+怪物），按沿向距离排序，逐个穿透衰减。
	var targets: Array = []
	for node in main.monsters.duplicate():
		var m: StarGloryMonster = node as StarGloryMonster
		if m == null or not is_instance_valid(m) or m.dead or m == self:
			continue
		if _beam_hit(m.global_position):
			targets.append(m)
	var pl: StarGloryPlayer = main.player
	if pl != null and is_instance_valid(pl) and pl.hp > 0.0 and _beam_hit(pl.global_position):
		targets.append(pl)
	targets.sort_custom(func(a, b): return _beam_along((a as Node3D).global_position) < _beam_along((b as Node3D).global_position))
	var base: float = float(attack) * 0.7 * ult_power
	for i in range(targets.size()):
		var dmg: int = int(maxf(base * 0.3, base * pow(JUDG_DECAY, float(i))))
		var t: Node = targets[i]
		if t == pl:
			main.combat.damage(pl, dmg, main)
		else:
			main.combat.damage(t, dmg, self)

func _spawn_onslaught(center: Vector3, seed_val: int) -> void:
	if main == null:
		return
	var fx: Node3D = BossOnslaughtScene.new()
	var root: Node = main.effect_root if main.effect_root != null else main
	root.add_child(fx)
	fx.start(main, self, center, seed_val)

# 残影：克隆本体外观为半透明幽灵，渐隐后自毁。单机连招与联机傀儡冲锋共用。
func spawn_afterimage() -> void:
	if visual == null or main == null:
		return
	var ghost: Node3D = visual.duplicate() as Node3D
	if ghost == null:
		return
	var mats: Array = []
	_ghostify_afterimage(ghost, mats)
	var root: Node = main.effect_root if main.effect_root != null else main
	root.add_child(ghost)
	ghost.global_transform = visual.global_transform
	# tween 绑在幽灵自身（而非本怪），即便本怪中途死亡也能渐隐并回收。
	var tw: Tween = ghost.create_tween()
	for m: StandardMaterial3D in mats:
		tw.parallel().tween_property(m, "albedo_color:a", 0.0, 0.35)
	tw.tween_callback(ghost.queue_free)
	# 兜底：无论 tween 是否异常，0.6s 后强制回收。
	get_tree().create_timer(0.6).timeout.connect(func() -> void:
		if is_instance_valid(ghost):
			ghost.queue_free())

func _ghostify_afterimage(node: Node, out_mats: Array) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		var gm := StandardMaterial3D.new()
		gm.albedo_color = Color(0.5, 0.85, 1.0, 0.42)
		gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		gm.emission_enabled = true
		gm.emission = Color(0.5, 0.85, 1.0, 1)
		gm.emission_energy_multiplier = 1.0
		mi.material_override = gm
		out_mats.append(gm)
	for c: Node in node.get_children():
		_ghostify_afterimage(c, out_mats)

# 玩家造成伤害时按吸血比例回血。
func _apply_lifesteal(dmg: int, source: Node) -> void:
	if source == null or not is_instance_valid(source) or main == null:
		return
	if main.player == null or source != main.player or main.player.lifesteal <= 0.0:
		return
	var heal: int = maxi(1, int(round(float(dmg) * main.player.lifesteal)))
	main.player.hp = minf(float(main.player.max_hp), main.player.hp + float(heal))

func take_damage(amount: int, source: Node = null) -> void:
	if dead:
		return
	Audio.sfx_at("hit", global_position, -4.0, randf_range(0.95, 1.1))
	# 打击感：命中处白色火花；玩家出手时轻微震屏。
	if main != null:
		var _fy: float = (3.0 if is_boss else aim_height * 0.9)
		if main.has_method("spawn_skill_flash"):
			main.spawn_skill_flash(global_position + Vector3(randf_range(-0.3, 0.3), _fy, randf_range(-0.3, 0.3)), Color(1, 1, 1, 1), 0.85, 0.09)
		if source is StarGloryPlayer and main.has_method("shake_at"):
			main.shake_at(global_position, 0.1)
	# 联机：怪物是傀儡 → 把伤害上报服务器（权威），本地不结算血量；仅显示飘字。
	if is_puppet:
		if Net.online:
			Net.report_monster_damage(net_id, amount)
		_apply_lifesteal(amount, source)
		if main != null:
			main.flash_damage(global_position + Vector3(0, 1.6 if not is_boss else 3.2, 0), "-%d" % amount, Color(1.0, 0.95, 0.45, 1))
		return
	var final_damage: int = max(1, amount - defense)
	if buff != null and buff.is_frozen():
		final_damage = int(final_damage * buff.frozen_damage_mult())
	hp -= final_damage
	_apply_lifesteal(final_damage, source)
	hurt_aggro_timer = 7.0
	# 被命中：自己锁定攻击者，并把仇恨示警给附近同伴（同伴被击中则一起仇恨该玩家）。
	if is_instance_valid(source) and source is StarGloryPlayer:
		has_target = true
		last_known = (source as Node3D).global_position
		if is_boss and fight_start_ms == 0:
			fight_start_ms = Time.get_ticks_msec()   # 记录与该 Boss 的交战起点
		if main != null:
			if main.has_method("mark_combat"):
				main.mark_combat()
			if main.has_method("aggro_nearby"):
				main.aggro_nearby(global_position, source, detect_radius * 1.2)
	if main != null:
		main.flash_damage(global_position + Vector3(0, 1.6 if not is_boss else 3.2, 0), "-%d" % final_damage, Color(1.0, 0.95, 0.45, 1))
	if is_instance_valid(source) and global_position.distance_to(source.global_position) > 0.2:
		var knock: Vector3 = (global_position - source.global_position)
		knock.y = 0
		if knock.length() > 0.01:
			velocity.x += knock.normalized().x * 1.5
			velocity.z += knock.normalized().z * 1.5
	if hp <= 0.0:
		dead = true
		if main != null:
			main.on_monster_died(self)

# 灼烧由 BuffComponent 持续推进；此处只负责施加时的视觉反馈并登记状态。
func apply_burn(damage_per_tick: int, duration: float, source: Node = null) -> void:
	if dead:
		return
	buff.apply_burn(damage_per_tick, duration, source)
	if main != null:
		main.spawn_skill_flash(global_position + Vector3(0, 0.7 if not is_boss else 1.5, 0), Color(1.0, 0.25, 0.05, 1), 0.8 if not is_boss else 1.6, 0.18)

# 持续伤害(DoT)单跳结算入口，由 CombatManager.apply_dot 调用（BuffComponent 驱动时序）。
func receive_dot(damage: int, _source: Node = null) -> void:
	if dead:
		return
	if is_puppet:
		if Net.online:
			Net.report_monster_damage(net_id, damage)
		if main != null:
			main.flash_damage(global_position + Vector3(0, 1.75 if not is_boss else 3.35, 0), "灼烧 -%d" % damage, Color(1.0, 0.42, 0.12, 1))
		return
	var final_damage: int = max(1, damage - int(float(defense) * 0.35))
	if buff != null and buff.is_frozen():
		final_damage = int(final_damage * buff.frozen_damage_mult())
	hp -= final_damage
	hurt_aggro_timer = 7.0
	if main != null:
		main.flash_damage(global_position + Vector3(0, 1.75 if not is_boss else 3.35, 0), "灼烧 -%d" % final_damage, Color(1.0, 0.42, 0.12, 1))
	if hp <= 0.0:
		dead = true
		if main != null:
			main.on_monster_died(self)

func apply_slow(power: float, duration: float) -> void:
	buff.apply_slow(power, duration)

func hp_ratio() -> float:
	return clamp(hp / float(max_hp), 0.0, 1.0)
