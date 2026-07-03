class_name StarGloryPlayer
extends CharacterBody3D

var main = null
var camera_yaw: float = 0.0
var map_radius: float = 90.0

var level: int = 1
var exp_points: int = 0
var next_level_exp: int = 80

var base_max_hp: int = 280   # 生命基数翻倍
var base_max_mp: int = 180   # 法力基数翻倍
var base_attack: int = 18
var base_magic: int = 14
var base_defense: int = 3
var base_speed: float = 7.2
var base_toughness: int = 6
var gm_speed_mult: float = 1.0

var max_hp: int = base_max_hp
var max_mp: int = base_max_mp
var hp: float = base_max_hp
var mp: float = base_max_mp
var attack: int = base_attack
var magic: int = base_magic
var defense: int = base_defense
var move_speed: float = base_speed
var toughness: int = base_toughness   # 韧性：越高越抗控、击飞/控制时间越短
var cast_seq: int = 0                  # 施法序号；被打断时自增使在飞技能场景失效
var mp_regen: float = 16.0   # 回蓝翻倍
# 体力（奔跑耐力）：奔跑/冲刺消耗，停下恢复；耗尽后需回到 25% 才能再次奔跑。
var max_stamina: int = 100
var stamina: float = 100.0
var stamina_regen: float = 22.0   # 不奔跑时每秒恢复
var stamina_drain: float = 26.0   # 奔跑时每秒消耗
var _stamina_exhausted: bool = false
var lifesteal: float = 0.0   # 吸血比例（伤害的百分比转为治疗），来自主/副武器
var zone_blocked: bool = false   # 处于未解锁的禁制领域：减速、禁技、持续扣血/外推（由 Main 设置）
var jump_velocity: float = 11.8
var gravity: float = 32.0
var run_multiplier: float = 1.65
var ground_accel: float = 46.0
var ground_decel: float = 36.0
var air_control: float = 8.5
var air_drag: float = 1.15
var is_running: bool = false
var external_velocity: Vector3 = Vector3.ZERO
var external_timer: float = 0.0

var equipment: Dictionary = {
	"weapon": null,
	"armor": null,
	"boots": null,
	"accessory": null
}

var cooldowns: Dictionary = {
	"star_slash": 0.0,
	"fireball": 0.0,
	"frost_ring": 0.0,
	"blink": 0.0,
	"meteor": 0.0,
	"fire_rain": 0.0
}

var anim: AnimationController = null   # 动作状态机/可视模型组件
var buff: BuffComponent = null         # 状态系统组件（无敌等）
var health_bar: HealthBar3D = null     # 头顶血条（掉血才显示）
var last_facing_dir: Vector3 = Vector3(0, 0, -1)
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

# 联机：傀儡（其他玩家）只按网络状态插值，不跑输入/物理；本地玩家正常。
var is_puppet: bool = false
var display_name: String = ""
var net_yaw: float = 0.0
var _name_label: Label3D = null
# 快照插值缓冲：带固定渲染延迟(~110ms)地在历史快照间插值，吸收网络抖动 → 丝滑匀速。
const INTERP_DELAY_MS := 110.0
const BUF_MAX := 24
var _buf: Array = []   # [{t: float(ms), pos: Vector3}]

var skill_lock_timer: float = 0.0
var skill_vertical_controlled: bool = false
var skill_movement_locked: bool = false
var skill_input_locked: bool = false        # 空中攻击：忽略移动输入但保留惯性
var skill_input_lock_timer: float = 0.0
var slash_combo: int = 0          # 星斩连击段数 0→1→2 循环
var slash_combo_timer: float = 0.0   # 连击衔接窗口
var _prev_a: bool = false         # 冰冻时 AD 反复按检测
var _prev_d: bool = false
var flying_cloud: bool = false    # 御云飞行状态
var cloud_node: Node3D = null
var cloud_target_y: float = 0.0
const CLOUD_RISE := 5.0
const CLOUD_MIN_Y := 1.5
const CLOUD_MAX_Y := 28.0
const CLOUD_VRATE := 8.0
const FLIGHT_MP_DRAIN := 6.0       # 御云飞行每秒法力消耗（法力耗尽则强制落地）
const AERIAL_SLASH_MP := 6         # 空中普通攻击（御云速射）每发额外法力消耗
var flight_smoke_timer: float = 0.0   # 飞行烟雾拖尾节流
# 触屏虚拟输入（仅单机；由 Main 的屏幕摇杆/按键设置）。与键盘并存。
var touch_move: Vector2 = Vector2.ZERO   # 摇杆方向：x=右, y=前（已按相机系归一）
var touch_jump: bool = false
var touch_q: bool = false
var touch_e: bool = false
var touch_attack: bool = false
var touch_accel: bool = false   # 触屏加速键（空中也可用）

func _ready() -> void:
	rng.randomize()
	add_to_group("player")
	_build_collision()
	anim = AnimationController.new()
	anim.name = "AnimationController"
	add_child(anim)
	anim.setup(self)
	buff = BuffComponent.new()
	buff.name = "BuffComponent"
	add_child(buff)
	buff.setup(self, main)
	health_bar = HealthBar3D.new()
	add_child(health_bar)
	health_bar.setup_player(1.1, 2.7)   # HP/MP/体力 三条，本人与联机他人都常显带数字
	recalculate_stats()
	face_direction(Vector3(0, 0, -1))
	if is_puppet:
		_buf = [{"t": float(Time.get_ticks_msec()), "pos": global_position}]
		_name_label = Label3D.new()
		_name_label.text = display_name
		_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_name_label.font_size = 40
		_name_label.pixel_size = 0.0085
		_name_label.position = Vector3(0, 3.35, 0)
		_name_label.modulate = Color(0.7, 0.95, 1.0, 1)
		_name_label.no_depth_test = true
		add_child(_name_label)

func _build_collision() -> void:
	var shape: CapsuleShape3D = CapsuleShape3D.new()
	shape.radius = 0.38
	shape.height = 1.25
	var collision: CollisionShape3D = CollisionShape3D.new()
	collision.name = "PlayerCollision"
	collision.shape = shape
	collision.position = Vector3(0, 0.625, 0)
	add_child(collision)

func _physics_process(delta: float) -> void:
	if is_puppet:
		_puppet_process(delta)
		return
	_update_cooldowns(delta)
	_update_timers(delta)
	# 持续回蓝始终生效（即便御云飞行在持续耗蓝，回蓝也照常进行）。
	mp = min(float(max_mp), mp + mp_regen * delta)
	# 体力：未在奔跑时恢复（奔跑消耗在地面移动逻辑里结算）。
	if not is_running:
		stamina = min(float(max_stamina), stamina + stamina_regen * delta)
	if health_bar != null:
		health_bar.set_stats(hp, float(max_hp), mp, float(max_mp), stamina, float(max_stamina))
	if hp <= 0.0:
		if flying_cloud:
			_end_cloud_flight()
		velocity.x = move_toward(velocity.x, 0.0, 14.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 14.0 * delta)
		velocity.y -= gravity * delta
		_apply_external_velocity(delta)
		move_and_slide()
		anim.update_locomotion(delta, Vector3.ZERO, is_running, is_on_floor())
		return

	if skill_lock_timer > 0.0 and skill_movement_locked:
		# 需要硬直的技能才锁移动；天星、火焰雨只锁动作状态，不限制走位。
		velocity.x = 0.0
		velocity.z = 0.0
		if skill_vertical_controlled:
			velocity.y = 0.0
			anim.update_locomotion(delta, Vector3.ZERO, is_running, is_on_floor())
			return
		if not is_on_floor():
			velocity.y -= gravity * delta
		else:
			velocity.y = -0.05
		_apply_external_velocity(delta)
		move_and_slide()
		anim.update_locomotion(delta, Vector3.ZERO, is_running, is_on_floor())
		return

	# 冰冻：禁止移动；反复按 A/D 加速融解冰块。
	if buff != null and buff.is_frozen():
		velocity.x = 0.0
		velocity.z = 0.0
		var a_now: bool = _kp(KEY_A)
		var d_now: bool = _kp(KEY_D)
		if (a_now and not _prev_a) or (d_now and not _prev_d):
			buff.add_melt(0.3)
		_prev_a = a_now
		_prev_d = d_now
		if not is_on_floor():
			velocity.y -= gravity * delta
		else:
			velocity.y = -0.05
		_apply_external_velocity(delta)
		move_and_slide()
		anim.update_locomotion(delta, Vector3.ZERO, is_running, is_on_floor())
		return

	# 眩晕：硬控，禁止移动/技能；保留击飞外力与重力（浮空照常）。
	if buff != null and buff.is_stunned():
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y -= gravity * delta
		else:
			velocity.y = -0.05
		_apply_external_velocity(delta)
		move_and_slide()
		anim.update_locomotion(delta, Vector3.ZERO, is_running, is_on_floor())
		return

	# 御云飞行：WASD 水平移动，Q/E 升降；免重力维持云朵高度。
	if flying_cloud:
		# 空中蓝耗降到地面的 1/5；耗尽则收云落地（回蓝照常进行，见上）。
		mp = max(0.0, mp - FLIGHT_MP_DRAIN * 0.2 * delta)
		if mp <= 0.0:
			_end_cloud_flight()
			if main != null:
				main.flash_message("法力耗尽，御云消散。")
		var fdir: Vector3 = Vector3.ZERO
		var ff: Vector3 = Vector3(-sin(camera_yaw), 0, -cos(camera_yaw))
		var fr: Vector3 = Vector3(cos(camera_yaw), 0, -sin(camera_yaw))
		if _kp(KEY_W):
			fdir += ff
		if _kp(KEY_S):
			fdir -= ff
		if _kp(KEY_D):
			fdir += fr
		if _kp(KEY_A):
			fdir -= fr
		if touch_move.length() > 0.15:
			fdir += fr * touch_move.x + ff * touch_move.y
		if fdir.length() > 0.01:
			fdir = fdir.normalized()
			face_direction(fdir)
			# 空中也可加速（Shift / 触屏加速键）。
			var fspeed: float = move_speed * (run_multiplier if (_kp(KEY_SHIFT) or touch_accel) else 1.0)
			velocity.x = fdir.x * fspeed
			velocity.z = fdir.z * fspeed
		else:
			velocity.x = move_toward(velocity.x, 0.0, ground_decel * delta)
			velocity.z = move_toward(velocity.z, 0.0, ground_decel * delta)
		if _kp(KEY_Q) or touch_q:
			cloud_target_y += CLOUD_VRATE * delta
		if _kp(KEY_E) or touch_e:
			cloud_target_y -= CLOUD_VRATE * delta
		cloud_target_y = clamp(cloud_target_y, CLOUD_MIN_Y, CLOUD_MAX_Y)
		# E 已把高度压到最低、且确实降到接近地面时仍继续按 E → 退出御云飞行（落地）。
		if (_kp(KEY_E) or touch_e) and cloud_target_y <= CLOUD_MIN_Y + 0.01 and global_position.y <= CLOUD_MIN_Y + 0.35:
			_end_cloud_flight()
			if main != null:
				main.flash_message("已落地，退出御云飞行。")
			return
		velocity.y = (cloud_target_y - global_position.y) * 5.0
		_apply_external_velocity(delta)
		move_and_slide()
		if main != null and not _in_dungeon():
			var ar: float = map_radius
			if main.has_method("get_unlocked_radius"):
				ar = float(main.get_unlocked_radius())
			# 处于地形区域内：放宽到整图半径，允许攀爬雪山（否则被夹回未解锁半径）。
			if "terrain_system" in main and main.terrain_system != null and main.terrain_system.in_region(global_position.x, global_position.z):
				ar = map_radius
			global_position.x = clamp(global_position.x, -ar + 2.0, ar - 2.0)
			global_position.z = clamp(global_position.z, -ar + 2.0, ar - 2.0)
		_emit_flight_smoke(delta)
		anim.update_locomotion(delta, fdir, false, false)
		return

	var direction: Vector3 = Vector3.ZERO
	var forward: Vector3 = Vector3(-sin(camera_yaw), 0, -cos(camera_yaw))
	var right: Vector3 = Vector3(cos(camera_yaw), 0, -sin(camera_yaw))
	if _kp(KEY_W):
		direction += forward
	if _kp(KEY_S):
		direction -= forward
	if _kp(KEY_D):
		direction += right
	if _kp(KEY_A):
		direction -= right
	if touch_move.length() > 0.15:
		direction += right * touch_move.x + forward * touch_move.y
	# 空中攻击：忽略移动输入（不主动加速/转向），但不清零速度→保留惯性。
	if skill_input_locked:
		direction = Vector3.ZERO

	var on_ground: bool = is_on_floor()
	var has_move_input: bool = direction.length() > 0.01
	if has_move_input:
		direction = direction.normalized()
		# 火球/升空技能期间，角色朝向由技能瞄准控制，仍允许侧移、背移或奔跑。
		if not (anim.get_pose() in ["fireball_charge", "meteor", "fire_rain"]):
			face_direction(direction)

	# 左 Shift / 触屏加速键；跳起后保留当前水平速度作为惯性。
	if on_ground:
		var want_run: bool = (_kp(KEY_SHIFT) or touch_accel) and has_move_input and not zone_blocked
		# 体力耗尽后需回到 25% 才能再次奔跑（避免在 0 附近抖动）。
		if _stamina_exhausted and stamina >= float(max_stamina) * 0.25:
			_stamina_exhausted = false
		is_running = want_run and not _stamina_exhausted and stamina > 1.0
		if is_running:
			stamina = max(0.0, stamina - stamina_drain * delta)
			if stamina <= 0.0:
				_stamina_exhausted = true
		var slow_mul: float = buff.get_speed_multiplier() if buff != null else 1.0
		var target_speed: float = move_speed * (run_multiplier if is_running else 1.0) * (0.4 if zone_blocked else 1.0) * slow_mul
		if has_move_input:
			var target_velocity: Vector3 = direction * target_speed
			velocity.x = move_toward(velocity.x, target_velocity.x, ground_accel * delta)
			velocity.z = move_toward(velocity.z, target_velocity.z, ground_accel * delta)
		else:
			is_running = false
			velocity.x = move_toward(velocity.x, 0.0, ground_decel * delta)
			velocity.z = move_toward(velocity.z, 0.0, ground_decel * delta)
	else:
		var current_horizontal_speed: float = Vector2(velocity.x, velocity.z).length()
		var air_target_speed: float = clamp(current_horizontal_speed, move_speed, move_speed * run_multiplier)
		if has_move_input:
			var air_target_velocity: Vector3 = direction * air_target_speed
			velocity.x = move_toward(velocity.x, air_target_velocity.x, air_control * delta)
			velocity.z = move_toward(velocity.z, air_target_velocity.z, air_control * delta)
		else:
			velocity.x = move_toward(velocity.x, 0.0, air_drag * delta)
			velocity.z = move_toward(velocity.z, 0.0, air_drag * delta)

	if not on_ground:
		velocity.y -= gravity * delta
	else:
		if _kp(KEY_SPACE) or touch_jump:
			# 跑步起跳时不清空水平速度，因此会带着冲刺惯性飞出去。
			velocity.y = jump_velocity
			start_temporary_pose("jump", 0.28)
		else:
			velocity.y = -0.05

	_apply_external_velocity(delta)
	var _pre_move: Vector3 = global_position
	move_and_slide()
	_step_up_assist(_pre_move, delta)   # 矮台阶（如草地边缘）自动跨越
	if main != null and not _in_dungeon():
		var allowed_radius: float = map_radius
		if main.has_method("get_unlocked_radius"):
			allowed_radius = float(main.get_unlocked_radius())
		var old_position: Vector3 = global_position
		global_position.x = clamp(global_position.x, -allowed_radius + 2.0, allowed_radius - 2.0)
		global_position.z = clamp(global_position.z, -allowed_radius + 2.0, allowed_radius - 2.0)
		if old_position.distance_to(global_position) > 0.01 and main.has_method("flash_locked_boundary"):
			main.flash_locked_boundary()
	# 水中浮力：没入湖面以下会被抬回水面，避免沉到湖底困住（可继续游向岸边走出）。
	if main != null and not _in_dungeon() and main.has_method("water_surface_at"):
		var ws: float = main.water_surface_at(global_position.x, global_position.z)
		if global_position.y < ws - 0.25:
			global_position.y = move_toward(global_position.y, ws - 0.4, delta * 6.0)
			if velocity.y < 0.0:
				velocity.y = 0.0
	anim.update_locomotion(delta, direction, is_running, is_on_floor())

# 收到新快照：入缓冲。远距跳变（闪现/复活/久站恢复）直接传送并清缓冲。
func net_set_target(p: Vector3) -> void:
	var now: float = float(Time.get_ticks_msec())
	if _buf.is_empty():
		_buf = [{"t": now, "pos": p}]
		global_position = p
		return
	var lastpos: Vector3 = _buf[_buf.size() - 1]["pos"]
	if lastpos.distance_to(p) < 0.0001:
		return
	if lastpos.distance_to(p) > 4.0 or (now - float(_buf[_buf.size() - 1]["t"])) > 250.0:
		_buf = [{"t": now, "pos": p}]
		global_position = p
		return
	_buf.append({"t": now, "pos": p})
	while _buf.size() > BUF_MAX:
		_buf.pop_front()

# 取「现在 - 渲染延迟」时刻的插值位置：在两个相邻历史快照间线性插值。
func _interp_pos() -> Vector3:
	var n: int = _buf.size()
	if n == 0:
		return global_position
	if n == 1:
		return _buf[0]["pos"]
	var render_t: float = float(Time.get_ticks_msec()) - INTERP_DELAY_MS
	if render_t <= float(_buf[0]["t"]):
		return _buf[0]["pos"]
	var last: Dictionary = _buf[n - 1]
	if render_t >= float(last["t"]):
		return last["pos"]
	for i in range(n - 1):
		var a: Dictionary = _buf[i]
		var b: Dictionary = _buf[i + 1]
		var ta: float = float(a["t"])
		var tb: float = float(b["t"])
		if render_t >= ta and render_t <= tb:
			var span: float = tb - ta
			var alpha: float = 0.0 if span <= 0.0 else clampf((render_t - ta) / span, 0.0, 1.0)
			return (a["pos"] as Vector3).lerp(b["pos"] as Vector3, alpha)
	return last["pos"]

# 傀儡（其他玩家）：缓冲插值定位，从位移推断动作，更新血条/朝向。
func _puppet_process(delta: float) -> void:
	var prev: Vector3 = global_position
	global_position = _interp_pos()
	var move: Vector3 = global_position - prev
	move.y = 0.0
	var moving: bool = move.length() > 0.003
	if moving:
		face_direction(move)
	else:
		face_direction(Vector3(-sin(net_yaw), 0.0, -cos(net_yaw)))
	if health_bar != null:
		health_bar.set_stats(hp, float(max_hp), mp, float(max_mp), stamina, float(max_stamina))
	if anim != null:
		# 御云飞行时按「空中」播放（on_floor=false）：用滑翔姿态，不走路动作。
		anim.update_locomotion(delta, move.normalized() if (moving and not flying_cloud) else Vector3.ZERO, false, not flying_cloud)
	# 御云飞行的烟雾拖尾特效：傀儡（其他玩家）飞行时同样喷烟。
	if flying_cloud:
		_emit_flight_smoke(delta)

func apply_forced_knockback(from_pos: Vector3, power: float, vertical_power: float = 3.0, duration: float = 0.32) -> void:
	# 韧性减免击飞强度。
	var resist: float = get_control_resist()
	var p: float = power * (1.0 - resist)
	var vp: float = vertical_power * (1.0 - resist)
	var away: Vector3 = global_position - from_pos
	away.y = 0.0
	if away.length() <= 0.05:
		away = -last_facing_dir
	away = away.normalized()
	external_velocity = away * p + Vector3(0, vp, 0)
	external_timer = max(external_timer, duration)
	# 施法中被强力击退 → 打断。
	if skill_lock_timer > 0.0 and p >= 3.0:
		interrupt_skill()

func _apply_external_velocity(delta: float) -> void:
	if external_timer <= 0.0 and external_velocity.length() <= 0.05:
		external_velocity = Vector3.ZERO
		return
	velocity.x += external_velocity.x
	velocity.z += external_velocity.z
	velocity.y += external_velocity.y
	external_timer = max(0.0, external_timer - delta)
	var decay: float = 18.0 * delta
	external_velocity.x = move_toward(external_velocity.x, 0.0, decay)
	external_velocity.z = move_toward(external_velocity.z, 0.0, decay)
	external_velocity.y = move_toward(external_velocity.y, 0.0, decay * 0.65)

# 键盘轮询：聊天输入聚焦时屏蔽移动/跳跃等按键，避免打字带动角色。
# 矮台阶自动跨越：CharacterBody 不会自动登台阶，用「上抬→前移→落下」探测让玩家迈过小坎
# （如草地边缘 12cm、小石块）；跨不上去（真墙/悬空）则还原，不影响正常行走。
const STEP_MAX := 0.45

func _step_up_assist(pre_move: Vector3, delta: float) -> void:
	if not is_on_floor():
		return
	var wish: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	var wl: float = wish.length()
	if wl < 0.5:
		return
	var made: float = Vector2(global_position.x - pre_move.x, global_position.z - pre_move.z).length()
	if made >= wl * delta * 0.6:
		return   # 没被明显挡住，正常行走
	var fwd: Vector3 = wish.normalized() * maxf(0.16, wl * delta)
	var save: Transform3D = global_transform
	move_and_collide(Vector3(0, STEP_MAX, 0))
	move_and_collide(fwd)
	var dc: KinematicCollision3D = move_and_collide(Vector3(0, -STEP_MAX, 0))
	var climbed: float = global_position.y - save.origin.y
	var advanced: float = Vector2(global_position.x - save.origin.x, global_position.z - save.origin.z).length()
	if dc != null and dc.get_normal().y > 0.6 and climbed > 0.02 and advanced > 0.03:
		return   # 成功迈上矮坎
	global_transform = save   # 失败 → 还原

func _in_dungeon() -> bool:
	return main != null and "in_dungeon" in main and main.in_dungeon

func _kp(code: int) -> bool:
	if main != null and (("chat_typing" in main and main.chat_typing) or ("admin_panel_open" in main and main.admin_panel_open)):
		return false
	return Input.is_key_pressed(code)

func _update_timers(delta: float) -> void:
	if skill_lock_timer > 0.0:
		skill_lock_timer = max(0.0, skill_lock_timer - delta)
		if skill_lock_timer <= 0.0:
			skill_vertical_controlled = false
			skill_movement_locked = false
	if skill_input_lock_timer > 0.0:
		skill_input_lock_timer = max(0.0, skill_input_lock_timer - delta)
		if skill_input_lock_timer <= 0.0:
			skill_input_locked = false
	if slash_combo_timer > 0.0:
		slash_combo_timer = max(0.0, slash_combo_timer - delta)
		if slash_combo_timer <= 0.0:
			slash_combo = 0

func _update_cooldowns(delta: float) -> void:
	for key: String in cooldowns.keys():
		cooldowns[key] = max(0.0, float(cooldowns[key]) - delta)

func face_direction(direction: Vector3) -> void:
	var dir: Vector3 = direction
	dir.y = 0.0
	if dir.length() <= 0.01:
		return
	dir = dir.normalized()
	last_facing_dir = dir
	# 朝向交由动作控制器旋转可视模型（模型正面定义在 -Z）。
	if anim != null:
		anim.set_facing(dir)

func get_cast_direction() -> Vector3:
	if main != null and main.has_method("get_mouse_aim_direction"):
		var aim: Vector3 = main.get_mouse_aim_direction(global_position + Vector3(0, 1.2, 0)) as Vector3
		if aim.length() > 0.01:
			return aim.normalized()
	return last_facing_dir.normalized()

func get_finger_tip_global_position() -> Vector3:
	if anim != null:
		return anim.get_finger_tip_global_position()
	return global_position + Vector3(0, 1.25, 0) + last_facing_dir * 0.8

func lock_for_skill(duration: float, vertical_controlled: bool = false, movement_locked: bool = false) -> void:
	skill_lock_timer = max(skill_lock_timer, duration)
	skill_vertical_controlled = skill_vertical_controlled or vertical_controlled
	skill_movement_locked = skill_movement_locked or movement_locked or vertical_controlled

func set_forced_pose(pose_name: String, duration: float = 0.0) -> void:
	if anim != null:
		anim.play_pose(pose_name, duration)

func start_temporary_pose(pose_name: String, duration: float) -> void:
	if anim != null:
		anim.play_pose(pose_name, duration)

func clear_forced_pose(pose_name: String = "") -> void:
	if anim != null:
		anim.clear_pose(pose_name)

# 被冰冻瞬间清掉连击/技能硬直状态：避免连击锁与冰冻硬直叠加，使冰冻分支干净地接管下落，
# 解冻后就停在落地处，不会因为残留的技能锁/连击态出现位置异常。
func on_frozen() -> void:
	skill_lock_timer = 0.0
	skill_movement_locked = false
	skill_input_locked = false
	skill_input_lock_timer = 0.0
	skill_vertical_controlled = false
	slash_combo = 0
	slash_combo_timer = 0.0

# ---------- 御云飞行 ----------
func toggle_cloud_flight() -> void:
	if flying_cloud:
		_end_cloud_flight()
	else:
		_start_cloud_flight()

func _start_cloud_flight() -> void:
	if hp <= 0.0 or skill_lock_timer > 0.0:
		return
	flying_cloud = true
	cloud_target_y = clamp(global_position.y + CLOUD_RISE, CLOUD_MIN_Y, CLOUD_MAX_Y)
	_build_cloud()
	if main != null:
		main.flash_message("御云飞行：WASD 移动，Q 升 / E 降，降到地面再按 E 落地退出，2 技能变炮击。")

func _end_cloud_flight() -> void:
	flying_cloud = false
	if cloud_node != null and is_instance_valid(cloud_node):
		cloud_node.queue_free()
	cloud_node = null

# 联机傀儡：仅同步「是否御云」的视觉（飞行高度已由位置快照带来）。
func set_puppet_flying(on: bool) -> void:
	if on == flying_cloud:
		return
	flying_cloud = on
	if on:
		_build_cloud()
	elif cloud_node != null and is_instance_valid(cloud_node):
		cloud_node.queue_free()
		cloud_node = null

func _build_cloud() -> void:
	cloud_node = Node3D.new()
	cloud_node.name = "FlightCloud"
	add_child(cloud_node)
	cloud_node.position = Vector3(0, -0.1, 0)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.97, 1.0, 0.9)
	mat.roughness = 1.0
	for off: Vector3 in [Vector3(0, 0, 0), Vector3(0.55, -0.05, 0.2), Vector3(-0.55, -0.05, -0.15), Vector3(0.2, 0.02, -0.55), Vector3(-0.25, 0.0, 0.5)]:
		var mesh: SphereMesh = SphereMesh.new()
		mesh.radius = 0.55
		mesh.height = 0.7
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		mi.position = off
		mi.scale = Vector3(1.0, 0.6, 1.0)
		cloud_node.add_child(mi)

# 御云飞行烟雾拖尾：周期性在身后生成一团向上飘散、逐渐变大变淡的烟雾。
func _emit_flight_smoke(delta: float) -> void:
	if main == null or not is_instance_valid(main):
		return
	flight_smoke_timer -= delta
	if flight_smoke_timer > 0.0:
		return
	flight_smoke_timer = 0.055
	var root: Node = main.effect_root if ("effect_root" in main) else null
	if root == null:
		return
	var mesh: SphereMesh = SphereMesh.new()
	mesh.radius = 0.30
	mesh.height = 0.60
	mesh.radial_segments = 8
	mesh.rings = 4
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.86, 0.91, 1.0, 0.48)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.7, 0.85, 1.0, 1)
	mat.emission_energy_multiplier = 0.35
	mi.material_override = mat
	root.add_child(mi)
	var off: Vector3 = Vector3(rng.randf_range(-0.28, 0.28), rng.randf_range(-0.2, 0.05), rng.randf_range(-0.28, 0.28))
	mi.global_position = global_position + Vector3(0, 0.12, 0) - last_facing_dir * 0.45 + off
	var target: Vector3 = mi.global_position + Vector3(0, 0.85, 0) - last_facing_dir * 0.55
	var tw: Tween = mi.create_tween()
	tw.tween_property(mi, "scale", Vector3.ONE * 2.3, 0.7)
	tw.parallel().tween_property(mi, "global_position", target, 0.7)
	tw.parallel().tween_property(mat, "albedo_color:a", 0.0, 0.7)
	tw.tween_callback(mi.queue_free)

func recalculate_stats() -> void:
	var old_max_hp: int = max_hp
	var old_max_mp: int = max_mp
	max_hp = base_max_hp + (level - 1) * 36   # 生命每级成长翻倍
	max_mp = base_max_mp + (level - 1) * 18   # 法力每级成长翻倍
	attack = base_attack + (level - 1) * 3
	magic = base_magic + (level - 1) * 2
	defense = base_defense + (level - 1)
	move_speed = base_speed
	toughness = base_toughness + (level - 1) * 2
	lifesteal = 0.0
	# 装备加成：来自背包系统中每类装备「最强一件」（2048 自动合成的结果）。
	if main != null and is_instance_valid(main) and ("inv" in main) and main.inv != null:
		var b: Dictionary = main.inv.get_bonus()
		attack += int(b.get("attack", 0))
		magic += int(b.get("magic", 0))
		defense += int(b.get("defense", 0))
		max_hp += int(b.get("hp", 0))
		max_mp += int(b.get("mp", 0))
		move_speed += float(b.get("speed", 0.0))
		toughness += int(b.get("toughness", 0))
		lifesteal = clampf(float(b.get("lifesteal", 0.0)), 0.0, 0.25)   # 吸血上限 25%
	move_speed *= gm_speed_mult
	if old_max_hp > 0:
		hp = clamp(hp + float(max_hp - old_max_hp), 1.0, float(max_hp))
	if old_max_mp > 0:
		mp = clamp(mp + float(max_mp - old_max_mp), 0.0, float(max_mp))

func equip_item(item_data: Dictionary) -> void:
	if main != null and main.equipment != null:
		main.equipment.equip(self, item_data)

func cast_skill(skill_id: String) -> bool:
	if main == null or main.skills == null:
		return false
	if zone_blocked:
		main.flash_message("禁制领域：无法施放技能。")
		return false
	if buff != null and buff.is_frozen():
		return false   # 冰冻期间不能攻击/施法
	return main.skills.cast(self, skill_id)

func take_damage(amount: int, _source: Node = null) -> void:
	if hp <= 0.0 or (buff != null and buff.is_invulnerable()):
		return
	# 安全区绝对免伤：处于无破损据点半径内。
	if main != null and main.outpost_system != null and main.outpost_system.is_player_safe(global_position):
		return
	var final_damage: int = max(1, amount - defense)
	# 冰冻期：按冰块已融化比例减伤（刚冻几乎免伤）。
	if buff != null and buff.is_frozen():
		final_damage = int(final_damage * buff.frozen_damage_mult())
	hp = max(0.0, hp - final_damage)
	if main != null:
		if main.has_method("mark_combat"):
			main.mark_combat()
		if final_damage > 0:
			main.flash_damage(global_position + Vector3(0, 2.3, 0), "-%d" % final_damage, Color(1.0, 0.35, 0.35, 1))
			# 打击感：仅红闪（取消被命中的屏幕震动，避免看着花眼）。
			if main.has_method("flash_hurt"):
				var frac: float = float(final_damage) / maxf(1.0, float(max_hp))
				main.flash_hurt(clampf(0.2 + frac * 1.6, 0.2, 0.5))
		else:
			main.flash_damage(global_position + Vector3(0, 2.3, 0), "冰封", Color(0.7, 0.9, 1.0, 1))
	if hp <= 0.0 and main != null:
		main.flash_message("你倒下了。按 R 在星门复活。")

func heal_full() -> void:
	hp = float(max_hp)
	mp = float(max_mp)
	stamina = float(max_stamina)
	_stamina_exhausted = false
	if buff != null:
		buff.apply_invuln(1.0)
	global_position.y = 0.05
	skill_lock_timer = 0.0
	skill_vertical_controlled = false
	skill_movement_locked = false
	_end_cloud_flight()
	clear_forced_pose()

var _cap_warned: bool = false   # 达到等级上限后只提示一次“需击败Boss”

# 经验照常累计；但单机下升级受关卡Boss闸门限制：达到 main.level_cap 后只攒经验不升级，
# 击败关卡大Boss（main 抬高 level_cap）后再调用本流程，溢出的经验即转化为等级。
func gain_exp(amount: int) -> void:
	exp_points += amount
	_apply_level_ups()

func _apply_level_ups() -> void:
	var cap: int = 99999
	if main != null and "level_cap" in main:
		cap = int(main.level_cap)   # 单机/联机都受升级上限约束（上限由通关副本解锁）
	while exp_points >= next_level_exp and level < cap:
		exp_points -= next_level_exp
		level += 1
		next_level_exp = int(next_level_exp * 1.32 + 30)
		base_max_hp += 24   # 翻倍
		base_max_mp += 14   # 翻倍
		base_attack += 2
		base_magic += 2
		base_defense += 1
		base_toughness += 1
		recalculate_stats()
		hp = float(max_hp)
		mp = float(max_mp)
		_cap_warned = false
		Audio.sfx("levelup")
		if main != null:
			main.flash_message("升级！当前 Lv.%d" % level)
	# 升到上限：经验继续累计，提示去通关对应单人副本解锁（仅提示一次）。
	if level >= cap and exp_points >= next_level_exp and not _cap_warned and main != null:
		_cap_warned = true
		main.flash_message("已达升级上限 Lv.%d，需通关对应单人副本才能继续升级（见任务提示）。" % cap)

# 控制抗性（0~0.7）：减少击飞强度与受控时间，随韧性成长。
func get_control_resist() -> float:
	return clamp(float(toughness) / 120.0, 0.0, 0.7)

# 被强力击飞打断施法（增 cast_seq 使在飞技能场景失效 + 解锁/清姿势）。
func interrupt_skill() -> void:
	if skill_lock_timer <= 0.0:
		return
	cast_seq += 1
	skill_lock_timer = 0.0
	skill_vertical_controlled = false
	skill_movement_locked = false
	clear_forced_pose()
	if main != null:
		main.flash_message("施法被击退打断！")

func get_status_text() -> String:
	return "Lv.%d  EXP %d/%d\nHP %d/%d  MP %d/%d  体力 %d/%d\nATK %d  MAG %d  DEF %d  SPD %.1f  韧%d(%.0f%%)%s" % [level, exp_points, next_level_exp, int(hp), max_hp, int(mp), max_mp, int(stamina), max_stamina, attack, magic, defense, move_speed, toughness, get_control_resist() * 100.0, ("  累" if _stamina_exhausted else ("  RUN" if is_running else ""))]

func skill_status_text() -> String:
	var lines: Array[String] = []
	if main == null or main.skills == null:
		return ""
	for id: String in main.skills.ORDER:
		var meta: Dictionary = main.skills.get_skill_meta(id)
		var cd: float = float(cooldowns[id])
		var ready: String = "READY" if cd <= 0.0 else "%.1fs" % cd
		var lvl: int = main.skills.get_skill_level(id)
		var prog: String = main.skills.progress_text(id)
		lines.append("%s %s Lv%d  MP:%d  %s  [%s]" % [String(meta["key"]), String(meta["name"]), lvl, int(meta["mp"]), ready, prog])
	return "\n".join(lines)

# 死亡惩罚：扣 n 级（联机用）。回退按每级成长量扣除基础属性，并据新等级重算升级所需经验。
# 死亡惩罚：不重置等级，仅扣除「当前升级所需经验」的 10%（经验下限 0，不掉级）。
func apply_death_penalty() -> int:
	var loss: int = int(float(next_level_exp) * 0.10)
	exp_points = maxi(0, exp_points - loss)
	return loss

func lose_levels(n: int) -> void:
	var lost: int = mini(n, level - 1)
	exp_points = 0
	if lost <= 0:
		return
	level -= lost
	base_max_hp = maxi(base_max_hp - 24 * lost, 1)
	base_max_mp = maxi(base_max_mp - 14 * lost, 0)
	base_attack = maxi(base_attack - 2 * lost, 1)
	base_magic = maxi(base_magic - 2 * lost, 0)
	base_defense = maxi(base_defense - 1 * lost, 0)
	base_toughness = maxi(base_toughness - 1 * lost, 0)
	next_level_exp = 80
	for i in range(level - 1):
		next_level_exp = int(next_level_exp * 1.32 + 30)
	recalculate_stats()

func equipment_summary() -> String:
	if main != null and is_instance_valid(main) and ("inv" in main) and main.inv != null:
		return main.inv.summary()
	return "暂无装备"
