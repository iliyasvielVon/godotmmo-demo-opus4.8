extends Node3D

# 弹幕术式（参考东方风 danmaku 视频）。确定性：origin/target/seed 驱动，单机与联机各客户端本地渲染，
# 命中只对本地玩家结算（main.combat.apply_player_area_damage）。附加发光材质（emission + 加色混合）近似 shader 观感。
# pattern: laser_web / spiral / hollow_rings / curved_arrows / dome / cross_grid

var main: Node = null
var source: Node = null
var _src_dead: bool = false
var pattern: String = "spiral"
var origin: Vector3 = Vector3.ZERO
var target: Vector3 = Vector3.ZERO
var atk: int = 20
var wl: int = 1
var rng := RandomNumberGenerator.new()
var elapsed: float = 0.0
var total_life: float = 4.0
var dir: Vector3 = Vector3(0, 0, 1)
var bullets: Array = []
var beams: Array = []

const GROUND_Y := 0.4
const HIT_R := 1.25

func start(p_main: Node, p_source: Node, p_pattern: String, p_origin: Vector3, p_target: Vector3, p_seed: int, p_atk: int, p_wl: int = 1) -> void:
	main = p_main
	source = p_source
	pattern = p_pattern
	origin = p_origin
	target = p_target
	atk = p_atk
	wl = max(1, p_wl)
	rng.seed = p_seed
	var d := target - origin
	dir = d.normalized() if d.length() > 0.05 else Vector3(0, 0, 1)
	match pattern:
		"laser_web": total_life = 1.9; _init_laser_web()
		"spiral": total_life = 3.6
		"hollow_rings": total_life = 4.0; _init_hollow_rings()
		"curved_arrows": total_life = 3.0; _init_curved_arrows()
		"dome": total_life = 2.6; _init_dome()
		"cross_grid": total_life = 3.2
		"laser_fan": total_life = 3.4; _init_laser_fan()
		"cage": total_life = 4.2; _init_cage()
		"star_rain": total_life = 3.6
		"charge_orb": total_life = 3.4; _init_charge_orb()
		"ground_lanes": total_life = 3.6
		"curtain": total_life = 3.8
		"slow_orbs": total_life = 4.6; _init_slow_orbs()
		_: total_life = 3.0

const FADE_ON_DEATH := 0.5

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
	# 来源怪物已死 → 停止继续发射(所有发射点都以 total_life 为闸)，已发射的逐步缩小消失。
	if not _src_dead and not _source_alive():
		_src_dead = true
		total_life = minf(total_life, elapsed + FADE_ON_DEATH)
	if _src_dead:
		for c in get_children():
			if c is MeshInstance3D:
				(c as MeshInstance3D).scale *= maxf(0.02, 1.0 - delta * 5.0)
	match pattern:
		"laser_web": _tick_laser_web(delta)
		"spiral": _tick_spiral(delta)
		"hollow_rings": _tick_hollow_rings(delta)
		"curved_arrows": _tick_curved_arrows(delta)
		"dome": _tick_dome(delta)
		"cross_grid": _tick_cross_grid(delta)
		"laser_fan": _tick_laser_fan(delta)
		"cage": _tick_cage(delta)
		"star_rain": _tick_star_rain(delta)
		"charge_orb": _tick_charge_orb(delta)
		"ground_lanes": _tick_ground_lanes(delta)
		"curtain": _tick_curtain(delta)
		"slow_orbs": _tick_slow_orbs(delta)
	if elapsed >= total_life and bullets.is_empty() and beams.is_empty() and not is_instance_valid(_orb):
		queue_free()

# ---------- 命中 ----------
func _hit_local(pos: Vector3, dmg: int) -> bool:
	if main == null or main.combat == null or main.player == null or not is_instance_valid(main.player):
		return false
	if (main.player as Node3D).global_position.distance_to(pos) <= HIT_R:
		main.combat.apply_player_area_damage(pos, HIT_R, dmg)
		return true
	return false

func _seg_hit_local(a: Vector3, b: Vector3, r: float, dmg: int) -> bool:
	if main == null or main.combat == null or main.player == null or not is_instance_valid(main.player):
		return false
	var p: Vector3 = (main.player as Node3D).global_position + Vector3(0, 1.0, 0)
	var ab: Vector3 = b - a
	var t: float = clampf((p - a).dot(ab) / maxf(0.0001, ab.length_squared()), 0.0, 1.0)
	var closest: Vector3 = a + ab * t
	if closest.distance_to(p) <= r:
		main.combat.apply_player_area_damage(main.player.global_position, r + 0.6, dmg)
		return true
	return false

func _hsv(i: float) -> Color:
	return Color.from_hsv(fposmod(i, 1.0), 0.85, 1.0)

func _bullet(pos: Vector3, col: Color, r: float) -> MeshInstance3D:
	r *= 1.35
	var m := SphereMesh.new()
	m.radius = r; m.height = r * 2.0; m.radial_segments = 8; m.rings = 4
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = _glow_mat(col)
	mi.global_position = pos
	add_child(mi)
	return mi

func _glow_mat(col: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 2.4
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD   # 加色发光，近似弹幕辉光
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat

func _free_all(arr: Array) -> void:
	for b_v: Variant in arr:
		var n: Node = (b_v as Dictionary).get("node", null)
		if is_instance_valid(n):
			n.queue_free()
	arr.clear()

# ================= laser_web：多向激光网 (t=86) =================
func _init_laser_web() -> void:
	var k: int = clampi(8 + int(wl / 2), 8, 16)
	for i in range(k):
		var bd := _rand_dir()
		var col: Color = Color(1, 0.3, 0.35, 1) if i % 2 == 0 else Color(0.35, 0.5, 1, 1)
		var len_v: float = rng.randf_range(22.0, 34.0)
		# 细长发光光束（BoxMesh 拉伸并朝向 dir）。
		var bm := BoxMesh.new(); bm.size = Vector3(0.16, 0.16, len_v)
		var mi := MeshInstance3D.new(); mi.mesh = bm; mi.material_override = _glow_mat(col)
		add_child(mi)
		mi.global_position = origin + bd * (len_v * 0.5)
		mi.look_at(mi.global_position + bd, Vector3.UP if absf(bd.y) < 0.95 else Vector3.RIGHT)
		beams.append({"node": mi, "dir": bd, "len": len_v, "born": rng.randf_range(0.0, 0.5), "hit": false})

func _tick_laser_web(_delta: float) -> void:
	var dmg: int = int(atk * 0.9 + wl * 3)
	for i in range(beams.size() - 1, -1, -1):
		var b: Dictionary = beams[i]
		var mi: Node3D = b["node"]
		var age: float = elapsed - float(b["born"])
		if age < 0.0:
			(mi as MeshInstance3D).visible = false
			continue
		(mi as MeshInstance3D).visible = true
		# 预警细 → 实体粗 → 收束
		var w: float = 0.08 if age < 0.35 else (0.5 if age < 1.1 else maxf(0.02, 0.5 - (age - 1.1) * 2.0))
		mi.scale = Vector3(w / 0.16, w / 0.16, 1.0)
		if age >= 0.35 and age < 1.2 and not bool(b["hit"]):
			if _seg_hit_local(origin, origin + (b["dir"] as Vector3) * float(b["len"]), 0.7, dmg):
				b["hit"] = true
		if age > 1.5:
			(mi as Node3D).queue_free()
			beams.remove_at(i)

# ================= spiral：旋转螺旋 (t=143/315) =================
const SPIRAL_ARMS := 4
const SPIRAL_SPEED := 6.5
var _spiral_emit_t: float = 0.0
var _spiral_ang: float = 0.0

func _tick_spiral(delta: float) -> void:
	if elapsed < total_life - 0.8:
		_spiral_emit_t -= delta
		if _spiral_emit_t <= 0.0:
			_spiral_emit_t = 0.095
			_spiral_ang += 0.5
			for a in range(SPIRAL_ARMS):
				var ang: float = _spiral_ang + TAU * float(a) / float(SPIRAL_ARMS)
				var bd := Vector3(cos(ang), rng.randf_range(-0.15, 0.15), sin(ang)).normalized()
				bullets.append({"node": _bullet(origin, _hsv(elapsed * 0.2 + float(a) * 0.13), 0.3), "age": 0.0, "dir": bd})
	var dmg: int = int(atk * 0.4 + wl * 1.5)
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		b["age"] = float(b["age"]) + delta
		var a: float = b["age"]
		var pos: Vector3 = origin + (b["dir"] as Vector3) * (SPIRAL_SPEED * a)
		pos.y = maxf(GROUND_Y, pos.y)
		(b["node"] as Node3D).global_position = pos
		if a > 3.0 or _hit_local(pos, dmg):
			(b["node"] as Node3D).queue_free()
			bullets.remove_at(i)

# ================= hollow_rings：中心爆发 + 空心环弹 (t=401) =================
func _init_hollow_rings() -> void:
	# 中心球状爆发
	var n: int = clampi(22 + wl * 2, 22, 42)
	var ga: float = PI * (3.0 - sqrt(5.0))
	for i in range(n):
		var y: float = 1.0 - 2.0 * (float(i) + 0.5) / float(n)
		var rr: float = sqrt(maxf(0.0, 1.0 - y * y))
		var th: float = ga * float(i)
		var bd := Vector3(cos(th) * rr, y, sin(th) * rr)
		bullets.append({"node": _bullet(origin, _hsv(float(i) * 0.02), 0.28), "age": 0.0, "dir": bd, "spd": rng.randf_range(5.0, 8.0)})
	# 大空心环弹（TorusMesh），向随机水平方向缓慢漂移并扩大
	var rings: int = clampi(4 + int(wl / 3), 4, 8)
	for j in range(rings):
		var ang: float = TAU * float(j) / float(rings)
		var rdir := Vector3(cos(ang), 0, sin(ang))
		var tm := TorusMesh.new(); tm.inner_radius = 0.9; tm.outer_radius = 1.15
		var mi := MeshInstance3D.new(); mi.mesh = tm; mi.material_override = _glow_mat(_hsv(float(j) * 0.11 + 0.5))
		mi.global_position = origin + rdir * 2.0
		add_child(mi)
		beams.append({"node": mi, "dir": rdir, "r": 1.0, "hit": false})

func _tick_hollow_rings(delta: float) -> void:
	var dmg: int = int(atk * 0.5 + wl * 2)
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		b["age"] = float(b["age"]) + delta
		var a: float = b["age"]
		var pos: Vector3 = origin + (b["dir"] as Vector3) * (float(b["spd"]) * a)
		pos.y = maxf(GROUND_Y, pos.y)
		(b["node"] as Node3D).global_position = pos
		if a > 2.4 or _hit_local(pos, dmg):
			(b["node"] as Node3D).queue_free()
			bullets.remove_at(i)
	# 环弹漂移+扩张
	var rdmg: int = int(atk * 0.7 + wl * 2)
	for i in range(beams.size() - 1, -1, -1):
		var rb: Dictionary = beams[i]
		var mi: Node3D = rb["node"]
		var r: float = float(rb["r"]) + delta * 1.1
		rb["r"] = r
		mi.global_position += (rb["dir"] as Vector3) * delta * 3.5
		mi.scale = Vector3.ONE * r
		mi.rotate_y(delta * 1.5)
		if not bool(rb["hit"]) and main != null and main.player != null and is_instance_valid(main.player):
			var pc: Vector3 = (main.player as Node3D).global_position
			var d2: float = Vector2(pc.x - mi.global_position.x, pc.z - mi.global_position.z).length()
			if absf(d2 - r) < 0.6 and absf(pc.y - mi.global_position.y) < 1.2:
				main.combat.apply_player_area_damage(pc, 1.0, rdmg)
				rb["hit"] = true
		if elapsed > total_life - 0.2:
			mi.queue_free(); beams.remove_at(i)

# ================= curved_arrows：曲线激光 + 归位箭矢 (t=444) =================
func _init_curved_arrows() -> void:
	var m: int = clampi(8 + int(wl / 2), 8, 16)
	for i in range(m):
		var spread := _rand_dir()
		var p0: Vector3 = origin + spread * 2.0
		var ctrl: Vector3 = (p0 + target) * 0.5 + Vector3(rng.randf_range(-6, 6), rng.randf_range(2, 7), rng.randf_range(-6, 6))
		# 箭矢：细长棱柱
		var pm := PrismMesh.new(); pm.size = Vector3(0.5, 0.9, 0.35)
		var mi := MeshInstance3D.new(); mi.mesh = pm; mi.material_override = _glow_mat(Color(1, 0.35, 0.4, 1) if i % 2 == 0 else Color(0.3, 0.9, 1, 1))
		mi.global_position = p0
		add_child(mi)
		bullets.append({"node": mi, "p0": p0, "ctrl": ctrl, "t": 0.0, "delay": rng.randf_range(0.0, 0.7), "hit": false})

func _tick_curved_arrows(delta: float) -> void:
	var dmg: int = int(atk * 0.7 + wl * 2)
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		if elapsed < float(b["delay"]):
			continue
		b["t"] = minf(1.0, float(b["t"]) + delta / 1.6)
		var t: float = b["t"]
		var p0: Vector3 = b["p0"]; var c: Vector3 = b["ctrl"]; var p2: Vector3 = target + Vector3(0, 0.6, 0)
		var pos: Vector3 = p0.lerp(c, t).lerp(c.lerp(p2, t), t)
		var mi: Node3D = b["node"]
		var prev: Vector3 = mi.global_position
		mi.global_position = pos
		if pos.distance_to(prev) > 0.01:
			mi.look_at(pos + (pos - prev), Vector3.UP)
		if not bool(b["hit"]) and _hit_local(pos, dmg):
			b["hit"] = true
		if t >= 1.0:
			mi.queue_free(); bullets.remove_at(i)

# ================= dome：分层半球罩 (t=487) =================
func _init_dome() -> void:
	for layer in range(2):
		var col: Color = Color(0.3, 0.5, 1, 1) if layer == 0 else Color(1, 0.3, 0.7, 1)
		var n: int = 36
		var ga: float = PI * (3.0 - sqrt(5.0))
		for i in range(n):
			var y: float = float(i) / float(n)          # 只取上半球
			var rr: float = sqrt(maxf(0.0, 1.0 - y * y))
			var th: float = ga * float(i)
			var hd := Vector3(cos(th) * rr, y, sin(th) * rr).normalized()
			bullets.append({"node": _bullet(origin, col, 0.26), "hd": hd, "layer": layer, "hit": false})

func _tick_dome(delta: float) -> void:
	var dmg: int = int(atk * 0.6 + wl * 2)
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		var layer: int = b["layer"]
		var start_t: float = 0.0 if layer == 0 else 0.5
		var r: float = maxf(0.0, (elapsed - start_t)) * 7.0
		var pos: Vector3 = origin + (b["hd"] as Vector3) * r
		pos.y = maxf(GROUND_Y, pos.y)
		(b["node"] as Node3D).global_position = pos
		if not bool(b["hit"]) and _hit_local(pos, dmg):
			b["hit"] = true
		if r > 24.0:
			(b["node"] as Node3D).queue_free(); bullets.remove_at(i)

# ================= cross_grid：四向网格流 (t=344) =================
func _tick_cross_grid(delta: float) -> void:
	if elapsed < total_life - 0.8:
		if fmod(elapsed, 0.13) < delta:
			var right := Vector3(1, 0, 0)
			var up := Vector3(0, 1, 0)
			# 四条对角方向（xz 平面 45°）
			for s in [Vector3(1, 0.4, 1), Vector3(-1, 0.4, 1), Vector3(1, 0.4, -1), Vector3(-1, 0.4, -1)]:
				var base := (s as Vector3).normalized()
				var perp := base.cross(up).normalized()
				for lane in range(-1, 2):
					var bd := (base + perp * (float(lane) * 0.14)).normalized()
					bullets.append({"node": _bullet(origin, _hsv(0.6 + float(lane) * 0.03), 0.24), "age": 0.0, "dir": bd})
	var dmg: int = int(atk * 0.45 + wl * 1.5)
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		b["age"] = float(b["age"]) + delta
		var a: float = b["age"]
		var pos: Vector3 = origin + (b["dir"] as Vector3) * (10.0 * a)
		pos.y = maxf(GROUND_Y, pos.y)
		(b["node"] as Node3D).global_position = pos
		if a > 2.6 or _hit_local(pos, dmg):
			(b["node"] as Node3D).queue_free()
			bullets.remove_at(i)

# 统一光束（单位长 z=1 的发光盒，运行时缩放/朝向）。
func _make_beam(col: Color, thick: float) -> MeshInstance3D:
	var bm := BoxMesh.new(); bm.size = Vector3(thick, thick, 1.0)
	var mi := MeshInstance3D.new(); mi.mesh = bm; mi.material_override = _glow_mat(col)
	add_child(mi)
	return mi

func _place_beam(mi: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	var mid: Vector3 = (a + b) * 0.5
	var len_v: float = maxf(0.01, a.distance_to(b))
	mi.global_position = mid
	var d: Vector3 = (b - a).normalized()
	if absf(d.dot(Vector3.UP)) < 0.98:
		mi.look_at(mid + d, Vector3.UP)
	else:
		mi.look_at(mid + d, Vector3.RIGHT)
	mi.scale = Vector3(1, 1, len_v)

# ================= laser_fan：旋转激光扇 (t=100) =================
const FAN_BEAMS := 6
const FAN_LEN := 30.0
var _fan_spin: float = 0.0

func _init_laser_fan() -> void:
	for i in range(FAN_BEAMS):
		var col: Color = Color(1, 0.3, 0.35, 1) if i % 2 == 0 else Color(0.35, 0.6, 1, 1)
		beams.append({"node": _make_beam(col, 0.22), "base": TAU * float(i) / float(FAN_BEAMS), "cd": 0.0})

func _tick_laser_fan(delta: float) -> void:
	_fan_spin += delta * 1.1
	var dmg: int = int(atk * 0.8 + wl * 2)
	var tilt: float = 0.35
	for b_v: Variant in beams:
		var b: Dictionary = b_v
		var ang: float = float(b["base"]) + _fan_spin
		var bd := Vector3(cos(ang), tilt, sin(ang)).normalized()
		var endp: Vector3 = origin + bd * FAN_LEN
		_place_beam(b["node"], origin, endp)
		b["cd"] = maxf(0.0, float(b["cd"]) - delta)
		if float(b["cd"]) <= 0.0 and _seg_hit_local(origin, endp, 0.7, dmg):
			b["cd"] = 0.5
	if elapsed >= total_life:
		_free_all(beams)

# ================= cage：旋转线框牢笼 (t=372) =================
const CAGE_VERTS := [Vector3(-1,-1,-1), Vector3(1,-1,-1), Vector3(1,-1,1), Vector3(-1,-1,1), Vector3(-1,1,-1), Vector3(1,1,-1), Vector3(1,1,1), Vector3(-1,1,1)]
const CAGE_EDGES := [[0,1],[1,2],[2,3],[3,0],[4,5],[5,6],[6,7],[7,4],[0,4],[1,5],[2,6],[3,7]]
var _cage_center: Vector3 = Vector3.ZERO

func _init_cage() -> void:
	_cage_center = target + Vector3(0, 3.0, 0)   # 罩住玩家所在处
	for e in CAGE_EDGES:
		beams.append({"node": _make_beam(Color(0.9, 0.95, 1.0, 1), 0.12), "e": e, "cd": 0.0})

func _tick_cage(delta: float) -> void:
	var r: float = 6.0 + sin(elapsed * 1.5) * 1.2         # 呼吸缩放
	var rot := Basis.from_euler(Vector3(elapsed * 0.6, elapsed * 0.9, elapsed * 0.3))
	var vpos: Array = []
	for v_v: Variant in CAGE_VERTS:
		vpos.append(_cage_center + rot * ((v_v as Vector3) * r))
	var dmg: int = int(atk * 0.7 + wl * 2)
	for b_v: Variant in beams:
		var b: Dictionary = b_v
		var e: Array = b["e"]
		var a: Vector3 = vpos[int(e[0])]
		var bb: Vector3 = vpos[int(e[1])]
		_place_beam(b["node"], a, bb)
		b["cd"] = maxf(0.0, float(b["cd"]) - delta)
		if float(b["cd"]) <= 0.0 and _seg_hit_local(a, bb, 0.6, dmg):
			b["cd"] = 0.6
	if elapsed >= total_life:
		_free_all(beams)

# ================= star_rain：星弹雨 + 彩虹激光 (t=200) =================
var _star_emit_t: float = 0.0
var _star_beams_made: bool = false

func _tick_star_rain(delta: float) -> void:
	# 彩虹横扫激光（少量）
	if not _star_beams_made:
		_star_beams_made = true
		for i in range(5):
			beams.append({"node": _make_beam(_hsv(float(i) * 0.2), 0.18), "base": TAU * float(i) / 5.0, "cd": 0.0})
	_fan_spin += delta * 0.8
	for b_v: Variant in beams:
		var b: Dictionary = b_v
		var ang: float = float(b["base"]) + _fan_spin
		var bd := Vector3(cos(ang), 0.05, sin(ang)).normalized()
		var a: Vector3 = target + Vector3(0, 1.2, 0) - bd * 20.0
		var bb: Vector3 = target + Vector3(0, 1.2, 0) + bd * 20.0
		(b["node"] as MeshInstance3D).material_override = _glow_mat(_hsv(elapsed * 0.3 + float(b["base"])))
		_place_beam(b["node"], a, bb)
		b["cd"] = maxf(0.0, float(b["cd"]) - delta)
		if float(b["cd"]) <= 0.0 and _seg_hit_local(a, bb, 0.6, int(atk * 0.6 + wl * 2)):
			b["cd"] = 0.7
	# 星弹从上方落向玩家周围
	if elapsed < total_life - 0.8:
		_star_emit_t -= delta
		if _star_emit_t <= 0.0:
			_star_emit_t = 0.16
			for i in range(3):
				var off := Vector3(rng.randf_range(-9, 9), rng.randf_range(10, 16), rng.randf_range(-9, 9))
				bullets.append({"node": _bullet(target + off, _hsv(rng.randf()), 0.32), "age": 0.0, "spawn": target + off})
	var dmg: int = int(atk * 0.5 + wl * 1.5)
	for i in range(bullets.size() - 1, -1, -1):
		var b2: Dictionary = bullets[i]
		b2["age"] = float(b2["age"]) + delta
		var a2: float = b2["age"]
		var pos: Vector3 = (b2["spawn"] as Vector3) + Vector3(0, -1, 0) * (11.0 * a2)   # 直落
		pos.y = maxf(GROUND_Y, pos.y)
		(b2["node"] as Node3D).global_position = pos
		(b2["node"] as Node3D).rotate_y(delta * 6.0)
		if pos.y <= GROUND_Y + 0.05 or _hit_local(pos, dmg):
			(b2["node"] as Node3D).queue_free()
			bullets.remove_at(i)

# ================= charge_orb：蓄力能量球 → 爆裂冲击波 (t=257/472) =================
const CHARGE_T := 1.2
var _orb: MeshInstance3D = null
var _charge_fired: bool = false

func _init_charge_orb() -> void:
	var m := SphereMesh.new(); m.radius = 0.6; m.height = 1.2
	_orb = MeshInstance3D.new(); _orb.mesh = m; _orb.material_override = _glow_mat(Color(0.6, 0.4, 1.0, 1))
	add_child(_orb); _orb.global_position = origin

func _tick_charge_orb(delta: float) -> void:
	if not _charge_fired:
		if elapsed < CHARGE_T:
			if is_instance_valid(_orb):
				_orb.scale = Vector3.ONE * (1.0 + elapsed / CHARGE_T * 3.5)
				_orb.rotate_y(delta * 7.0)
			return
		_charge_fired = true
		if is_instance_valid(_orb):
			_orb.queue_free()
		if main != null and main.has_method("spawn_skill_flash"):
			main.spawn_skill_flash(origin, Color(0.75, 0.55, 1.0, 1), 5.5, 0.4)
		if main != null and main.has_method("shake_at"):
			main.shake_at(origin, 0.55)
		var n: int = clampi(24 + wl * 2, 24, 46)
		var ga: float = PI * (3.0 - sqrt(5.0))
		for i in range(n):
			var y: float = 1.0 - 2.0 * (float(i) + 0.5) / float(n)
			var rr: float = sqrt(maxf(0.0, 1.0 - y * y))
			var th: float = ga * float(i)
			bullets.append({"node": _bullet(origin, _hsv(float(i) * 0.02 + 0.6), 0.3), "age": 0.0, "dir": Vector3(cos(th) * rr, y, sin(th) * rr), "spd": rng.randf_range(5.5, 9.0)})
		var tm := TorusMesh.new(); tm.inner_radius = 0.9; tm.outer_radius = 1.15
		var ring := MeshInstance3D.new(); ring.mesh = tm; ring.material_override = _glow_mat(Color(0.85, 0.6, 1.0, 1))
		add_child(ring); ring.global_position = origin + Vector3(0, 0.4, 0)
		beams.append({"node": ring, "r": 1.0, "hit": false})
	var dmg: int = int(atk * 0.5 + wl * 2)
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		b["age"] = float(b["age"]) + delta
		var a: float = b["age"]
		var pos: Vector3 = origin + (b["dir"] as Vector3) * (float(b["spd"]) * a)
		pos.y = maxf(GROUND_Y, pos.y)
		(b["node"] as Node3D).global_position = pos
		if a > 2.2 or _hit_local(pos, dmg):
			(b["node"] as Node3D).queue_free(); bullets.remove_at(i)
	var rdmg: int = int(atk * 0.9 + wl * 3)
	for i in range(beams.size() - 1, -1, -1):
		var rb: Dictionary = beams[i]
		var r: float = float(rb["r"]) + delta * 16.0
		rb["r"] = r
		(rb["node"] as Node3D).scale = Vector3.ONE * r
		(rb["node"] as Node3D).rotate_y(delta * 2.0)
		if not bool(rb["hit"]) and main != null and main.player != null and is_instance_valid(main.player):
			var pc: Vector3 = (main.player as Node3D).global_position
			var d2: float = Vector2(pc.x - origin.x, pc.z - origin.z).length()
			if absf(d2 - r) < 1.3:
				main.combat.apply_player_area_damage(pc, 1.5, rdmg); rb["hit"] = true
		if r > 26.0:
			(rb["node"] as Node3D).queue_free(); beams.remove_at(i)

# ================= ground_lanes：地面弹幕跑道 (t=57/300) =================
var _lane_t: float = 0.0

func _tick_ground_lanes(delta: float) -> void:
	if elapsed < total_life - 0.9:
		_lane_t -= delta
		if _lane_t <= 0.0:
			_lane_t = 0.22
			var perp := Vector3(-dir.z, 0, dir.x).normalized()
			for lane in range(-2, 3):
				var o: Vector3 = origin + perp * (float(lane) * 1.9); o.y = GROUND_Y
				bullets.append({"node": _bullet(o, _hsv(0.3 + float(lane) * 0.03), 0.3), "age": 0.0, "start": o})
	var dmg: int = int(atk * 0.5 + wl * 1.5)
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		b["age"] = float(b["age"]) + delta
		var a: float = float(b["age"])
		var pos: Vector3 = (b["start"] as Vector3) + dir * (11.0 * a); pos.y = GROUND_Y
		(b["node"] as Node3D).global_position = pos
		if a > 2.8 or _hit_local(pos, dmg):
			(b["node"] as Node3D).queue_free(); bullets.remove_at(i)

# ================= curtain：弹幕帘（整面推进，带移动缺口）(t=71) =================
var _curtain_t: float = 0.0

func _tick_curtain(delta: float) -> void:
	if elapsed < total_life - 1.0:
		_curtain_t -= delta
		if _curtain_t <= 0.0:
			_curtain_t = 0.32
			var perp := Vector3(-dir.z, 0, dir.x).normalized()
			var gap: int = rng.randi_range(-5, 5)   # 每排一个可躲缺口
			for w in range(-6, 7):
				if absi(w - gap) <= 1:
					continue
				var o: Vector3 = origin + perp * (float(w) * 1.5) + Vector3(0, 1.1, 0)
				bullets.append({"node": _bullet(o, _hsv(0.55 + float(w) * 0.01), 0.3), "age": 0.0, "start": o})
	var dmg: int = int(atk * 0.5 + wl * 1.5)
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		b["age"] = float(b["age"]) + delta
		var a: float = float(b["age"])
		var pos: Vector3 = (b["start"] as Vector3) + dir * (8.5 * a)
		pos.y = maxf(GROUND_Y, pos.y)
		(b["node"] as Node3D).global_position = pos
		if a > 3.0 or _hit_local(pos, dmg):
			(b["node"] as Node3D).queue_free(); bullets.remove_at(i)

# ================= slow_orbs：大型慢速光球 (t=28) =================
func _init_slow_orbs() -> void:
	var k: int = clampi(4 + int(wl / 2), 4, 8)
	for i in range(k):
		var d := _rand_dir(); d.y = absf(d.y) * 0.3
		var m := SphereMesh.new(); m.radius = 0.85; m.height = 1.7
		var mi := MeshInstance3D.new(); mi.mesh = m; mi.material_override = _glow_mat(_hsv(float(i) * 0.15))
		add_child(mi); mi.global_position = origin
		bullets.append({"node": mi, "age": 0.0, "dir": d.normalized(), "spd": rng.randf_range(2.5, 4.2)})

func _tick_slow_orbs(delta: float) -> void:
	var dmg: int = int(atk * 0.8 + wl * 2)
	for i in range(bullets.size() - 1, -1, -1):
		var b: Dictionary = bullets[i]
		b["age"] = float(b["age"]) + delta
		var a: float = float(b["age"])
		var pos: Vector3 = origin + (b["dir"] as Vector3) * (float(b["spd"]) * a)
		pos.y = maxf(GROUND_Y + 0.6, pos.y)
		var mi: Node3D = b["node"]
		mi.global_position = pos
		mi.rotate_y(delta * 1.4)
		if main != null and main.player != null and is_instance_valid(main.player) and main.combat != null:
			if pos.distance_to((main.player as Node3D).global_position + Vector3(0, 1.0, 0)) < 1.5:
				main.combat.apply_player_area_damage(main.player.global_position, 1.5, dmg)
				mi.queue_free(); bullets.remove_at(i); continue
		if a > 4.2:
			mi.queue_free(); bullets.remove_at(i)

func _rand_dir() -> Vector3:
	var z: float = rng.randf_range(-1.0, 1.0)
	var th: float = rng.randf_range(0.0, TAU)
	var r: float = sqrt(maxf(0.0, 1.0 - z * z))
	return Vector3(cos(th) * r, z, sin(th) * r)
