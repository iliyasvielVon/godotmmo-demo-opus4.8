class_name StarGloryPickup
extends Area3D

var main = null
var item_data: Dictionary = {}
var bob_seed: float = 0.0
var base_y: float = 0.0
var net_drop_id: int = -1   # >=0：服务器同步的共享掉落（拾取需服务器裁决）；<0：单机本地掉落

func _ready() -> void:
	# 联机共享掉落：bob 相位由 drop_id 推导，保证各端漂浮一致；单机用随机相位。
	bob_seed = (float(net_drop_id) * 0.7) if net_drop_id >= 0 else (randf() * 10.0)
	base_y = position.y
	monitoring = true
	monitorable = true
	_build_visual()

func _build_visual() -> void:
	var shape := SphereShape3D.new()
	shape.radius = 0.85
	var collision := CollisionShape3D.new()
	collision.shape = shape
	add_child(collision)

	var color: Color = item_data.get("color", Color(0.65, 0.9, 1.0, 1)) as Color
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.9
	mat.roughness = 0.45

	var root := Node3D.new()
	root.name = "PickupVisual"
	add_child(root)

	# 技能书：书本造型（封面=阶位色，内页=米白），颜色由阶位决定。
	if String(item_data.get("kind", "equipment")) == "skillbook":
		var cover_mesh := BoxMesh.new()
		cover_mesh.size = Vector3(0.5, 0.62, 0.12)
		var cover := MeshInstance3D.new()
		cover.mesh = cover_mesh
		cover.material_override = mat
		root.add_child(cover)
		var page_mesh := BoxMesh.new()
		page_mesh.size = Vector3(0.46, 0.58, 0.14)
		var page_mat := StandardMaterial3D.new()
		page_mat.albedo_color = Color(0.97, 0.95, 0.85, 1)
		var page := MeshInstance3D.new()
		page.mesh = page_mesh
		page.material_override = page_mat
		root.add_child(page)
		var halo2 := TorusMesh.new()
		halo2.inner_radius = 0.42
		halo2.outer_radius = 0.48
		var h2 := MeshInstance3D.new()
		h2.mesh = halo2
		h2.material_override = mat
		h2.rotation.x = PI / 2.0
		root.add_child(h2)
		return

	# 药剂：药水瓶造型（瓶身=药剂色，瓶塞=深色）。
	if String(item_data.get("kind", "equipment")) == "potion":
		var body_mesh := SphereMesh.new()
		body_mesh.radius = 0.26
		body_mesh.height = 0.46
		var body := MeshInstance3D.new()
		body.mesh = body_mesh
		body.material_override = mat
		body.position = Vector3(0, -0.05, 0)
		root.add_child(body)
		var neck_mesh := CylinderMesh.new()
		neck_mesh.top_radius = 0.08
		neck_mesh.bottom_radius = 0.12
		neck_mesh.height = 0.22
		var neck := MeshInstance3D.new()
		neck.mesh = neck_mesh
		neck.material_override = mat
		neck.position = Vector3(0, 0.26, 0)
		root.add_child(neck)
		var cork_mesh := CylinderMesh.new()
		cork_mesh.top_radius = 0.07
		cork_mesh.bottom_radius = 0.07
		cork_mesh.height = 0.10
		var cork := MeshInstance3D.new()
		cork.mesh = cork_mesh
		cork.material_override = StandardMaterial3D.new()
		(cork.material_override as StandardMaterial3D).albedo_color = Color(0.32, 0.22, 0.14, 1)
		cork.position = Vector3(0, 0.40, 0)
		root.add_child(cork)
		return

	# 磁铁：U 形马蹄磁铁（红色磁体 + 银色磁极）。
	if String(item_data.get("kind", "equipment")) == "magnet":
		for sx in [-1.0, 1.0]:
			var leg_mesh := BoxMesh.new()
			leg_mesh.size = Vector3(0.16, 0.5, 0.16)
			var leg := MeshInstance3D.new()
			leg.mesh = leg_mesh
			leg.material_override = mat
			leg.position = Vector3(sx * 0.17, 0.0, 0)
			root.add_child(leg)
			var tip_mesh := BoxMesh.new()
			tip_mesh.size = Vector3(0.18, 0.14, 0.18)
			var tip := MeshInstance3D.new()
			tip.mesh = tip_mesh
			var tip_mat := StandardMaterial3D.new()
			tip_mat.albedo_color = Color(0.85, 0.88, 0.92, 1)
			tip_mat.metallic = 0.8
			tip_mat.roughness = 0.3
			tip.material_override = tip_mat
			tip.position = Vector3(sx * 0.17, -0.32, 0)
			root.add_child(tip)
		var arc_mesh := BoxMesh.new()
		arc_mesh.size = Vector3(0.50, 0.16, 0.16)
		var arc := MeshInstance3D.new()
		arc.mesh = arc_mesh
		arc.material_override = mat
		arc.position = Vector3(0, 0.29, 0)
		root.add_child(arc)
		var halo3 := TorusMesh.new()
		halo3.inner_radius = 0.42
		halo3.outer_radius = 0.48
		var h3 := MeshInstance3D.new()
		h3.mesh = halo3
		h3.material_override = mat
		h3.rotation.x = PI / 2.0
		root.add_child(h3)
		return

	var slot := String(item_data.get("slot", "weapon"))
	var mesh: Mesh
	match slot:
		"weapon":
			mesh = BoxMesh.new()
			mesh.size = Vector3(0.18, 1.1, 0.18)
		"armor":
			mesh = CapsuleMesh.new()
			mesh.radius = 0.36
			mesh.height = 0.9
		"boots":
			mesh = BoxMesh.new()
			mesh.size = Vector3(0.55, 0.25, 0.38)
		"accessory":
			mesh = SphereMesh.new()
			mesh.radius = 0.32
			mesh.height = 0.64
		_:
			mesh = SphereMesh.new()
			mesh.radius = 0.3
			mesh.height = 0.6
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	root.add_child(mi)

	var halo_mesh := TorusMesh.new()
	halo_mesh.inner_radius = 0.42
	halo_mesh.outer_radius = 0.48
	var halo := MeshInstance3D.new()
	halo.mesh = halo_mesh
	halo.material_override = mat
	halo.rotation.x = PI / 2.0
	root.add_child(halo)

func _physics_process(delta: float) -> void:
	rotation.y += delta * 1.8
	position.y = base_y + sin(Time.get_ticks_msec() / 420.0 + bob_seed) * 0.12
