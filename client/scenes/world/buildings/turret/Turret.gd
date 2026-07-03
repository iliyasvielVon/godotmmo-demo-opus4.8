class_name StarGloryTurret
extends StaticBody3D

# 固定炮塔：不可移动，顶部转向玩家，按间隔发射导弹做远程打击。
# 可被无差别爆炸炸伤（building 组）。可在编辑器里把本 .tscn 直接拖进区块场景摆放，
# 也可由 Main 在代码里生成；main 缺省时用 current_scene 解析。

var main: Node = null
@export var level: int = 1          # 初始等级，可在编辑器/放置时设置
var world_level: int = 1            # 世界等级：越高炮台起始等级越高、伤害与射速越强
var max_hp: int = 260
var hp: float = 260.0
var level_up_timer: float = 30.0    # 每 30s 自动升一级（封顶 5）
var fire_timer: float = 1.6
var bullet_type: String = "missile" # 本炮塔固定弹种（_ready 随机分配）

var top: Node3D = null      # 可旋转的炮塔头
var muzzle: Node3D = null   # 炮口（导弹出生点）
var glow_head: MeshInstance3D = null
var health_bar: HealthBar3D = null
var range_ring: MeshInstance3D = null
var dead: bool = false

const TYPES: Array[String] = ["aimed", "homing", "missile", "split", "frost", "firework"]
const MAX_LEVEL := 5
const MissileScene = preload("res://scenes/world/buildings/turret/Missile.tscn")

# 实时世界等级（随玩家成长上升，让已存在的炮台也跟着变强）。
func _live_world_level() -> int:
	if main != null and main.has_method("get_world_level"):
		return int(main.get_world_level())
	return world_level

# 每级属性（一级温和，逐级变强）；伤害/射速/射程再叠加世界等级加成。
# DAMAGE_AMP 整体增幅炮台输出（之前偏低）。
const DAMAGE_AMP := 1.9
func _stat_range() -> float: return (22.0 + 5.0 * float(level - 1)) + 2.0 * float(_live_world_level() - 1)
func _stat_damage() -> int: return int((20 + 9 * (level - 1)) * (1.0 + 0.32 * float(_live_world_level() - 1)) * DAMAGE_AMP)
func _stat_aoe() -> float: return 3.0 + 0.6 * float(level - 1)
func _stat_knockback() -> float: return 4.0 + 1.5 * float(level - 1)
func _stat_interval() -> float: return max(1.3, 3.6 - 0.3 * float(level - 1) - 0.2 * float(_live_world_level() - 1))

func _ready() -> void:
	if main == null:
		main = get_tree().current_scene
	# 世界等级越高，炮台起始等级越高。
	level = clampi(level + (world_level - 1), 1, MAX_LEVEL)
	bullet_type = TYPES[randi() % TYPES.size()]
	add_to_group("building")
	add_to_group("obstacle")   # 实体阻挡 + 在小地图显示
	_build_collision()
	_build_model()
	health_bar = HealthBar3D.new()
	add_child(health_bar)
	health_bar.setup(1.8, 3.4)
	_build_range_ring()
	fire_timer = _stat_interval()

func _build_range_ring() -> void:
	var ring := TorusMesh.new()
	ring.inner_radius = 0.97
	ring.outer_radius = 1.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.5, 0.2, 0.35)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.2, 1)
	mat.emission_energy_multiplier = 1.2
	range_ring = MeshInstance3D.new()
	range_ring.name = "RangeRing"
	range_ring.mesh = ring
	range_ring.material_override = mat
	range_ring.rotation.x = PI / 2.0
	range_ring.position = Vector3(0, 0.08, 0)
	add_child(range_ring)
	_update_range_ring()

func _update_range_ring() -> void:
	if range_ring != null:
		var r: float = _stat_range()
		range_ring.scale = Vector3(r, r, r)

func _mat(color: Color, emission: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.6
	m.metallic = 0.4
	if emission > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = emission
	return m

func _add(parent: Node, mesh: Mesh, mat: Material, pos: Vector3, rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi

func _build_collision() -> void:
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.8, 2.0, 1.8)
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = Vector3(0, 1.0, 0)
	add_child(col)

func _build_model() -> void:
	var metal := _mat(Color(0.40, 0.44, 0.50, 1))
	var dark := _mat(Color(0.16, 0.17, 0.22, 1))
	var glow := _mat(Color(1.0, 0.55, 0.2, 1), 1.4)

	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 1.25
	base_mesh.bottom_radius = 1.45
	base_mesh.height = 0.5
	_add(self, base_mesh, dark, Vector3(0, 0.25, 0))

	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(1.5, 1.3, 1.5)
	_add(self, body_mesh, metal, Vector3(0, 1.1, 0))

	top = Node3D.new()
	top.name = "TurretTop"
	top.position = Vector3(0, 1.95, 0)
	add_child(top)

	var head_mesh := BoxMesh.new()
	head_mesh.size = Vector3(1.1, 0.7, 1.2)
	_add(top, head_mesh, metal, Vector3(0, 0, 0))
	glow_head = _add(top, head_mesh.duplicate(), glow, Vector3(0, 0.42, 0))
	glow_head.scale = Vector3(0.4, 0.18, 0.4)

	# 炮管沿 -Z（look_at 默认把 -Z 指向目标）。
	var barrel_mesh := CylinderMesh.new()
	barrel_mesh.top_radius = 0.16
	barrel_mesh.bottom_radius = 0.18
	barrel_mesh.height = 1.5
	_add(top, barrel_mesh, dark, Vector3(0, 0.06, -0.9), Vector3(PI / 2.0, 0, 0))

	muzzle = Node3D.new()
	muzzle.name = "Muzzle"
	muzzle.position = Vector3(0, 0.06, -1.65)
	top.add_child(muzzle)

func _physics_process(delta: float) -> void:
	if dead:
		return
	if health_bar != null:
		health_bar.set_hp(hp, float(max_hp))
	fire_timer -= delta
	# 随时间自动升级。
	if level < MAX_LEVEL:
		level_up_timer -= delta
		if level_up_timer <= 0.0:
			level_up_timer = 30.0
			level += 1
			_update_range_ring()
			if glow_head != null and glow_head.material_override is StandardMaterial3D:
				(glow_head.material_override as StandardMaterial3D).emission_energy_multiplier = 1.4 + 0.4 * float(level - 1)
			if main != null and main.has_method("flash_message"):
				main.flash_message("炮塔升级 → Lv%d" % level)
			if main != null and main.has_method("spawn_skill_flash"):
				main.spawn_skill_flash(global_position + Vector3(0, 2.4, 0), Color(1.0, 0.7, 0.25, 1), 1.6, 0.4)
	var player: StarGloryPlayer = (main.player as StarGloryPlayer) if main != null else null
	if player == null or not is_instance_valid(player) or player.hp <= 0.0:
		return
	var to: Vector3 = player.global_position - global_position
	var dist: float = Vector2(to.x, to.z).length()
	if dist > _stat_range():
		return
	# 炮塔头朝导弹初速方向（上抬+朝目标），与升空弧线一致——炮管对准发射方向。
	if top != null:
		var horiz: Vector3 = Vector3(to.x, 0, to.z)
		if horiz.length() < 0.5:
			horiz = -top.global_transform.basis.z   # 玩家几乎在正上方时退化保护
			horiz.y = 0.0
		var hdist: float = horiz.length()
		var aim_pt: Vector3 = top.global_position + horiz * 0.5 + Vector3(0, 12.0 + hdist * 0.15, 0)
		top.look_at(aim_pt, Vector3.UP)
	if fire_timer <= 0.0:
		fire_timer = _stat_interval()
		_fire(player)

func _fire(player: StarGloryPlayer) -> void:
	if main == null:
		return
	# 弹种：每次开火随机一种（UI 强制项已移除；若仍设了 forced 则优先）。
	var bt: String = TYPES[randi() % TYPES.size()]
	if "forced_bullet_type" in main and String(main.forced_bullet_type) != "":
		bt = String(main.forced_bullet_type)
	var start_pos: Vector3 = muzzle.global_position if muzzle != null else global_position + Vector3(0, 2.0, 0)
	var missile: Node3D = MissileScene.instantiate() as Node3D
	main.projectile_root.add_child(missile)
	missile.setup({
		"main": main,
		"source": self,
		"start": start_pos,
		"target": player.global_position,       # 发射瞬间锁定玩家所在位置
		"bullet_type": bt,
		"damage": _stat_damage(),
		"aoe": _stat_aoe(),
		"knockback": _stat_knockback() * 0.1
	})
	if main.has_method("spawn_skill_flash"):
		main.spawn_skill_flash(start_pos, Color(1.0, 0.6, 0.2, 1), 0.7, 0.16)

# 自动索敌瞄准点：炮塔头部中心，便于普攻速射/焰弹精确命中。
func aim_point() -> Vector3:
	return global_position + Vector3(0, 1.95, 0)

func take_damage(amount: int, _source: Node = null) -> void:
	if dead:
		return
	hp -= max(1, amount)
	if main != null and main.has_method("flash_damage"):
		main.flash_damage(global_position + Vector3(0, 2.6, 0), "-%d" % max(1, amount), Color(0.9, 0.85, 0.5, 1))
	if hp <= 0.0:
		dead = true
		if main != null and main.has_method("spawn_skill_flash"):
			main.spawn_skill_flash(global_position + Vector3(0, 1.0, 0), Color(1.0, 0.5, 0.15, 1), 3.0, 0.5)
		queue_free()
