extends Node3D

# 缩小版「天星」：Boss 连招冲锋命中玩家后 0.5s 在命中点落下的小号陨石。
# 表现仿 MeteorSkill（脚下标记 + 小陨石坠落 + 冲击闪光 + 碎片）。
# 落地结算复用 CombatManager.apply_meteor_ground_impact（友伤命中其他怪物+玩家，并「击飞落地后眩晕」）。
# visual_only=true 时（联机客户端）只播表现，伤害/控制由服务器权威结算。

const MARK_T := 0.22
const FALL_T := 0.5
const MINI_R := 3.5
const SKY_H := 16.0

var main: Node = null
var source: Node = null
var center: Vector3 = Vector3.ZERO
var dmg: int = 20
var level: int = 1
var visual_only: bool = false
var elapsed: float = 0.0
var total_life: float = 0.0
var rock: Node3D = null
var marker: MeshInstance3D = null
var impacted: bool = false

func start(p_main: Node, p_source: Node, p_center: Vector3, p_dmg: int, p_level: int, p_visual_only: bool = false) -> void:
	main = p_main
	source = p_source
	center = p_center
	center.y = max(0.0, center.y)
	dmg = p_dmg
	level = p_level
	visual_only = p_visual_only
	total_life = MARK_T + FALL_T + 0.45
	_build_marker()

func _process(delta: float) -> void:
	if main == null:
		queue_free()
		return
	elapsed += delta
	if marker != null and not impacted:
		var pulse: float = 1.0 + sin(elapsed * 12.0) * 0.1
		marker.scale = Vector3(pulse, 1.0, pulse)
	if rock == null and not impacted and elapsed >= MARK_T:
		_build_rock()
	if rock != null and not impacted:
		var ft: float = clampf((elapsed - MARK_T) / FALL_T, 0.0, 1.0)
		var accel: float = ft * ft
		rock.global_position = (center + Vector3(0, SKY_H, 0)).lerp(center + Vector3(0, 0.5, 0), accel)
		rock.rotate_y(delta * 5.0)
		if ft >= 1.0:
			_impact()
	if elapsed >= total_life:
		queue_free()

func _impact() -> void:
	impacted = true
	if rock != null:
		rock.visible = false
	if marker != null:
		marker.queue_free()
		marker = null
	if main.has_method("spawn_skill_flash"):
		main.spawn_skill_flash(center + Vector3(0, 0.4, 0), Color(1.0, 0.55, 0.16, 1), MINI_R + 0.6, 0.7)
	_spawn_shards()
	if not visual_only and main.combat != null:
		# 友伤命中其他怪物+玩家；击飞落地后眩晕（0.1 + 0.05×等级）。
		main.combat.apply_meteor_ground_impact(center + Vector3(0, 0.3, 0), MINI_R, dmg, source, 8.0, 0.1 + 0.05 * float(level))

func _build_marker() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = MINI_R
	mesh.bottom_radius = MINI_R
	mesh.height = 0.035
	mesh.radial_segments = 40
	marker = MeshInstance3D.new()
	marker.mesh = mesh
	marker.global_position = center + Vector3(0, 0.035, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.4, 0.10, 0.30)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.32, 0.07, 1)
	mat.emission_energy_multiplier = 1.4
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	marker.material_override = mat
	add_child(marker)

func _build_rock() -> void:
	rock = Node3D.new()
	add_child(rock)
	var rm := SphereMesh.new()
	rm.radius = 0.55
	rm.height = 1.0
	var core := MeshInstance3D.new()
	core.mesh = rm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.33, 0.14, 0.08, 1)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.40, 0.08, 1)
	mat.emission_energy_multiplier = 1.8
	core.material_override = mat
	rock.add_child(core)
	var tail := CylinderMesh.new()
	tail.top_radius = 0.08
	tail.bottom_radius = 0.7
	tail.height = 2.6
	var tnode := MeshInstance3D.new()
	tnode.mesh = tail
	tnode.position = Vector3(0, 1.5, 0)
	var tmat := StandardMaterial3D.new()
	tmat.albedo_color = Color(1.0, 0.28, 0.05, 0.36)
	tmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tmat.emission_enabled = true
	tmat.emission = Color(1.0, 0.3, 0.06, 1)
	tmat.emission_energy_multiplier = 2.2
	tnode.material_override = tmat
	rock.add_child(tnode)
	rock.global_position = center + Vector3(0, SKY_H, 0)

func _spawn_shards() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i: int in range(8):
		var sm := BoxMesh.new()
		sm.size = Vector3(rng.randf_range(0.12, 0.3), rng.randf_range(0.1, 0.22), rng.randf_range(0.14, 0.34))
		var shard := MeshInstance3D.new()
		shard.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.32, 0.15, 0.09, 1)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.35, 0.08, 1)
		mat.emission_energy_multiplier = 1.1
		shard.material_override = mat
		shard.global_position = center + Vector3(0, 0.3, 0)
		add_child(shard)
		var ang: float = TAU * float(i) / 8.0 + rng.randf_range(-0.2, 0.2)
		var dir := Vector3(cos(ang), 0, sin(ang))
		var dist: float = rng.randf_range(1.2, 3.0)
		var endp: Vector3 = center + dir * dist + Vector3(0, 0.1, 0)
		var tw := create_tween()
		tw.tween_property(shard, "global_position", center + dir * (dist * 0.5) + Vector3(0, rng.randf_range(0.6, 1.4), 0), 0.16).set_ease(Tween.EASE_OUT)
		tw.tween_property(shard, "global_position", endp, 0.26).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
		tw.tween_callback(shard.queue_free)
