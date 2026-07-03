class_name StarGloryTotem
extends StaticBody3D

# 仇恨图腾：可被击毁的目标物，放在刷怪区域中心。被玩家命中→附近敌人仇恨该玩家；
# 被击毁→更大范围的敌人都仇恨击毁者（配合 Monster「同伴被击中」一起形成区域仇恨）。

var main: Node = null
var max_hp: int = 320
var hp: float = 320.0
var dead: bool = false
var health_bar: HealthBar3D = null
var _core: MeshInstance3D = null

func _ready() -> void:
	if main == null:
		main = get_tree().current_scene
	add_to_group("building")   # 受范围伤害/可被治疗类系统识别
	add_to_group("obstacle")   # 投射物可命中并阻挡
	_build()
	health_bar = HealthBar3D.new()
	add_child(health_bar)
	health_bar.setup(1.4, 2.6)

func _build() -> void:
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.2, 2.2, 1.2)
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = Vector3(0, 1.1, 0)
	add_child(col)
	var base := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.7
	bm.bottom_radius = 0.85
	bm.height = 0.4
	base.mesh = bm
	base.material_override = _mat(Color(0.2, 0.18, 0.24, 1), 0.0)
	base.position = Vector3(0, 0.2, 0)
	add_child(base)
	_core = MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.7, 1.7, 0.7)
	_core.mesh = cm
	_core.material_override = _mat(Color(0.9, 0.4, 0.2, 1), 1.4)
	_core.position = Vector3(0, 1.2, 0)
	add_child(_core)

func _process(delta: float) -> void:
	if _core != null:
		_core.rotate_y(delta * 0.8)
	if health_bar != null:
		health_bar.set_hp(hp, float(max_hp))

func _mat(color: Color, emission: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.6
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emission
	return m

func aim_point() -> Vector3:
	return global_position + Vector3(0, 1.2, 0)

func take_damage(amount: int, source: Node = null) -> void:
	if dead:
		return
	hp -= max(1, amount)
	if main != null and main.has_method("flash_damage"):
		main.flash_damage(global_position + Vector3(0, 2.6, 0), "-%d" % max(1, amount), Color(1.0, 0.7, 0.3, 1))
	# 被命中：附近敌人仇恨该玩家。
	if is_instance_valid(source) and source is StarGloryPlayer and main != null and main.has_method("aggro_nearby"):
		main.aggro_nearby(global_position, source, 30.0)
	if hp <= 0.0:
		dead = true
		# 被击毁：更大范围内的敌人都仇恨击毁者。
		if is_instance_valid(source) and source is StarGloryPlayer and main != null and main.has_method("aggro_nearby"):
			main.aggro_nearby(global_position, source, 44.0)
		if main != null and main.has_method("spawn_skill_flash"):
			main.spawn_skill_flash(global_position + Vector3(0, 1.0, 0), Color(1.0, 0.5, 0.15, 1), 3.5, 0.5)
			main.flash_message("仇恨图腾被击毁！周围的敌人转向你。")
		queue_free()
