class_name StarGloryOreNode
extends StaticBody3D

var main: Node = null
var mat_name: String = "寒霜晶矿"
var mat_color: Color = Color(0.82, 0.94, 1.0, 1)
var hp: int = 90
var dead: bool = false
var net_node_id: int = -1

func _ready() -> void:
	if main == null:
		main = get_tree().current_scene
	add_to_group("building")
	add_to_group("obstacle")
	if not _has_collision_shape():
		var shape := SphereShape3D.new()
		shape.radius = 1.7
		var col := CollisionShape3D.new()
		col.shape = shape
		col.position = Vector3(0, 1.2, 0)
		add_child(col)

func _has_collision_shape() -> bool:
	for c: Node in get_children():
		if c is CollisionShape3D:
			return true
	return false

func take_damage(amount: int, _source: Node = null) -> void:
	if dead:
		return
	var dmg: int = maxi(1, amount)
	hp -= dmg
	if main != null and main.has_method("flash_damage"):
		main.flash_damage(global_position + Vector3(0, 2.4, 0), "-%d" % dmg, mat_color)
	if hp <= 0:
		_break_apart()

func _chunk_count() -> int:
	var r: float = randf()
	if r < 0.20:
		return 1
	if r < 0.80:
		return 2
	return 3

func _break_apart() -> void:
	dead = true
	var count: int = _chunk_count()
	if main != null and main.has_method("spawn_skill_flash"):
		main.spawn_skill_flash(global_position + Vector3(0, 1.0, 0), mat_color, 2.4, 0.35)
	if net_node_id > 0 and Net.online:
		Net.send_gather_node(net_node_id)
		queue_free()
		return
	if main != null and main.has_method("_spawn_material_drop"):
		main._spawn_material_drop(global_position + Vector3(0, 0.45, 0), mat_name, mat_color, count)
	elif main != null and main.get("inv") != null:
		main.get("inv").add_material(mat_name, mat_color, count)
	queue_free()
