extends Node3D

var main: Node = null
var caster: StarGloryPlayer = null
var direction: Vector3 = Vector3(0, 0, -1)
var elapsed: float = 0.0
var target: Vector3 = Vector3.ZERO
var meteor_start: Vector3 = Vector3.ZERO
var meteor_end: Vector3 = Vector3.ZERO
var meteor: Node3D = null
var target_marker: Decal = null
var impact_done: bool = false
var target_locked: bool = false
var total_life: float = 2.85
var meteor_spawn_time: float = 0.66
var meteor_fall_duration: float = 1.18
var meteor_hit_radius: float = 2.25
var meteor_hits: Dictionary = {}
var damage_mult: float = 1.0   # 由 SkillManager 按技能等级注入
var skill_level: int = 0       # 由 SkillManager 注入；用于按等级放大范围
var radius_mult: float = 1.0   # 范围随技能等级放大（每级 +8%）
var cast_seq: int = -999       # 施法序号；与 caster.cast_seq 不符则被打断
var remote: bool = false       # 联机：他人施法在本地的纯表现（不升空、不结算、目标取朝向前方）
var remote_target: Vector3 = Vector3.ZERO   # 联机：同步过来的真实落点（非零则优先）
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

func start(p_main: Node, p_caster: StarGloryPlayer, p_direction: Vector3) -> void:
	main = p_main
	caster = p_caster
	direction = p_direction.normalized()
	rng.randomize()
	if caster == null:
		queue_free()
		return
	radius_mult = 1.0 + 0.18 * float(skill_level)   # 范围成长率提高（每级 +18%）
	meteor_hit_radius *= radius_mult
	if not remote:
		caster.face_direction(direction)
		caster.lock_for_skill(total_life, false, false)
		caster.set_forced_pose("meteor", total_life)
	_update_target(0.0)
	_build_target_marker()
	# 前摇期间可调落点：PC 鼠标 / 手机摇杆 / 点按世界；前摇结束（陨石生成）才锁定。
	target_locked = false
	if main != null and not remote:
		main.begin_skill_aim(target)
		main.flash_message("天星：移动鼠标/摇杆或点按选择落点。")

func _process(delta: float) -> void:
	if caster == null or not is_instance_valid(caster):
		queue_free()
		return
	if not remote and caster.cast_seq != cast_seq:   # 被击退打断：清姿势、中止
		caster.clear_forced_pose("meteor")
		if main != null:
			main.end_skill_aim()
		queue_free()
		return
	elapsed += delta
	if not target_locked:
		_update_target(delta)
		_update_target_marker()
	if elapsed >= meteor_spawn_time and meteor == null:
		_lock_meteor_path()
		_build_meteor()
	if meteor != null and not impact_done:
		_update_meteor_fall(delta)
	if elapsed >= total_life:
		if not remote:
			caster.clear_forced_pose("meteor")
		queue_free()

func _update_target(delta: float) -> void:
	# 本地：前摇期间用统一瞄准（鼠标/摇杆/点按）控制落点；联机表现取朝向前方。
	if not remote and main != null and main.has_method("update_skill_aim"):
		target = main.update_skill_aim(delta)
		var to_target: Vector3 = target - caster.global_position
		to_target.y = 0.0
		if to_target.length() > 0.2:
			direction = to_target.normalized()
			caster.face_direction(direction)
	elif remote_target != Vector3.ZERO:
		target = remote_target
	else:
		target = caster.global_position + direction * 10.0
	target.y = _ground_y(target)

func _lock_meteor_path() -> void:
	target_locked = true
	if main != null and not remote:
		main.end_skill_aim()
	if target_marker != null:
		target_marker.visible = false
	var sky_offset: Vector3 = -direction * 3.8 + Vector3(0, 24.0, 0)
	meteor_start = target + sky_offset
	meteor_end = target + Vector3(0, 0.55, 0)

func _build_target_marker() -> void:
	var r: float = 3.8 * radius_mult
	target_marker = Decal.new()
	target_marker.name = "MeteorTargetMarker"
	if main != null:
		target_marker.texture_albedo = main.ground_marker_texture()
	target_marker.modulate = Color(1.0, 0.48, 0.12, 0.78)
	target_marker.emission_energy = 0.0
	target_marker.albedo_mix = 1.0
	target_marker.size = Vector3(r * 2.0, 42.0, r * 2.0)
	add_child(target_marker)
	_update_target_marker()

func _update_target_marker() -> void:
	if target_marker == null:
		return
	var gy: float = _ground_y(target)
	target_marker.global_position = Vector3(target.x, gy + 21.0, target.z)
	var pulse: float = 0.8 + sin(elapsed * 8.0) * 0.2
	target_marker.modulate = Color(1.0, 0.48, 0.12, 0.78 * pulse)

func _ground_y(pos: Vector3) -> float:
	if main != null and main.has_method("terrain_height"):
		return main.terrain_height(pos.x, pos.z)
	return 0.0

func _build_meteor() -> void:
	meteor = Node3D.new()
	meteor.name = "TrajectoryLockedMeteor"
	add_child(meteor)
	meteor.global_position = meteor_start

	var rock_mesh: SphereMesh = SphereMesh.new()
	rock_mesh.radius = 1.0
	rock_mesh.height = 1.8
	rock_mesh.radial_segments = 32
	rock_mesh.rings = 16
	var rock: MeshInstance3D = MeshInstance3D.new()
	rock.name = "CoreRock"
	rock.mesh = rock_mesh
	rock.scale = Vector3(1.35, 1.15, 1.35)
	rock.material_override = _meteor_mat(Color(0.33, 0.14, 0.08, 1), Color(1.0, 0.40, 0.08, 1), 1.9)
	meteor.add_child(rock)

	for i: int in range(9):
		var spike_mesh: BoxMesh = BoxMesh.new()
		spike_mesh.size = Vector3(rng.randf_range(0.24, 0.48), rng.randf_range(0.16, 0.34), rng.randf_range(0.24, 0.54))
		var spike: MeshInstance3D = MeshInstance3D.new()
		spike.mesh = spike_mesh
		spike.material_override = _meteor_mat(Color(0.20, 0.12, 0.09, 1), Color(1.0, 0.25, 0.06, 1), 0.7)
		spike.position = Vector3(rng.randf_range(-0.85, 0.85), rng.randf_range(-0.62, 0.62), rng.randf_range(-0.85, 0.85))
		spike.rotation = Vector3(rng.randf_range(0, TAU), rng.randf_range(0, TAU), rng.randf_range(0, TAU))
		meteor.add_child(spike)

	var tail_mesh: CylinderMesh = CylinderMesh.new()
	tail_mesh.top_radius = 0.16
	tail_mesh.bottom_radius = 1.45
	tail_mesh.height = 5.0
	tail_mesh.radial_segments = 24
	var tail: MeshInstance3D = MeshInstance3D.new()
	tail.name = "FlameTail"
	tail.mesh = tail_mesh
	tail.position = Vector3(0, 2.7, 0)
	tail.material_override = _transparent_mat(Color(1.0, 0.28, 0.05, 0.36), 2.4)
	meteor.add_child(tail)

	if main != null:
		main.spawn_skill_flash(target + Vector3(0, 0.08, 0), Color(1.0, 0.50, 0.10, 1), 6.0 * radius_mult, 0.75)

func _update_meteor_fall(delta: float) -> void:
	var fall_t: float = clamp((elapsed - meteor_spawn_time) / meteor_fall_duration, 0.0, 1.0)
	var accel_t: float = fall_t * fall_t
	meteor.global_position = meteor_start.lerp(meteor_end, accel_t)
	meteor.scale = Vector3.ONE * (1.0 + fall_t * 0.45)
	meteor.rotate_y(delta * 3.8)
	meteor.rotate_x(delta * 2.4)
	if not remote and main != null and main.combat != null:
		var direct_damage: int = int((caster.magic * 1.55 + caster.attack + 28) * damage_mult)
		main.combat.apply_meteor_body_collision(meteor.global_position, meteor_hit_radius, direct_damage, caster, 13.0, meteor_hits)
	if fall_t >= 1.0:
		_impact()

func _impact() -> void:
	impact_done = true
	if meteor != null:
		meteor.visible = false
	if main != null:
		if not remote:
			# 击飞落地后眩晕：0.1 + 0.05×技能等级。
			main.combat.apply_meteor_ground_impact(target + Vector3(0, 0.4, 0), 7.3 * radius_mult, int((caster.magic * 3 + caster.attack + 58) * damage_mult), caster, 10.5, 0.1 + 0.05 * float(skill_level))
		main.spawn_skill_flash(target + Vector3(0, 0.58, 0), Color(1.0, 0.70, 0.18, 1), 7.8 * radius_mult, 0.95)
		if not remote:
			main.flash_message("天星坠地，陨石碎裂！")
	_spawn_shards(target)

func _spawn_shards(center: Vector3) -> void:
	for i: int in range(20):
		var shard_mesh: BoxMesh = BoxMesh.new()
		shard_mesh.size = Vector3(rng.randf_range(0.18, 0.48), rng.randf_range(0.14, 0.36), rng.randf_range(0.20, 0.56))
		var shard: MeshInstance3D = MeshInstance3D.new()
		shard.name = "MeteorShard"
		shard.mesh = shard_mesh
		shard.material_override = _meteor_mat(Color(0.31, 0.15, 0.09, 1), Color(1.0, 0.35, 0.08, 1), 1.2)
		shard.global_position = center + Vector3(0, 0.38, 0)
		shard.rotation = Vector3(rng.randf_range(0, TAU), rng.randf_range(0, TAU), rng.randf_range(0, TAU))
		add_child(shard)
		var angle: float = TAU * float(i) / 20.0 + rng.randf_range(-0.18, 0.18)
		var dir: Vector3 = Vector3(cos(angle), 0, sin(angle)).normalized()
		var dist: float = rng.randf_range(2.4, 6.8)
		var mid: Vector3 = center + dir * (dist * 0.55) + Vector3(0, rng.randf_range(1.0, 2.8), 0)
		var end_pos: Vector3 = center + dir * dist + Vector3(0, 0.12, 0)
		var tween: Tween = create_tween()
		tween.tween_property(shard, "global_position", mid, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(shard, "global_position", end_pos, 0.30).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
		tween.parallel().tween_property(shard, "rotation", shard.rotation + Vector3(rng.randf_range(1.5, 4.5), rng.randf_range(1.5, 4.5), rng.randf_range(1.5, 4.5)), 0.48)
		tween.parallel().tween_property(shard, "scale", Vector3.ONE * 0.42, 0.36).set_delay(0.18)
		tween.tween_callback(shard.queue_free)

func _meteor_mat(color: Color, emission_color: Color, emission_energy: float) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.82
	mat.emission_enabled = true
	mat.emission = emission_color
	mat.emission_energy_multiplier = emission_energy
	return mat

func _transparent_mat(color: Color, emission_energy: float) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = emission_energy
	return mat
