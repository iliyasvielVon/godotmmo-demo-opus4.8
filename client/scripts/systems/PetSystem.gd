extends Node3D
class_name PetSystem

# 宠物系统（客户端个人进度，存档）。多宠物、不同形象/技能;抽卡池(蛋)获取,重复转技能书;
# 技能书升级技能;进化(消耗技能书)提升星级放大威力;十连 + 保底(每10抽必出★4+);
# 出战宠物化作跟随伙伴,提供被动(自动攻击/回血/回蓝)与主动技能(按 T 释放,有冷却)。
# 蛋/书从副本通关、常驻 Boss 概率掉落,或任务/活动赠送。按 O 打开宠物面板。

var main: Node = null
var owned: Dictionary = {}        # pet_id -> {level:int, star:int}
var active_id: String = ""
var pulls_since_high: int = 0      # 保底计数
var _companion: Node3D = null
var _atk_cd: float = 0.0
var active_cd: float = 0.0         # 主动技能冷却
var _panel: Control = null
var _grid: GridContainer = null
var _status: Label = null

const EGG := "宠物蛋"
const BOOK := "宠物技能书"
const MAX_PET_LEVEL := 10
const MAX_STAR := 5
const EVOLVE_BOOKS := 4            # 每次进化(+1星)消耗技能书
const PITY := 10                   # 每 10 抽保底 ★4+
const ACTIVE_COOLDOWN := 18.0

const POOL := [
	{"id": "firefox", "name": "火灵狐", "rarity": 3, "color": Color(1.0, 0.5, 0.2, 1), "skill": "atk", "base": 12.0, "cd": 1.4, "shape": "fox"},
	{"id": "icedeer", "name": "冰晶鹿", "rarity": 2, "color": Color(0.5, 0.9, 1.0, 1), "skill": "hp", "base": 6.0, "cd": 0.0, "shape": "deer"},
	{"id": "thunderbird", "name": "雷羽鸟", "rarity": 4, "color": Color(1.0, 0.9, 0.35, 1), "skill": "atk", "base": 16.0, "cd": 0.9, "shape": "bird"},
	{"id": "forestspirit", "name": "森语精", "rarity": 2, "color": Color(0.4, 0.9, 0.5, 1), "skill": "mp", "base": 8.0, "cd": 0.0, "shape": "spirit"},
	{"id": "rockturtle", "name": "岩甲龟", "rarity": 3, "color": Color(0.6, 0.5, 0.35, 1), "skill": "hp", "base": 10.0, "cd": 0.0, "shape": "turtle"},
	{"id": "stardragon", "name": "星辉龙", "rarity": 5, "color": Color(1.0, 0.95, 0.6, 1), "skill": "all", "base": 24.0, "cd": 1.0, "shape": "dragon"},
	{"id": "shadowcat", "name": "暗影猫", "rarity": 3, "color": Color(0.65, 0.4, 0.95, 1), "skill": "atk", "base": 14.0, "cd": 1.2, "shape": "cat"},
	{"id": "glowfly", "name": "微光萤", "rarity": 1, "color": Color(0.85, 1.0, 0.7, 1), "skill": "hp", "base": 4.0, "cd": 0.0, "shape": "fly"},
]
const RARITY_W := {1: 40, 2: 30, 3: 20, 4: 8, 5: 2}

func setup(p_main: Node) -> void:
	main = p_main

# ---------------- 存档 ----------------
func to_save() -> Dictionary:
	return {"owned": owned, "active": active_id, "pity": pulls_since_high}

func from_save(d: Dictionary) -> void:
	owned = {}
	for id: Variant in (d.get("owned", {}) as Dictionary).keys():
		var v: Variant = (d["owned"] as Dictionary)[id]
		if v is Dictionary:
			owned[String(id)] = {"level": int(v.get("level", 1)), "star": int(v.get("star", 0))}
		else:
			owned[String(id)] = {"level": int(v), "star": 0}   # 兼容旧存档(纯等级)
	active_id = String(d.get("active", ""))
	pulls_since_high = int(d.get("pity", 0))
	_rebuild_companion()

func _save() -> void:
	if main != null and main.has_method("_save_quests"):
		main._save_quests()

func _def(id: String) -> Dictionary:
	for p_v: Variant in POOL:
		if String((p_v as Dictionary)["id"]) == id:
			return p_v
	return {}

func _lvl(id: String) -> int:
	return int((owned.get(id, {}) as Dictionary).get("level", 1)) if owned.has(id) else 0
func _star(id: String) -> int:
	return int((owned.get(id, {}) as Dictionary).get("star", 0)) if owned.has(id) else 0
func _power(pd: Dictionary, id: String) -> float:
	return float(pd["base"]) * float(_lvl(id)) * (1.0 + 0.25 * float(_star(id)))

# ---------------- 抽卡（含保底 + 十连）----------------
func _roll_one() -> Dictionary:
	pulls_since_high += 1
	var force_high: bool = pulls_since_high >= PITY
	var total: int = 0
	for r: int in RARITY_W.keys():
		total += int(RARITY_W[r])
	var roll: int = randi() % total
	var rar: int = 1
	for r: int in RARITY_W.keys():
		roll -= int(RARITY_W[r])
		if roll < 0:
			rar = r; break
	if force_high and rar < 4:
		rar = 4
	if rar >= 4:
		pulls_since_high = 0
	var pool_r: Array = []
	for p_v: Variant in POOL:
		if int((p_v as Dictionary)["rarity"]) == rar:
			pool_r.append(p_v)
	if pool_r.is_empty():
		pool_r = POOL.duplicate()
	var pd: Dictionary = pool_r[randi() % pool_r.size()]
	var id: String = String(pd["id"])
	if owned.has(id):
		main.inv.add_material(BOOK, Color(0.9, 0.8, 0.4, 1), 1)
		return {"pd": pd, "new": false}
	owned[id] = {"level": 1, "star": 0}
	if active_id == "":
		active_id = id; _rebuild_companion()
	return {"pd": pd, "new": true}

func draw() -> void:
	if main.inv == null or main.inv.material_count(EGG) < 1:
		main.flash_message("需要「宠物蛋」才能抽卡（副本通关/常驻Boss 掉落）。")
		return
	main.inv.consume_material(EGG, 1)
	var r: Dictionary = _roll_one()
	var pd: Dictionary = r["pd"]
	if bool(r["new"]):
		main.flash_message("🎉获得新宠物【%s】★%d!" % [String(pd["name"]), int(pd["rarity"])])
	else:
		main.flash_message("✨抽到【%s】★%d — 已有,转技能书!" % [String(pd["name"]), int(pd["rarity"])])
	_save(); _refresh_panel()

func draw_ten() -> void:
	if main.inv == null or main.inv.material_count(EGG) < 10:
		main.flash_message("十连需要 10 个宠物蛋。")
		return
	main.inv.consume_material(EGG, 10)
	var news: Array = []
	var best: int = 0
	for i in range(10):
		var r: Dictionary = _roll_one()
		var pd: Dictionary = r["pd"]
		best = maxi(best, int(pd["rarity"]))
		if bool(r["new"]):
			news.append(String(pd["name"]))
	if news.is_empty():
		main.flash_message("十连完成!最高 ★%d,全为已有(转技能书)。" % best)
	else:
		main.flash_message("十连完成!最高 ★%d,新宠物:%s" % [best, "、".join(PackedStringArray(news))])
	_save(); _refresh_panel()

func grant_pet(id: String) -> void:
	if _def(id).is_empty() or owned.has(id):
		return
	owned[id] = {"level": 1, "star": 0}
	if active_id == "":
		active_id = id; _rebuild_companion()
	main.flash_message("🎁获得宠物【%s】!" % String(_def(id)["name"]))
	_save()

func set_active(id: String) -> void:
	if not owned.has(id):
		return
	active_id = id
	_rebuild_companion()
	_save(); _refresh_panel()

func upgrade(id: String) -> void:
	if not owned.has(id):
		return
	if _lvl(id) >= MAX_PET_LEVEL:
		main.flash_message("该宠物技能已满级（可进化提升星级）。")
		return
	if main.inv.material_count(BOOK) < 1:
		main.flash_message("需要「宠物技能书」升级。")
		return
	main.inv.consume_material(BOOK, 1)
	owned[id]["level"] = _lvl(id) + 1
	main.flash_message("【%s】技能升到 Lv.%d!" % [String(_def(id)["name"]), _lvl(id)])
	_save(); _refresh_panel()

func evolve(id: String) -> void:
	if not owned.has(id):
		return
	if _star(id) >= MAX_STAR:
		main.flash_message("该宠物已满星。")
		return
	if _lvl(id) < MAX_PET_LEVEL:
		main.flash_message("需先把技能升满 Lv.%d 才能进化。" % MAX_PET_LEVEL)
		return
	if main.inv.material_count(BOOK) < EVOLVE_BOOKS:
		main.flash_message("进化需要 %d 本技能书。" % EVOLVE_BOOKS)
		return
	main.inv.consume_material(BOOK, EVOLVE_BOOKS)
	owned[id]["star"] = _star(id) + 1
	owned[id]["level"] = 1   # 进化后技能等级重置,威力更高
	main.flash_message("⭐【%s】进化至 ★升%d!威力大增!" % [String(_def(id)["name"]), _star(id)])
	if main.has_method("spawn_skill_flash") and _companion != null and is_instance_valid(_companion):
		main.spawn_skill_flash(_companion.global_position, Color(1, 0.9, 0.5, 1), 3.0, 0.6)
	_save(); _refresh_panel()

# ---------------- 主动技能（按 T）----------------
func cast_active() -> void:
	if active_id == "" or not owned.has(active_id) or main.player == null or not is_instance_valid(main.player):
		return
	if active_cd > 0.0:
		main.flash_message("宠物主动技能冷却中（%.0f秒）。" % active_cd)
		return
	active_cd = ACTIVE_COOLDOWN
	var pd: Dictionary = _def(active_id)
	var pw: float = _power(pd, active_id)
	var skill: String = String(pd["skill"])
	var p: Node3D = main.player
	if skill == "atk" or skill == "all":
		# 环形爆发:对身边一定范围内所有怪造成伤害。
		var dmg: int = int(pw * 6.0)
		var hit: int = _aoe_damage(p.global_position, 9.0, dmg)
		if main.has_method("spawn_skill_flash"):
			main.spawn_skill_flash(p.global_position + Vector3(0, 1, 0), pd["color"], 9.0, 0.5)
		main.flash_message("🐾【%s】主动:爆发,命中 %d 个敌人!" % [String(pd["name"]), hit])
	if skill == "hp" or skill == "all":
		p.hp = minf(float(p.max_hp), p.hp + float(p.max_hp) * (0.3 + 0.06 * float(_star(active_id))))
		if skill == "hp":
			main.flash_message("🐾【%s】主动:治愈!" % String(pd["name"]))
	if skill == "mp":
		p.mp = minf(float(p.max_mp), p.mp + float(p.max_mp) * 0.5)
		main.flash_message("🐾【%s】主动:回复法力!" % String(pd["name"]))

func _aoe_damage(center: Vector3, r: float, dmg: int) -> int:
	var n: int = 0
	if "monsters" in main:
		for mn_v: Variant in main.monsters:
			if is_instance_valid(mn_v) and not (mn_v as Object).get("dead") and center.distance_to((mn_v as Node3D).global_position) <= r:
				(mn_v as Object).take_damage(dmg, main.player); n += 1
	if "net_monsters" in main:
		for mn_v2: Variant in (main.net_monsters as Dictionary).values():
			if is_instance_valid(mn_v2) and not (mn_v2 as Object).get("dead") and center.distance_to((mn_v2 as Node3D).global_position) <= r:
				(mn_v2 as Object).take_damage(dmg, main.player); n += 1
	return n

# ---------------- 出战伙伴（更精致造型）+ 被动 ----------------
func _rebuild_companion() -> void:
	if _companion != null and is_instance_valid(_companion):
		_companion.queue_free()
	_companion = null
	if active_id == "" or not owned.has(active_id):
		return
	var pd: Dictionary = _def(active_id)
	if pd.is_empty():
		return
	_companion = Node3D.new()
	_build_pet_model(_companion, pd)
	(main.effect_root if ("effect_root" in main and main.effect_root != null) else main).add_child(_companion)

func _pmat(col: Color, e: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new(); m.albedo_color = col
	m.emission_enabled = true; m.emission = col; m.emission_energy_multiplier = e
	return m

func _part(parent: Node3D, mesh: Mesh, mat: StandardMaterial3D, pos: Vector3, rot := Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new(); mi.mesh = mesh; mi.material_override = mat; mi.position = pos; mi.rotation = rot
	parent.add_child(mi)

func _build_pet_model(root: Node3D, pd: Dictionary) -> void:
	var col: Color = pd["color"]
	var body_m := _pmat(col, 2.2)
	var dark := _pmat(col.darkened(0.4), 1.4)
	var shape: String = String(pd.get("shape", "fly"))
	# 通用身体
	var body := SphereMesh.new(); body.radius = 0.38; body.height = 0.7
	_part(root, body, body_m, Vector3(0, 0, 0))
	var head := SphereMesh.new(); head.radius = 0.26; head.height = 0.5
	_part(root, head, body_m, Vector3(0, 0.34, -0.22))
	# 眼睛
	var eye := SphereMesh.new(); eye.radius = 0.07; eye.height = 0.14
	_part(root, eye, _pmat(Color(0.1, 0.1, 0.12, 1), 0.0), Vector3(0, 0.38, -0.44))
	match shape:
		"fox", "cat", "deer":
			# 耳朵(锥) + 尾巴
			for sx in [-1.0, 1.0]:
				var ear := CylinderMesh.new(); ear.top_radius = 0.0; ear.bottom_radius = 0.12; ear.height = 0.3
				_part(root, ear, dark, Vector3(sx * 0.14, 0.56, -0.2), Vector3(0.2, 0, sx * 0.2))
			var tail := CylinderMesh.new(); tail.top_radius = 0.04; tail.bottom_radius = 0.14; tail.height = 0.5
			_part(root, tail, dark, Vector3(0, 0.05, 0.35), Vector3(1.1, 0, 0))
		"bird", "dragon":
			# 翅膀 + (龙加尖角)
			for sx in [-1.0, 1.0]:
				var wing := BoxMesh.new(); wing.size = Vector3(0.6, 0.05, 0.34)
				_part(root, wing, dark, Vector3(sx * 0.5, 0.1, 0.05), Vector3(0, 0, sx * 0.5))
			if shape == "dragon":
				for sx2 in [-1.0, 1.0]:
					var horn := CylinderMesh.new(); horn.top_radius = 0.0; horn.bottom_radius = 0.06; horn.height = 0.24
					_part(root, horn, dark, Vector3(sx2 * 0.1, 0.58, -0.2))
		"turtle":
			var shell := SphereMesh.new(); shell.radius = 0.46; shell.height = 0.55
			_part(root, shell, dark, Vector3(0, 0.02, 0.02))
		_:
			# spirit/fly: 光翼
			for sx in [-1.0, 1.0]:
				var w := BoxMesh.new(); w.size = Vector3(0.5, 0.06, 0.26)
				_part(root, w, _pmat(col, 3.0), Vector3(sx * 0.42, 0.08, 0.02), Vector3(0, 0, sx * 0.4))

func _process(delta: float) -> void:
	active_cd = maxf(0.0, active_cd - delta)
	if main == null or main.player == null or not is_instance_valid(main.player):
		return
	if _companion == null or not is_instance_valid(_companion):
		return
	var p: Node3D = main.player
	var target: Vector3 = p.global_position + Vector3(1.4, 2.1 + sin(float(Time.get_ticks_msec()) * 0.004) * 0.2, 1.0)
	_companion.global_position = _companion.global_position.lerp(target, clampf(delta * 4.0, 0.0, 1.0))
	_companion.rotate_y(delta * 1.2)
	var pd: Dictionary = _def(active_id)
	if pd.is_empty():
		return
	var skill: String = String(pd["skill"])
	var pw: float = _power(pd, active_id)
	if skill == "hp" or skill == "all":
		if p.hp > 0.0 and p.hp < float(p.max_hp):
			p.hp = minf(float(p.max_hp), p.hp + pw * 0.12 * delta)
	if skill == "mp":
		if p.mp < float(p.max_mp):
			p.mp = minf(float(p.max_mp), p.mp + pw * 0.12 * delta)
	if skill == "atk" or skill == "all":
		_atk_cd -= delta
		if _atk_cd <= 0.0:
			_pet_attack(pd, pw)

func _pet_attack(pd: Dictionary, pw: float) -> void:
	var from: Vector3 = _companion.global_position
	var tgt: Node3D = _nearest_monster(from, 16.0)
	if tgt == null:
		return
	_atk_cd = maxf(0.4, float(pd.get("cd", 1.2)))
	if not main.has_method("spawn_projectile"):
		return
	var dir: Vector3 = (tgt.global_position + Vector3(0, 0.8, 0) - from).normalized()
	main.spawn_projectile({
		"position": from + dir * 0.6, "direction": dir, "speed": 22.0,
		"damage": int(pw), "radius": 0.3, "aoe": 0.0, "color": pd["color"],
		"source": main.player, "target_group": "monster",
	})

func _nearest_monster(from: Vector3, rng: float) -> Node3D:
	var best: Node3D = null
	var bd: float = rng
	if "monsters" in main:
		for mn_v: Variant in main.monsters:
			if is_instance_valid(mn_v) and not (mn_v as Object).get("dead"):
				var d: float = from.distance_to((mn_v as Node3D).global_position)
				if d < bd:
					bd = d; best = mn_v
	if "net_monsters" in main:
		for mn_v2: Variant in (main.net_monsters as Dictionary).values():
			if is_instance_valid(mn_v2) and not (mn_v2 as Object).get("dead"):
				var d2: float = from.distance_to((mn_v2 as Node3D).global_position)
				if d2 < bd:
					bd = d2; best = mn_v2
	return best

# ---------------- 面板（O）----------------
func toggle() -> void:
	if _panel == null:
		_build_panel()
	_panel.visible = not _panel.visible
	if _panel.visible:
		_refresh_panel()

func is_open() -> bool: return _panel != null and _panel.visible
func close() -> void:
	if _panel != null: _panel.visible = false

func _refresh_panel() -> void:
	if _grid == null:
		return
	for c in _grid.get_children():
		c.queue_free()
	for p_v: Variant in POOL:
		var pd: Dictionary = p_v
		var id: String = String(pd["id"])
		var cell := Button.new(); cell.custom_minimum_size = Vector2(132, 82)
		if owned.has(id):
			cell.text = "%s ★%d\nLv.%d 升%d %s" % [String(pd["name"]), int(pd["rarity"]), _lvl(id), _star(id), ("◀出战" if id == active_id else "")]
			cell.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3, 1) if id == active_id else Color(1, 1, 1, 1))
			cell.pressed.connect(func() -> void: set_active(id))
		else:
			cell.text = "??? ★%d\n(未获得)" % int(pd["rarity"])
			cell.add_theme_color_override("font_color", Color(0.55, 0.6, 0.68, 1)); cell.disabled = true
		_grid.add_child(cell)
	if _status != null:
		_status.text = "宠物蛋 ×%d   技能书 ×%d   保底进度 %d/%d   （点宠物出战;T 放主动技能）" % [
			main.inv.material_count(EGG) if main.inv != null else 0, main.inv.material_count(BOOK) if main.inv != null else 0, pulls_since_high, PITY]

func _build_panel() -> void:
	var layer := CanvasLayer.new(); layer.layer = 62; add_child(layer)
	_panel = Control.new(); _panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); layer.add_child(_panel)
	var dim := ColorRect.new(); dim.color = Color(0, 0, 0, 0.6); dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); _panel.add_child(dim)
	var card := Panel.new(); card.set_anchors_and_offsets_preset(Control.PRESET_CENTER); card.position = Vector2(-320, -240); card.size = Vector2(640, 480)
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(0.07, 0.06, 0.11, 0.98); sb.set_border_width_all(2); sb.border_color = Color(0.8, 0.5, 1.0, 0.7); sb.set_corner_radius_all(14)
	card.add_theme_stylebox_override("panel", sb); _panel.add_child(card)
	var title := Label.new(); title.text = "🐾 宠物"; title.position = Vector2(0, 12); title.size = Vector2(640, 32); title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24); title.add_theme_color_override("font_color", Color(0.85, 0.6, 1.0, 1)); card.add_child(title)
	_status = Label.new(); _status.position = Vector2(20, 46); _status.size = Vector2(600, 24); _status.add_theme_font_size_override("font_size", 13); _status.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95, 1))
	card.add_child(_status)
	var scroll := ScrollContainer.new(); scroll.position = Vector2(16, 76); scroll.size = Vector2(608, 320); card.add_child(scroll)
	_grid = GridContainer.new(); _grid.columns = 4; _grid.add_theme_constant_override("h_separation", 8); _grid.add_theme_constant_override("v_separation", 8); scroll.add_child(_grid)
	var y: float = 420.0
	var b1 := Button.new(); b1.text = "抽卡(1蛋)"; b1.position = Vector2(20, y); b1.size = Vector2(120, 40); b1.pressed.connect(draw); card.add_child(b1)
	var b2 := Button.new(); b2.text = "十连(10蛋)"; b2.position = Vector2(148, y); b2.size = Vector2(130, 40); b2.pressed.connect(draw_ten); card.add_child(b2)
	var b3 := Button.new(); b3.text = "升级(1书)"; b3.position = Vector2(286, y); b3.size = Vector2(120, 40); b3.pressed.connect(func() -> void: if active_id != "": upgrade(active_id)); card.add_child(b3)
	var b4 := Button.new(); b4.text = "进化(%d书)" % EVOLVE_BOOKS; b4.position = Vector2(414, y); b4.size = Vector2(130, 40); b4.pressed.connect(func() -> void: if active_id != "": evolve(active_id)); card.add_child(b4)
	var b5 := Button.new(); b5.text = "关闭"; b5.position = Vector2(552, y); b5.size = Vector2(70, 40); b5.pressed.connect(func() -> void: _panel.visible = false); card.add_child(b5)
