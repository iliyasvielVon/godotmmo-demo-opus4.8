extends Node3D
class_name ShelterSystem

# 个人庇护所（客户端个人进度，等级存档）。在新手村内的地基上,用采集材料建造/升级。
# 各级解锁:Lv1 休整回满 + 微弱回复光环;Lv2 更快回复;Lv3 强回复 + 回复法力 + 光环更大。
# 走到地基按 E 打开面板:建造/升级(消耗材料)、休整。

var main: Node = null
var level: int = 0
var _structure: Node3D = null
var _panel: Control = null
var _info_label: RichTextLabel = null

const PLOT := Vector3(0, 0, 42)     # 新手村内的庇护所地基
const PLOT_R := 4.5                 # 交互距离
# 每级建造/升级材料需求。
const COSTS := [
	{"寒霜晶矿": 4},                                  # → Lv1
	{"寒霜晶矿": 8, "星莹水晶": 4},                    # → Lv2
	{"寒霜晶矿": 16, "星莹水晶": 12},                  # → Lv3
]
const MAX_LEVEL := 3

func setup(p_main: Node) -> void:
	main = p_main
	level = int(main.shelter_level) if ("shelter_level" in main) else 0
	_build_plot()
	_rebuild_structure()

func _build_plot() -> void:
	var base := MeshInstance3D.new()
	var cm := CylinderMesh.new(); cm.top_radius = 3.2; cm.bottom_radius = 3.2; cm.height = 0.2
	base.mesh = cm
	var bmat := StandardMaterial3D.new(); bmat.albedo_color = Color(0.3, 0.28, 0.24, 1)
	base.material_override = bmat
	base.position = PLOT + Vector3(0, 0.12, 0)
	add_child(base)
	var lbl := Label3D.new()
	lbl.name = "ShelterLabel"
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.font_size = 30; lbl.outline_size = 6
	lbl.modulate = Color(0.7, 1.0, 0.85, 1)
	lbl.position = PLOT + Vector3(0, 5.5, 0)
	add_child(lbl)
	_shelter_label = lbl
	_update_label()

var _shelter_label: Label3D = null

func _update_label() -> void:
	if _shelter_label == null:
		return
	if level <= 0:
		_shelter_label.text = "🏕 庇护所地基（按 E 建造）"
	elif level >= MAX_LEVEL:
		_shelter_label.text = "🏠 庇护所 Lv.%d（满级·按 E 休整）" % level
	else:
		_shelter_label.text = "🏠 庇护所 Lv.%d（按 E 升级/休整）" % level

func _rebuild_structure() -> void:
	if _structure != null and is_instance_valid(_structure):
		_structure.queue_free()
	_structure = Node3D.new()
	_structure.position = PLOT
	add_child(_structure)
	var wall := StandardMaterial3D.new(); wall.albedo_color = Color(0.5, 0.36, 0.22, 1)
	var roof := StandardMaterial3D.new(); roof.albedo_color = Color(0.45, 0.2, 0.16, 1)
	var glow := StandardMaterial3D.new(); glow.albedo_color = Color(0.5, 0.95, 0.8, 1)
	glow.emission_enabled = true; glow.emission = Color(0.4, 1.0, 0.8, 1); glow.emission_energy_multiplier = 2.0
	if level >= 1:
		var body := MeshInstance3D.new()
		var bm := BoxMesh.new(); bm.size = Vector3(4.0, 2.6, 4.0)
		body.mesh = bm; body.material_override = wall; body.position = Vector3(0, 1.3, 0)
		_structure.add_child(body)
		var rf := MeshInstance3D.new()
		var rm := CylinderMesh.new(); rm.top_radius = 0.0; rm.bottom_radius = 3.4; rm.height = 1.8; rm.radial_segments = 4
		rf.mesh = rm; rf.material_override = roof; rf.position = Vector3(0, 3.5, 0); rf.rotation.y = PI * 0.25
		_structure.add_child(rf)
	if level >= 2:
		for sx in [-1.0, 1.0]:
			var post := MeshInstance3D.new()
			var pm := BoxMesh.new(); pm.size = Vector3(0.4, 3.4, 0.4)
			post.mesh = pm; post.material_override = wall; post.position = Vector3(sx * 2.4, 1.7, 2.4)
			_structure.add_child(post)
	if level >= 3:
		var crystal := MeshInstance3D.new()
		var pm := PrismMesh.new(); pm.size = Vector3(0.8, 2.4, 0.8)
		crystal.mesh = pm; crystal.material_override = glow; crystal.position = Vector3(0, 5.4, 0)
		_structure.add_child(crystal)
		var lt := OmniLight3D.new(); lt.position = Vector3(0, 5.4, 0); lt.light_color = Color(0.5, 1.0, 0.85, 1); lt.light_energy = 2.4; lt.omni_range = 14.0
		_structure.add_child(lt)
	_update_label()

# 玩家在庇护所附近 → 被动回复（等级越高越强）。
func _process(delta: float) -> void:
	if level <= 0 or main == null or main.player == null or not is_instance_valid(main.player):
		return
	var p: Node3D = main.player
	if p.global_position.distance_to(PLOT) > 12.0:
		return
	var hps: float = float([0.0, 4.0, 8.0, 14.0][level])
	if p.hp > 0.0 and p.hp < float(p.max_hp):
		p.hp = minf(float(p.max_hp), p.hp + hps * delta)
	if level >= 2 and p.mp < float(p.max_mp):
		p.mp = minf(float(p.max_mp), p.mp + hps * 0.6 * delta)

# 读档后由 Main 调用，同步等级并重建结构。
func apply_level(lvl: int) -> void:
	level = lvl
	_rebuild_structure()

# Main 的 E 交互链调用。
func try_interact(pos: Vector3) -> bool:
	if pos.distance_to(PLOT) > PLOT_R:
		return false
	if _panel == null:
		_build_panel()
	_refresh_panel()
	_panel.visible = true
	return true

func _cost_text(idx: int) -> String:
	if idx < 0 or idx >= COSTS.size():
		return ""
	var parts: Array = []
	for k: String in (COSTS[idx] as Dictionary).keys():
		var need: int = int(COSTS[idx][k])
		var have: int = main.inv.material_count(k) if main.inv != null else 0
		parts.append("%s %d/%d" % [k, have, need])
	return "、".join(PackedStringArray(parts))

func _can_afford(idx: int) -> bool:
	if idx < 0 or idx >= COSTS.size():
		return false
	for k: String in (COSTS[idx] as Dictionary).keys():
		if main.inv.material_count(k) < int(COSTS[idx][k]):
			return false
	return true

func _refresh_panel() -> void:
	if _info_label == null:
		return
	if level >= MAX_LEVEL:
		_info_label.text = "[b]庇护所 Lv.%d（满级）[/b]\n附近强力回复生命与法力。\n按「休整」回满状态。" % level
	else:
		_info_label.text = "[b]庇护所 Lv.%d[/b]\n升到 Lv.%d 需要：%s\n[i]附近被动回复；升级解锁更快回复/回蓝。[/i]" % [level, level + 1, _cost_text(level)]

func _do_build() -> void:
	if level >= MAX_LEVEL:
		main.flash_message("庇护所已满级。")
		return
	if not _can_afford(level):
		main.flash_message("材料不足：%s" % _cost_text(level))
		return
	for k: String in (COSTS[level] as Dictionary).keys():
		main.inv.consume_material(k, int(COSTS[level][k]))
	level += 1
	if "shelter_level" in main:
		main.shelter_level = level
	_rebuild_structure()
	_refresh_panel()
	main.flash_message("🏠 庇护所升级至 Lv.%d！" % level)
	if main.has_method("spawn_skill_flash"):
		main.spawn_skill_flash(PLOT + Vector3(0, 2, 0), Color(0.5, 1.0, 0.8, 1), 4.0, 0.6)
	if main.has_method("on_shelter_changed"):
		main.on_shelter_changed(level)

func _do_rest() -> void:
	if level <= 0:
		return
	if main.player != null and is_instance_valid(main.player) and main.player.has_method("heal_full"):
		main.player.heal_full()
	main.flash_message("在庇护所休整，状态已回满。")
	_panel.visible = false

func _build_panel() -> void:
	var layer := CanvasLayer.new(); layer.layer = 61; add_child(layer)
	_panel = Control.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_panel)
	var dim := ColorRect.new(); dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(dim)
	var card := Panel.new()
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.position = Vector2(-210, -150); card.size = Vector2(420, 300)
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(0.06, 0.09, 0.08, 0.98)
	sb.set_border_width_all(2); sb.border_color = Color(0.4, 0.9, 0.7, 0.7); sb.set_corner_radius_all(14)
	card.add_theme_stylebox_override("panel", sb)
	_panel.add_child(card)
	var title := Label.new(); title.text = "🏠 庇护所"
	title.position = Vector2(0, 16); title.size = Vector2(420, 34); title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24); title.add_theme_color_override("font_color", Color(0.7, 1.0, 0.85, 1))
	card.add_child(title)
	_info_label = RichTextLabel.new(); _info_label.bbcode_enabled = true
	_info_label.position = Vector2(24, 58); _info_label.size = Vector2(372, 150)
	card.add_child(_info_label)
	var build := Button.new(); build.text = "建造 / 升级"; build.position = Vector2(24, 244); build.size = Vector2(170, 40)
	build.pressed.connect(_do_build); card.add_child(build)
	var rest := Button.new(); rest.text = "休整（回满）"; rest.position = Vector2(206, 244); rest.size = Vector2(120, 40)
	rest.pressed.connect(_do_rest); card.add_child(rest)
	var close := Button.new(); close.text = "关闭"; close.position = Vector2(338, 244); close.size = Vector2(58, 40)
	close.pressed.connect(func() -> void: _panel.visible = false); card.add_child(close)
