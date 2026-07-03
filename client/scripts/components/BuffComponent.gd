class_name BuffComponent
extends Node

# 状态系统（Buff/Debuff）组件：挂在 Player / Monster 上，统一管理灼烧(DoT)、减速、无敌。
# 行为与 v0.1 中 Monster 内联的 burn/slow、Player 的 invuln_timer 完全一致，只是集中到一处。

var host: Node = null   # 宿主实体（Player / Monster）
var main: Node = null   # 主场景，用于经 CombatManager 结算 DoT
var _effects: Dictionary = {}   # id(String) -> StatusEffect

# 冰冻状态（生根 + 冰块模型 + 随时间消融 + 减伤）。
var _freeze_remaining: float = 0.0
var _freeze_total: float = 0.0
var _ice_node: MeshInstance3D = null
var _frost_node: MeshInstance3D = null   # 减速时的冰霜覆盖视觉

# 眩晕状态（生根 + 头顶星圈）；落地延迟眩晕用于「击飞落地后眩晕」。
var _stun_remaining: float = 0.0
var _star_node: Node3D = null
var _pending_stun: float = 0.0           # 待落地触发的眩晕时长
var _pending_armed: bool = false         # 已离地，落地即触发

func setup(p_host: Node, p_main: Node) -> void:
	host = p_host
	main = p_main

func _physics_process(delta: float) -> void:
	# 灼烧：保持原 _update_burn 时序——可在剩余时间归零的那一帧仍结算一次，之后停止。
	var burn: StatusEffect = _effects.get("burn")
	if burn != null:
		burn.remaining = max(0.0, burn.remaining - delta)
		burn.tick_timer -= delta
		if burn.tick_timer <= 0.0:
			burn.tick_timer = burn.tick_interval
			if main != null and main.combat != null and is_instance_valid(host):
				main.combat.apply_dot(host, int(burn.magnitude), burn.source)
		if burn.remaining <= 0.0:
			_effects.erase("burn")

	var slow: StatusEffect = _effects.get("slow")
	if slow != null:
		slow.remaining = max(0.0, slow.remaining - delta)
		if slow.remaining <= 0.0:
			_effects.erase("slow")

	var inv: StatusEffect = _effects.get("invuln")
	if inv != null:
		inv.remaining = max(0.0, inv.remaining - delta)
		if inv.remaining <= 0.0:
			_effects.erase("invuln")

	# 冰冻消融：随时间减少，冰块按剩余比例收缩；归零解冻。
	if _freeze_remaining > 0.0:
		_freeze_remaining = max(0.0, _freeze_remaining - delta)
		if _ice_node != null and is_instance_valid(_ice_node) and _freeze_total > 0.0:
			var f: float = clamp(_freeze_remaining / _freeze_total, 0.05, 1.0)
			_ice_node.scale = Vector3(f, f, f)
		if _freeze_remaining <= 0.0:
			_remove_ice()

	# 减速冰霜覆盖：减速中显示，结束移除。
	if _effects.has("slow") and float((_effects["slow"] as StatusEffect).magnitude) > 0.0:
		_ensure_frost()
	else:
		_remove_frost()

	# 眩晕倒计时 + 头顶星圈旋转。
	if _stun_remaining > 0.0:
		_stun_remaining = max(0.0, _stun_remaining - delta)
		if _star_node != null and is_instance_valid(_star_node):
			_star_node.rotate_y(delta * 6.0)
		if _stun_remaining <= 0.0:
			_remove_stars()

	# 落地延迟眩晕：先离地、再落地才触发（避免击飞瞬间在地面就触发）。
	if _pending_stun > 0.0 and host != null and is_instance_valid(host) and host.has_method("is_on_floor"):
		if not host.is_on_floor():
			_pending_armed = true
		elif _pending_armed:
			var d: float = _pending_stun
			_pending_stun = 0.0
			_pending_armed = false
			apply_stun(d)

func apply_burn(damage_per_tick: int, duration: float, source: Node = null) -> void:
	var burn: StatusEffect = _effects.get("burn")
	if burn == null:
		_effects["burn"] = StatusEffect.new(StatusEffect.Kind.BURN, duration, float(damage_per_tick), 0.55, 0.18, source)
	else:
		# 取较大伤害、刷新持续时间（与原 max 叠加逻辑一致）。
		burn.magnitude = max(burn.magnitude, float(damage_per_tick))
		burn.remaining = max(burn.remaining, duration)
		burn.tick_timer = min(burn.tick_timer, 0.18) if burn.tick_timer > 0.0 else 0.18
		burn.source = source

func apply_slow(power: float, duration: float) -> void:
	# 正值=减速，负值=加速（精英自我提速用）。
	var p: float = clamp(power, -0.6, 0.75)
	var dur: float = duration
	# 韧性缩短受控时间（仅对减速；加速不缩短）。
	if p > 0.0:
		dur *= (1.0 - _host_control_resist())
	var slow: StatusEffect = _effects.get("slow")
	if slow == null:
		_effects["slow"] = StatusEffect.new(StatusEffect.Kind.SLOW, dur, p)
	else:
		# 原逻辑：减速比例直接覆盖，持续时间取较大。
		slow.magnitude = p
		slow.remaining = max(slow.remaining, dur)

func _host_control_resist() -> float:
	if host != null and host.has_method("get_control_resist"):
		return float(host.get_control_resist())
	return 0.0

func get_speed_multiplier() -> float:
	var slow: StatusEffect = _effects.get("slow")
	return 1.0 - (slow.magnitude if slow != null else 0.0)

func apply_invuln(duration: float) -> void:
	var inv: StatusEffect = _effects.get("invuln")
	if inv == null:
		_effects["invuln"] = StatusEffect.new(StatusEffect.Kind.INVULN, duration)
	else:
		inv.remaining = max(inv.remaining, duration)

func is_invulnerable() -> bool:
	return _effects.has("invuln")

# ---------- 冰冻 ----------
func apply_freeze(duration: float) -> void:
	# 韧性缩短冰冻时间。
	var dur: float = duration * (1.0 - _host_control_resist())
	if dur <= 0.05:
		return
	var fresh: bool = _freeze_remaining <= 0.0
	_freeze_total = max(_freeze_remaining, dur)
	_freeze_remaining = _freeze_total
	_ensure_ice()
	# 刚被冻住：清掉宿主的连击/技能硬直，让冰冻干净接管（解冻后停在落地处）。
	if fresh and host != null and host.has_method("on_frozen"):
		host.on_frozen()

func is_frozen() -> bool:
	return _freeze_remaining > 0.0

# 冰冻减伤：伤害 ×已融化比例（刚冻≈0，快化完≈满伤）。
func frozen_damage_mult() -> float:
	if _freeze_remaining <= 0.0 or _freeze_total <= 0.0:
		return 1.0
	return clamp(1.0 - _freeze_remaining / _freeze_total, 0.0, 1.0)

# AD 反复按加速融解（仅玩家调用）。
func add_melt(amount: float) -> void:
	if _freeze_remaining > 0.0:
		_freeze_remaining = max(0.0, _freeze_remaining - amount)
		if _freeze_remaining <= 0.0:
			_remove_ice()

# ---------- 眩晕 ----------
func apply_stun(duration: float) -> void:
	# 韧性缩短眩晕时间。
	var dur: float = duration * (1.0 - _host_control_resist())
	if dur <= 0.02:
		return
	var fresh: bool = _stun_remaining <= 0.0
	_stun_remaining = max(_stun_remaining, dur)
	_ensure_stars()
	# 刚被控：清掉宿主连击/技能硬直（与冰冻一致）。
	if fresh and host != null and host.has_method("on_frozen"):
		host.on_frozen()

func is_stunned() -> bool:
	return _stun_remaining > 0.0

# 击飞后登记：落地（先离地再触地）时再施加眩晕。
func queue_stun_on_landing(duration: float) -> void:
	if duration <= 0.0:
		return
	_pending_stun = max(_pending_stun, duration)
	_pending_armed = false

func clear_all() -> void:
	_effects.clear()
	_freeze_remaining = 0.0
	_stun_remaining = 0.0
	_pending_stun = 0.0
	_pending_armed = false
	_remove_ice()
	_remove_frost()
	_remove_stars()

# ---------- 视觉 ----------
func _host_height() -> float:
	var h: float = 2.2
	if host != null and "aim_height" in host:
		h = float(host.aim_height) * 2.0 + 0.6
	return h

func _ensure_ice() -> void:
	if _ice_node != null and is_instance_valid(_ice_node):
		return
	if host == null or not is_instance_valid(host):
		return
	var h: float = _host_height()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.35, h, 1.35)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.6, 0.85, 1.0, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.7, 0.9, 1.0, 1)
	mat.emission_energy_multiplier = 0.5
	_ice_node = MeshInstance3D.new()
	_ice_node.name = "IceBlock"
	_ice_node.mesh = mesh
	_ice_node.material_override = mat
	_ice_node.position = Vector3(0, h * 0.5, 0)
	host.add_child(_ice_node)

func _remove_ice() -> void:
	if _ice_node != null and is_instance_valid(_ice_node):
		_ice_node.queue_free()
	_ice_node = null

func _ensure_frost() -> void:
	if _frost_node != null and is_instance_valid(_frost_node):
		return
	if host == null or not is_instance_valid(host):
		return
	var h: float = _host_height()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.15, h * 0.95, 1.15)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.65, 0.9, 1.0, 0.18)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.7, 0.95, 1.0, 1)
	mat.emission_energy_multiplier = 0.3
	_frost_node = MeshInstance3D.new()
	_frost_node.name = "FrostCoat"
	_frost_node.mesh = mesh
	_frost_node.material_override = mat
	_frost_node.position = Vector3(0, h * 0.5, 0)
	host.add_child(_frost_node)

func _remove_frost() -> void:
	if _frost_node != null and is_instance_valid(_frost_node):
		_frost_node.queue_free()
	_frost_node = null

# 眩晕视觉：头顶旋转的小星圈（几颗发光小球绕圈）。
func _ensure_stars() -> void:
	if _star_node != null and is_instance_valid(_star_node):
		return
	if host == null or not is_instance_valid(host):
		return
	var h: float = _host_height()
	_star_node = Node3D.new()
	_star_node.name = "StunStars"
	_star_node.position = Vector3(0, h + 0.25, 0)
	host.add_child(_star_node)
	for i: int in range(4):
		var a: float = TAU * float(i) / 4.0
		var sm := SphereMesh.new()
		sm.radius = 0.12
		sm.height = 0.24
		var star := MeshInstance3D.new()
		star.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.9, 0.25, 1)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.85, 0.2, 1)
		mat.emission_energy_multiplier = 1.6
		star.material_override = mat
		star.position = Vector3(cos(a) * 0.5, 0, sin(a) * 0.5)
		_star_node.add_child(star)

func _remove_stars() -> void:
	if _star_node != null and is_instance_valid(_star_node):
		_star_node.queue_free()
	_star_node = null
