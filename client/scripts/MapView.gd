extends Control

var main = null
var big: bool = false

const MINI_VIEW := 38.0   # 小地图可视世界半径

func _ready() -> void:
	# 可点击：小地图点击=展开/收起大地图；大地图点击=设导航点。
	mouse_filter = Control.MOUSE_FILTER_STOP

func _process(_delta: float) -> void:
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	var pressed: bool = false
	var pos: Vector2 = Vector2.ZERO
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT and (event as InputEventMouseButton).pressed:
		pressed = true
		pos = (event as InputEventMouseButton).position
	elif event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed:
		pressed = true
		pos = (event as InputEventScreenTouch).position
	if not pressed or main == null:
		return
	if big:
		_set_nav_from_screen(pos)   # 大地图：点哪导航到哪
	elif main.has_method("toggle_big_map"):
		main.toggle_big_map()       # 小地图：点击展开/收起大地图（手机点按）
	accept_event()

# 大地图本地点击坐标 -> 世界坐标，设为导航点（超出地图范围则忽略）。
func _set_nav_from_screen(local_pos: Vector2) -> void:
	var radius: float = main.map_radius
	var s: float = min(size.x, size.y) / (radius * 2.0)
	var center: Vector2 = size * 0.5
	var world := Vector3((local_pos.x - center.x) / s, 0.0, (local_pos.y - center.y) / s)
	if Vector2(world.x, world.z).length() > radius:
		return
	if main.has_method("set_nav_target"):
		main.set_nav_target(world)

func _draw() -> void:
	if main == null:
		return
	if big:
		_draw_full()
	else:
		_draw_mini()

# ---------------- 大地图（全图，保持原样） ----------------
func _draw_full() -> void:
	var bg: Color = Color(0.015, 0.025, 0.055, 0.94)
	draw_rect(Rect2(Vector2.ZERO, size), bg, true)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.45, 0.85, 1.0, 0.72), false, 2.0)
	var radius: float = main.map_radius
	var unlocked_radius: float = main.get_unlocked_radius() if main.has_method("get_unlocked_radius") else radius
	var s: float = min(size.x, size.y) / (radius * 2.0)
	var center: Vector2 = size * 0.5
	for i in range(-2, 3):
		var x: float = center.x + float(i) * radius * s / 2.0
		var y: float = center.y + float(i) * radius * s / 2.0
		draw_line(Vector2(x, 0), Vector2(x, size.y), Color(0.25, 0.45, 0.7, 0.25), 1.0)
		draw_line(Vector2(0, y), Vector2(size.x, y), Color(0.25, 0.45, 0.7, 0.25), 1.0)
	_draw_zone(Vector3(-96, 0, -94), 18.0, Color(1.0, 0.25, 0.2, 0.23), s, center)
	_draw_zone(Vector3(42, 0, 35), 16.0, Color(0.3, 0.7, 1.0, 0.18), s, center)
	_draw_zone(Vector3(0, 0, 0), 13.0, Color(0.4, 1.0, 0.75, 0.14), s, center)
	draw_arc(center, unlocked_radius * s, 0, TAU, 96, Color(1.0, 0.72, 0.22, 0.70), 3.0)
	if main.player != null:
		_draw_entity(main.player.global_position, Color(0.35, 0.95, 1.0, 1), 7.5, s, center)
	for node in main.monsters:
		var monster: StarGloryMonster = node as StarGloryMonster
		if monster == null or not is_instance_valid(monster) or monster.dead:
			continue
		if monster.is_boss:
			var bp: Vector2 = _world_to_map(monster.global_position, s, center)
			var bt: float = Time.get_ticks_msec() * 0.001
			draw_circle(bp, 13.0, Color(1.0, 0.5, 0.1, 0.25))
			_draw_star(bp, 9.0 * (1.0 + 0.18 * sin(bt * 5.0)), Color(1.0, 0.85, 0.22, 1), bt * 0.8)
			continue
		_draw_entity(monster.global_position, Color(1.0, 0.32, 0.22, 1), 3.6, s, center)
	for node in main.pickups:
		var pickup: StarGloryPickup = node as StarGloryPickup
		if pickup == null or not is_instance_valid(pickup):
			continue
		_draw_entity(pickup.global_position, Color(0.7, 1.0, 0.45, 1), 3.2, s, center)
	if main.has_nav:
		_draw_nav_marker(_world_to_map(main.nav_target, s, center))

# ---------------- 小地图（原神风：玩家居中、正北朝上、局部缩放、圆形） ----------------
func _draw_mini() -> void:
	var center: Vector2 = size * 0.5
	var r_px: float = min(size.x, size.y) * 0.5 - 2.0
	var scale_v: float = r_px / MINI_VIEW
	# 圆形底 + 边框
	draw_circle(center, r_px, Color(0.015, 0.025, 0.055, 0.86))
	draw_arc(center, r_px, 0, TAU, 64, Color(0.45, 0.85, 1.0, 0.8), 2.0)
	draw_arc(center, r_px * 0.5, 0, TAU, 48, Color(0.3, 0.55, 0.8, 0.25), 1.0)
	# 正北标记
	draw_string(ThemeDB.fallback_font, center + Vector2(-5, -r_px + 14), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.85, 0.4, 0.9))

	if main.player == null:
		return
	var origin: Vector3 = main.player.global_position
	# 地标（在视野内才画）
	_draw_zone_mini(Vector3(0, 0, 0), 13.0, Color(0.4, 1.0, 0.75, 0.18), origin, scale_v, center, r_px)
	_draw_zone_mini(Vector3(42, 0, 35), 16.0, Color(0.3, 0.7, 1.0, 0.20), origin, scale_v, center, r_px)
	_draw_zone_mini(Vector3(-96, 0, -94), 18.0, Color(1.0, 0.25, 0.2, 0.26), origin, scale_v, center, r_px)
	# 障碍物：当玩家被某障碍物（在其足迹内且其顶部高于玩家头部）遮住时，该障碍物半透明以露出玩家。
	for node in get_tree().get_nodes_in_group("obstacle"):
		var body: Node3D = node as Node3D
		if body == null or not is_instance_valid(body):
			continue
		var ext: Vector2 = _obstacle_extent(body)   # x=水平半径, y=顶部世界Y
		var horiz: float = Vector2(body.global_position.x - origin.x, body.global_position.z - origin.z).length()
		if horiz > MINI_VIEW + ext.x:
			continue
		var occluding: bool = horiz < ext.x and ext.y > origin.y + 0.6
		var col: Color = Color(0.62, 0.56, 0.48, 0.30 if occluding else 0.80)
		var p: Vector2 = _mini_to_screen(body.global_position, origin, scale_v, center)
		if p.distance_to(center) > r_px - 1.0:
			continue
		draw_circle(p, max(ext.x * scale_v, 2.0), col)
	# 怪物（Boss 用特殊★标注，实时；超出小地图视野时贴边指向）
	for node in main.monsters:
		var monster: StarGloryMonster = node as StarGloryMonster
		if monster == null or not is_instance_valid(monster) or monster.dead:
			continue
		if monster.is_boss:
			_draw_boss_mini(monster.global_position, origin, scale_v, center, r_px)
			continue
		var col: Color = Color(1.0, 0.6, 0.2, 1) if monster.elite else Color(1.0, 0.32, 0.22, 1)
		_draw_entity_mini(monster.global_position, col, 4.2 if monster.elite else 3.2, origin, scale_v, center, r_px)
	# 掉落
	for node in main.pickups:
		var pickup: StarGloryPickup = node as StarGloryPickup
		if pickup == null or not is_instance_valid(pickup):
			continue
		_draw_entity_mini(pickup.global_position, Color(0.7, 1.0, 0.45, 1), 3.0, origin, scale_v, center, r_px)
	# 导航点（视野内画标记，视野外贴边指向）
	if main.has_nav:
		_draw_nav_mini(main.nav_target, origin, scale_v, center, r_px)
	# 玩家朝向箭头（居中）
	_draw_player_arrow(center)

func _draw_player_arrow(center: Vector2) -> void:
	var lf: Vector3 = main.player.last_facing_dir
	var fwd: Vector2 = Vector2(lf.x, lf.z)
	if fwd.length() < 0.01:
		fwd = Vector2(0, -1)
	fwd = fwd.normalized()
	var side: Vector2 = Vector2(-fwd.y, fwd.x)
	var tip: Vector2 = center + fwd * 8.0
	var bl: Vector2 = center - fwd * 5.0 + side * 5.0
	var br: Vector2 = center - fwd * 5.0 - side * 5.0
	draw_colored_polygon(PackedVector2Array([tip, bl, br]), Color(0.35, 0.95, 1.0, 1))

# 从障碍物的碰撞形状估算 (水平半径, 顶部世界Y)，供小地图绘制与遮挡判定。
func _obstacle_extent(body: Node3D) -> Vector2:
	var rad: float = 0.6
	var top: float = body.global_position.y
	for c in body.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape != null:
			var shape: Shape3D = (c as CollisionShape3D).shape
			var center_y: float = body.global_position.y + (c as CollisionShape3D).position.y
			if shape is BoxShape3D:
				var sz: Vector3 = (shape as BoxShape3D).size
				rad = max(sz.x, sz.z) * 0.5
				top = center_y + sz.y * 0.5
			elif shape is CylinderShape3D:
				rad = (shape as CylinderShape3D).radius
				top = center_y + (shape as CylinderShape3D).height * 0.5
			elif shape is SphereShape3D:
				rad = (shape as SphereShape3D).radius
				top = center_y + (shape as SphereShape3D).radius
			break
	return Vector2(rad, top)

func _mini_to_screen(world: Vector3, origin: Vector3, scale_v: float, center: Vector2) -> Vector2:
	return center + Vector2(world.x - origin.x, world.z - origin.z) * scale_v

func _draw_entity_mini(world: Vector3, color: Color, r: float, origin: Vector3, scale_v: float, center: Vector2, r_px: float) -> void:
	var p: Vector2 = _mini_to_screen(world, origin, scale_v, center)
	if p.distance_to(center) > r_px - 1.0:
		return
	draw_circle(p, r, color)

# Boss 小地图标注：视野内画脉动★+光环；视野外贴到圆形边缘并加三角箭头指向。
func _draw_boss_mini(world: Vector3, origin: Vector3, scale_v: float, center: Vector2, r_px: float) -> void:
	var t: float = Time.get_ticks_msec() * 0.001
	var pulse: float = 1.0 + 0.20 * sin(t * 5.0)
	var gold: Color = Color(1.0, 0.85, 0.22, 1)
	var ember: Color = Color(1.0, 0.5, 0.12, 1)
	var p: Vector2 = _mini_to_screen(world, origin, scale_v, center)
	if p.distance_to(center) <= r_px - 7.0:
		draw_arc(p, 11.0 * pulse, 0, TAU, 22, Color(ember.r, ember.g, ember.b, 0.55), 1.6)
		_draw_star(p, 8.0 * pulse, gold, t * 0.8)
	else:
		var dir: Vector2 = p - center
		if dir.length() < 0.01:
			dir = Vector2(0, -1)
		dir = dir.normalized()
		var edge: Vector2 = center + dir * (r_px - 10.0)
		var tip: Vector2 = center + dir * (r_px - 1.0)
		var side: Vector2 = Vector2(-dir.y, dir.x)
		draw_colored_polygon(PackedVector2Array([tip, edge + side * 5.0, edge - side * 5.0]), Color(ember.r, ember.g, ember.b, 0.95))
		_draw_star(edge, 6.5 * pulse, gold, t * 0.8)

# 生成 n 角星的顶点（外/内半径交替）。
func _star_points(c: Vector2, outer: float, inner: float, n: int, rot: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(n * 2):
		var rad: float = outer if i % 2 == 0 else inner
		var a: float = rot + PI * float(i) / float(n)
		pts.append(c + Vector2(cos(a), sin(a)) * rad)
	return pts

func _draw_star(c: Vector2, outer: float, color: Color, rot: float) -> void:
	var pts: PackedVector2Array = _star_points(c, outer, outer * 0.44, 5, rot - PI * 0.5)
	draw_colored_polygon(pts, color)
	var outline := pts
	outline.append(pts[0])
	draw_polyline(outline, Color(0.35, 0.2, 0.0, 0.8), 1.4)

# 导航点标记：脉动金色菱形。
func _draw_nav_marker(p: Vector2) -> void:
	var t: float = Time.get_ticks_msec() * 0.001
	var pulse: float = 1.0 + 0.22 * sin(t * 4.0)
	var r: float = 7.0 * pulse
	var pts := PackedVector2Array([p + Vector2(0, -r), p + Vector2(r * 0.7, 0), p + Vector2(0, r), p + Vector2(-r * 0.7, 0)])
	draw_colored_polygon(pts, Color(1.0, 0.85, 0.25, 1))
	var outline := pts
	outline.append(pts[0])
	draw_polyline(outline, Color(0.3, 0.2, 0.0, 0.85), 1.4)

# 小地图导航点：视野内画菱形；视野外贴圆形边缘并加三角箭头指向。
func _draw_nav_mini(world: Vector3, origin: Vector3, scale_v: float, center: Vector2, r_px: float) -> void:
	var p: Vector2 = _mini_to_screen(world, origin, scale_v, center)
	if p.distance_to(center) <= r_px - 6.0:
		_draw_nav_marker(p)
		return
	var dir: Vector2 = p - center
	if dir.length() < 0.01:
		dir = Vector2(0, -1)
	dir = dir.normalized()
	var edge: Vector2 = center + dir * (r_px - 9.0)
	var tip: Vector2 = center + dir * (r_px - 1.0)
	var side: Vector2 = Vector2(-dir.y, dir.x)
	draw_colored_polygon(PackedVector2Array([tip, edge + side * 5.0, edge - side * 5.0]), Color(1.0, 0.85, 0.25, 0.95))
	_draw_nav_marker(edge)

func _draw_zone_mini(world: Vector3, world_radius: float, color: Color, origin: Vector3, scale_v: float, center: Vector2, r_px: float) -> void:
	var p: Vector2 = _mini_to_screen(world, origin, scale_v, center)
	if p.distance_to(center) > r_px + world_radius * scale_v:
		return
	draw_circle(p, world_radius * scale_v, color)

# ---------------- 大地图辅助（原有） ----------------
func _world_to_map(pos: Vector3, scale_value: float, center: Vector2) -> Vector2:
	return center + Vector2(pos.x, pos.z) * scale_value

func _draw_entity(pos: Vector3, color: Color, r: float, scale_value: float, center: Vector2) -> void:
	var p: Vector2 = _world_to_map(pos, scale_value, center)
	draw_circle(p, r, color)
	draw_circle(p, r + 1.5, Color(color.r, color.g, color.b, 0.22))

func _draw_zone(pos: Vector3, world_radius: float, color: Color, scale_value: float, center: Vector2) -> void:
	var p: Vector2 = _world_to_map(pos, scale_value, center)
	draw_circle(p, world_radius * scale_value, color)
	draw_arc(p, world_radius * scale_value, 0, TAU, 48, Color(color.r, color.g, color.b, 0.55), 1.0)
