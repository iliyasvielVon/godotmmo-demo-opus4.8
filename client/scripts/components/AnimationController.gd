class_name AnimationController
extends Node

# 动作状态机（程序化）：拥有玩家可视模型与全部骨骼锚点，按 idle/walk/run/jump + 各技能 pose
# 驱动锚点旋转。语义等价 AnimationTree 的 StateMachine，但不依赖 AnimationPlayer/骨架/关键帧。
# 同时负责装备外观的挂载（装备网格依附在本控制器构建的锚点上）。

var host: Node3D = null   # 宿主（Player），可视模型直接挂在宿主下以继承其变换

var visual: Node3D
var body_mesh: MeshInstance3D
var head_mesh: MeshInstance3D
var left_arm_anchor: Node3D
var right_arm_anchor: Node3D
var left_leg_anchor: Node3D
var right_leg_anchor: Node3D
var left_hand_anchor: Node3D
var right_hand_anchor: Node3D
var right_finger_tip: Node3D
var weapon_anchor: Node3D
var armor_anchor: Node3D
var boots_anchor: Node3D
var accessory_anchor: Node3D
var equip_visuals: Dictionary = {}

var anim_time: float = 0.0
var visual_base_y: float = 0.0
var forced_pose: String = ""
var forced_pose_timer: float = 0.0

# 第一人称时头部跟随相机视角转动。
var head_follow: bool = false
var head_world_yaw: float = 0.0
var head_world_pitch: float = 0.0

func setup(p_host: Node3D) -> void:
	host = p_host
	_build_model()

# ---------- 网格工具 ----------
func _mat(color: Color, emission: float = 0.0) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.62
	mat.metallic = 0.05
	if emission > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = emission
	return mat

func _add_mesh(parent: Node, mesh: Mesh, mat: Material, pos: Vector3, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi

func _box(size: Vector3) -> BoxMesh:
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = size
	return mesh

func _sphere(radius: float, height: float = -1.0) -> SphereMesh:
	var mesh: SphereMesh = SphereMesh.new()
	mesh.radius = radius
	mesh.height = height if height > 0.0 else radius * 2.0
	mesh.radial_segments = 24
	mesh.rings = 12
	return mesh

func _capsule(radius: float, height: float) -> CapsuleMesh:
	var mesh: CapsuleMesh = CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	mesh.radial_segments = 24
	mesh.rings = 8
	return mesh

func _cylinder(top_radius: float, bottom_radius: float, height: float) -> CylinderMesh:
	var mesh: CylinderMesh = CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	mesh.radial_segments = 20
	mesh.rings = 2
	return mesh

# ---------- 模型构建 ----------
func _build_model() -> void:
	visual = Node3D.new()
	visual.name = "AnimeHeroVisual_FrontIsMinusZ"
	host.add_child(visual)
	visual_base_y = visual.position.y

	var skin: StandardMaterial3D = _mat(Color(1.0, 0.78, 0.66, 1))
	var cloth: StandardMaterial3D = _mat(Color(0.42, 0.55, 1.0, 1))
	var dark: StandardMaterial3D = _mat(Color(0.09, 0.10, 0.18, 1))
	var hair: StandardMaterial3D = _mat(Color(0.18, 0.19, 0.36, 1))
	var glow: StandardMaterial3D = _mat(Color(0.5, 0.95, 1.0, 1), 1.0)

	body_mesh = _add_mesh(visual, _capsule(0.35, 1.25), cloth, Vector3(0, 1.15, 0))
	head_mesh = _add_mesh(visual, _sphere(0.28), skin, Vector3(0, 1.95, 0))
	_add_mesh(visual, _sphere(0.30, 0.42), hair, Vector3(0, 2.08, -0.02))
	_add_mesh(visual, _box(Vector3(0.62, 0.12, 0.18)), hair, Vector3(0, 2.02, -0.22), Vector3(0.15, 0, 0))
	_add_mesh(visual, _box(Vector3(0.78, 0.15, 0.42)), _mat(Color(0.82, 0.86, 1.0, 1)), Vector3(0, 0.96, 0.05))
	_add_mesh(visual, _sphere(0.05), glow, Vector3(-0.10, 1.98, -0.26))
	_add_mesh(visual, _sphere(0.05), glow, Vector3(0.10, 1.98, -0.26))

	left_arm_anchor = Node3D.new()
	left_arm_anchor.name = "LeftArmAnchor"
	left_arm_anchor.position = Vector3(-0.46, 1.55, 0)
	visual.add_child(left_arm_anchor)
	_add_mesh(left_arm_anchor, _box(Vector3(0.16, 0.66, 0.16)), skin, Vector3(0, -0.33, 0), Vector3.ZERO)
	left_hand_anchor = Node3D.new()
	left_hand_anchor.position = Vector3(0, -0.70, -0.02)
	left_arm_anchor.add_child(left_hand_anchor)
	_add_mesh(left_hand_anchor, _sphere(0.09), skin, Vector3.ZERO)

	right_arm_anchor = Node3D.new()
	right_arm_anchor.name = "RightArmAnchor"
	right_arm_anchor.position = Vector3(0.46, 1.55, 0)
	visual.add_child(right_arm_anchor)
	_add_mesh(right_arm_anchor, _box(Vector3(0.16, 0.66, 0.16)), skin, Vector3(0, -0.33, 0), Vector3.ZERO)
	right_hand_anchor = Node3D.new()
	right_hand_anchor.position = Vector3(0, -0.70, -0.02)
	right_arm_anchor.add_child(right_hand_anchor)
	_add_mesh(right_hand_anchor, _sphere(0.09), skin, Vector3.ZERO)
	right_finger_tip = Node3D.new()
	right_finger_tip.name = "RightFingerTip"
	right_finger_tip.position = Vector3(0, -0.03, -0.22)
	right_hand_anchor.add_child(right_finger_tip)
	_add_mesh(right_finger_tip, _box(Vector3(0.035, 0.035, 0.20)), skin, Vector3(0, 0, -0.08))

	left_leg_anchor = Node3D.new()
	left_leg_anchor.name = "LeftLegAnchor"
	left_leg_anchor.position = Vector3(-0.18, 0.80, 0)
	visual.add_child(left_leg_anchor)
	_add_mesh(left_leg_anchor, _box(Vector3(0.16, 0.70, 0.18)), dark, Vector3(0, -0.35, 0))

	right_leg_anchor = Node3D.new()
	right_leg_anchor.name = "RightLegAnchor"
	right_leg_anchor.position = Vector3(0.18, 0.80, 0)
	visual.add_child(right_leg_anchor)
	_add_mesh(right_leg_anchor, _box(Vector3(0.16, 0.70, 0.18)), dark, Vector3(0, -0.35, 0))

	weapon_anchor = Node3D.new()
	weapon_anchor.name = "WeaponAnchor"
	weapon_anchor.position = Vector3(0, -0.42, -0.08)
	right_arm_anchor.add_child(weapon_anchor)

	armor_anchor = Node3D.new()
	armor_anchor.name = "ArmorAnchor"
	armor_anchor.position = Vector3.ZERO
	visual.add_child(armor_anchor)

	boots_anchor = Node3D.new()
	boots_anchor.name = "BootsAnchor"
	boots_anchor.position = Vector3.ZERO
	visual.add_child(boots_anchor)

	accessory_anchor = Node3D.new()
	accessory_anchor.name = "AccessoryAnchor"
	accessory_anchor.position = Vector3.ZERO
	visual.add_child(accessory_anchor)

# ---------- 对外接口 ----------
func set_facing(dir: Vector3) -> void:
	if visual == null:
		return
	# 模型正面定义在 -Z。
	visual.rotation.y = atan2(-dir.x, -dir.z)

func play_pose(pose_name: String, duration: float = 0.0) -> void:
	forced_pose = pose_name
	forced_pose_timer = duration

func clear_pose(pose_name: String = "") -> void:
	if pose_name == "" or forced_pose == pose_name:
		forced_pose = ""
		forced_pose_timer = 0.0

func get_pose() -> String:
	return forced_pose

# 由 Main 每帧传入相机世界 yaw/pitch；enabled 为 false 时头部回归姿态控制。
func set_head_follow(enabled: bool, world_yaw: float, world_pitch: float) -> void:
	head_follow = enabled
	head_world_yaw = world_yaw
	head_world_pitch = world_pitch

func get_anchor(slot: String) -> Node3D:
	match slot:
		"weapon":
			return weapon_anchor
		"armor":
			return armor_anchor
		"boots":
			return boots_anchor
		"accessory":
			return accessory_anchor
	return null

func get_finger_tip_global_position() -> Vector3:
	if right_finger_tip != null and is_instance_valid(right_finger_tip):
		return right_finger_tip.global_position
	return host.global_position + Vector3(0, 1.25, 0) + host.last_facing_dir * 0.8

# 每物理帧由 Player 驱动：推进姿态状态机（idle/walk/run/jump + 各技能 forced_pose）。
func update_locomotion(delta: float, move_dir: Vector3, is_running: bool, on_floor: bool) -> void:
	if forced_pose_timer > 0.0:
		forced_pose_timer = max(0.0, forced_pose_timer - delta)
		if forced_pose_timer <= 0.0:
			forced_pose = ""
	anim_time += delta
	if visual == null:
		return
	var moving: bool = move_dir.length() > 0.01 and on_floor
	var stride_speed: float = 12.5 if is_running else 9.0
	var stride: float = sin(anim_time * stride_speed)
	var bob: float = sin(anim_time * 2.4) * 0.012
	if moving:
		bob = abs(stride) * (0.055 if is_running else 0.035)
	visual.position.y = visual_base_y + bob
	body_mesh.rotation = Vector3.ZERO
	head_mesh.rotation = Vector3.ZERO
	left_arm_anchor.rotation = Vector3(0.06, 0.0, 0.18)
	right_arm_anchor.rotation = Vector3(0.06, 0.0, -0.18)
	left_leg_anchor.rotation = Vector3.ZERO
	right_leg_anchor.rotation = Vector3.ZERO

	if moving:
		var arm_swing: float = 0.68 if is_running else 0.45
		var leg_swing: float = 0.62 if is_running else 0.42
		body_mesh.rotation.x = -0.10 if is_running else 0.0
		left_arm_anchor.rotation.x = stride * arm_swing
		right_arm_anchor.rotation.x = -stride * arm_swing
		left_leg_anchor.rotation.x = -stride * leg_swing
		right_leg_anchor.rotation.x = stride * leg_swing
	elif not on_floor:
		left_arm_anchor.rotation = Vector3(0.55, 0.0, 0.45)
		right_arm_anchor.rotation = Vector3(0.55, 0.0, -0.45)
		left_leg_anchor.rotation.x = -0.25
		right_leg_anchor.rotation.x = 0.22

	match forced_pose:
		"slash":
			body_mesh.rotation.z = -0.20
			right_arm_anchor.rotation = Vector3(0.25, 0.0, -1.35 + sin(anim_time * 38.0) * 0.12)
			left_arm_anchor.rotation = Vector3(0.35, 0.0, 0.45)
		"slash2":
			body_mesh.rotation.z = 0.20
			left_arm_anchor.rotation = Vector3(0.25, 0.0, 1.35 - sin(anim_time * 38.0) * 0.12)
			right_arm_anchor.rotation = Vector3(0.35, 0.0, -0.45)
		"slash3":
			body_mesh.rotation.x = -0.28
			head_mesh.rotation.x = -0.12
			right_arm_anchor.rotation = Vector3(2.5, 0.0, -0.22)
			left_arm_anchor.rotation = Vector3(2.3, 0.0, 0.22)
		"fireball_charge":
			body_mesh.rotation.x = -0.08
			head_mesh.rotation.x = -0.08
			right_arm_anchor.rotation = Vector3(1.48, 0.0, -0.08)
			left_arm_anchor.rotation = Vector3(0.85, 0.0, 0.55)
			visual.position.y = visual_base_y + 0.03 + sin(anim_time * 8.0) * 0.015
		"frost":
			left_arm_anchor.rotation = Vector3(0.95, 0.0, 0.75)
			right_arm_anchor.rotation = Vector3(0.95, 0.0, -0.75)
			body_mesh.rotation.x = 0.10
		"blink":
			body_mesh.rotation.x = -0.25
			left_arm_anchor.rotation = Vector3(-0.35, 0.0, 0.25)
			right_arm_anchor.rotation = Vector3(-0.35, 0.0, -0.25)
		"meteor":
			body_mesh.rotation.x = -0.18
			head_mesh.rotation.x = -0.22
			left_arm_anchor.rotation = Vector3(2.45, 0.0, 0.62)
			right_arm_anchor.rotation = Vector3(2.45, 0.0, -0.62)
			left_leg_anchor.rotation.x = -0.10
			right_leg_anchor.rotation.x = 0.10
		"fire_rain":
			body_mesh.rotation.x = -0.12
			head_mesh.rotation.x = -0.18
			left_arm_anchor.rotation = Vector3(2.15, 0.0, 0.42)
			right_arm_anchor.rotation = Vector3(1.85, 0.0, -0.32)
			left_leg_anchor.rotation.x = -0.08
			right_leg_anchor.rotation.x = 0.08
			visual.position.y = visual_base_y + 0.05 + sin(anim_time * 7.0) * 0.02
		"jump":
			left_arm_anchor.rotation = Vector3(0.65, 0.0, 0.45)
			right_arm_anchor.rotation = Vector3(0.65, 0.0, -0.45)

	# 第一人称：头部跟随相机视角（覆盖上面的姿态对头部的设置）。
	if head_follow and head_mesh != null:
		var local_yaw: float = clamp(wrapf(head_world_yaw - visual.rotation.y, -PI, PI), -1.6, 1.6)
		head_mesh.rotation = Vector3(-head_world_pitch, local_yaw, 0.0)

# ---------- 装备外观 ----------
func build_equipment_visual(slot: String, item: Dictionary) -> void:
	_free_equipment_visual(slot)
	if item == null or item.is_empty():
		return
	var color: Color = item.get("color", Color(0.8, 0.9, 1.0, 1.0)) as Color
	var mat: StandardMaterial3D = _mat(color, 0.55)

	# 靴子分别挂到左右腿锚点上，随腿部摆动而动（其余部位挂在对应静态锚点）。
	if slot == "boots":
		var left_boot: Node3D = Node3D.new()
		left_boot.name = "Visual_boots_L"
		left_leg_anchor.add_child(left_boot)
		_add_mesh(left_boot, _box(Vector3(0.23, 0.22, 0.38)), mat, Vector3(0, -0.68, -0.04))
		var right_boot: Node3D = Node3D.new()
		right_boot.name = "Visual_boots_R"
		right_leg_anchor.add_child(right_boot)
		_add_mesh(right_boot, _box(Vector3(0.23, 0.22, 0.38)), mat, Vector3(0, -0.68, -0.04))
		equip_visuals[slot] = [left_boot, right_boot]
		return

	var node: Node3D = Node3D.new()
	node.name = "Visual_%s" % slot
	match slot:
		"weapon":
			weapon_anchor.add_child(node)
			_add_mesh(node, _box(Vector3(0.12, 0.94, 0.12)), mat, Vector3(0, -0.36, -0.08), Vector3(0.2, 0.0, -0.25))
			_add_mesh(node, _box(Vector3(0.26, 0.10, 0.18)), _mat(Color(0.08, 0.08, 0.12, 1)), Vector3(0, 0.02, 0))
			_add_mesh(node, _sphere(0.10), mat, Vector3(0, -0.86, -0.12))
		"armor":
			armor_anchor.add_child(node)
			_add_mesh(node, _capsule(0.40, 1.03), mat, Vector3(0, 1.13, 0))
			_add_mesh(node, _box(Vector3(0.88, 0.15, 0.48)), mat, Vector3(0, 1.42, -0.02))
		"accessory":
			accessory_anchor.add_child(node)
			_add_mesh(node, _sphere(0.10), mat, Vector3(-0.31, 1.84, -0.16))
			_add_mesh(node, _sphere(0.10), mat, Vector3(0.31, 1.84, -0.16))
			_add_mesh(node, _box(Vector3(0.68, 0.04, 0.04)), mat, Vector3(0, 1.84, -0.16))
	equip_visuals[slot] = node

func _free_equipment_visual(slot: String) -> void:
	if not equip_visuals.has(slot):
		return
	var prev: Variant = equip_visuals[slot]
	if prev is Array:
		for n: Node in prev:
			if is_instance_valid(n):
				n.queue_free()
	elif is_instance_valid(prev):
		prev.queue_free()
