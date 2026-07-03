extends Node3D

# 焰弹：在角色朝向的正面锥范围内自动索敌，朝最近敌人直线发射（非追踪）。
# 0 阶无爆炸，仅直接命中；升阶解锁命中爆炸（每阶提升范围与爆炸伤害）。
# 每升 3 级，释放时额外多发一枚（多目标优先锁定锥内最近的几只，不足则朝朝向小扇形补发）。

const CONE_COS := 0.5   # 锥半角 60°（正面 120° 弧）

var main: Node = null
var caster: StarGloryPlayer = null
var direction: Vector3 = Vector3(0, 0, -1)   # 蓄力期间的水平朝向
var elapsed: float = 0.0
var charge_duration: float = 0.68
var launched: bool = false
var damage_mult: float = 1.0   # 由 SkillManager 按技能等级注入
var skill_level: int = 0       # 由 SkillManager 注入；>=1 才有爆炸
var cast_seq: int = -999       # 施法序号；与 caster.cast_seq 不符则被打断
var remote: bool = false       # 联机：他人施法在本地的纯表现（弹道为表现弹，不结算伤害）
var charge_mesh: MeshInstance3D = null
var charge_mat: StandardMaterial3D = null

func start(p_main: Node, p_caster: StarGloryPlayer, p_direction: Vector3) -> void:
	main = p_main
	caster = p_caster
	direction = p_direction.normalized()
	if caster == null:
		queue_free()
		return
	# 御云飞行时：2 技能变炮击——朝瞄准方向直射炮弹，引信到时或撞到任意单位即全体爆炸。
	if caster.flying_cloud:
		_fire_cannon()
		queue_free()
		return
	if not remote:
		caster.lock_for_skill(0.92, false, false)
		caster.set_forced_pose("fireball_charge", 0.95)
	var h: Vector3 = _primary_horizontal()
	if h.length() > 0.01:
		direction = h
	if not remote:
		caster.face_direction(direction)
	_build_charge_visual()

func _process(delta: float) -> void:
	if caster == null or not is_instance_valid(caster):
		queue_free()
		return
	if caster.cast_seq != cast_seq:   # 被击退打断
		caster.clear_forced_pose("fireball_charge")
		queue_free()
		return
	elapsed += delta
	# 蓄力期间把朝向更新到锥内最近敌人（仅水平），不会转向背后的敌人。
	var h: Vector3 = _primary_horizontal()
	if h.length() > 0.01:
		direction = h
		if not remote:
			caster.face_direction(direction)
	var tip: Vector3 = caster.get_finger_tip_global_position()
	global_position = tip + direction * 0.26
	var t: float = clamp(elapsed / charge_duration, 0.0, 1.0)
	if charge_mesh != null:
		charge_mesh.scale = Vector3.ONE * (0.35 + t * 1.15)
		charge_mesh.rotate_y(delta * 7.0)
		charge_mesh.rotate_x(delta * 4.0)
	if charge_mat != null:
		charge_mat.emission_energy_multiplier = 1.8 + t * 2.2
	if elapsed >= charge_duration and not launched:
		_launch()

# 锥内目标列表（怪物 + 炮台等建筑，按距离近→远）。
func _cone_targets() -> Array[Node3D]:
	var muzzle: Vector3 = caster.get_finger_tip_global_position()
	if main != null and main.has_method("get_targets_in_cone"):
		return main.get_targets_in_cone(muzzle, caster.last_facing_dir, CONE_COS)
	return [] as Array[Node3D]

# 目标瞄准点：优先用碰撞体中心 aim_point，缺省回退到原点。
func _aim_point_of(t: Node3D) -> Vector3:
	if t.has_method("aim_point"):
		return t.call("aim_point")
	return t.global_position

# 蓄力期朝向：锥内最近敌人的水平方向，无则保持角色当前朝向。
func _primary_horizontal() -> Vector3:
	var targets: Array[Node3D] = _cone_targets()
	if targets.size() > 0:
		var muzzle: Vector3 = caster.get_finger_tip_global_position()
		var d: Vector3 = targets[0].global_position - muzzle
		d.y = 0.0
		if d.length() > 0.1:
			return d.normalized()
	return caster.last_facing_dir.normalized()

func _fire_cannon() -> void:
	var muzzle: Vector3 = caster.get_finger_tip_global_position()
	# 球体范围自动索敌（任意方向最近的敌人，非追踪：发射瞬间锁定其位置直线打出）。
	var dir: Vector3 = caster.last_facing_dir.normalized()
	if main != null and main.has_method("get_nearest_target"):
		var tgt: Node3D = main.get_nearest_target(muzzle)
		if tgt != null and is_instance_valid(tgt) and tgt.global_position.distance_to(muzzle) <= 40.0:
			var aim_pt: Vector3 = _aim_point_of(tgt)
			var d3: Vector3 = aim_pt - muzzle
			if d3.length() > 0.1:
				dir = d3.normalized()
	if not remote:
		caster.face_direction(Vector3(dir.x, 0, dir.z))
	var dmg: int = int((caster.attack + caster.magic * 2 + 22) * damage_mult)
	if main != null:
		main.spawn_skill_flash(muzzle, Color(1.0, 0.6, 0.2, 1), 0.8, 0.16)
		main.spawn_projectile({
			"position": muzzle + dir * 0.4,
			"direction": dir,
			"speed": 28.0,
			"damage": dmg,
			"radius": 0.42,
			"aoe": 4.0 + 0.4 * float(skill_level),
			"aoe_damage": dmg,
			"universal": true,
			"fuse": 1.7,
			"blast_knockback": 6.0,
			"color": Color(1.0, 0.4, 0.14, 1),
			"source": caster,
			"visual_only": remote
		})

func _build_charge_visual() -> void:
	var mesh: SphereMesh = SphereMesh.new()
	mesh.radius = 0.24
	mesh.height = 0.48
	mesh.radial_segments = 24
	mesh.rings = 12
	charge_mesh = MeshInstance3D.new()
	charge_mesh.mesh = mesh
	charge_mat = StandardMaterial3D.new()
	charge_mat.albedo_color = Color(1.0, 0.34, 0.12, 0.82)
	charge_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	charge_mat.emission_enabled = true
	charge_mat.emission = Color(1.0, 0.34, 0.12, 1)
	charge_mat.emission_energy_multiplier = 2.0
	charge_mesh.material_override = charge_mat
	add_child(charge_mesh)

func _launch() -> void:
	launched = true
	if not remote and caster != null and is_instance_valid(caster):
		caster.clear_forced_pose("fireball_charge")
	if main == null:
		queue_free()
		return
	var muzzle: Vector3 = caster.get_finger_tip_global_position()
	var facing: Vector3 = caster.last_facing_dir.normalized()
	var targets: Array[Node3D] = _cone_targets()

	var direct_damage: int = int((caster.attack + caster.magic * 2 + 20) * damage_mult)
	var aoe: float = 0.0
	var blast: int = 0
	if skill_level >= 1:
		aoe = 2.2 + 0.7 * float(skill_level - 1)
		blast = int(direct_damage * (0.5 + 0.1 * float(skill_level)))

	var count: int = 1 + int(skill_level / 3)   # 每 3 级 +1 枚
	for i in range(count):
		var fire_dir: Vector3
		if i < targets.size():
			# 锁定锥内第 i 近的目标，瞄准其碰撞体中心（aim_point，可精确命中飞行怪/炮台）。
			fire_dir = (_aim_point_of(targets[i]) - muzzle).normalized()
		else:
			# 目标不足：朝朝向做小扇形补发（±0.16 rad 交替）。
			var extra: int = i - targets.size()
			var sign_v: float = 1.0 if (extra % 2 == 0) else -1.0
			var step: float = 0.16 * float(extra / 2 + 1)
			fire_dir = facing.rotated(Vector3.UP, sign_v * step)
		var spawn_pos: Vector3 = muzzle + fire_dir * 0.26
		main.spawn_skill_flash(spawn_pos, Color(1.0, 0.45, 0.12, 1), 0.7, 0.16)
		main.spawn_projectile({
			"position": spawn_pos,
			"direction": fire_dir,
			"speed": 21.5,
			"damage": direct_damage,
			"radius": 0.36,
			"aoe": aoe,
			"aoe_damage": blast,
			"color": Color(1.0, 0.36, 0.14, 1),
			"source": caster,
			"visual_only": remote
		})
	queue_free()
