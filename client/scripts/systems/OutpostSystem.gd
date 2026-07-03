extends Node
class_name OutpostSystem

# 安全区/攻城系统。用基础模型搭建的据点（带城墙：HP/防御/等级）。
# - 进入据点半径内且该据点无破损 → 玩家绝对安全（免伤，由 Player.take_damage 查询）。
# - 怪物周期性集群攻城：在城墙外刷一波怪，聚在墙边持续削减城墙 HP。
# - 城墙被打破 → 该段成为缺口，据点失去安全；玩家走到缺口按 E 读条重建，完成后恢复安全。
# 单机：本系统本地权威（刷怪/掉血/攻破/重建）。
# 联机：服务器权威，本地仅按同步渲染城墙状态，并把重建请求上报服务器。

var main: Node = null

# 3 个据点定义（中心/半径/等级）。城墙布局由中心确定性生成，客户端与服务器一致。
# 与服务器 OP_DEFS 几何一致。half=半边长（新手村大）。4 面各中央留门 → 8 段墙 + 护城河 + 索桥。
const OUTPOSTS := [
	{"id": 0, "name": "新手村", "center": Vector3(0, 0, 20), "half": 28.0, "level": 1},
	{"id": 1, "name": "西境壁垒", "center": Vector3(-56, 0, -30), "half": 12.0, "level": 2},
	{"id": 2, "name": "东岭关城", "center": Vector3(58, 0, -16), "half": 12.0, "level": 3},
]
const WALL_H := 5.0
const GATE_HALF := 4.0     # 门洞半宽（开口=8）
const MOAT_W := 6.0        # 护城河宽
const SIEGE_HOUR := 20
const DEF_SCROLL_COST := 3
const REBUILD_TIME := 5.0
const SEG_HP_BASE := 2000.0   # 城墙血量（高强度，与服务器一致）
const REPAIR_COST := {"寒霜晶矿": 8}   # 单机每段城墙缺口重建所需材料

func _mat_owned(k: String) -> int:
	return main.inv.material_count(k) if main.inv != null else 0
func _afford(cost: Dictionary) -> bool:
	for k: String in cost.keys():
		if _mat_owned(k) < int(cost[k]):
			return false
	return true
func _pay(cost: Dictionary) -> void:
	for k: String in cost.keys():
		main.inv.consume_material(k, int(cost[k]))
# 「材料×需要（有拥有）」文字，供重建提示。
func _cost_owned_str(cost: Dictionary) -> String:
	var parts: Array = []
	for k: String in cost.keys():
		parts.append("%s×%d（有%d）" % [k, int(cost[k]), _mat_owned(k)])
	return "、".join(PackedStringArray(parts))
func _cost_str_simple(cost: Dictionary) -> String:
	var parts: Array = []
	for k: String in cost.keys():
		parts.append("%s×%d" % [k, int(cost[k])])
	return "、".join(PackedStringArray(parts))

var outposts: Array = []       # 运行态 [{def, breached, segs:[...]}]
var _last_siege_day: String = ""
var _siege_units: Array = []   # 单机攻城怪 [{mon, op, seg}]
# 重建读条
var rebuild_seg: Dictionary = {}
var rebuild_progress: float = 0.0

var _hint: Label = null

func setup(p_main: Node) -> void:
	main = p_main
	_build_all()
	var cl := CanvasLayer.new()
	add_child(cl)
	_hint = Label.new()
	_hint.anchor_left = 0.5; _hint.anchor_right = 0.5; _hint.anchor_top = 1.0; _hint.anchor_bottom = 1.0
	_hint.offset_left = -220; _hint.offset_right = 220; _hint.offset_top = -120; _hint.offset_bottom = -92
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 22)
	_hint.add_theme_color_override("font_color", Color(0.6, 1.0, 0.75, 1))
	_hint.add_theme_constant_override("outline_size", 6)
	_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	cl.add_child(_hint)

# ---------------- 建造 ----------------
# 8 段墙（4 面 × 2 半，中央留门），顺序与服务器一致。返回 [{pos,size}]
func _seg_layout(center: Vector3, half: float) -> Array:
	var c: Vector3 = center
	var g: float = GATE_HALF
	var wl: float = half - g                 # 半墙长度
	var m: float = (half + g) * 0.5          # 半墙中心相对边中心的偏移
	var y: float = WALL_H * 0.5
	return [
		{"pos": c + Vector3(-m, y, -half), "size": Vector3(wl, WALL_H, 1.6)},   # 北-左
		{"pos": c + Vector3(m, y, -half), "size": Vector3(wl, WALL_H, 1.6)},    # 北-右
		{"pos": c + Vector3(-m, y, half), "size": Vector3(wl, WALL_H, 1.6)},    # 南-左
		{"pos": c + Vector3(m, y, half), "size": Vector3(wl, WALL_H, 1.6)},     # 南-右
		{"pos": c + Vector3(-half, y, -m), "size": Vector3(1.6, WALL_H, wl)},   # 西-下
		{"pos": c + Vector3(-half, y, m), "size": Vector3(1.6, WALL_H, wl)},    # 西-上
		{"pos": c + Vector3(half, y, -m), "size": Vector3(1.6, WALL_H, wl)},    # 东-下
		{"pos": c + Vector3(half, y, m), "size": Vector3(1.6, WALL_H, wl)},     # 东-上
	]

func _build_all() -> void:
	var root: Node = main.entity_root if ("entity_root" in main and main.entity_root != null) else main
	for opd_v: Variant in OUTPOSTS:
		var opd: Dictionary = opd_v
		var lvl: int = int(opd["level"])
		var half: float = float(opd["half"])
		var op: Dictionary = {"def": opd, "breached": 0, "defense_scrolls": 0, "segs": []}
		# 地面标记 + 名牌
		var lbl := Label3D.new()
		lbl.text = "🛡 %s（安全区）" % String(opd["name"])
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.font_size = 48; lbl.outline_size = 8
		lbl.modulate = Color(0.6, 1.0, 0.8, 1)
		lbl.position = (opd["center"] as Vector3) + Vector3(0, WALL_H + 3.0, 0)
		root.add_child(lbl)
		_add_moat_and_bridges(root, opd["center"] as Vector3, half)
		var si: int = 0
		for seg_v: Variant in _seg_layout(opd["center"], half):
			var segd: Dictionary = seg_v
			var maxhp: float = SEG_HP_BASE * float(lvl)
			var body := StaticBody3D.new()
			body.add_to_group("wall")
			body.add_to_group("obstacle")
			body.position = segd["pos"]
			var cs := CollisionShape3D.new()
			var box := BoxShape3D.new(); box.size = segd["size"]
			cs.shape = box
			body.add_child(cs)
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new(); bm.size = segd["size"]
			mi.mesh = bm
			mi.material_override = _wall_mat(lvl, false)
			body.add_child(mi)
			var hpbar := Label3D.new()
			hpbar.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			hpbar.font_size = 22; hpbar.outline_size = 5
			hpbar.position = Vector3(0, WALL_H * 0.5 + 0.9, 0)
			hpbar.modulate = Color(0.7, 1.0, 0.7, 1)
			hpbar.text = ""
			body.add_child(hpbar)
			root.add_child(body)
			op["segs"].append({"id": si, "body": body, "cs": cs, "mesh": mi, "hpbar": hpbar,
				"pos": segd["pos"] as Vector3, "size": segd["size"] as Vector3,
				"hp": maxhp, "max_hp": maxhp, "defense": 15 * lvl, "level": lvl, "breached": false})
			si += 1
		outposts.append(op)

func _wall_mat(lvl: int, breached: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	if breached:
		m.albedo_color = Color(0.18, 0.14, 0.12, 1)
	else:
		m.albedo_color = Color(0.42, 0.45, 0.52, 1).lerp(Color(0.5, 0.75, 1.0, 1), clampf(float(lvl - 1) / 3.0, 0.0, 1.0))
	m.emission_enabled = true
	m.emission = m.albedo_color * 0.4
	m.roughness = 0.9
	return m

# 护城河（围墙外一圈半透明水）+ 四座索桥（每面门中央跨河，可行走）。
func _add_moat_and_bridges(root: Node, c: Vector3, half: float) -> void:
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(0.14, 0.4, 0.62, 0.6)
	wmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wmat.metallic = 0.35; wmat.roughness = 0.08
	wmat.emission_enabled = true; wmat.emission = Color(0.1, 0.3, 0.5, 1); wmat.emission_energy_multiplier = 0.2
	var inner: float = half + 1.5
	var mid: float = inner + MOAT_W * 0.5
	var full: float = (inner + MOAT_W) * 2.0
	var strips := [
		{"pos": Vector3(c.x, -0.15, c.z - mid), "size": Vector3(full, 0.5, MOAT_W)},   # 北
		{"pos": Vector3(c.x, -0.15, c.z + mid), "size": Vector3(full, 0.5, MOAT_W)},   # 南
		{"pos": Vector3(c.x - mid, -0.15, c.z), "size": Vector3(MOAT_W, 0.5, inner * 2.0)},  # 西
		{"pos": Vector3(c.x + mid, -0.15, c.z), "size": Vector3(MOAT_W, 0.5, inner * 2.0)},  # 东
	]
	for s_v: Variant in strips:
		var s: Dictionary = s_v
		var w := MeshInstance3D.new()
		var bm := BoxMesh.new(); bm.size = s["size"]
		w.mesh = bm; w.material_override = wmat; w.position = s["pos"]
		root.add_child(w)
	# 四座索桥（跨河，带栏杆，走上去过河）。
	var gw: float = GATE_HALF * 2.0 + 1.0    # 桥面宽
	var bl: float = MOAT_W + 3.6             # 桥长（跨河）
	var bridges := [
		{"pos": Vector3(c.x, 0.1, c.z - mid), "size": Vector3(gw, 0.3, bl), "horiz": true},   # 北门
		{"pos": Vector3(c.x, 0.1, c.z + mid), "size": Vector3(gw, 0.3, bl), "horiz": true},   # 南门
		{"pos": Vector3(c.x - mid, 0.1, c.z), "size": Vector3(bl, 0.3, gw), "horiz": false},  # 西门
		{"pos": Vector3(c.x + mid, 0.1, c.z), "size": Vector3(bl, 0.3, gw), "horiz": false},  # 东门
	]
	var wood := StandardMaterial3D.new(); wood.albedo_color = Color(0.42, 0.28, 0.16, 1); wood.roughness = 0.85
	var rope := StandardMaterial3D.new(); rope.albedo_color = Color(0.6, 0.5, 0.32, 1)
	for b_v: Variant in bridges:
		var b: Dictionary = b_v
		var body := StaticBody3D.new()
		body.position = b["pos"]
		var cs := CollisionShape3D.new(); var box := BoxShape3D.new(); box.size = b["size"]; cs.shape = box; body.add_child(cs)
		var deck := MeshInstance3D.new(); var dm := BoxMesh.new(); dm.size = b["size"]; deck.mesh = dm; deck.material_override = wood; body.add_child(deck)
		# 两侧栏杆（索桥感）
		var sz: Vector3 = b["size"]
		for side in [-1.0, 1.0]:
			var rail := MeshInstance3D.new()
			var rm := BoxMesh.new()
			if bool(b["horiz"]):
				rm.size = Vector3(0.15, 0.9, sz.z)
				rail.position = Vector3(side * (sz.x * 0.5), 0.6, 0)
			else:
				rm.size = Vector3(sz.x, 0.9, 0.15)
				rail.position = Vector3(0, 0.6, side * (sz.z * 0.5))
			rail.mesh = rm; rail.material_override = rope; body.add_child(rail)
		root.add_child(body)

# ---------------- 每帧 ----------------
func _process(delta: float) -> void:
	if main == null:
		return
	if not Net.online:
		_sp_siege(delta)      # 单机本地权威攻城；联机由服务器驱动，客户端只渲染
	_update_hpbars()
	_update_rebuild(delta)
	if _hint != null:
		_hint.text = rebuild_prompt()

# 玩家是否处于安全区（免伤）：在某据点半径内且该据点零破损。
func is_player_safe(pos: Vector3) -> bool:
	for op_v: Variant in outposts:
		var op: Dictionary = op_v
		var c: Vector3 = op["def"]["center"]
		var h: float = float(op["def"]["half"])
		if int(op["breached"]) == 0 and absf(pos.x - c.x) <= h and absf(pos.z - c.z) <= h:
			return true
	return false

func _update_hpbars() -> void:
	for op_v: Variant in outposts:
		for seg_v: Variant in (op_v as Dictionary)["segs"]:
			var seg: Dictionary = seg_v
			var bar: Label3D = seg["hpbar"]
			if bool(seg["breached"]):
				bar.text = "⚠ 缺口·需重建"
				bar.modulate = Color(1.0, 0.5, 0.4, 1)
			elif float(seg["hp"]) < float(seg["max_hp"]):
				bar.text = "城墙 %d/%d" % [int(seg["hp"]), int(seg["max_hp"])]
				bar.modulate = Color(1.0, 0.85, 0.5, 1)
			else:
				bar.text = ""

# ---------------- 单机攻城 ----------------
func _sp_siege(delta: float) -> void:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var day_key: String = "%04d-%02d-%02d" % [int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0))]
	if int(dt.get("hour", -1)) == SIEGE_HOUR and _last_siege_day != day_key:
		_last_siege_day = day_key
		_try_daily_siege()
	# 清理死亡攻城怪 + 对城墙持续掉血
	for i in range(_siege_units.size() - 1, -1, -1):
		var u: Dictionary = _siege_units[i]
		if not is_instance_valid(u["mon"]):
			_siege_units.remove_at(i)
	for op_v: Variant in outposts:
		var op: Dictionary = op_v
		for seg_v: Variant in op["segs"]:
			var seg: Dictionary = seg_v
			if bool(seg["breached"]):
				continue
			var dps: float = 0.0
			for u_v: Variant in _siege_units:
				var u: Dictionary = u_v
				if u["seg"] != seg:
					continue
				var mon: Node3D = u["mon"]
				if is_instance_valid(mon) and mon.global_position.distance_to(seg["pos"] as Vector3) < 16.0:
					dps += maxf(2.0, float(mon.attack) - float(seg["defense"]))
			if dps > 0.0:
				seg["hp"] = float(seg["hp"]) - dps * delta
				if randf() < delta * 6.0:
					main.spawn_skill_flash((seg["pos"] as Vector3) + Vector3(randf_range(-2, 2), randf_range(-1, 1), randf_range(-2, 2)), Color(1.0, 0.7, 0.3, 1), 0.9, 0.12)
				if float(seg["hp"]) <= 0.0:
					_breach(op, seg)

func _try_daily_siege() -> void:
	var op: Dictionary = _nearest_outpost()
	if op.is_empty():
		return
	if main.inv != null and main.inv.material_count("防御卷轴") >= DEF_SCROLL_COST:
		main.inv.consume_material("防御卷轴", DEF_SCROLL_COST)
		if main.has_method("flash_message"):
			main.flash_message("消耗防御卷轴×%d，已抵御今晚 20:00 的怪物攻城。本次无奖励。" % DEF_SCROLL_COST)
		return
	_spawn_siege_wave(op)

func _spawn_siege_wave(op: Dictionary = {}) -> void:
	if not ("_spawn_monster" in main) and not main.has_method("_spawn_monster"):
		return
	# 选一个据点（离玩家最近的），选一段非门墙作为主攻目标
	if op.is_empty():
		op = _nearest_outpost()
	if op.is_empty():
		return
	var segs: Array = op["segs"]
	var seg: Dictionary = segs[randi() % segs.size()]   # 随机一段墙攻打
	var lvl: int = int(op["def"]["level"])
	var n: int = 6 + lvl * 2
	var outward: Vector3 = ((seg["pos"] as Vector3) - (op["def"]["center"] as Vector3))
	outward.y = 0
	outward = outward.normalized() if outward.length() > 0.1 else Vector3(0, 0, -1)
	var kinds := ["wolf", "slime", "archer", "mage"]
	for i in range(n):
		if main.has_method("_live_monster_count") and main._live_monster_count(false) >= 72:
			break
		var side := Vector3(-outward.z, 0, outward.x) * randf_range(-8.0, 8.0)
		var pos: Vector3 = (seg["pos"] as Vector3) + outward * randf_range(4.0, 9.0) + side
		pos.y = 0.0
		var kind: String = kinds[randi() % kinds.size()]
		var mon = main._spawn_monster(kind, pos, false, maxi(1, lvl + 1))
		if mon != null:
			_siege_units.append({"mon": mon, "op": op, "seg": seg})
	if main.has_method("flash_message"):
		main.flash_message("⚔ 集群攻城！怪物正在猛攻「%s」的城墙，守住它！" % String(op["def"]["name"]))

func _nearest_outpost() -> Dictionary:
	if main.player == null or not is_instance_valid(main.player):
		return outposts[0] if not outposts.is_empty() else {}
	var best: Dictionary = {}
	var bd: float = 1.0e9
	for op_v: Variant in outposts:
		var op: Dictionary = op_v
		var d: float = (main.player as Node3D).global_position.distance_to((op["def"]["center"]) as Vector3)
		if d < bd:
			bd = d; best = op
	return best

# ---------------- 攻破 / 重建 ----------------
func _breach(op: Dictionary, seg: Dictionary) -> void:
	if bool(seg["breached"]):
		return
	seg["breached"] = true
	seg["hp"] = 0.0
	op["breached"] = int(op["breached"]) + 1
	(seg["cs"] as CollisionShape3D).disabled = true
	var mi: MeshInstance3D = seg["mesh"]
	mi.material_override = _wall_mat(int(seg["level"]), true)
	mi.scale = Vector3(1, 0.28, 1)              # 塌成矮墙碎块
	mi.position = Vector3(0, -WALL_H * 0.34, 0)
	if main.has_method("shake_at"):
		main.shake_at(seg["pos"] as Vector3, 0.5)
	if main.has_method("spawn_skill_flash"):
		main.spawn_skill_flash(seg["pos"] as Vector3, Color(1.0, 0.5, 0.2, 1), 4.0, 0.4)
	if main.has_method("flash_message"):
		main.flash_message("💥「%s」的城墙被攻破！缺口处不再安全，走到缺口按 E 重建。" % String(op["def"]["name"]))

func _restore(op: Dictionary, seg: Dictionary) -> void:
	if not bool(seg["breached"]):
		return
	seg["breached"] = false
	seg["hp"] = float(seg["max_hp"])
	op["breached"] = maxi(0, int(op["breached"]) - 1)
	(seg["cs"] as CollisionShape3D).disabled = false
	var mi: MeshInstance3D = seg["mesh"]
	mi.material_override = _wall_mat(int(seg["level"]), false)
	mi.scale = Vector3.ONE
	mi.position = Vector3.ZERO
	if main.has_method("flash_message"):
		main.flash_message("🧱「%s」的城墙已重建，安全恢复。" % String(op["def"]["name"]))

# 找玩家附近的破损段（供 Main 的 E 交互/提示用）。
func nearest_breach(pos: Vector3, dist: float = 4.5) -> Dictionary:
	for op_v: Variant in outposts:
		var op: Dictionary = op_v
		if int(op["breached"]) == 0:
			continue
		for seg_v: Variant in op["segs"]:
			var seg: Dictionary = seg_v
			if bool(seg["breached"]) and pos.distance_to(seg["pos"] as Vector3) < dist:
				return {"op": op, "seg": seg}
	return {}

# Main 在玩家按 E 且靠近破损段时调用：开始/取消读条。
func try_toggle_rebuild() -> bool:
	if main.player == null or not is_instance_valid(main.player):
		return false
	if Net.online:
		return _try_deposit()   # 联机:靠近据点捐献材料建造/加固/重建（全服共享）
	if not rebuild_seg.is_empty():
		rebuild_seg = {}; rebuild_progress = 0.0   # 再按取消
		if main.has_method("flash_message"): main.flash_message("已取消重建。")
		return true
	var hit: Dictionary = nearest_breach((main.player as Node3D).global_position)
	if hit.is_empty():
		return false
	if not _afford(REPAIR_COST):
		if main.has_method("flash_message"): main.flash_message("重建城墙缺口需要 %s，去野外采集晶矿。" % _cost_owned_str(REPAIR_COST))
		return true
	rebuild_seg = hit; rebuild_progress = 0.0
	if main.has_method("flash_message"): main.flash_message("开始重建城墙（完成消耗 %s）……保持在缺口附近。" % _cost_owned_str(REPAIR_COST))
	return true

# 联机:走到据点附近按 E → 捐献全部持有材料,服务器用来重建/加固城墙(全服共享)。
func _try_deposit() -> bool:
	var pp: Vector3 = (main.player as Node3D).global_position
	var op: Dictionary = {}
	for op_v: Variant in outposts:
		var o: Dictionary = op_v
		var c: Vector3 = o["def"]["center"]
		var h: float = float(o["def"]["half"])
		if absf(pp.x - c.x) <= h + 6.0 and absf(pp.z - c.z) <= h + 6.0:
			op = o; break
	if op.is_empty() or main.inv == null:
		return false
	var deposited: bool = false
	var parts: Array = []
	var pts: int = 0
	for mat: String in ["寒霜晶矿", "星莹水晶", "防御卷轴"]:
		var cnt: int = main.inv.material_count(mat)
		if cnt > 0:
			main.inv.consume_material(mat, cnt)
			Net.send_deposit(int(op["def"]["id"]), mat, cnt)
			deposited = true
			parts.append("%s×%d" % [mat, cnt])
			if mat != "防御卷轴":
				pts += cnt * (3 if mat == "星莹水晶" else 1)
	if deposited:
		main.flash_message("向「%s」捐献 %s（建造点+%d；防御卷轴用于抵御20点攻城）。" % [String(op["def"]["name"]), "、".join(PackedStringArray(parts)), pts])
		return true
	return false   # 无材料 → 不占用 E,让其继续拾取等（提示见墙边浮标）

func _update_rebuild(delta: float) -> void:
	if rebuild_seg.is_empty():
		return
	var seg: Dictionary = rebuild_seg["seg"]
	var op: Dictionary = rebuild_seg["op"]
	if main.player == null or not is_instance_valid(main.player) or not bool(seg["breached"]) \
			or (main.player as Node3D).global_position.distance_to(seg["pos"] as Vector3) > 5.5:
		rebuild_seg = {}; rebuild_progress = 0.0
		return
	rebuild_progress += delta
	if main.has_method("spawn_skill_flash") and randf() < delta * 4.0:
		main.spawn_skill_flash((seg["pos"] as Vector3) + Vector3(0, randf_range(0, 2), 0), Color(0.5, 1.0, 0.7, 1), 0.7, 0.12)
	if rebuild_progress >= REBUILD_TIME:
		var done: Dictionary = rebuild_seg
		rebuild_seg = {}; rebuild_progress = 0.0
		if "online" in Net and Net.online:
			Net.send_rebuild(int((done["op"]["def"])["id"]), int((done["seg"])["id"]))   # 联机：服务器权威恢复
		else:
			if not _afford(REPAIR_COST):
				if main.has_method("flash_message"): main.flash_message("材料不足，重建中止：需 %s。" % _cost_owned_str(REPAIR_COST))
				return
			_pay(REPAIR_COST)
			_restore(op, seg)
			if main.has_method("flash_message"): main.flash_message("城墙缺口已重建（消耗 %s）。" % _cost_str_simple(REPAIR_COST))

func rebuild_prompt() -> String:
	if not rebuild_seg.is_empty():
		return "重建中… %d%%（再按 E 取消） 需 %s" % [int(rebuild_progress / REBUILD_TIME * 100.0), _cost_str_simple(REPAIR_COST)]
	if main.player != null and is_instance_valid(main.player) and not nearest_breach((main.player as Node3D).global_position).is_empty():
		if Net.online:
			return "按 E 捐献材料修城墙/存防御卷轴（你有 寒霜晶矿×%d、星莹水晶×%d、防御卷轴×%d）" % [_mat_owned("寒霜晶矿"), _mat_owned("星莹水晶"), _mat_owned("防御卷轴")]
		return "按 E 重建城墙缺口 — 需 %s" % _cost_owned_str(REPAIR_COST)
	return ""

# ---------------- 联机：应用服务器同步的据点状态 ----------------
func apply_server_state(data: Array) -> void:
	# data: [{op:int, segs:[{id,hp,max,breached}]}]
	for od_v: Variant in data:
		var od: Dictionary = od_v
		var oi: int = int(od["op"])
		if oi < 0 or oi >= outposts.size():
			continue
		var op: Dictionary = outposts[oi]
		op["defense_scrolls"] = int(od.get("defense_scrolls", op.get("defense_scrolls", 0)))
		var breached_cnt: int = 0
		for sd_v: Variant in od["segs"]:
			var sd: Dictionary = sd_v
			var si: int = int(sd["id"])
			if si < 0 or si >= (op["segs"] as Array).size():
				continue
			var seg: Dictionary = (op["segs"] as Array)[si]
			seg["hp"] = float(sd["hp"]); seg["max_hp"] = float(sd["max"])
			var nb: bool = bool(sd["breached"])
			if nb:
				breached_cnt += 1
			if nb != bool(seg["breached"]):
				if nb:
					_breach(op, seg)
				else:
					_restore(op, seg)
		op["breached"] = breached_cnt
