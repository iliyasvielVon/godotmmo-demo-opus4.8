extends Node3D

var main: Node = null
var caster: StarGloryPlayer = null
var elapsed: float = 0.0
var life: float = 0.62
var damage_mult: float = 1.0   # 由 SkillManager 按技能等级注入
var skill_level: int = 0       # 由 SkillManager 注入；用于按等级放大范围
var remote: bool = false       # 联机：他人施法在本地的纯表现
var radius_mult: float = 1.0   # 范围随技能等级放大（每级 +8%）
var ring: MeshInstance3D = null
var mat: StandardMaterial3D = null

func start(p_main: Node, p_caster: StarGloryPlayer, p_direction: Vector3) -> void:
	main = p_main
	caster = p_caster
	if caster == null:
		queue_free()
		return
	radius_mult = 1.0 + 0.08 * float(skill_level)
	global_position = caster.global_position + Vector3(0, 0.16, 0)
	if not remote:
		caster.lock_for_skill(0.45, false, false)
		caster.start_temporary_pose("frost", 0.45)
	_build_ring()
	if main != null:
		if not remote:
			main.combat.apply_area_damage(global_position + Vector3(0, 0.4, 0), 5.6 * radius_mult, int((caster.magic + 26) * damage_mult), caster, 0.58, 1.2)
		main.spawn_skill_flash(global_position + Vector3(0, 0.35, 0), Color(0.45, 0.85, 1.0, 1), 5.2 * radius_mult, 0.52)

func _process(delta: float) -> void:
	elapsed += delta
	var t: float = clamp(elapsed / life, 0.0, 1.0)
	if ring != null:
		ring.scale = Vector3.ONE * ((0.35 + t * 5.9) * radius_mult)
		ring.rotate_y(delta * 2.5)
	if mat != null:
		mat.albedo_color.a = 0.72 * (1.0 - t)
	if elapsed >= life:
		queue_free()

func _build_ring() -> void:
	var mesh: CylinderMesh = CylinderMesh.new()
	mesh.top_radius = 1.0
	mesh.bottom_radius = 1.0
	mesh.height = 0.035
	mesh.radial_segments = 64
	ring = MeshInstance3D.new()
	ring.mesh = mesh
	mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.85, 1.0, 0.72)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.45, 0.85, 1.0, 1)
	mat.emission_energy_multiplier = 1.6
	ring.material_override = mat
	add_child(ring)
