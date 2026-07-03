extends Node3D

# 飞天弹幕精英的三套 3D 弹幕（确定性：origin/target/seed 驱动，单机与联机各客户端本地渲染）。
# 命中只对「本地玩家」结算（main.combat.apply_player_area_damage），与既有玩家受击模型一致。
# sub: 1=球面甩鞭(3D)  2=贝塞尔环幕  3=弹跳爆炸球。
# 全部为立体弹幕：发射点为球心，方向覆盖整个球面，不限于水平面。

var main: Node = null
var source: Node = null
var sub: int = 1
var origin: Vector3 = Vector3.ZERO     # 发射球心（怪物处，空中）
var target: Vector3 = Vector3.ZERO     # 锁定目标点（玩家释放瞬间位置，非追踪）
var atk: int = 16
var wl: int = 1                        # 世界等级：弹幕数量/密度/伤害的成长
var rng := RandomNumberGenerator.new()
var elapsed: float = 0.0
var total_life: float = 4.0
var dir: Vector3 = Vector3(0, 0, 1)    # origin→target 的方向
var bullets: Array = []

const GROUND_Y := 0.4
const BULLET_R := 0.48
const HIT_R := 1.25

func start(p_main: Node, p_source: Node, p_sub: int, p_origin: Vector3, p_target: Vector3, p_seed: int, p_atk: int, p_wl: int = 1) -> void:
	main = p_main
	source = p_source
	sub = p_sub
	origin = p_origin
	target = p_target
	atk = p_atk
	wl = max(1, p_wl)
	rng.seed = p_seed
	var d := target - origin
	dir = d.normalized() if d.length() > 0.05 else Vector3(0, 0, 1)
	match sub:
		1: total_life = 3.4
		2: total_life = 3.2
		3: total_life = 4.2
	if sub == 2:
		_init_ring()
	elif sub == 3:
		_bounce_spawn_t = 0.0
		_bounce_count = 0
	else:
		_init_sphere()

const FADE_ON_DEATH := 0.5
var _src_dead: bool = false

func _source_alive() -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if "dead" in source and bool(source.dead):
		return false
	return true

func _process(delta: float) -> void:
	if main == null:
		queue_free()
		return
	elapsed += delta
	# 来源怪物已死 → 停止继续发射，已发射的逐步缩小消失。
	if not _src_dead and not _source_alive():
		_src_dead = true
		total_life = minf(total_life, elapsed + FADE_ON_DEATH)
	if _src_dead:
		for c in get_children():
			if c is MeshInstance3D:
				(c as MeshInstance3D).scale *= maxf(0.02, 1.0 - delta * 5.0)
	match sub:
		1: _tick_sphere(delta)
		2: _tick_ring(delta)
		3: _tick_bounce(delta)
	if elapsed >= total_life and bullets.is_empty():
		queue_free()

func _hit_local(pos: Vector3, dmg: int) -> bool:
	if main == null or main.combat == null or main.player == null or not is_instance_valid(main.player):
		return false
	if (main.player as Node3D).global_position.distance_to(pos) <= HIT_R:
		main.combat.apply_player_area_damage(pos, HIT_R, dmg)
		return true
	return false

func _color(i: int) -> Color:
	return Color.from_hsv(fposmod(float(i) * 0.0739 + float(sub) * 0.2 + elapsed * 0.15, 1.0), 0.9, 1.0)

func _bullet(pos: Vector3, col: Color, r: float) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.radial_segments = 10
	var mi := MeshInstance3D.new()
	mi.mesh = m
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 2.0
	mi.material_override = mat
	mi.global_position = pos
	add_child(mi)
	return mi

func _free_bullet(b: Dictionary) -> void:
	if is_instance_valid(b["node"]):
		(b["node"] as Node3D).queue_free()

# ============== 模式 1：球面 3D 甩鞭 ==============
# 发射点=球心；N 条鞭幕方向均匀铺满整个球面（斐波那契球），每条沿其 3D 方向放射、并在两条法向上做螺旋 sin 摆动。
const SPHERE_SPEED := 8.5
const SPHERE_AMP := 1.45
const SPHERE_FREQ := 7.5
const SPHERE_EMIT := 0.09
var _sphere_dirs: Array = []       # [{dir, perp1, perp2, phase}]
var _sphere_emit_t: float = 0.0

func _init_sphere() -> void:
	var n: int = clampi(12 + wl, 12, 30)   # 条数随世界等级成长，但保持移动端可控
	var ga: float = PI * (3.0 - sqrt(5.0))
	for i in range(n):
		var y: float = 1.0 - 2.0 * (float(i) + 0.5) / float(n)
		var rr: float = sqrt(maxf(0.0, 1.0 - y * y))
		var th: float = ga * float(i)
		var bdir := Vector3(cos(th) * rr, y, sin(th) * rr).normalized()
		var perp1: Vector3 = bdir.cross(Vector3(0, 1, 0))
		if perp1.length() < 0.05:
			perp1 = bdir.cross(Vector3(1, 0, 0))
		perp1 = perp1.normalized()
		var perp2: Vector3 = bdir.cross(perp1).normalized()
		_sphere_dirs.append({"dir": bdir, "perp1": perp1, "perp2": perp2, "phase": float(i)})
	_sphere_emit_t = 0.0

func _tick_sphere(delta: float) -> void:
	if elapsed < total_life - 0.5:
		_sphere_emit_t -= delta
		if _sphere_emit_t <= 0.0:
			_sphere_emit_t = SPHERE_EMIT
			var idx: int = 0
			for sd: Dictionary in _sphere_dirs:
				bullets.append({"node": _bullet(origin, _color(idx), BULLET_R), "age": 0.0, "sd": sd})
				idx += 1
	var dmg: int = int(atk * 0.5 + float(wl) * 1.5)
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		b["age"] = float(b["age"]) + delta
		var a: float = b["age"]
		var sd: Dictionary = b["sd"]
		var bd: Vector3 = sd["dir"]
		var p1: Vector3 = sd["perp1"]
		var p2: Vector3 = sd["perp2"]
		var ph: float = sd["phase"]
		# 3D 螺旋甩鞭：沿 dir 放射 + 两条法向上的 sin/cos 摆动。
		var pos: Vector3 = origin + bd * (SPHERE_SPEED * a) \
			+ p1 * (SPHERE_AMP * sin(SPHERE_FREQ * a + ph)) \
			+ p2 * (SPHERE_AMP * 0.7 * cos(SPHERE_FREQ * a + ph))
		if pos.y < GROUND_Y:
			pos.y = GROUND_Y
		(b["node"] as Node3D).global_position = pos
		if a > 2.4 or _hit_local(pos, dmg):
			_free_bullet(b)
			bullets.remove_at(i)

# ============== 模式 2：环幕沿切线 → 贝塞尔扑向锁定点（3D）==============
const RING_RADIUS := 2.8
const RING_TAN_T := 0.9
const RING_BEZ_T := 1.4
var _ring_center: Vector3 = Vector3.ZERO

func _init_ring() -> void:
	var n: int = clampi(14 + wl, 14, 28)
	_ring_center = origin - dir * 3.0 + Vector3(0, 0.6, 0)
	var up := Vector3(0, 1, 0)
	var right := dir.cross(up)
	if right.length() < 0.05:
		right = dir.cross(Vector3(1, 0, 0))
	right = right.normalized()
	var vert := dir.cross(right).normalized()   # 竖直方向（环在 dir 的法平面内）
	for i in range(n):
		var ang := TAU * float(i) / float(n)
		var off := right * (cos(ang) * RING_RADIUS) + vert * (sin(ang) * RING_RADIUS)
		var node := _bullet(_ring_center + off, _color(i), BULLET_R)
		bullets.append({"node": node, "ang": ang, "right": right, "vert": vert, "p0": Vector3.ZERO})

func _tick_ring(delta: float) -> void:
	var dmg: int = int(atk * 0.7 + float(wl) * 2.0)
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		var node: Node3D = b["node"]
		var right: Vector3 = b["right"]
		var vert: Vector3 = b["vert"]
		if elapsed < RING_TAN_T:
			b["ang"] = float(b["ang"]) + delta * 3.6
			node.global_position = _ring_center + right * (cos(float(b["ang"])) * RING_RADIUS) + vert * (sin(float(b["ang"])) * RING_RADIUS)
			b["p0"] = node.global_position
		else:
			var t: float = clampf((elapsed - RING_TAN_T) / RING_BEZ_T, 0.0, 1.0)
			var p0: Vector3 = b["p0"]
			var ctrl: Vector3 = (p0 + target) * 0.5 + Vector3(0, 4.5, 0) + right * (sin(float(b["ang"])) * 4.0)
			var pos: Vector3 = p0.lerp(ctrl, t).lerp(ctrl.lerp(target + Vector3(0, 0.6, 0), t), t)
			node.global_position = pos
			if t >= 1.0 or _hit_local(pos, dmg):
				_free_bullet(b)
				bullets.remove_at(i)

# ============== 模式 3：弹跳爆炸大球 ==============
const BOUNCE_INTERVAL := 0.45
const BOUNCE_MAX := 3
const BOUNCE_R := 1.25
var _bounce_spawn_t: float = 0.0
var _bounce_count: int = 0

func _tick_bounce(delta: float) -> void:
	var total: int = clampi(3 + int(wl / 3), 3, 6)
	if _bounce_count < total and not _src_dead:
		_bounce_spawn_t -= delta
		if _bounce_spawn_t <= 0.0:
			_bounce_spawn_t = BOUNCE_INTERVAL
			_bounce_count += 1
			var land := target + Vector3(rng.randf_range(-5, 5), 0, rng.randf_range(-5, 5))
			var startp := origin + Vector3(0, 1.0, 0)
			var horiz := Vector3(land.x - startp.x, 0, land.z - startp.z)
			var node := _bullet(startp, _color(_bounce_count), BOUNCE_R)
			var vel := horiz * 0.55 + Vector3(0, 7.5, 0)
			bullets.append({"node": node, "vel": vel, "bounces": 0})
	var blast: int = int(atk * 1.2 + float(wl) * 4.0)
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		var node: Node3D = b["node"]
		var vel: Vector3 = b["vel"]
		vel.y -= 22.0 * delta
		var pos: Vector3 = node.global_position + vel * delta
		if pos.y <= GROUND_Y:
			pos.y = GROUND_Y
			b["bounces"] = int(b["bounces"]) + 1
			vel.y = -vel.y * 0.62
			vel.x *= 0.7
			vel.z *= 0.7
			if int(b["bounces"]) >= BOUNCE_MAX:
				if main != null and main.has_method("spawn_skill_flash"):
					main.spawn_skill_flash(pos + Vector3(0, 0.4, 0), _color(i), 3.4, 0.6)
				if main != null and main.combat != null:
					main.combat.apply_player_area_damage(pos, 3.4, blast)
				_free_bullet(b)
				bullets.remove_at(i)
				continue
		b["vel"] = vel
		node.global_position = pos
