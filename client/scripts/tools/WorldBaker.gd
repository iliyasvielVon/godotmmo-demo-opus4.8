extends SceneTree

# 一次性世界烘焙工具：把原本在 Main.gd 里程序化生成的地图（地面/草皮/湖/星门/Boss竞技场/
# 树/遗迹/水晶等）按 64 单位网格分块，导出成可在编辑器里可视化编辑的区块 .tscn。
# 烘焙后这批 .tscn 即为世界本体，由 WorldStreamer 运行时按距离流式加载。
#
# 运行（无头一次性）：
#   godot --headless --script res://scripts/tools/WorldBaker.gd
# 重新生成会覆盖 scenes/world/chunks/ 下的同名文件。

const CHUNK_SIZE := 64.0
const MAP_RADIUS := 155.0
const CHUNK_DIR := "res://scenes/world/chunks"
const BAKE_SEED := 20260615

var rng := RandomNumberGenerator.new()
var mats: Dictionary = {}
var world_root: Node3D            # 临时容器：所有生成节点先挂这里（世界坐标）
var chunks: Dictionary = {}       # Vector2i -> Node3D（区块根）

func _initialize() -> void:
	rng.seed = BAKE_SEED
	_build_materials()
	world_root = Node3D.new()

	# 1) 程序化生成全部内容到 world_root（世界坐标）。
	_create_ground()
	_create_landmarks()
	_create_props()

	# 2) 建 6x6 区块根并铺地面瓦片。
	for cx in range(-3, 3):
		for cz in range(-3, 3):
			var coord := Vector2i(cx, cz)
			var root := Node3D.new()
			root.name = "Chunk_%d_%d" % [cx, cz]
			chunks[coord] = root
			_add_ground_tile(root)

	# 3) 把 world_root 的每个顶层节点按世界坐标分箱进区块（转局部坐标）。
	for child in world_root.get_children():
		var node := child as Node3D
		var coord := _chunk_of(node.position)
		var root: Node3D = chunks[coord]
		world_root.remove_child(node)
		node.position -= _chunk_origin(coord)
		root.add_child(node)

	# 4) 设 owner 并打包保存。
	DirAccess.make_dir_recursive_absolute(CHUNK_DIR)
	var saved := 0
	for coord: Vector2i in chunks.keys():
		var root: Node3D = chunks[coord]
		for c in root.get_children():
			_set_owner_recursive(c, root)
		var ps := PackedScene.new()
		var err := ps.pack(root)
		if err != OK:
			push_error("pack 失败 %s: %d" % [str(coord), err])
			continue
		var path := "%s/chunk_%d_%d.tscn" % [CHUNK_DIR, coord.x, coord.y]
		var serr := ResourceSaver.save(ps, path)
		if serr != OK:
			push_error("save 失败 %s: %d" % [path, serr])
			continue
		saved += 1
	print("WorldBaker 完成：已保存 %d 个区块到 %s" % [saved, CHUNK_DIR])
	quit()

# ---------- 区块工具 ----------
func _chunk_of(world_pos: Vector3) -> Vector2i:
	var cx := clampi(int(floor(world_pos.x / CHUNK_SIZE)), -3, 2)
	var cz := clampi(int(floor(world_pos.z / CHUNK_SIZE)), -3, 2)
	return Vector2i(cx, cz)

func _chunk_origin(coord: Vector2i) -> Vector3:
	return Vector3(coord.x * CHUNK_SIZE, 0.0, coord.y * CHUNK_SIZE)

func _add_ground_tile(root: Node3D) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(CHUNK_SIZE, CHUNK_SIZE)
	var ground := MeshInstance3D.new()
	ground.name = "GroundTile"
	ground.mesh = plane
	ground.material_override = mats["ground"]
	ground.position = Vector3(CHUNK_SIZE * 0.5, 0.0, CHUNK_SIZE * 0.5)
	root.add_child(ground)

	var body := StaticBody3D.new()
	body.name = "GroundCollision"
	var shape := BoxShape3D.new()
	shape.size = Vector3(CHUNK_SIZE, 0.18, CHUNK_SIZE)
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	body.position = Vector3(CHUNK_SIZE * 0.5, -0.09, CHUNK_SIZE * 0.5)
	root.add_child(body)

func _set_owner_recursive(node: Node, owner_node: Node) -> void:
	node.owner = owner_node
	for c in node.get_children():
		_set_owner_recursive(c, owner_node)

# ---------- 材质 ----------
func _build_materials() -> void:
	mats["ground"] = _mat(Color(0.12, 0.18, 0.25, 1))
	mats["grass"] = _mat(Color(0.16, 0.36, 0.25, 1))
	mats["stone"] = _mat(Color(0.36, 0.39, 0.46, 1))
	mats["wood"] = _mat(Color(0.28, 0.17, 0.10, 1))
	mats["leaf"] = _mat(Color(0.15, 0.43, 0.32, 1))
	mats["crystal"] = _mat(Color(0.35, 0.9, 1.0, 1), 1.2)
	mats["danger"] = _mat(Color(0.9, 0.18, 0.16, 1), 0.6)
	mats["water"] = _mat(Color(0.15, 0.45, 0.9, 0.72), 0.4, 0.45)

func _mat(color: Color, emission: float = 0.0, alpha: float = 1.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var final_color := color
	final_color.a = alpha
	mat.albedo_color = final_color
	mat.roughness = 0.68
	mat.metallic = 0.0
	if alpha < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emission > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = emission
	return mat

# ---------- 生成（从 Main.gd 移植，节点加到 world_root，世界坐标）----------
func _random_map_pos(y: float = 0.0) -> Vector3:
	return Vector3(rng.randf_range(-MAP_RADIUS + 5, MAP_RADIUS - 5), y, rng.randf_range(-MAP_RADIUS + 5, MAP_RADIUS - 5))

func _create_ground() -> void:
	for i in range(76):
		var patch := MeshInstance3D.new()
		var mesh := PlaneMesh.new()
		var s := rng.randf_range(4.0, 12.0)
		mesh.size = Vector2(s, s)
		patch.name = "GrassPatch"
		patch.mesh = mesh
		patch.material_override = mats["grass"]
		patch.position = _random_map_pos(0.02)
		patch.rotation.y = rng.randf_range(0, TAU)
		world_root.add_child(patch)

	var lake := MeshInstance3D.new()
	var lake_mesh := CylinderMesh.new()
	lake_mesh.top_radius = 14.0
	lake_mesh.bottom_radius = 14.0
	lake_mesh.height = 0.04
	lake_mesh.radial_segments = 64
	lake.name = "Lake"
	lake.mesh = lake_mesh
	lake.position = Vector3(42, 0.03, 35)
	lake.material_override = mats["water"]
	world_root.add_child(lake)

func _create_landmarks() -> void:
	_add_cylinder_prop("StarGateBase", Vector3(0, 0.1, 0), 5.4, 5.4, 0.22, mats["stone"], false)
	for i in range(8):
		var a := TAU * float(i) / 8.0
		var pos := Vector3(cos(a) * 4.4, 1.1, sin(a) * 4.4)
		var pillar := _add_cylinder_prop("GatePillar", pos, 0.25, 0.36, 2.2, mats["crystal"])
		pillar.rotation.y = -a
	_add_cylinder_prop("GateCrystal", Vector3(0, 2.15, 0), 0.0, 0.8, 2.4, mats["crystal"])

	_add_cylinder_prop("BossArena", Vector3(-96, 0.12, -94), 17.0, 17.0, 0.22, _mat(Color(0.26, 0.11, 0.10, 1)), false)
	for i in range(10):
		var a := TAU * float(i) / 10.0
		var pos := Vector3(-96 + cos(a) * 16.5, 1.9, -94 + sin(a) * 16.5)
		_add_cylinder_prop("BossObelisk", pos, 0.25, 0.45, 3.8, mats["danger"])
	_add_box_prop("BossThrone", Vector3(-96, 0.9, -102), Vector3(4.8, 1.8, 2.0), mats["stone"])
	_add_box_prop("BossBack", Vector3(-96, 2.3, -103), Vector3(5.3, 3.8, 0.55), mats["danger"])

	for i in range(6):
		var pos := Vector3(42 + rng.randf_range(-11, 11), 0.6, 35 + rng.randf_range(-11, 11))
		_add_cylinder_prop("LakeCrystal", pos, 0.0, rng.randf_range(0.35, 0.75), rng.randf_range(1.5, 3.8), mats["crystal"])

func _create_props() -> void:
	for i in range(116):
		var pos := _random_map_pos(0.0)
		if pos.distance_to(Vector3.ZERO) < 8.0 or pos.distance_to(Vector3(-96, 0, -94)) < 22.0:
			continue
		_create_tree(pos)
	for i in range(54):
		var pos := _random_map_pos(0.15)
		if pos.distance_to(Vector3.ZERO) < 7.0:
			continue
		_add_box_prop("RuinBlock", pos + Vector3(0, 0.22, 0), Vector3(rng.randf_range(0.8, 2.2), rng.randf_range(0.35, 1.0), rng.randf_range(0.8, 2.2)), mats["stone"])
	for i in range(24):
		var pos := _random_map_pos(0.4)
		_add_cylinder_prop("SmallCrystal", pos + Vector3(0, 0.4, 0), 0.0, rng.randf_range(0.15, 0.35), rng.randf_range(0.8, 1.8), mats["crystal"])

func _create_tree(pos: Vector3) -> void:
	_add_cylinder_prop("TreeTrunk", pos + Vector3(0, 0.75, 0), 0.16, 0.22, 1.5, mats["wood"], true)
	var crown := SphereMesh.new()
	crown.radius = rng.randf_range(0.9, 1.35)
	crown.height = crown.radius * 1.7
	crown.radial_segments = 12
	crown.rings = 6
	var mi := MeshInstance3D.new()
	mi.name = "TreeCrown"
	mi.mesh = crown
	mi.position = pos + Vector3(0, 1.8, 0)
	mi.material_override = mats["leaf"]
	world_root.add_child(mi)
	_add_sphere_obstacle("TreeCrownObstacle", pos + Vector3(0, 1.55, 0), crown.radius * 0.72)

func _add_box_prop(name: String, pos: Vector3, size: Vector3, mat: Material, collide: bool = true) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	mi.position = pos
	mi.rotation.y = rng.randf_range(0, TAU)
	mi.material_override = mat
	world_root.add_child(mi)
	if collide:
		_add_box_obstacle("%sCollision" % name, pos, size, mi.rotation)
	return mi

func _add_cylinder_prop(name: String, pos: Vector3, top_radius: float, bottom_radius: float, height: float, mat: Material, collide: bool = true) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	mesh.radial_segments = 24
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	world_root.add_child(mi)
	if collide:
		var radius: float = max(abs(top_radius), abs(bottom_radius), 0.2)
		_add_cylinder_obstacle("%sCollision" % name, pos, radius, height)
	return mi

func _add_box_obstacle(name: String, pos: Vector3, size: Vector3, rot: Vector3 = Vector3.ZERO) -> void:
	var body := StaticBody3D.new()
	body.name = name
	body.position = pos
	body.rotation = rot
	body.add_to_group("obstacle", true)
	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	world_root.add_child(body)

func _add_cylinder_obstacle(name: String, pos: Vector3, radius: float, height: float) -> void:
	var body := StaticBody3D.new()
	body.name = name
	body.position = pos
	body.add_to_group("obstacle", true)
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	world_root.add_child(body)

func _add_sphere_obstacle(name: String, pos: Vector3, radius: float) -> void:
	var body := StaticBody3D.new()
	body.name = name
	body.position = pos
	body.add_to_group("obstacle", true)
	var shape := SphereShape3D.new()
	shape.radius = radius
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	world_root.add_child(body)
