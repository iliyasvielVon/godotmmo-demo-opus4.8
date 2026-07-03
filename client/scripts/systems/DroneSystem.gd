extends Node3D
class_name DroneSystem

# 无人机系统（客户端个人进度，存档；联机随存档存服务器）。一期:
#   在安全区(据点)附近用材料【制造/升级/维修/加注燃料/装配工具】;升级提升等级(上限=安全区等级)、
#   燃料容量、耐久、可同时释放数量、可搭载工具数。工具:挖矿/武器/续航/信号/动力/载人仓(各有负重)。
#   动力↑推力、续航↑燃料上限。释放后化作飞行无人机跟随;移速/转向/爬升/坠落由【负重+动力】推导;
#   飞行消耗燃料与耐久,耗尽自动召回。按 G 打开机库。工具的世界效果(自动挖矿/攻击/载人)见二期。

var main: Node = null
var drones: Array = []             # [{level, fuel, dura, tools:[id...], deployed:bool}]
var sel: int = 0                   # 选中的机体索引
var _nodes: Dictionary = {}        # drone_index -> Node3D(已释放的飞行体)
var _panel: Control = null
var _list: VBoxContainer = null
var _detail: RichTextLabel = null
var _tools_box: HBoxContainer = null

const BASE_WEIGHT := 10.0
const TOOLS := [
	{"id": "mine", "name": "挖矿臂", "weight": 6.0, "cost": {"寒霜晶矿": 4}},
	{"id": "combat", "name": "武器挂载", "weight": 5.0, "cost": {"寒霜晶矿": 5}},
	{"id": "endurance", "name": "续航电池", "weight": 4.0, "cost": {"寒霜晶矿": 3, "星莹水晶": 1}},
	{"id": "signal", "name": "信号增幅", "weight": 2.0, "cost": {"寒霜晶矿": 2}},
	{"id": "power", "name": "动力核心", "weight": 3.0, "cost": {"寒霜晶矿": 4, "星莹水晶": 2}},
	{"id": "cabin", "name": "载人仓", "weight": 12.0, "cost": {"寒霜晶矿": 8, "星莹水晶": 4}},
]
const MANUFACTURE_COST := {"寒霜晶矿": 6, "星莹水晶": 2}

func setup(p_main: Node) -> void:
	main = p_main

# ---------------- 存档 ----------------
func to_save() -> Dictionary:
	var out: Array = []
	for d_v: Variant in drones:
		var d: Dictionary = d_v
		out.append({"level": int(d["level"]), "fuel": float(d["fuel"]), "dura": float(d["dura"]),
			"tools": (d["tools"] as Array).duplicate()})   # deployed 不存(登录默认收回)
	return {"drones": out}

func from_save(dd: Dictionary) -> void:
	drones = []
	for d_v: Variant in (dd.get("drones", []) as Array):
		var d: Dictionary = d_v
		drones.append({"level": int(d.get("level", 1)), "fuel": float(d.get("fuel", 0.0)),
			"dura": float(d.get("dura", 0.0)), "tools": (d.get("tools", []) as Array).duplicate(), "deployed": false})

func _save() -> void:
	if main != null and main.has_method("_save_quests"):
		main._save_quests()

# ---------------- 派生数值（负重/动力→性能）----------------
func _has_tool(d: Dictionary, id: String) -> bool:
	return (d["tools"] as Array).has(id)
func _weight(d: Dictionary) -> float:
	var w: float = BASE_WEIGHT
	for t_v: Variant in TOOLS:
		if _has_tool(d, String((t_v as Dictionary)["id"])):
			w += float((t_v as Dictionary)["weight"])
	return w
func _power(d: Dictionary) -> float:
	return 8.0 + float(int(d["level"])) * 2.0 + (10.0 if _has_tool(d, "power") else 0.0)
func _thrust(d: Dictionary) -> float:
	return _power(d) / maxf(1.0, _weight(d))
func _move_speed(d: Dictionary) -> float:
	return clampf(_thrust(d) * 6.0, 2.0, 16.0)
func _turn_rate(d: Dictionary) -> float:
	return clampf(_thrust(d) * 3.0, 0.8, 6.0)
func _climb(d: Dictionary) -> float:
	return clampf(_thrust(d) * 4.0, 1.0, 10.0)
func _fuel_cap(d: Dictionary) -> float:
	return 40.0 + float(int(d["level"])) * 10.0 + (60.0 if _has_tool(d, "endurance") else 0.0)
func _dura_max(d: Dictionary) -> float:
	return 50.0 + float(int(d["level"])) * 20.0
func _tool_cap(d: Dictionary) -> int:
	return int(d["level"]) + 1    # 可搭载工具数随等级
func _best_level() -> int:
	var b: int = 0
	for d_v: Variant in drones:
		b = maxi(b, int((d_v as Dictionary)["level"]))
	return b
func _deploy_cap() -> int:
	return 1 + int(_best_level() / 3)   # 允许同时释放数量随等级
func _deployed_count() -> int:
	var n: int = 0
	for d_v: Variant in drones:
		if bool((d_v as Dictionary)["deployed"]):
			n += 1
	return n

# ---------------- 安全区约束 ----------------
func _safe_zone_level() -> int:
	return main.safe_zone_level() if main.has_method("safe_zone_level") else 1
func _near_safe_zone() -> bool:
	if main.player == null or not is_instance_valid(main.player) or main.outpost_system == null:
		return false
	var pp: Vector3 = (main.player as Node3D).global_position
	for o_v: Variant in main.outpost_system.outposts:
		var o: Dictionary = o_v
		var c: Vector3 = o["def"]["center"]
		var h: float = float(o["def"]["half"])
		if absf(pp.x - c.x) <= h + 8.0 and absf(pp.z - c.z) <= h + 8.0:
			return true
	return false
func _require_zone() -> bool:
	if not _near_safe_zone():
		main.flash_message("需在安全区(据点)内操作无人机机库。")
		return false
	return true

# ---------------- 材料 ----------------
func _afford(cost: Dictionary) -> bool:
	for k: String in cost.keys():
		if main.inv == null or main.inv.material_count(k) < int(cost[k]):
			return false
	return true
func _pay(cost: Dictionary) -> void:
	for k: String in cost.keys():
		main.inv.consume_material(k, int(cost[k]))
func _cost_str(cost: Dictionary) -> String:
	var parts: Array = []
	for k: String in cost.keys():
		parts.append("%s×%d" % [k, int(cost[k])])
	return "、".join(PackedStringArray(parts))

# ---------------- 操作 ----------------
func manufacture() -> void:
	if not _require_zone():
		return
	if not _afford(MANUFACTURE_COST):
		main.flash_message("材料不足:%s" % _cost_str(MANUFACTURE_COST))
		return
	_pay(MANUFACTURE_COST)
	var d: Dictionary = {"level": 1, "fuel": 0.0, "dura": 0.0, "tools": [], "deployed": false}
	d["fuel"] = _fuel_cap(d); d["dura"] = _dura_max(d)
	drones.append(d); sel = drones.size() - 1
	main.flash_message("🛩 制造无人机 #%d 完成!" % drones.size())
	_save(); _refresh()

func _upgrade_cost(lvl: int) -> Dictionary:
	return {"寒霜晶矿": 4 + lvl * 2, "星莹水晶": 1 + lvl}

func upgrade() -> void:
	if not _require_zone() or sel < 0 or sel >= drones.size():
		return
	var d: Dictionary = drones[sel]
	if int(d["level"]) >= _safe_zone_level():
		main.flash_message("等级上限受安全区等级限制(当前上限 Lv.%d)，先升级安全区。" % _safe_zone_level())
		return
	var cost: Dictionary = _upgrade_cost(int(d["level"]))
	if not _afford(cost):
		main.flash_message("升级材料不足:%s" % _cost_str(cost))
		return
	_pay(cost)
	d["level"] = int(d["level"]) + 1
	d["dura"] = _dura_max(d)   # 升级顺带修复
	main.flash_message("无人机 #%d 升至 Lv.%d!" % [sel + 1, int(d["level"])])
	_save(); _refresh()

func repair() -> void:
	if not _require_zone() or sel < 0 or sel >= drones.size():
		return
	var d: Dictionary = drones[sel]
	var missing: float = _dura_max(d) - float(d["dura"])
	if missing <= 1.0:
		main.flash_message("耐久已满。")
		return
	var need: int = int(ceil(missing / 15.0))
	var cost: Dictionary = {"寒霜晶矿": need}
	if not _afford(cost):
		main.flash_message("维修材料不足:%s" % _cost_str(cost))
		return
	_pay(cost)
	d["dura"] = _dura_max(d)
	main.flash_message("无人机 #%d 已维修至满耐久。" % [sel + 1])
	_save(); _refresh()

func refuel() -> void:
	if not _require_zone() or sel < 0 or sel >= drones.size():
		return
	var d: Dictionary = drones[sel]
	d["fuel"] = _fuel_cap(d)
	main.flash_message("无人机 #%d 燃料已加满。" % [sel + 1])
	_refresh()

func toggle_tool(id: String) -> void:
	if not _require_zone() or sel < 0 or sel >= drones.size():
		return
	var d: Dictionary = drones[sel]
	var tools: Array = d["tools"]
	if tools.has(id):
		tools.erase(id)
		main.flash_message("已卸下工具。")
	else:
		if tools.size() >= _tool_cap(d):
			main.flash_message("工具位已满(上限 %d，升级可增加)。" % _tool_cap(d))
			return
		var tdef: Dictionary = _tool_def(id)
		if not _afford(tdef["cost"]):
			main.flash_message("装配材料不足:%s" % _cost_str(tdef["cost"]))
			return
		_pay(tdef["cost"])
		tools.append(id)
		main.flash_message("已装配【%s】(负重+%d)。" % [String(tdef["name"]), int(tdef["weight"])])
	d["fuel"] = minf(float(d["fuel"]), _fuel_cap(d))
	_save(); _refresh()

func _tool_def(id: String) -> Dictionary:
	for t_v: Variant in TOOLS:
		if String((t_v as Dictionary)["id"]) == id:
			return t_v
	return {}

func toggle_deploy() -> void:
	if sel < 0 or sel >= drones.size():
		return
	var d: Dictionary = drones[sel]
	if bool(d["deployed"]):
		_recall(sel)
		main.flash_message("无人机 #%d 已召回。" % [sel + 1])
	else:
		if float(d["fuel"]) <= 1.0:
			main.flash_message("燃料不足，先在安全区加注。")
			return
		if _deployed_count() >= _deploy_cap():
			main.flash_message("已达同时释放上限 %d(升级提升)。" % _deploy_cap())
			return
		d["deployed"] = true
		_spawn_drone_node(sel)
		main.flash_message("🛩 无人机 #%d 已释放!" % [sel + 1])
	_refresh()

func _recall(idx: int) -> void:
	if idx >= 0 and idx < drones.size():
		(drones[idx] as Dictionary)["deployed"] = false
	if _nodes.has(idx):
		var n: Node = _nodes[idx]
		_nodes.erase(idx)
		if is_instance_valid(n):
			(n as Node3D).queue_free()

# ---------------- 飞行体 ----------------
func _spawn_drone_node(idx: int) -> void:
	if _nodes.has(idx):
		return
	var root := Node3D.new()
	var col := Color(0.7, 0.8, 0.95, 1)
	var bmat := StandardMaterial3D.new(); bmat.albedo_color = col; bmat.metallic = 0.6; bmat.roughness = 0.4
	var body := MeshInstance3D.new(); var bm := BoxMesh.new(); bm.size = Vector3(0.7, 0.22, 0.7)
	body.mesh = bm; body.material_override = bmat; root.add_child(body)
	var rmat := StandardMaterial3D.new(); rmat.albedo_color = Color(0.2, 0.9, 1.0, 1); rmat.emission_enabled = true; rmat.emission = Color(0.2, 0.8, 1.0, 1); rmat.emission_energy_multiplier = 1.5
	var rotors: Array = []
	for corner: Array in [[0.45, 0.45], [-0.45, 0.45], [0.45, -0.45], [-0.45, -0.45]]:
		var arm := MeshInstance3D.new(); var am := CylinderMesh.new(); am.top_radius = 0.05; am.bottom_radius = 0.05; am.height = 0.35
		arm.mesh = am; arm.material_override = bmat; arm.rotation.z = PI / 2; arm.position = Vector3(corner[0] * 0.6, 0, corner[1] * 0.6)
		root.add_child(arm)
		var rotor := MeshInstance3D.new(); var rm := BoxMesh.new(); rm.size = Vector3(0.55, 0.02, 0.06)
		rotor.mesh = rm; rotor.material_override = rmat; rotor.position = Vector3(corner[0], 0.14, corner[1])
		root.add_child(rotor); rotors.append(rotor)
	root.set_meta("rotors", rotors)
	root.global_position = (main.player as Node3D).global_position + Vector3(0, 3.0, 0)
	(main.effect_root if ("effect_root" in main and main.effect_root != null) else main).add_child(root)
	_nodes[idx] = root

func _process(delta: float) -> void:
	if main == null or main.player == null or not is_instance_valid(main.player):
		return
	var p: Node3D = main.player
	for idx: int in _nodes.keys():
		if idx >= drones.size():
			_recall(idx); continue
		var d: Dictionary = drones[idx]
		var node: Node3D = _nodes[idx]
		if not is_instance_valid(node):
			_nodes.erase(idx); continue
		# 燃料/耐久消耗
		d["fuel"] = float(d["fuel"]) - (2.0 + _weight(d) * 0.04) * delta
		d["dura"] = float(d["dura"]) - 0.4 * delta
		if float(d["fuel"]) <= 0.0 or float(d["dura"]) <= 0.0:
			d["fuel"] = maxf(0.0, float(d["fuel"]))
			main.flash_message("无人机 #%d %s，自动召回。" % [idx + 1, ("燃料耗尽" if float(d["fuel"]) <= 0.0 else "耐久归零")])
			_recall(idx); continue
		# 目标:玩家上方环绕点
		var ang: float = float(idx) * 2.4
		var tgt: Vector3 = p.global_position + Vector3(cos(ang) * 3.0, 3.2, sin(ang) * 3.0)
		var cur: Vector3 = node.global_position
		var to: Vector3 = tgt - cur
		# 水平:受移速限制
		var horiz: Vector3 = Vector3(to.x, 0, to.z)
		var mstep: float = _move_speed(d) * delta
		if horiz.length() > mstep:
			horiz = horiz.normalized() * mstep
		# 垂直:爬升较慢、坠落更快
		var vrate: float = _climb(d) if to.y >= 0.0 else (_climb(d) + 3.0)
		var dy: float = clampf(to.y, -vrate * delta, vrate * delta)
		node.global_position = cur + horiz + Vector3(0, dy, 0)
		# 朝向:按转向速度转向移动方向
		if horiz.length() > 0.02:
			var desired: float = atan2(-horiz.x, -horiz.z)
			var cyaw: float = node.rotation.y
			var da: float = wrapf(desired - cyaw, -PI, PI)
			node.rotation.y = cyaw + clampf(da, -_turn_rate(d) * delta, _turn_rate(d) * delta)
		# 旋翼转动
		if node.has_meta("rotors"):
			for r_v: Variant in node.get_meta("rotors"):
				(r_v as Node3D).rotate_y(delta * 30.0)

# ---------------- 机库面板（G）----------------
func toggle() -> void:
	if _panel == null:
		_build_panel()
	_panel.visible = not _panel.visible
	if _panel.visible:
		_refresh()

func is_open() -> bool: return _panel != null and _panel.visible
func close() -> void:
	if _panel != null: _panel.visible = false

func _refresh() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		c.queue_free()
	if drones.is_empty():
		var e := Label.new(); e.text = "（还没有无人机，在安全区点『制造』）"; e.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72, 1)); _list.add_child(e)
	for i in range(drones.size()):
		var d: Dictionary = drones[i]
		var b := Button.new(); b.custom_minimum_size = Vector2(220, 30)
		b.text = "#%d  Lv.%d  燃%d  耐%d %s" % [i + 1, int(d["level"]), int(d["fuel"]), int(d["dura"]), ("[飞行中]" if bool(d["deployed"]) else "")]
		b.add_theme_color_override("font_color", Color(0.4, 1.0, 0.8, 1) if i == sel else Color(1, 1, 1, 1))
		var idx: int = i
		b.pressed.connect(func() -> void: sel = idx; _refresh())
		_list.add_child(b)
	_refresh_detail()

func _refresh_detail() -> void:
	if _detail == null:
		return
	if sel < 0 or sel >= drones.size():
		_detail.text = "[color=#9fb8cf]安全区等级(=上限):Lv.%d　可同时释放:%d[/color]" % [_safe_zone_level(), _deploy_cap()]
		if _tools_box != null:
			for c in _tools_box.get_children(): c.queue_free()
		return
	var d: Dictionary = drones[sel]
	var tnames: Array = []
	for t: String in (d["tools"] as Array):
		tnames.append(String(_tool_def(t)["name"]))
	_detail.text = "[b]无人机 #%d　Lv.%d[/b]（上限 Lv.%d）\n负重 %.0f　动力 %.0f　推力比 %.2f\n移速 %.1f　转向 %.1f　爬升 %.1f\n燃料 %d/%d　耐久 %d/%d\n工具位 %d/%d：%s\n[color=#8fd8ff]同时释放 %d/%d　%s[/color]" % [
		sel + 1, int(d["level"]), _safe_zone_level(), _weight(d), _power(d), _thrust(d),
		_move_speed(d), _turn_rate(d), _climb(d), int(d["fuel"]), int(_fuel_cap(d)), int(d["dura"]), int(_dura_max(d)),
		(d["tools"] as Array).size(), _tool_cap(d), ("、".join(PackedStringArray(tnames)) if not tnames.is_empty() else "无"),
		_deployed_count(), _deploy_cap(), ("✅在安全区" if _near_safe_zone() else "⚠离开安全区无法制造/升级/维修/加注")]
	if _tools_box != null:
		for c in _tools_box.get_children(): c.queue_free()
		for t_v: Variant in TOOLS:
			var t: Dictionary = t_v
			var tid: String = String(t["id"])
			var tb := Button.new(); tb.custom_minimum_size = Vector2(96, 30)
			var on: bool = (d["tools"] as Array).has(tid)
			tb.text = ("✓" if on else "+") + String(t["name"])
			tb.add_theme_color_override("font_color", Color(0.5, 1.0, 0.7, 1) if on else Color(0.85, 0.9, 1.0, 1))
			tb.pressed.connect(func() -> void: toggle_tool(tid))
			_tools_box.add_child(tb)

func _build_panel() -> void:
	var layer := CanvasLayer.new(); layer.layer = 62; add_child(layer)
	_panel = Control.new(); _panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); layer.add_child(_panel)
	var dim := ColorRect.new(); dim.color = Color(0, 0, 0, 0.6); dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); _panel.add_child(dim)
	var card := Panel.new(); card.set_anchors_and_offsets_preset(Control.PRESET_CENTER); card.position = Vector2(-340, -250); card.size = Vector2(680, 500)
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(0.06, 0.08, 0.11, 0.98); sb.set_border_width_all(2); sb.border_color = Color(0.4, 0.75, 0.95, 0.7); sb.set_corner_radius_all(14)
	card.add_theme_stylebox_override("panel", sb); _panel.add_child(card)
	var title := Label.new(); title.text = "🛩 无人机机库"; title.position = Vector2(0, 12); title.size = Vector2(680, 32); title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24); title.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0, 1)); card.add_child(title)
	# 左:机体列表
	var lscroll := ScrollContainer.new(); lscroll.position = Vector2(16, 52); lscroll.size = Vector2(240, 320); card.add_child(lscroll)
	_list = VBoxContainer.new(); _list.add_theme_constant_override("separation", 4); lscroll.add_child(_list)
	# 右:详情
	_detail = RichTextLabel.new(); _detail.bbcode_enabled = true; _detail.position = Vector2(268, 52); _detail.size = Vector2(400, 250); _detail.add_theme_font_size_override("normal_font_size", 14)
	card.add_child(_detail)
	_tools_box = HBoxContainer.new(); _tools_box.position = Vector2(268, 310); _tools_box.size = Vector2(400, 34); _tools_box.add_theme_constant_override("separation", 4)
	card.add_child(_tools_box)
	# 底部操作按钮
	var y: float = 384.0
	_mk_btn(card, "制造", Vector2(16, y), Vector2(96, 38), manufacture)
	_mk_btn(card, "升级", Vector2(118, y), Vector2(96, 38), upgrade)
	_mk_btn(card, "维修", Vector2(220, y), Vector2(96, 38), repair)
	_mk_btn(card, "加注燃料", Vector2(322, y), Vector2(110, 38), refuel)
	_mk_btn(card, "释放/召回", Vector2(438, y), Vector2(120, 38), toggle_deploy)
	_mk_btn(card, "关闭", Vector2(580, y), Vector2(84, 38), func() -> void: _panel.visible = false)
	var tip := Label.new(); tip.text = "制造/升级/维修/加注/装配需在安全区(据点)内；释放/召回随处可用。"; tip.position = Vector2(16, y + 46); tip.size = Vector2(650, 20)
	tip.add_theme_font_size_override("font_size", 12); tip.add_theme_color_override("font_color", Color(0.65, 0.72, 0.82, 1)); card.add_child(tip)

func _mk_btn(parent: Control, text: String, pos: Vector2, sz: Vector2, cb: Callable) -> void:
	var b := Button.new(); b.text = text; b.position = pos; b.size = sz; b.pressed.connect(cb); parent.add_child(b)
