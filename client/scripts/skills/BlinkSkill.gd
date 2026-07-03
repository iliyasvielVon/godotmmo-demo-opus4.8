extends Node3D

var main: Node = null
var caster: StarGloryPlayer = null
var direction: Vector3 = Vector3(0, 0, -1)
var life: float = 0.18
var damage_mult: float = 1.0   # 闪现无伤害，仅占位以兼容 SkillManager 注入
var remote: bool = false       # 联机：他人施法在本地的纯表现（不位移 caster）

func start(p_main: Node, p_caster: StarGloryPlayer, p_direction: Vector3) -> void:
	main = p_main
	caster = p_caster
	direction = p_direction.normalized()
	if caster == null:
		queue_free()
		return
	if not remote:
		caster.face_direction(direction)
		caster.lock_for_skill(0.16, false, false)
		caster.start_temporary_pose("blink", 0.18)
		if caster.buff != null:
			caster.buff.apply_invuln(0.42)
	var start_pos: Vector3 = caster.global_position
	var target: Vector3 = start_pos + direction * 6.5
	if main != null:
		target.x = clamp(target.x, -main.map_radius + 2.0, main.map_radius - 2.0)
		target.z = clamp(target.z, -main.map_radius + 2.0, main.map_radius - 2.0)
		main.spawn_skill_flash(start_pos + Vector3(0, 0.75, 0), Color(0.72, 0.55, 1.0, 1), 1.2, 0.20)
	if not remote:
		caster.global_position = target
	if main != null:
		main.spawn_skill_flash(target + Vector3(0, 0.75, 0), Color(0.72, 0.55, 1.0, 1), 1.5, 0.32)

func _process(delta: float) -> void:
	life -= delta
	if life <= 0.0:
		queue_free()
