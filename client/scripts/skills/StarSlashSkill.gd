extends Node3D

# 星斩：三段连击。短冷却可连按，第三段为收尾重击（范围/伤害/击退更大）。
# 每段交替左右挥砍并带轻微前冲，提升打击感。

var main: Node = null
var caster: StarGloryPlayer = null
var direction: Vector3 = Vector3(0, 0, -1)
var life: float = 0.24
var damage_mult: float = 1.0   # 由 SkillManager 按技能等级注入
var skill_level: int = 0       # 由 SkillManager 注入
var remote: bool = false       # 联机：他人施法在本地的纯表现（不改 caster 状态、不结算伤害）
var combo_step: int = 0
var arc_color: Color = Color(0.55, 0.95, 1.0, 1)
var arc_tilt: float = 0.95

func start(p_main: Node, p_caster: StarGloryPlayer, p_direction: Vector3) -> void:
	main = p_main
	caster = p_caster
	direction = p_direction.normalized()
	if caster == null:
		queue_free()
		return
	# 御云飞行中：普通攻击改为远程速射（低伤害高频，随等级提升）。
	# 普通跳跃不算飞行，仍沿用地面三段星斩。
	if _is_flight_attack():
		_aerial_ranged()
		return
	combo_step = caster.slash_combo
	if not remote:
		# 推进连击并续上衔接窗口。
		caster.slash_combo = (combo_step + 1) % 3
		caster.slash_combo_timer = 0.65
		caster.face_direction(direction)

	# 每段参数：第三段为收尾重击。范围随技能等级放大（每级 +8%）。
	var rmul: float = 1.0 + 0.08 * float(skill_level)
	var is_finisher: bool = combo_step == 2
	var radius: float = (2.4 if not is_finisher else 3.4) * rmul
	var dmg_base: int = (caster.attack + 14) if not is_finisher else (caster.attack * 2 + 24)
	var knockback: float = 3.0 if not is_finisher else 7.5
	var lock: float = 0.18 if not is_finisher else 0.3
	life = 0.2 if not is_finisher else 0.32
	arc_tilt = 0.95 if combo_step == 0 else (-0.95 if combo_step == 1 else 0.2)
	arc_color = Color(0.55, 0.95, 1.0, 1) if not is_finisher else Color(1.0, 0.85, 0.45, 1)

	if not remote:
		if caster.is_on_floor():
			# 地面普通攻击：锁定移动（出招时不能走动，速度归零）。
			caster.lock_for_skill(lock, false, true)
		else:
			# 跳跃在空中攻击：停止「主动移动」但保留惯性（不归零速度，仅忽略输入）。
			caster.lock_for_skill(lock, false, false)
			caster.skill_input_locked = true
			caster.skill_input_lock_timer = lock
		caster.start_temporary_pose("slash" if combo_step == 0 else ("slash2" if combo_step == 1 else "slash3"), lock + 0.05)

	global_position = caster.global_position + direction * 1.7 + Vector3(0, 1.0, 0)
	_build_arc_visual()
	if main != null:
		if not remote:
			main.combat.apply_area_damage(global_position, radius, int(dmg_base * damage_mult), caster, 0.0, knockback)
		main.spawn_skill_flash(global_position, arc_color, (1.6 if not is_finisher else 2.4) * rmul, 0.18)

# 是否进入飞行攻击模式：仅御云飞行时为真。普通跳跃（仅离地）不算，
# 这样跳起过程中依然使用与地面相同的三段普攻。本地与傀儡都按 flying_cloud 判断
# （傀儡的 flying_cloud 由 set_puppet_flying 依服务器同步设置）。
func _is_flight_attack() -> bool:
	return caster.flying_cloud

# 空中速射：朝最近目标（怪物或炮台等建筑，含向下）自动索敌发射一枚星弹；伤害为普攻的 ratio（随角色等级提高，起步 20%）。
func _aerial_ranged() -> void:
	var ratio: float = minf(0.60, 0.20 + 0.025 * float(caster.level - 1))
	var dmg: int = max(1, int((caster.attack + 14) * damage_mult * ratio))
	var muzzle: Vector3 = caster.global_position + Vector3(0, 1.1, 0)
	var dir: Vector3 = direction
	var locked: Node3D = null
	if main != null and main.has_method("get_nearest_target"):
		var tgt = main.get_nearest_target(muzzle)
		if tgt != null and is_instance_valid(tgt):
			locked = tgt
			var aim: Vector3 = tgt.aim_point() if tgt.has_method("aim_point") else tgt.global_position
			var d3: Vector3 = aim - muzzle
			if d3.length() > 0.2:
				dir = d3.normalized()
	if not remote:
		caster.face_direction(Vector3(dir.x, 0.0, dir.z))
	# 空中速射对建筑（炮塔/塔）保底命中：高空斜射时弹体易擦过塔体，故对锁定的建筑直接结算一次，
	# 同时把弹体改为纯表现（visual_only），避免再命中造成双倍。
	var hit_building: bool = not remote and locked != null and is_instance_valid(locked) \
		and locked.is_in_group("building") and locked.has_method("take_damage")
	if hit_building:
		var hd: float = Vector2(locked.global_position.x - caster.global_position.x, locked.global_position.z - caster.global_position.z).length()
		if hd <= 26.0:
			locked.take_damage(dmg, caster)
		else:
			hit_building = false
	if main != null:
		main.spawn_skill_flash(muzzle + dir * 0.4, Color(0.6, 0.95, 1.0, 1), 0.55, 0.12)
		main.spawn_projectile({
			"position": muzzle + dir * 0.4,
			"direction": dir,
			"speed": 30.0,
			"damage": dmg,
			"radius": 0.28,
			"color": Color(0.66, 0.95, 1.0, 1),
			"source": caster,
			"visual_only": remote or hit_building
		})
	queue_free()

func _process(delta: float) -> void:
	life -= delta
	rotate_y(delta * 9.0)
	if life <= 0.0:
		queue_free()

func _build_arc_visual() -> void:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(arc_color.r, arc_color.g, arc_color.b, 0.58)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = arc_color
	mat.emission_energy_multiplier = 1.8
	var n: int = 5 if combo_step != 2 else 7
	for i: int in range(n):
		var mesh: BoxMesh = BoxMesh.new()
		mesh.size = Vector3(0.18, 0.08, 1.75 - float(i) * 0.16)
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		mi.position = Vector3((float(i) - float(n - 1) * 0.5) * 0.26, 0.0, -0.15)
		mi.rotation = Vector3(0.0, float(i) * 0.16 * sign(arc_tilt), arc_tilt)
		add_child(mi)
