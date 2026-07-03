extends Node3D

# Boss「跃起砸地 + 四虚影连续冲锋」连招的纯表现时间线（不结算伤害、不控制 Boss 位置）。
# 单机由 Monster 的连招状态机在「锁定砸点」时启动；联机由傀儡收到 rpc_monster_combo 后启动。
# 时间线：脚下标记(MARK_T) → 砸地冲击+碎片+生成四道虚影 → 虚影持续至冲锋结束 → 渐隐自毁。
# Boss 本体的跃起/冲锋位移：单机由状态机驱动、联机由位置快照驱动；残影由 Monster.spawn_afterimage 触发。

const MARK_T := 0.45                 # 砸点标记预警时长（与状态机 SLAM 下砸窗口对齐）
const PHANTOM_R := 9.5               # 四道地面虚影距砸点的半径（拉远）
const COMBO_LEAP_H := 7.0            # 空中虚影高度（第 5 道残影 = 天上坠落点）
const CHARGES := 17
const CHARGE_T := 0.22
const CHARGE_GAP := 0.06
const FADE_T := 0.45                 # 虚影渐隐时长
const GHOST_COLOR := Color(0.45, 0.85, 1.0, 0.5)

var main: Node = null
var boss: Node3D = null
var center: Vector3 = Vector3.ZERO
var seed_val: int = 0
var elapsed: float = 0.0
var total_life: float = 0.0
var impacted: bool = false
var marker: MeshInstance3D = null
var phantoms: Array = []             # [{node:Node3D, mats:Array[StandardMaterial3D]}]

func start(p_main: Node, p_boss: Node3D, p_center: Vector3, p_seed: int) -> void:
	main = p_main
	boss = p_boss
	center = p_center
	center.y = max(0.0, center.y)
	seed_val = p_seed
	var charges_dur: float = float(CHARGES) * (CHARGE_T + CHARGE_GAP)
	total_life = MARK_T + charges_dur + 0.3 + FADE_T
	_build_marker()

func _process(delta: float) -> void:
	if main == null:
		queue_free()
		return
	elapsed += delta
	if marker != null and not impacted:
		var pulse: float = 1.0 + sin(elapsed * 10.0) * 0.08
		marker.scale = Vector3(pulse, 1.0, pulse)
		marker.rotate_y(delta * 1.2)
	if not impacted and elapsed >= MARK_T:
		_impact()
	# 末尾渐隐四道虚影
	var fade_start: float = total_life - FADE_T
	if elapsed >= fade_start and not phantoms.is_empty():
		var a: float = clampf(1.0 - (elapsed - fade_start) / FADE_T, 0.0, 1.0)
		for ph: Dictionary in phantoms:
			for m: StandardMaterial3D in ph["mats"]:
				m.albedo_color.a = GHOST_COLOR.a * a
	if elapsed >= total_life:
		queue_free()

func _build_marker() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 6.4
	mesh.bottom_radius = 6.4
	mesh.height = 0.04
	mesh.radial_segments = 48
	marker = MeshInstance3D.new()
	marker.name = "BossSlamMarker"
	marker.mesh = mesh
	marker.global_position = center + Vector3(0, 0.04, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.18, 0.10, 0.30)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.25, 0.06, 1)
	mat.emission_energy_multiplier = 1.5
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	marker.material_override = mat
	add_child(marker)

func _impact() -> void:
	impacted = true
	if marker != null:
		marker.queue_free()
		marker = null
	if main != null and main.has_method("spawn_skill_flash"):
		main.spawn_skill_flash(center + Vector3(0, 0.5, 0), Color(1.0, 0.62, 0.16, 1), 7.0, 0.9)
	_spawn_shards()
	_spawn_phantoms()

func _spawn_shards() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	for i: int in range(14):
		var sm := BoxMesh.new()
		sm.size = Vector3(rng.randf_range(0.18, 0.46), rng.randf_range(0.14, 0.34), rng.randf_range(0.2, 0.5))
		var shard := MeshInstance3D.new()
		shard.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.32, 0.15, 0.09, 1)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.35, 0.08, 1)
		mat.emission_energy_multiplier = 1.2
		shard.material_override = mat
		shard.global_position = center + Vector3(0, 0.35, 0)
		shard.rotation = Vector3(rng.randf_range(0, TAU), rng.randf_range(0, TAU), rng.randf_range(0, TAU))
		add_child(shard)
		var ang: float = TAU * float(i) / 14.0 + rng.randf_range(-0.2, 0.2)
		var dir := Vector3(cos(ang), 0, sin(ang))
		var dist: float = rng.randf_range(2.0, 5.5)
		var mid: Vector3 = center + dir * (dist * 0.55) + Vector3(0, rng.randf_range(1.0, 2.4), 0)
		var endp: Vector3 = center + dir * dist + Vector3(0, 0.12, 0)
		var tw := create_tween()
		tw.tween_property(shard, "global_position", mid, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(shard, "global_position", endp, 0.30).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(shard, "scale", Vector3.ONE * 0.4, 0.36).set_delay(0.18)
		tw.tween_callback(shard.queue_free)

# 四方四道虚影：克隆 Boss 本体外观、调成半透明幽蓝，立于砸点四周（随 seed 旋一个角度）。
func _spawn_phantoms() -> void:
	if boss == null or not is_instance_valid(boss):
		return
	var src: Node3D = boss.get("visual") if boss.get("visual") != null else null
	if src == null:
		return
	var base_ang: float = float(seed_val % 360) * (PI / 180.0)
	# 四道地面虚影 + 第 5 道空中虚影（砸点正上方 = 天上坠落点）。
	var spots: Array = []
	for i: int in range(4):
		var ang: float = base_ang + TAU * float(i) / 4.0
		spots.append(center + Vector3(cos(ang), 0, sin(ang)) * PHANTOM_R)
	spots.append(center + Vector3(0, COMBO_LEAP_H, 0))
	for sp: Vector3 in spots:
		var ghost: Node3D = src.duplicate() as Node3D
		if ghost == null:
			continue
		var mats: Array = []
		_ghostify(ghost, mats)
		add_child(ghost)
		ghost.global_position = sp
		var face: Vector3 = center - sp
		if Vector2(face.x, face.z).length() > 0.1:
			ghost.rotation.y = atan2(-face.x, -face.z)
		phantoms.append({"node": ghost, "mats": mats})

# 递归把节点下所有 MeshInstance3D 改成半透明幽灵材质，并收集材质引用以便后续渐隐。
func _ghostify(node: Node, out_mats: Array) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		var gm := StandardMaterial3D.new()
		gm.albedo_color = GHOST_COLOR
		gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		gm.emission_enabled = true
		gm.emission = Color(0.45, 0.85, 1.0, 1)
		gm.emission_energy_multiplier = 1.1
		mi.material_override = gm
		out_mats.append(gm)
	for c: Node in node.get_children():
		_ghostify(c, out_mats)
