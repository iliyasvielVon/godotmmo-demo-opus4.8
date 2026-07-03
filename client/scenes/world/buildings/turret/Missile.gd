class_name StarGloryMissile
extends Node3D

# 炮塔弹：升空后沿二次贝塞尔曲线弧线飞向目标。按 bullet_type 表现不同：
#   aimed  瞄准弹：低弧、速度快、打发射瞬间锁定的旧位置
#   homing 追踪弹：高弧 + 每帧更新目标为玩家当前位置
#   missile导弹  ：高弧、打旧位置
#   split  分裂弹：高弧；下落段分裂成多枚小弹覆盖目标区域
#   frost  冰霜弹：高弧；落地范围减速 + 中心冰冻
# 普通弹落地走无差别物理爆炸；冰霜弹走冰霜结算。

var main: Node = null
var source: Node = null
var p0: Vector3 = Vector3.ZERO
var target: Vector3 = Vector3.ZERO
var bullet_type: String = "missile"
var no_split: bool = false   # 分裂出的子弹不再分裂
var damage: int = 32
var aoe: float = 5.5
var knockback: float = 13.0
var sky_h: float = 16.0
var speed: float = 40.0
var t: float = 0.0
var flight_time: float = 1.2
var exploded: bool = false
var split_done: bool = false

const ChildScene = preload("res://scenes/world/buildings/turret/Missile.tscn")

func setup(data: Dictionary) -> void:
	main = data.get("main", null)
	source = data.get("source", null)
	p0 = data.get("start", Vector3.ZERO) as Vector3
	target = data.get("target", Vector3.ZERO) as Vector3
	bullet_type = String(data.get("bullet_type", bullet_type))
	no_split = bool(data.get("no_split", false))
	damage = int(data.get("damage", damage))
	aoe = float(data.get("aoe", aoe))
	knockback = float(data.get("knockback", knockback))

func _ready() -> void:
	if main == null:
		main = get_tree().current_scene
	global_position = p0
	# 瞄准弹低弧更快；其余高弧。
	if bullet_type == "aimed":
		sky_h = 3.0
		speed = 58.0
	elif bullet_type == "firework":
		sky_h = 24.0
		speed = 26.0
	elif bullet_type == "firework_bomb":
		sky_h = 2.0
		speed = 24.0
	flight_time = clamp(p0.distance_to(target) / speed, 0.6, 2.6)
	_build_model()

func _build_model() -> void:
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.78, 0.80, 0.85, 1)
	body_mat.metallic = 0.5
	body_mat.roughness = 0.4
	var nose_col := Color(0.85, 0.2, 0.15, 1)
	if bullet_type == "frost":
		nose_col = Color(0.4, 0.8, 1.0, 1)
	elif bullet_type == "split":
		nose_col = Color(1.0, 0.8, 0.2, 1)
	elif bullet_type == "homing":
		nose_col = Color(0.9, 0.3, 0.9, 1)
	elif bullet_type == "firework":
		nose_col = Color.from_hsv(randf(), 0.85, 1.0)
	elif bullet_type == "firework_bomb":
		nose_col = Color(1.0, 0.35 + randf() * 0.25, 0.1, 1)
	var nose_mat := StandardMaterial3D.new()
	nose_mat.albedo_color = nose_col
	nose_mat.emission_enabled = true
	nose_mat.emission = nose_col
	nose_mat.emission_energy_multiplier = 0.9
	var flame_mat := StandardMaterial3D.new()
	flame_mat.albedo_color = Color(1.0, 0.6, 0.15, 0.7)
	flame_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flame_mat.emission_enabled = true
	flame_mat.emission = Color(1.0, 0.5, 0.1, 1)
	flame_mat.emission_energy_multiplier = 2.2

	# 模型沿 -Z 为前进方向（与 look_at 一致）。
	var body := CylinderMesh.new()
	body.top_radius = 0.16
	body.bottom_radius = 0.16
	body.height = 1.0
	_add(body, body_mat, Vector3(0, 0, 0.1), Vector3(PI / 2.0, 0, 0))
	var nose := CylinderMesh.new()
	nose.top_radius = 0.0
	nose.bottom_radius = 0.16
	nose.height = 0.4
	_add(nose, nose_mat, Vector3(0, 0, -0.6), Vector3(-PI / 2.0, 0, 0))
	var tail := CylinderMesh.new()
	tail.top_radius = 0.34
	tail.bottom_radius = 0.05
	tail.height = 0.7
	_add(tail, flame_mat, Vector3(0, 0, 0.85), Vector3(PI / 2.0, 0, 0))
	for ang in [0.0, PI * 0.5, PI, PI * 1.5]:
		var fin := BoxMesh.new()
		fin.size = Vector3(0.05, 0.28, 0.3)
		var mi := _add(fin, body_mat, Vector3(cos(ang) * 0.18, sin(ang) * 0.18, 0.45))
		mi.rotation.z = ang

func _add(mesh: Mesh, mat: Material, pos: Vector3, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	add_child(mi)
	return mi

func _physics_process(delta: float) -> void:
	if exploded:
		return
	t += delta / flight_time
	# 追踪弹：每帧更新目标为玩家当前位置。
	if bullet_type == "homing" and main != null and main.player != null and is_instance_valid(main.player):
		target = main.player.global_position
	var p1: Vector3 = (p0 + target) * 0.5 + Vector3(0, sky_h + p0.distance_to(target) * 0.15, 0)
	var ct: float = clamp(t, 0.0, 1.0)
	var pos: Vector3 = _bezier(p0, p1, target, ct)
	var nxt: Vector3 = _bezier(p0, p1, target, clamp(t + 0.03, 0.0, 1.0))
	global_position = pos
	var dir: Vector3 = nxt - pos
	if dir.length() > 0.02 and absf(dir.normalized().dot(Vector3.UP)) < 0.985:
		look_at(pos + dir, Vector3.UP)
	# 分裂弹：下落段分裂成多枚覆盖目标区域。
	if bullet_type == "firework" and not no_split and not split_done and t >= 0.66:
		_do_firework()
		return
	if bullet_type == "split" and not no_split and not split_done and t >= 0.55:
		_do_split()
		return
	if t >= 1.0:
		_impact()

func _do_split() -> void:
	split_done = true
	# 炮塔可能在分裂前就被摧毁；把已释放引用净化成 null 再传给子弹，避免后续结算时报错。
	var safe_source: Node = source if is_instance_valid(source) else null
	var count: int = 4 + (randi() % 3)   # 4~6 枚
	for i in range(count):
		var ang: float = TAU * float(i) / float(count) + randf() * 0.4
		var rr: float = aoe * (0.3 + randf() * 0.7)
		var spread_target: Vector3 = target + Vector3(cos(ang) * rr, 0, sin(ang) * rr)
		var child: Node3D = ChildScene.instantiate() as Node3D
		main.projectile_root.add_child(child)
		child.setup({
			"main": main,
			"source": safe_source,
			"start": global_position,
			"target": spread_target,
			"bullet_type": "aimed",
			"no_split": true,
			"damage": int(damage * 0.55),
			"aoe": aoe * 0.5,
			"knockback": knockback * 0.6
		})
	queue_free()

func _do_firework() -> void:
	split_done = true
	if main == null or main.projectile_root == null:
		queue_free()
		return
	var safe_source: Node = source if is_instance_valid(source) else null
	var count: int = 9
	if main != null and main.has_method("spawn_skill_flash"):
		main.spawn_skill_flash(global_position, Color.from_hsv(randf(), 0.85, 1.0), aoe * 1.2, 0.35)
	for i in range(count):
		var ang: float = TAU * float(i) / float(count) + randf_range(-0.18, 0.18)
		var rr: float = aoe * randf_range(0.35, 1.15)
		var ground: Vector3 = target + Vector3(cos(ang) * rr, 0.0, sin(ang) * rr)
		var child: Node3D = ChildScene.instantiate() as Node3D
		main.projectile_root.add_child(child)
		child.setup({
			"main": main,
			"source": safe_source,
			"start": global_position + Vector3(cos(ang) * 0.5, randf_range(0.0, 1.2), sin(ang) * 0.5),
			"target": ground,
			"bullet_type": "firework_bomb",
			"no_split": true,
			"damage": int(damage * 0.42),
			"aoe": maxf(1.8, aoe * 0.42),
			"knockback": knockback * 0.45
		})
	queue_free()

func _bezier(a: Vector3, b: Vector3, c: Vector3, k: float) -> Vector3:
	return a.lerp(b, k).lerp(b.lerp(c, k), k)

func _impact() -> void:
	exploded = true
	# 发射后炮塔可能已被摧毁(queue_free)。Godot 4 中已释放的 Node 引用不等于 null，
	# 直接把它传给 combat 的 source:Node 形参会触发类型校验报错，必须先净化成 null。
	var safe_source: Node = source if is_instance_valid(source) else null
	if main != null:
		if bullet_type == "frost":
			if main.has_method("spawn_skill_flash"):
				main.spawn_skill_flash(target + Vector3(0, 0.4, 0), Color(0.5, 0.85, 1.0, 1), aoe, 0.5)
			if main.combat != null:
				main.combat.apply_frost_blast(target, aoe, int(damage * 0.6), safe_source, 0.5, 4.0, 2.6)
		elif bullet_type == "firework_bomb":
			if main.has_method("spawn_skill_flash"):
				main.spawn_skill_flash(target + Vector3(0, 0.4, 0), Color(1.0, 0.35, 0.08, 1), aoe, 0.45)
			if main.combat != null:
				main.combat.apply_universal_blast(target, aoe, damage, safe_source, knockback)
				main.combat.apply_fire_rain_tick(target, aoe * 0.85, int(damage * 0.12), max(1, int(damage * 0.08)), 3.0, safe_source)
		else:
			if main.has_method("spawn_skill_flash"):
				main.spawn_skill_flash(target + Vector3(0, 0.4, 0), Color(1.0, 0.5, 0.12, 1), aoe, 0.5)
			if main.combat != null:
				main.combat.apply_universal_blast(target, aoe, damage, safe_source, knockback)
	queue_free()
