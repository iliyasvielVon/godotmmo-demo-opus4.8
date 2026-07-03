extends Node3D

var main: Node = null
var caster: StarGloryPlayer = null
var direction: Vector3 = Vector3(0, 0, -1)
var elapsed: float = 0.0
var target: Vector3 = Vector3.ZERO
var total_life: float = 4.25
var aim_duration: float = 0.92
var rain_duration: float = 2.82
var rain_radius: float = 6.2
var tick_interval: float = 0.34
var tick_timer: float = 0.05
var target_locked: bool = false
var _marker_lit: bool = false   # 火雨开始时把落区标记点亮（与落点锁定解耦）
var target_marker: Decal = null
var _marker_col: Color = Color(1.0, 0.34, 0.08, 0.55)
var damage_mult: float = 1.0   # 由 SkillManager 按技能等级注入
var skill_level: int = 0       # 由 SkillManager 注入；用于按等级放大范围
var cast_seq: int = -999       # 施法序号；与 caster.cast_seq 不符则被打断
var remote: bool = false       # 联机：他人施法在本地的纯表现（不升空、不结算、落区取朝向前方）
var remote_target: Vector3 = Vector3.ZERO   # 联机：同步过来的真实落区中心（非零则优先）
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

func start(p_main: Node, p_caster: StarGloryPlayer, p_direction: Vector3) -> void:
	main = p_main
	caster = p_caster
	direction = p_direction.normalized()
	rng.randomize()
	if caster == null:
		queue_free()
		return
	# 范围随技能等级放大（每级 +18%）；rain_radius 同时用于标记/伤害判定/落雨散布，统一缩放。
	rain_radius *= (1.0 + 0.18 * float(skill_level))
	if not remote:
		caster.face_direction(direction)
		caster.lock_for_skill(total_life, false, false)
		caster.set_forced_pose("fire_rain", total_life)
	_update_target(0.0)
	_build_target_marker()
	# 前摇期间可调落区：PC 鼠标 / 手机摇杆 / 点按世界；火雨开始（aim_duration）才锁定。
	target_locked = false
	if main != null and not remote:
		main.begin_skill_aim(target)
		main.flash_message("火焰雨：移动鼠标/摇杆或点按选择落区。")

func _process(delta: float) -> void:
	if caster == null or not is_instance_valid(caster):
		queue_free()
		return
	if not remote and caster.cast_seq != cast_seq:   # 被击退打断：清姿势、中止
		caster.clear_forced_pose("fire_rain")
		if main != null:
			main.end_skill_aim()
		queue_free()
		return
	elapsed += delta
	if not target_locked:
		_update_target(delta)
		_update_target_marker()
	if elapsed >= aim_duration and not _marker_lit:
		_marker_lit = true
		target_locked = true   # 前摇结束：锁定落区
		if not remote and main != null:
			main.end_skill_aim()
		_marker_col = Color(1.0, 0.22, 0.05, 0.8)   # 火雨开始：落区点亮加深
		_update_target_marker()
	if elapsed >= aim_duration and elapsed <= aim_duration + rain_duration:
		tick_timer -= delta
		if tick_timer <= 0.0:
			tick_timer += tick_interval
			_do_rain_tick()
	if elapsed >= total_life:
		if not remote:
			caster.clear_forced_pose("fire_rain")
		queue_free()

func _update_target(delta: float) -> void:
	# 本地：前摇期间用统一瞄准（鼠标/摇杆/点按）控制落区；联机表现取朝向前方。
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
		target = caster.global_position + direction * 11.0
	target.y = _ground_y(target)

func _build_target_marker() -> void:
	target_marker = Decal.new()
	target_marker.name = "FireRainTargetMarker"
	if main != null:
		target_marker.texture_albedo = main.ground_marker_texture()
	target_marker.modulate = _marker_col
	target_marker.emission_energy = 0.0
	target_marker.albedo_mix = 1.0
	target_marker.size = Vector3(rain_radius * 2.0, 42.0, rain_radius * 2.0)
	add_child(target_marker)
	_update_target_marker()

func _update_target_marker() -> void:
	if target_marker == null:
		return
	var gy: float = _ground_y(target)
	target_marker.global_position = Vector3(target.x, gy + 21.0, target.z)
	var pulse: float = 0.82 + sin(elapsed * 7.5) * 0.18
	target_marker.modulate = Color(_marker_col.r, _marker_col.g, _marker_col.b, _marker_col.a * pulse)

func _ground_y(pos: Vector3) -> float:
	if main != null and main.has_method("terrain_height"):
		return main.terrain_height(pos.x, pos.z)
	return 0.0

func _do_rain_tick() -> void:
	if main == null or caster == null:
		return
	var direct_damage: int = int((caster.magic * 0.72 + 14.0) * damage_mult)
	var burn_damage: int = int((caster.magic * 0.28 + 5.0) * damage_mult)
	if not remote and main.combat != null:
		main.combat.apply_fire_rain_tick(target + Vector3(0, 0.45, 0), rain_radius, direct_damage, burn_damage, 3.2, caster)
	for i: int in range(7):
		_spawn_fire_drop()
	if rng.randf() < 0.45 and main.has_method("spawn_skill_flash"):
		main.spawn_skill_flash(target + Vector3(rng.randf_range(-2.0, 2.0), 0.35, rng.randf_range(-2.0, 2.0)), Color(1.0, 0.26, 0.05, 1), rng.randf_range(1.0, 1.7), 0.20)

func _spawn_fire_drop() -> void:
	var angle: float = rng.randf_range(0.0, TAU)
	var dist: float = sqrt(rng.randf()) * rain_radius
	var ground_pos: Vector3 = target + Vector3(cos(angle) * dist, 0.18, sin(angle) * dist)
	var start_pos: Vector3 = ground_pos + Vector3(rng.randf_range(-0.45, 0.45), rng.randf_range(10.5, 15.5), rng.randf_range(-0.45, 0.45))
	var mesh: CylinderMesh = CylinderMesh.new()
	mesh.top_radius = 0.06
	mesh.bottom_radius = 0.18
	mesh.height = rng.randf_range(1.8, 2.8)
	mesh.radial_segments = 16
	var drop: MeshInstance3D = MeshInstance3D.new()
	drop.name = "FireRainDrop"
	drop.mesh = mesh
	drop.global_position = start_pos
	drop.material_override = _transparent_mat(Color(1.0, 0.28, 0.05, 0.78), 2.8)
	add_child(drop)
	var tween: Tween = create_tween()
	tween.tween_property(drop, "global_position", ground_pos, rng.randf_range(0.22, 0.34)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(drop, "scale", Vector3(0.55, 1.25, 0.55), 0.24)
	tween.tween_callback(drop.queue_free)

func _transparent_mat(color: Color, emission_energy: float) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = emission_energy
	return mat
