class_name HealthBar3D
extends Node3D

# 头顶状态条，面向相机。两种模式：
# - 单条模式 setup()（怪物/建筑）：仅 HP，掉血时才显示。
# - 玩家模式 setup_player()（本人 + 联机他人）：HP/MP/体力 三条常显，各带 当前/总数 数字。

var width: float = 1.2
var multi: bool = false
# 单条模式
var fill: MeshInstance3D = null
var fill_mat: StandardMaterial3D = null
var hp_text: Label3D = null
# 玩家模式：三条（HP/MP/体力），每项 {fill, mat, text, full, low, yo}
var _bars: Array = []

func setup(w: float, y: float) -> void:
	width = w
	multi = false
	position = Vector3(0, y, 0)
	_make_quad(w + 0.06, 0.18, Color(0.0, 0.0, 0.0, 0.65), 0.0, Vector3.ZERO)   # 背景
	fill = _make_quad(w, 0.13, Color(0.35, 0.95, 0.4, 1.0), 0.01, Vector3.ZERO) # 血量条
	fill_mat = fill.material_override as StandardMaterial3D
	hp_text = _make_text(40)
	hp_text.position = Vector3(w * 0.5 + 0.12, 0.0, 0.01)
	add_child(hp_text)
	visible = false

# 玩家三条：HP(上) / MP(中) / 体力(下)。
func setup_player(w: float, y: float) -> void:
	width = w
	multi = true
	position = Vector3(0, y, 0)
	var rows: Array = [
		{"yo": 0.34, "full": Color(0.35, 0.95, 0.4, 1.0), "low": Color(0.9, 0.25, 0.2, 1.0)},  # HP
		{"yo": 0.17, "full": Color(0.3, 0.6, 1.0, 1.0), "low": Color(0.18, 0.3, 0.65, 1.0)},   # MP
		{"yo": 0.0, "full": Color(0.96, 0.82, 0.3, 1.0), "low": Color(0.55, 0.4, 0.12, 1.0)},  # 体力
	]
	for r: Dictionary in rows:
		var yo: float = float(r["yo"])
		_make_quad(w + 0.05, 0.15, Color(0.0, 0.0, 0.0, 0.7), 0.0, Vector3(0, yo, 0))
		var f: MeshInstance3D = _make_quad(w, 0.11, r["full"] as Color, 0.01, Vector3(0, yo, 0))
		var t: Label3D = _make_text(34)
		t.position = Vector3(w * 0.5 + 0.12, yo, 0.01)
		add_child(t)
		_bars.append({"fill": f, "mat": f.material_override as StandardMaterial3D, "text": t,
			"full": r["full"], "low": r["low"], "yo": yo})
	visible = true

func _make_quad(w: float, h: float, color: Color, z: float, offset: Vector3) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(w, h)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = offset + Vector3(0, 0, z)
	add_child(mi)
	return mi

func _make_text(fsize: int) -> Label3D:
	var t := Label3D.new()
	t.billboard = BaseMaterial3D.BILLBOARD_DISABLED   # 父节点已朝向相机
	t.no_depth_test = true
	t.fixed_size = false
	t.font_size = fsize
	t.outline_size = 8
	t.pixel_size = 0.0035
	t.modulate = Color(1.0, 1.0, 1.0, 1)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return t

# 单条（怪物/建筑）：满血或死亡时隐藏（“掉血时才显示”）。
func set_hp(cur: float, maxv: float) -> void:
	if multi:
		set_stats(cur, maxv, 0.0, 0.0, 0.0, 0.0)
		return
	var r: float = clamp(cur / maxv, 0.0, 1.0) if maxv > 0.0 else 0.0
	visible = cur > 0.0 and r < 0.999
	if not visible:
		return
	fill.scale.x = max(r, 0.001)
	fill.position.x = -width * 0.5 * (1.0 - r)
	fill_mat.albedo_color = Color(0.9, 0.25, 0.2, 1).lerp(Color(0.35, 0.95, 0.4, 1), r)
	if hp_text != null:
		hp_text.text = "%d/%d" % [int(ceil(cur)), int(maxv)]

# 玩家三条：HP / MP / 体力，常显并带数字（死亡时整体隐藏）。
func set_stats(hp: float, max_hp: float, mp: float, max_mp: float, st: float, max_st: float) -> void:
	if not multi:
		set_hp(hp, max_hp)
		return
	visible = hp > 0.0
	if not visible:
		return
	_apply_bar(0, hp, max_hp)
	_apply_bar(1, mp, max_mp)
	_apply_bar(2, st, max_st)

func _apply_bar(i: int, cur: float, maxv: float) -> void:
	if i >= _bars.size():
		return
	var b: Dictionary = _bars[i]
	var r: float = clamp(cur / maxv, 0.0, 1.0) if maxv > 0.0 else 0.0
	var f: MeshInstance3D = b["fill"]
	f.scale.x = max(r, 0.001)
	f.position.x = -width * 0.5 * (1.0 - r)
	(b["mat"] as StandardMaterial3D).albedo_color = (b["low"] as Color).lerp(b["full"] as Color, r)
	(b["text"] as Label3D).text = "%d/%d" % [int(ceil(cur)), int(maxv)]

func _process(_delta: float) -> void:
	# 朝向相机（拷贝相机朝向使条平行于屏幕）。
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		global_transform.basis = cam.global_transform.basis
