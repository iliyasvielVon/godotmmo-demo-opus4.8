extends Node3D

# Boss 究极「巨兵天罚」表现：蓄力期头顶自底向上长出巨剑 → 沿目标方向砸落 → 沿该长度宽幅激光持续。
# 纯表现（伤害/击飞由 Monster(单机) 或服务器(联机) 权威结算）。用 (origin,dir,len,width,charge_t,slam_t,beam_t) 启动。

var main: Node = null
var boss: Node3D = null
var origin: Vector3 = Vector3.ZERO
var dir: Vector3 = Vector3(0, 0, 1)
var length: float = 18.0
var width: float = 5.0
var charge_t: float = 1.3
var slam_t: float = 0.6
var beam_t: float = 2.5
var elapsed: float = 0.0
var total_life: float = 0.0
var blade: Node3D = null
var beam: MeshInstance3D = null
var beam_mat: StandardMaterial3D = null
const BLADE_H := 6.0          # 巨剑长度
const HEAD_Y := 4.0           # 蓄力时剑悬于 Boss 头顶高度

func start(p_main: Node, p_boss: Node3D, p_origin: Vector3, p_dir: Vector3, p_len: float, p_width: float, p_charge: float, p_slam: float, p_beam: float) -> void:
	main = p_main
	boss = p_boss
	origin = p_origin
	origin.y = 0.0
	dir = p_dir.normalized() if p_dir.length() > 0.01 else Vector3(0, 0, 1)
	length = p_len
	width = p_width
	charge_t = p_charge
	slam_t = p_slam
	beam_t = p_beam
	total_life = charge_t + slam_t + beam_t + 0.4
	_build_blade()

func _yaw() -> float:
	return atan2(dir.x, dir.z)

func _process(delta: float) -> void:
	if main == null:
		queue_free()
		return
	elapsed += delta
	var base: Vector3 = (boss.global_position if (boss != null and is_instance_valid(boss)) else origin)
	if elapsed < charge_t:
		# 蓄力：巨剑自底向上生长于 Boss 头顶（竖直，剑尖向上）。
		var g: float = clampf(elapsed / max(charge_t, 0.01), 0.0, 1.0)
		blade.global_position = Vector3(base.x, HEAD_Y, base.z)
		blade.rotation = Vector3(0, _yaw(), 0)
		blade.scale = Vector3(0.6 + 0.4 * g, g, 0.6 + 0.4 * g)
	elif elapsed < charge_t + slam_t:
		# 砸落：剑旋到水平、沿 dir 拍到地面矩形中线上。
		var s: float = clampf((elapsed - charge_t) / max(slam_t, 0.01), 0.0, 1.0)
		var ss: float = s * s
		var mid: Vector3 = origin + dir * (length * 0.5)
		blade.global_position = Vector3(base.x, HEAD_Y, base.z).lerp(Vector3(mid.x, 0.6, mid.z), ss)
		blade.rotation = Vector3(lerpf(0.0, -PI * 0.5, ss), _yaw(), 0)
		blade.scale = Vector3.ONE
		if s >= 1.0 and beam == null:
			_build_beam()
	else:
		# 激光：宽幅矩形光束沿 dir 持续，末尾淡出。
		if beam == null:
			_build_beam()
		var bt: float = elapsed - charge_t - slam_t
		var pulse: float = 0.7 + 0.3 * sin(bt * 22.0)
		if beam_mat != null:
			beam_mat.emission_energy_multiplier = 2.5 * pulse
			var fade: float = clampf(1.0 - (bt - beam_t) / 0.4, 0.0, 1.0) if bt > beam_t else 1.0
			beam_mat.albedo_color.a = 0.5 * fade
	if elapsed >= total_life:
		queue_free()

func _build_blade() -> void:
	blade = Node3D.new()
	add_child(blade)
	# 剑身
	var bm := BoxMesh.new()
	bm.size = Vector3(0.6, BLADE_H, 0.18)
	var b := MeshInstance3D.new()
	b.mesh = bm
	b.position = Vector3(0, BLADE_H * 0.5, 0)
	b.material_override = _mat(Color(0.85, 0.9, 1.0, 1), Color(0.7, 0.85, 1.0, 1), 2.0, false)
	blade.add_child(b)
	# 护手
	var gm := BoxMesh.new()
	gm.size = Vector3(1.8, 0.3, 0.3)
	var g := MeshInstance3D.new()
	g.mesh = gm
	g.position = Vector3(0, 0.2, 0)
	g.material_override = _mat(Color(1.0, 0.85, 0.4, 1), Color(1.0, 0.7, 0.2, 1), 1.4, false)
	blade.add_child(g)
	# 剑柄
	var hm := BoxMesh.new()
	hm.size = Vector3(0.28, 1.1, 0.28)
	var h := MeshInstance3D.new()
	h.mesh = hm
	h.position = Vector3(0, -0.55, 0)
	h.material_override = _mat(Color(0.4, 0.3, 0.2, 1), Color(0.3, 0.2, 0.1, 1), 0.4, false)
	blade.add_child(h)
	blade.global_position = Vector3(origin.x, HEAD_Y, origin.z)
	blade.scale = Vector3(0.6, 0.01, 0.6)

func _build_beam() -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(width, 0.3, length)
	beam = MeshInstance3D.new()
	beam.mesh = mesh
	beam_mat = _mat(Color(0.7, 0.85, 1.0, 0.5), Color(0.6, 0.8, 1.0, 1), 2.5, true)
	beam.material_override = beam_mat
	add_child(beam)
	var mid: Vector3 = origin + dir * (length * 0.5)
	beam.global_position = Vector3(mid.x, 0.3, mid.z)
	beam.rotation = Vector3(0, _yaw(), 0)

func _mat(albedo: Color, emission: Color, energy: float, transparent: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.emission_enabled = true
	m.emission = emission
	m.emission_energy_multiplier = energy
	if transparent:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
