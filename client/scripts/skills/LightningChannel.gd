extends Node3D

# Boss 究极「雷霆引导」表现：Boss 原地引导雷电（电柱随引导增强），范围内玩家头顶出现雷击标记，
# 离开范围即丢失标记；蓄力完成对当前带标记者闪下雷击特效。
# 伤害/减速由 Monster(单机) 或服务器(联机) 权威结算；本节点只负责表现。

const HEAD_Y := 3.0

var main: Node = null
var boss: Node3D = null
var center: Vector3 = Vector3.ZERO
var radius: float = 11.0
var duration: float = 3.5
var elapsed: float = 0.0
var struck: bool = false
var beam: MeshInstance3D = null
var beam_mat: StandardMaterial3D = null
var _markers: Dictionary = {}   # player instance_id -> {marker:Node3D, player:Node3D}

func start(p_main: Node, p_boss: Node3D, p_center: Vector3, p_radius: float, p_duration: float, _seed: int = 0, _visual_only: bool = false) -> void:
	main = p_main
	boss = p_boss
	center = p_center
	radius = p_radius
	duration = p_duration
	_build_beam()

func _process(delta: float) -> void:
	if main == null:
		queue_free()
		return
	elapsed += delta
	var c: Vector3 = boss.global_position if (boss != null and is_instance_valid(boss)) else center
	# 引导电柱：随进度增强 + 抖动闪烁。
	if beam != null and is_instance_valid(beam):
		beam.global_position = c + Vector3(0, 3.0, 0)
		var prog: float = clampf(elapsed / max(duration, 0.1), 0.0, 1.0)
		var flick: float = 0.6 + 0.4 * sin(elapsed * 40.0)
		beam.scale = Vector3(1.0 + prog * 0.8, 1.0, 1.0 + prog * 0.8)
		if beam_mat != null:
			beam_mat.emission_energy_multiplier = 1.5 + prog * 4.0 * flick
	# 标记：范围内玩家头顶常驻雷击标记，离开即移除（引导未结束时持续刷新）。
	if not struck:
		_update_markers(c)
	if not struck and elapsed >= duration:
		struck = true
		_strike()
	if elapsed >= duration + 0.6:
		_clear_markers()
		queue_free()

func _candidates() -> Array:
	var out: Array = []
	if main == null:
		return out
	if main.player != null and is_instance_valid(main.player):
		out.append(main.player)
	if "net_players" in main:
		for p in main.net_players.values():
			if p != null and is_instance_valid(p):
				out.append(p)
	return out

func _update_markers(c: Vector3) -> void:
	var present: Dictionary = {}
	for p in _candidates():
		var pn: Node3D = p as Node3D
		if pn == null:
			continue
		if "hp" in p and float(p.hp) <= 0.0:
			continue
		var d: float = Vector2(pn.global_position.x - c.x, pn.global_position.z - c.z).length()
		if d <= radius:
			var id: int = pn.get_instance_id()
			present[id] = true
			if not _markers.has(id):
				_markers[id] = {"marker": _make_marker(pn), "player": pn}
	# 移除离开范围/失效的标记
	for id in _markers.keys():
		var e: Dictionary = _markers[id]
		var pl: Node = e["player"]
		if not present.has(id) or pl == null or not is_instance_valid(pl):
			var mk: Node = e["marker"]
			if mk != null and is_instance_valid(mk):
				mk.queue_free()
			_markers.erase(id)

func _make_marker(player: Node3D) -> Node3D:
	# 头顶向下的雷击警示标记（朝下的发光锥 + 轻微旋转）。
	var holder := Node3D.new()
	holder.name = "LightningMark"
	holder.position = Vector3(0, HEAD_Y, 0)
	player.add_child(holder)
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.34
	mesh.bottom_radius = 0.02
	mesh.height = 0.5
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.85, 1.0, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.6, 0.8, 1.0, 1)
	mat.emission_energy_multiplier = 2.2
	mi.material_override = mat
	holder.add_child(mi)
	return holder

func _strike() -> void:
	# 对当前仍带标记的玩家闪下雷击柱。
	for id in _markers.keys():
		var e: Dictionary = _markers[id]
		var pl: Node = e["player"]
		if pl == null or not is_instance_valid(pl):
			continue
		var pos: Vector3 = (pl as Node3D).global_position
		if main != null and main.has_method("spawn_skill_flash"):
			main.spawn_skill_flash(pos + Vector3(0, 1.0, 0), Color(0.7, 0.9, 1.0, 1), 2.2, 0.5)
		_spawn_bolt(pos)

func _spawn_bolt(pos: Vector3) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.18
	mesh.bottom_radius = 0.05
	mesh.height = 14.0
	var bolt := MeshInstance3D.new()
	bolt.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.92, 1.0, 0.95)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.7, 0.88, 1.0, 1)
	mat.emission_energy_multiplier = 5.0
	bolt.material_override = mat
	bolt.global_position = pos + Vector3(0, 7.0, 0)
	add_child(bolt)
	var tw := create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.45)
	tw.parallel().tween_property(bolt, "scale", Vector3(0.3, 1.0, 0.3), 0.45)
	tw.tween_callback(bolt.queue_free)

func _build_beam() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.5
	mesh.bottom_radius = 0.7
	mesh.height = 6.0
	beam = MeshInstance3D.new()
	beam.name = "ChannelBeam"
	beam.mesh = mesh
	beam_mat = StandardMaterial3D.new()
	beam_mat.albedo_color = Color(0.6, 0.82, 1.0, 0.5)
	beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beam_mat.emission_enabled = true
	beam_mat.emission = Color(0.6, 0.82, 1.0, 1)
	beam_mat.emission_energy_multiplier = 1.5
	beam.material_override = beam_mat
	add_child(beam)

func _clear_markers() -> void:
	for id in _markers.keys():
		var e: Dictionary = _markers[id]
		var mk: Node = e["marker"]
		if mk != null and is_instance_valid(mk):
			mk.queue_free()
	_markers.clear()
