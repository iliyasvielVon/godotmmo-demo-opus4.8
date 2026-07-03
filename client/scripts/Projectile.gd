class_name StarGloryProjectile
extends Area3D

var source: Node = null
var direction: Vector3 = Vector3.FORWARD
var speed: float = 16.0
var damage: int = 20
var radius: float = 0.25
var aoe: float = 0.0
var aoe_damage: int = -1   # 显式爆炸伤害；<0 时回退为 damage*0.65
var life: float = 3.0
var color: Color = Color(1.0, 0.45, 0.1, 1)
var target_group: String = "monster"
var has_hit: bool = false
# 炮击模式：碰到任意单位或引信耗尽即无差别爆炸（全体伤害）。
var universal: bool = false
var fuse: float = -1.0          # >0：飞行该秒数后自爆
var blast_knockback: float = 6.0
var visual_only: bool = false   # 联机：他人技能在本地的纯表现弹，飞行/爆炸但不结算伤害

func setup(data: Dictionary) -> void:
	global_position = data.get("position", Vector3.ZERO) as Vector3
	direction = (data.get("direction", Vector3.FORWARD) as Vector3).normalized()
	speed = float(data.get("speed", speed))
	damage = int(data.get("damage", damage))
	radius = float(data.get("radius", radius))
	aoe = float(data.get("aoe", aoe))
	aoe_damage = int(data.get("aoe_damage", aoe_damage))
	life = float(data.get("life", life))
	color = data.get("color", color) as Color
	source = data.get("source", source) as Node
	target_group = String(data.get("target_group", target_group))
	universal = bool(data.get("universal", universal))
	fuse = float(data.get("fuse", fuse))
	blast_knockback = float(data.get("blast_knockback", blast_knockback))
	visual_only = bool(data.get("visual_only", visual_only))

func _ready() -> void:
	monitoring = true
	monitorable = false
	var shape := SphereShape3D.new()
	shape.radius = radius
	var collision := CollisionShape3D.new()
	collision.shape = shape
	add_child(collision)
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.6
	mi.material_override = mat
	add_child(mi)
	body_entered.connect(_on_body_entered)

func _physics_process(delta: float) -> void:
	life -= delta
	if life <= 0.0:
		queue_free()
		return
	if fuse > 0.0:
		fuse -= delta
		if fuse <= 0.0:
			_explode_universal()
			return
	global_position += direction * speed * delta
	rotate_y(delta * 9.0)

func _on_body_entered(body: Node) -> void:
	if has_hit:
		return
	var safe_src: Node = source if is_instance_valid(source) else null
	# 纯表现弹：撞到目标/障碍即闪光消失，不结算任何伤害。
	if visual_only:
		if safe_src != null and body == safe_src:
			return
		if body.is_in_group(target_group) or body.is_in_group("obstacle") or universal:
			has_hit = true
			var vroot: Node = get_tree().current_scene
			if vroot != null and vroot.has_method("spawn_skill_flash"):
				vroot.spawn_skill_flash(global_position, color, max(aoe, 1.0), 0.22)
			queue_free()
		return
	# 炮击：碰到任意单位（排除发射者）即无差别爆炸。
	if universal:
		if safe_src != null and body == safe_src:
			return
		_explode_universal()
		return
	# source 可能在弹道飞行途中被释放（例如发射者死亡 queue_free）。
	# Godot 4 中被释放的 Node 引用不等于 null，必须用 is_instance_valid 判断，
	# 否则把已释放对象作为参数传入 take_damage 会触发类型校验报错。
	var safe_source: Node = source if is_instance_valid(source) else null
	if safe_source != null and body == safe_source:
		return
	# 玩家弹（target_group=="monster"）直接命中炮台等建筑也结算伤害；
	# 其余建筑/地形仅作为障碍阻挡（hit_obstacle），不结算直接伤害。
	var is_target_building: bool = target_group == "monster" and body.is_in_group("building") and body.has_method("take_damage")
	var hit_obstacle: bool = body.is_in_group("obstacle") and not is_target_building
	if not body.is_in_group(target_group) and not is_target_building and not hit_obstacle:
		return
	has_hit = true
	if (body.is_in_group(target_group) or is_target_building) and body.has_method("take_damage"):
		body.take_damage(damage, safe_source)
	var root: Node = get_tree().current_scene
	if root != null and root.has_method("spawn_skill_flash"):
		root.spawn_skill_flash(global_position, color, max(aoe, 1.0), 0.22)
	var blast: int = aoe_damage if aoe_damage >= 0 else int(damage * 0.65)
	if aoe > 0.0 and root != null and root.combat != null and target_group == "monster":
		root.combat.apply_area_damage(global_position, aoe, blast, safe_source, 0.0, 1.5)
	elif aoe > 0.0 and root != null and root.combat != null and target_group == "player":
		root.combat.apply_player_area_damage(global_position, aoe, blast)
	queue_free()

func _explode_universal() -> void:
	if has_hit:
		return
	has_hit = true
	var root: Node = get_tree().current_scene
	var safe_src: Node = source if is_instance_valid(source) else null
	if root != null and root.has_method("spawn_skill_flash"):
		root.spawn_skill_flash(global_position, color, max(aoe, 1.2), 0.3)
	if visual_only:
		queue_free()
		return
	if root != null and root.combat != null:
		var blast: int = aoe_damage if aoe_damage >= 0 else int(damage * 0.7)
		root.combat.apply_universal_blast(global_position, max(aoe, 2.0), blast, safe_src, blast_knockback)
	queue_free()
