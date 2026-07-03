extends Node3D
class_name TerrainSystem

const OreNodeScript = preload("res://scripts/OreNode.gd")

# 一块草地山林 + 蒙德雪山（先做一部分）。程序化高度场：
# - 边缘平滑归 0，无缝接回大世界平地。
# - 起伏草坡高度差小（坡度 < 45°）可直接走上；雪山陡峭需走盘山山路。
# - 山路：绕峰螺旋而上的平缓走廊（横向平、纵向缓坡），山体其余处过陡被 CharacterBody 当墙挡住。
# 顶点色：草地绿 → 岩灰 → 雪白；山路夯土色。带碰撞（trimesh），玩家/怪物可站立行走。

var main: Node = null
var _last_foot: Vector3 = Vector3(9999, 0, 9999)
var _foot_side: float = 1.0
var _snow: CPUParticles3D = null

# 区域（出生点北侧，南缘 z≈-32 在初始可达范围内；避开出生城/据点/副本入口）。
const CX := 0.0
const CZ := -112.0
const HS := 84.0           # 半边长（大幅扩大，靠瓦片流式承载）
const REGION_LIFT := 0.12  # 地形整体抬高量：始终盖在平地(y=0)之上，避免 Z-fighting 闪烁
# 寒冷/取暖
const COLD_LINE := 16.0    # 该地表高度以上进入「严寒」
const WARMTH_R := 8.0
const WARMTH := [Vector3(5, 16, -89), Vector3(22, 2.2, -58)]   # 篝火（高山湖畔 + 山脚湖畔）
# 雪山
const PEAK_X := 0.0
const PEAK_Z := -112.0
const MR := 44.0           # 山体半径
const PEAK := 38.0         # 峰顶高度
const PATH_TURNS := 2.5    # 盘山圈数
const PATH_W := 3.6        # 山路半宽

# 湖泊：山脚盆地湖 + 半山腰削出的高山湖（platform=带围堰的平台盆地）。
const LAKES := [
	{"x": 20.0, "z": -58.0, "r": 13.0, "level": 2.2, "depth": 1.9, "platform": false},
	{"x": -24.0, "z": -66.0, "r": 11.0, "level": 2.0, "depth": 1.7, "platform": false},
	{"x": 0.0, "z": -93.0, "r": 8.0, "level": 16.0, "depth": 2.2, "platform": true},
]
const SNOW_LINE := 24.0
# 瀑布：山坡斜下汇入湖泊；含从高山湖溢出、层层跌落到山脚湖的一道。[{top, bottom, width}]
const FALLS := [
	{"top": Vector3(6, 24, -100), "bottom": Vector3(18, 2.4, -70), "width": 5.0},
	{"top": Vector3(-10, 20, -104), "bottom": Vector3(-22, 2.2, -74), "width": 4.0},
	{"top": Vector3(3, 15, -87), "bottom": Vector3(17, 2.6, -64), "width": 3.2},
]

# 是否处于地形区域（供边界系统豁免，使雪山现在就能攀爬）。
func in_region(x: float, z: float) -> bool:
	return absf(x - CX) <= HS and absf(z - CZ) <= HS

func setup(p_main: Node) -> void:
	main = p_main
	_build()
	_make_snow()

# 采样螺旋山路：返回 {d:到山路中线距离, h:该处山路坡道高度}
func _path_sample(x: float, z: float) -> Dictionary:
	var best_d: float = 1.0e9
	var best_h: float = 0.0
	var steps: int = 150
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)          # 0..1（山脚→峰顶）
		var r: float = MR * (1.0 - t) * 0.92
		var ang: float = t * PATH_TURNS * TAU
		var px: float = PEAK_X + cos(ang) * r
		var pz: float = PEAK_Z + sin(ang) * r
		var d: float = Vector2(x - px, z - pz).length()
		if d < best_d:
			best_d = d
			best_h = t * PEAK
	return {"d": best_d, "h": best_h}

# 核心高度函数（网格与运行时查询共用），返回 {h, path:bool}
func _height(x: float, z: float) -> Dictionary:
	# 边缘平滑：距区域边界 <12 时渐隐到 0。
	var mx: float = HS - absf(x - CX)
	var mz: float = HS - absf(z - CZ)
	var edge: float = clampf(minf(mx, mz) / 12.0, 0.0, 1.0)
	edge = edge * edge * (3.0 - 2.0 * edge)     # smoothstep
	if edge <= 0.0:
		return {"h": REGION_LIFT, "path": false}
	# 起伏草坡（小高度差，可直接走）
	var hills: float = (sin(x * 0.09) * cos(z * 0.08) + 0.5 * sin(x * 0.17 + 1.3) + 0.6 * cos(z * 0.13)) * 2.0
	hills = maxf(0.0, hills + 2.0)
	# 雪山圆锥
	var dm: float = Vector2(x - PEAK_X, z - PEAK_Z).length()
	var cone: float = 0.0
	var is_path: bool = false
	if dm < MR:
		cone = pow(clampf((MR - dm) / MR, 0.0, 1.0), 1.5) * PEAK
		var ps: Dictionary = _path_sample(x, z)
		if float(ps["d"]) < PATH_W:
			# 山路走廊：取坡道高度（横向平），边缘与山体混合。
			var k: float = smoothstep(PATH_W - 1.2, PATH_W, float(ps["d"]))
			cone = lerpf(float(ps["h"]), cone, k)
			is_path = float(ps["d"]) < PATH_W - 1.0
	var h: float = edge * (hills * 0.6 + cone)
	h = _lake_carve(x, z, h)
	# 整体抬高一点，始终盖在大世界平地(y=0)之上，避免草坡与平地共面导致 Z-fighting 闪烁。
	return {"h": h + REGION_LIFT, "path": is_path}

# (x,z) 若在某湖范围内，返回该湖水面高度；否则返回极低哨兵值（用于玩家浮力）。
func lake_surface_at(x: float, z: float) -> float:
	var best: float = -1.0e9
	for lk_v: Variant in LAKES:
		var lk: Dictionary = lk_v
		if Vector2(x - float(lk["x"]), z - float(lk["z"])).length() <= float(lk["r"]) + 1.0:
			best = maxf(best, float(lk["level"]))
	return best

# 在湖泊处把地形塑成盆地：平台湖=带围堰的碗（能在山坡上积水）；普通湖=只下挖。
func _lake_carve(x: float, z: float, h: float) -> float:
	for lk_v: Variant in LAKES:
		var lk: Dictionary = lk_v
		var r: float = float(lk["r"])
		var dl: float = Vector2(x - float(lk["x"]), z - float(lk["z"])).length()
		var lvl: float = float(lk["level"])
		var dep: float = float(lk["depth"])
		if bool(lk.get("platform", false)):
			# 平台湖：碗底=level-depth，围堰=level+1.2；外圈薄环混合回自然山体。
			if dl < r * 1.18:
				var t: float = clampf(dl / r, 0.0, 1.0)
				var bowl: float = (lvl - dep) + (dep + 1.2) * t * t
				h = lerpf(bowl, h, smoothstep(1.0, 1.18, dl / r))
		elif dl < r:
			var t2: float = dl / r
			var floorh: float = maxf(0.2, lvl - dep * (1.0 - t2 * t2))
			h = lerpf(minf(h, floorh), h, smoothstep(r * 0.8, r, dl))   # 靠岸混合
	return h

# 运行时高度查询（刷怪落地/傀儡贴地用）；区域外返回 0。
func height_at(x: float, z: float) -> float:
	if absf(x - CX) > HS or absf(z - CZ) > HS:
		return 0.0
	return float(_height(x, z)["h"])

func _color_for(h: float, path: bool) -> Color:
	if path:
		return Color(0.52, 0.43, 0.32, 1)          # 夯土山路
	if h < 3.0:
		return Color(0.33, 0.58, 0.24, 1)          # 草地
	elif h < 13.0:
		return Color(0.33, 0.58, 0.24, 1).lerp(Color(0.44, 0.44, 0.47, 1), (h - 3.0) / 10.0)
	elif h < 24.0:
		return Color(0.44, 0.44, 0.47, 1).lerp(Color(0.95, 0.97, 1.0, 1), (h - 13.0) / 11.0)
	return Color(0.95, 0.97, 1.0, 1)               # 雪

# 固定景观一次性建好（湖/浪花/瀑布/休息点/湖畔树）；地面按瓦片随玩家流式加载。
func _build() -> void:
	_add_lakes()
	_add_foam()
	_add_waterfalls()
	_add_rest_points()
	_add_lakeside_trees()
	_add_ore_veins()

# 山坡上散布可采集的寒霜晶矿（持久，按 E 采集 → 道具区）。
func _add_ore_veins() -> void:
	if main == null:
		return
	var spots := [Vector2(30, -90), Vector2(18, -84), Vector2(-14, -100), Vector2(8, -122), Vector2(-24, -95), Vector2(38, -108), Vector2(-6, -78)]
	var rng := RandomNumberGenerator.new(); rng.seed = 4242
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = Color(0.82, 0.94, 1.0, 1)
	cmat.emission_enabled = true; cmat.emission = Color(0.7, 0.9, 1.0, 1); cmat.emission_energy_multiplier = 2.6
	for sp: Vector2 in spots:
		var h: float = height_at(sp.x, sp.y)
		if h < 2.5:
			continue
		var vein: StarGloryOreNode = OreNodeScript.new()
		vein.main = main
		vein.mat_name = "寒霜晶矿"
		vein.mat_color = Color(0.82, 0.94, 1.0, 1)
		vein.hp = 85 + rng.randi_range(0, 35)
		vein.position = Vector3(sp.x, h, sp.y)
		add_child(vein)
		for j in range(rng.randi_range(3, 5)):
			var s: float = rng.randf_range(1.1, 2.1)
			var cr := MeshInstance3D.new()
			var pm := PrismMesh.new(); pm.size = Vector3(0.4 * s, 1.6 * s, 0.4 * s)
			cr.mesh = pm; cr.material_override = cmat
			cr.position = Vector3(rng.randf_range(-0.8, 0.8), 0.7 * s, rng.randf_range(-0.8, 0.8))
			cr.rotation = Vector3(rng.randf_range(-0.25, 0.25), rng.randf() * TAU, rng.randf_range(-0.25, 0.25))
			vein.add_child(cr)
		var lbl := Label3D.new()
		lbl.text = "⛏ 寒霜晶矿（攻击打碎）"
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.position = Vector3(0, 3.0, 0); lbl.font_size = 20; lbl.outline_size = 5
		lbl.modulate = Color(0.8, 0.95, 1.0, 1)
		vein.add_child(lbl)

# ---- 瓦片流式地面 ----
const TILE := 40.0
const TILE_CELLS := 18     # 每瓦片网格分辨率
const LOAD_R := 2          # 玩家周围 (2*2+1)^2 瓦片保持加载
const UNLOAD_R := 3
const TILE_BUDGET := 2     # 每帧最多新建瓦片数（摊平加载开销，避免入区卡顿）
var _tiles: Dictionary = {}    # Vector2i -> Node3D

func _tile_of(pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(pos.x / TILE)), int(floor(pos.z / TILE)))

func _tile_overlaps_region(c: Vector2i) -> bool:
	var minx: float = float(c.x) * TILE
	var minz: float = float(c.y) * TILE
	return minx + TILE > CX - HS and minx < CX + HS and minz + TILE > CZ - HS and minz < CZ + HS

func _stream_tiles() -> void:
	if main == null or main.player == null or not is_instance_valid(main.player):
		return
	var pt: Vector2i = _tile_of((main.player as Node3D).global_position)
	# 玩家脚下瓦片优先立即建好，避免掉进未加载区。
	if not _tiles.has(pt) and _tile_overlaps_region(pt):
		_tiles[pt] = _build_tile(pt)
	# 加载范围内、且与地形区域相交的瓦片（每帧限量新建，摊平开销）。
	var built: int = 0
	for dx in range(-LOAD_R, LOAD_R + 1):
		for dz in range(-LOAD_R, LOAD_R + 1):
			if built >= TILE_BUDGET:
				break
			var c := Vector2i(pt.x + dx, pt.y + dz)
			if not _tiles.has(c) and _tile_overlaps_region(c):
				_tiles[c] = _build_tile(c)
				built += 1
	# 卸载远处瓦片。
	for c: Vector2i in _tiles.keys():
		if maxi(absi(c.x - pt.x), absi(c.y - pt.y)) > UNLOAD_R:
			var n: Node = _tiles[c]
			_tiles.erase(c)
			if is_instance_valid(n):
				n.queue_free()

func _build_tile(c: Vector2i) -> Node3D:
	var ox: float = float(c.x) * TILE
	var oz: float = float(c.y) * TILE
	var root := Node3D.new()
	root.name = "Tile_%d_%d" % [c.x, c.y]
	add_child(root)
	# 地面网格 + 碰撞
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cell: float = TILE / float(TILE_CELLS)
	var hs: Array = []
	var cols: Array = []
	for i in range(TILE_CELLS + 1):
		var row_h: Array = []
		var row_c: Array = []
		var x: float = ox + float(i) * cell
		for j in range(TILE_CELLS + 1):
			var z: float = oz + float(j) * cell
			var r: Dictionary = _height(x, z)
			row_h.append(float(r["h"]))
			row_c.append(_color_for(float(r["h"]), bool(r["path"])))
		hs.append(row_h); cols.append(row_c)
	for i in range(TILE_CELLS):
		for j in range(TILE_CELLS):
			var x0: float = ox + float(i) * cell
			var x1: float = x0 + cell
			var z0: float = oz + float(j) * cell
			var z1: float = z0 + cell
			var v00 := Vector3(x0, hs[i][j], z0)
			var v10 := Vector3(x1, hs[i + 1][j], z0)
			var v11 := Vector3(x1, hs[i + 1][j + 1], z1)
			var v01 := Vector3(x0, hs[i][j + 1], z1)
			_tri(st, v00, cols[i][j], v10, cols[i + 1][j], v11, cols[i + 1][j + 1])
			_tri(st, v00, cols[i][j], v11, cols[i + 1][j + 1], v01, cols[i][j + 1])
	st.generate_normals()
	var mesh: ArrayMesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	var mi := MeshInstance3D.new(); mi.mesh = mesh; mi.material_override = mat
	var body := StaticBody3D.new()
	body.add_to_group("obstacle")   # 让怪物视线射线把山体当遮挡
	var cshape := CollisionShape3D.new()
	var tri := mesh.create_trimesh_shape()
	tri.backface_collision = true   # 双面：从山体下方/内部也挡住射线，防止隔山索敌
	cshape.shape = tri
	body.add_child(cshape); body.add_child(mi)
	root.add_child(body)
	_tile_props(c, root)
	return root

# 每瓦片确定性散布树/岩（unload/reload 一致）。
func _tile_props(c: Vector2i, parent: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(hash(Vector2i(c.x, c.y))) ^ 0x9e37
	var ox: float = float(c.x) * TILE
	var oz: float = float(c.y) * TILE
	var n: int = 10
	for k in range(n):
		var x: float = ox + rng.randf_range(0.0, TILE)
		var z: float = oz + rng.randf_range(0.0, TILE)
		if not in_region(x, z):
			continue
		var r: Dictionary = _height(x, z)
		var h: float = float(r["h"])
		if bool(r["path"]) or h < 0.9 or _near_lake(x, z, 1.0):
			continue
		if h < 20.0 and rng.randf() < 0.7:
			_plant_tree_on(parent, x, h, z, rng, h > 11.0)
		elif rng.randf() < 0.5:
			var rock := MeshInstance3D.new()
			var bm := BoxMesh.new(); bm.size = Vector3(rng.randf_range(0.8, 2.0), rng.randf_range(0.8, 1.8), rng.randf_range(0.8, 2.0))
			rock.mesh = bm; rock.material_override = _rock_mat_of()
			rock.position = Vector3(x, h + 0.4, z)
			rock.rotation.y = rng.randf_range(0, TAU)
			parent.add_child(rock)

func _water_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec4 shallow : source_color = vec4(0.34, 0.62, 0.78, 0.6);
uniform vec4 deep : source_color = vec4(0.06, 0.26, 0.44, 0.9);
void fragment() {
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);   // 菲涅尔
	// 水下折射：按波纹扰动屏幕 UV 采样背景
	vec2 wob = vec2(sin(UV.y * 22.0 + TIME * 1.6), cos(UV.x * 20.0 + TIME * 1.3)) * 0.012;
	vec3 refr = texture(screen_tex, SCREEN_UV + wob).rgb;
	vec3 water = mix(deep.rgb, shallow.rgb, f);
	ALBEDO = mix(mix(refr, water, 0.6), water, f);   // 浅处偏水色、透出折射背景
	METALLIC = 0.45;
	ROUGHNESS = 0.05;
	float sp = smoothstep(0.72, 0.98, sin(UV.x * 34.0 + TIME * 1.7) * sin(UV.y * 30.0 + TIME * 1.2));
	EMISSION = shallow.rgb * 0.16 + vec3(sp * 0.6);
	ALPHA = mix(deep.a, shallow.a, f);
}
"""
	return sh

# 岸边浪花：每个湖沿水线一圈半透明白环，轻微起伏。
func _add_foam() -> void:
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.95, 0.98, 1.0, 0.55)
	fmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.emission_enabled = true; fmat.emission = Color(0.8, 0.92, 1.0, 1); fmat.emission_energy_multiplier = 0.4
	for lk_v: Variant in LAKES:
		var lk: Dictionary = lk_v
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = float(lk["r"]) * 0.9
		tm.outer_radius = float(lk["r"]) * 0.98
		tm.rings = 40
		ring.mesh = tm
		ring.material_override = fmat
		ring.position = Vector3(float(lk["x"]), float(lk["level"]) + 0.03, float(lk["z"]))
		add_child(ring)

func _add_lakes() -> void:
	var sh := _water_shader()
	for lk_v: Variant in LAKES:
		var lk: Dictionary = lk_v
		var disc := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = float(lk["r"]) * 0.92
		cm.bottom_radius = float(lk["r"]) * 0.92
		cm.height = 0.06
		cm.radial_segments = 40
		disc.mesh = cm
		var mat := ShaderMaterial.new(); mat.shader = sh
		disc.material_override = mat
		disc.position = Vector3(float(lk["x"]), float(lk["level"]), float(lk["z"]))
		add_child(disc)

func _waterfall_shader() -> Shader:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never;
uniform vec4 col : source_color = vec4(0.62, 0.86, 1.0, 0.85);
void fragment() {
	float flow = fract(UV.y * 5.0 - TIME * 1.9);
	float streak = 0.55 + 0.45 * sin(UV.x * 26.0 + UV.y * 3.0);
	float foam = smoothstep(0.82, 1.0, flow);
	ALBEDO = col.rgb;
	EMISSION = col.rgb * (0.4 + foam * 1.2);
	ALPHA = col.a * (0.45 + 0.55 * flow) * streak;
}
"""
	return sh

func _add_waterfalls() -> void:
	var sh := _waterfall_shader()
	for f_v: Variant in FALLS:
		var f: Dictionary = f_v
		var top: Vector3 = f["top"]
		var bottom: Vector3 = f["bottom"]
		var width: float = float(f["width"])
		var falldir: Vector3 = (bottom - top).normalized()
		var up: Vector3 = -falldir
		var normal: Vector3 = Vector3(0, 0, 1)
		var right: Vector3 = up.cross(normal)
		if right.length() < 0.01:
			right = Vector3(1, 0, 0)
		right = right.normalized()
		normal = right.cross(up).normalized()
		var mi := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(width, top.distance_to(bottom))
		mi.mesh = qm
		var mat := ShaderMaterial.new()
		mat.shader = sh
		mi.material_override = mat
		mi.transform = Transform3D(Basis(right, up, normal), (top + bottom) * 0.5 + normal * 0.4)
		add_child(mi)
		# 落水口水雾
		var mist := CPUParticles3D.new()
		mist.amount = 28
		mist.lifetime = 1.3
		mist.position = bottom + Vector3(0, 0.6, 0)
		mist.direction = Vector3(0, 1, 0)
		mist.spread = 45.0
		mist.initial_velocity_min = 1.0
		mist.initial_velocity_max = 2.6
		mist.gravity = Vector3(0, -2.0, 0)
		mist.scale_amount_min = 0.3
		mist.scale_amount_max = 0.7
		mist.color = Color(0.85, 0.94, 1.0, 0.5)
		add_child(mist)
		# 落水循环音（定位 3D，靠近渐响）
		var ws: AudioStream = Audio.stream_of("water") if Audio.has_method("stream_of") else null
		if ws != null:
			var wp := AudioStreamPlayer3D.new()
			wp.stream = ws
			wp.position = bottom + Vector3(0, 0.5, 0)
			wp.unit_size = 6.0
			wp.max_distance = 34.0
			wp.volume_db = -6.0
			wp.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
			add_child(wp)
			wp.play()

func _tri(st: SurfaceTool, a: Vector3, ca: Color, b: Vector3, cb: Color, c: Vector3, cc: Color) -> void:
	st.set_color(ca); st.add_vertex(a)
	st.set_color(cb); st.add_vertex(b)
	st.set_color(cc); st.add_vertex(c)

# 雪地脚印：玩家在雪线以上落地行走时，间隔留下渐隐的脚印。
func _process(_delta: float) -> void:
	if main == null or main.player == null or not is_instance_valid(main.player):
		return
	var p: Node3D = main.player
	var pp: Vector3 = p.global_position
	_stream_tiles()
	_update_snow(pp)
	# 脚印：雪线以上、落地、走动才留。
	if not in_region(pp.x, pp.z) or height_at(pp.x, pp.z) < SNOW_LINE:
		return
	if p.has_method("is_on_floor") and not p.is_on_floor():
		return
	if Vector2(pp.x - _last_foot.x, pp.z - _last_foot.z).length() < 1.1:
		return
	_last_foot = pp
	_drop_footprint(pp)

# ---------------- 严寒 / 取暖 / 风雪 ----------------
# 严寒强度 0..1（按所站地表高度；区域外/低处为 0）。
func cold_level(pos: Vector3) -> float:
	if not in_region(pos.x, pos.z):
		return 0.0
	var ht: float = height_at(pos.x, pos.z)
	if ht < COLD_LINE:
		return 0.0
	return clampf((ht - COLD_LINE) / (PEAK - COLD_LINE), 0.0, 1.0)

# 是否在篝火取暖范围内。
func is_warm(pos: Vector3) -> bool:
	for w_v: Variant in WARMTH:
		var w: Vector3 = w_v
		if Vector2(pos.x - w.x, pos.z - w.z).length() < WARMTH_R:
			return true
	return false

# 玩家按 E 靠近篝火休息：回满状态（供 Main 的 E 交互链调用）。
func try_rest(pos: Vector3) -> bool:
	if not is_warm(pos):
		return false
	if main.player != null and is_instance_valid(main.player) and main.player.has_method("heal_full"):
		main.player.heal_full()
		var p: Node3D = main.player as Node3D
		var ground_y: float = height_at(p.global_position.x, p.global_position.z) + 0.35
		var water_y: float = lake_surface_at(p.global_position.x, p.global_position.z) + 0.45
		var safe_y: float = maxf(ground_y, water_y)
		if p.global_position.y < safe_y:
			p.global_position.y = safe_y
		var body: CharacterBody3D = main.player as CharacterBody3D
		if body != null:
			body.velocity = Vector3.ZERO
	if main.has_method("flash_message"):
		main.flash_message("🔥 在篝火旁休整，状态已恢复。")
	if main.has_method("spawn_skill_flash"):
		main.spawn_skill_flash((main.player as Node3D).global_position + Vector3(0, 1.0, 0), Color(1.0, 0.7, 0.35, 1), 2.2, 0.5)
	return true

func _make_snow() -> void:
	_snow = CPUParticles3D.new()
	_snow.amount = 260
	_snow.lifetime = 3.2
	_snow.emitting = false
	_snow.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_snow.emission_box_extents = Vector3(16, 1, 16)
	_snow.direction = Vector3(0.2, -1, 0.1)
	_snow.spread = 12.0
	_snow.gravity = Vector3(1.5, -5.0, 0.5)
	_snow.initial_velocity_min = 1.0
	_snow.initial_velocity_max = 2.5
	_snow.scale_amount_min = 0.06
	_snow.scale_amount_max = 0.14
	_snow.color = Color(1, 1, 1, 0.9)
	add_child(_snow)

func _update_snow(pp: Vector3) -> void:
	if _snow == null:
		return
	var c: float = cold_level(pp)
	if c > 0.1:
		_snow.emitting = true
		_snow.global_position = pp + Vector3(0, 11, 0)
	else:
		_snow.emitting = false

# 高山湖畔 + 山脚湖畔各一处休息点：小木屋 + 篝火（暖光 + 火焰粒子）。
func _add_rest_points() -> void:
	for w_v: Variant in WARMTH:
		var w: Vector3 = w_v
		_build_hut(w + Vector3(3.5, 0, 1.5))
		_build_bonfire(w)

func _build_bonfire(pos: Vector3) -> void:
	var log_mat := StandardMaterial3D.new(); log_mat.albedo_color = Color(0.32, 0.2, 0.12, 1)
	for i in range(4):
		var lg := MeshInstance3D.new()
		var bm := BoxMesh.new(); bm.size = Vector3(0.2, 0.2, 1.4)
		lg.mesh = bm; lg.material_override = log_mat
		lg.position = pos + Vector3(0, 0.2, 0)
		lg.rotation.y = TAU * float(i) / 4.0
		add_child(lg)
	var fire := CPUParticles3D.new()
	fire.amount = 40; fire.lifetime = 0.8
	fire.position = pos + Vector3(0, 0.4, 0)
	fire.direction = Vector3(0, 1, 0); fire.spread = 18.0
	fire.gravity = Vector3(0, 3.0, 0)
	fire.initial_velocity_min = 1.2; fire.initial_velocity_max = 2.4
	fire.scale_amount_min = 0.25; fire.scale_amount_max = 0.55
	fire.color = Color(1.0, 0.6, 0.2, 0.9)
	add_child(fire)
	var light := OmniLight3D.new()
	light.position = pos + Vector3(0, 1.2, 0)
	light.light_color = Color(1.0, 0.7, 0.4, 1)
	light.light_energy = 2.2; light.omni_range = WARMTH_R + 4.0
	add_child(light)
	var lbl := Label3D.new()
	lbl.text = "🔥 篝火休息点（按 E 休整）"
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.font_size = 26; lbl.outline_size = 6
	lbl.modulate = Color(1.0, 0.85, 0.5, 1)
	lbl.position = pos + Vector3(0, 2.4, 0)
	add_child(lbl)

func _build_hut(pos: Vector3) -> void:
	var wall_mat := StandardMaterial3D.new(); wall_mat.albedo_color = Color(0.45, 0.32, 0.2, 1)
	var roof_mat := StandardMaterial3D.new(); roof_mat.albedo_color = Color(0.55, 0.2, 0.16, 1)
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = Vector3(4.0, 3.0, 4.0)
	body.mesh = bm; body.material_override = wall_mat
	body.position = pos + Vector3(0, 1.5, 0)
	add_child(body)
	var roof := MeshInstance3D.new()
	var rm := CylinderMesh.new(); rm.top_radius = 0.0; rm.bottom_radius = 3.2; rm.height = 2.0; rm.radial_segments = 4
	roof.mesh = rm; roof.material_override = roof_mat
	roof.position = pos + Vector3(0, 4.0, 0)
	roof.rotation.y = PI * 0.25
	add_child(roof)

func _drop_footprint(pos: Vector3) -> void:
	var fdir: Vector3 = Vector3(0, 0, -1)
	if "last_facing_dir" in main.player:
		fdir = (main.player.last_facing_dir as Vector3)
	fdir.y = 0.0
	if fdir.length() < 0.05:
		fdir = Vector3(0, 0, -1)
	fdir = fdir.normalized()
	var perp: Vector3 = Vector3(-fdir.z, 0, fdir.x)
	var yaw: float = atan2(-fdir.x, -fdir.z)
	var fp := MeshInstance3D.new()
	var q := QuadMesh.new(); q.size = Vector2(0.34, 0.54)
	fp.mesh = q
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.55, 0.62, 0.74, 0.85)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fp.material_override = m
	fp.rotation = Vector3(-PI * 0.5, yaw, 0)
	fp.position = pos + perp * (0.18 * _foot_side) + Vector3(0, 0.04, 0)
	_foot_side = -_foot_side
	add_child(fp)
	var tw := create_tween()
	tw.tween_interval(4.0)
	tw.tween_property(m, "albedo_color:a", 0.0, 3.0)
	tw.tween_callback(fp.queue_free)

var _trunk_mat: StandardMaterial3D = null
var _leaf_mat: StandardMaterial3D = null
var _pine_mat: StandardMaterial3D = null
var _rock_mat: StandardMaterial3D = null

func _ensure_mats() -> void:
	if _trunk_mat != null:
		return
	_trunk_mat = StandardMaterial3D.new(); _trunk_mat.albedo_color = Color(0.35, 0.24, 0.14, 1)
	_leaf_mat = StandardMaterial3D.new(); _leaf_mat.albedo_color = Color(0.18, 0.42, 0.18, 1)
	_pine_mat = StandardMaterial3D.new(); _pine_mat.albedo_color = Color(0.12, 0.32, 0.22, 1)   # 高处深色云杉
	_rock_mat = StandardMaterial3D.new(); _rock_mat.albedo_color = Color(0.4, 0.41, 0.45, 1)

func _rock_mat_of() -> StandardMaterial3D:
	_ensure_mats()
	return _rock_mat

# 湖畔沿岸各种一圈树（固定，不随瓦片卸载）。
func _add_lakeside_trees() -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 20260701
	for lk_v: Variant in LAKES:
		var lk: Dictionary = lk_v
		for i in range(14):
			var ang: float = TAU * float(i) / 14.0 + rng.randf_range(-0.2, 0.2)
			var rr: float = float(lk["r"]) + rng.randf_range(1.5, 5.0)
			var x2: float = float(lk["x"]) + cos(ang) * rr
			var z2: float = float(lk["z"]) + sin(ang) * rr
			var h2: float = height_at(x2, z2)
			if h2 > float(lk["level"]) - 0.2 and h2 < 14.0:
				_plant_tree_on(self, x2, h2, z2, rng, false)

func _near_lake(x: float, z: float, margin: float) -> bool:
	for lk_v: Variant in LAKES:
		var lk: Dictionary = lk_v
		if Vector2(x - float(lk["x"]), z - float(lk["z"])).length() < float(lk["r"]) - margin:
			return true
	return false

func _plant_tree_on(parent: Node, x: float, h: float, z: float, rng: RandomNumberGenerator, alpine: bool) -> void:
	_ensure_mats()
	var s: float = rng.randf_range(0.8, 1.4)
	var trunk := MeshInstance3D.new()
	var cyl := CylinderMesh.new(); cyl.top_radius = 0.18 * s; cyl.bottom_radius = 0.24 * s; cyl.height = 1.6 * s
	trunk.mesh = cyl; trunk.material_override = _trunk_mat
	trunk.position = Vector3(x, h + 0.8 * s, z)
	parent.add_child(trunk)
	var leaf := MeshInstance3D.new()
	var cone := CylinderMesh.new(); cone.top_radius = 0.0; cone.bottom_radius = 1.3 * s; cone.height = (3.4 if alpine else 3.0) * s
	leaf.mesh = cone; leaf.material_override = (_pine_mat if alpine else _leaf_mat)
	leaf.position = Vector3(x, h + (2.9 if alpine else 3.0) * s, z)
	parent.add_child(leaf)
