extends RefCounted

# 轻量权威怪物：只有数值与极简 AI，无可视/物理节点。服务器跑这套逻辑作为唯一权威，
# 客户端用 client 工程里的 StarGloryMonster 做“傀儡”渲染（位置/血量由服务器快照驱动）。

var id: int = 0
var kind: String = "slime"
var name: String = "Monster"
var pos: Vector3 = Vector3.ZERO
var max_hp: int = 60
var hp: float = 60.0
var attack: int = 8
var defense: int = 0
var speed: float = 3.5
var detect: float = 16.0
var atk_range: float = 1.6
var interval: float = 1.2
var exp_reward: int = 20
var rank: int = 1
var elite: bool = false
var is_boss: bool = false
var ranged: bool = false     # 远程怪（发射弹幕），不受近战高度差限制
var flying: bool = false
var hover: float = 2.2
var color: Array = [0.85, 0.2, 0.45, 1]
var world_level: int = 1     # 强度档位（区域固定，放大血量/攻击/危险外观）
var level: int = 1           # 区域固定怪物等级（显示用）
var resident: bool = false   # 常驻 Boss：等级恒定、击杀后定时重生、掉吸血装备

var dead: bool = false
var attack_timer: float = 0.0
var spawner_index: int = -1
var last_attacker: int = 0
var home_pos: Vector3 = Vector3.ZERO   # 出生点（GM 重置怪物用）
var inst: int = 0                      # 所属实例（0=大世界，>0=某副本）；只对同实例玩家可见/可锁
# 飞天弹幕精英：循环三套弹幕
var is_barrage: bool = false
var barrage_sub: int = 0
var barrage_cd: float = 2.0
const BARRAGE_CD := 4.5
# Boss 弹幕术式
var danmaku_list: Array = []
var danmaku_idx: int = 0
var danmaku_cd: float = 3.0
const DANMAKU_CD := 7.5

# ---- Boss 连招「天崩冲锋」（服务器权威：驱动 pos + 产出 aoe/combo_start 事件，与客户端常量一致）----
const COMBO_LEAP_T := 0.7
const COMBO_HOVER_T := 0.45
const COMBO_SLAM_T := 0.45
const COMBO_LEAP_H := 7.0
const COMBO_PHANTOM_R := 9.5
const COMBO_CHARGES := 17
const COMBO_CHARGE_T := 0.22
const COMBO_CHARGE_GAP := 0.06
const COMBO_SLAM_R := 6.5
const COMBO_CHARGE_R := 2.6
const COMBO_GROUND_Y := 0.05
const COMBO_CD := 18.0
var combo_cd: float = 8.0           # 出生后首次连招的预热
var combo_active: bool = false
var combo_phase: int = 0
var combo_timer: float = 0.0
var combo_start_pos: Vector3 = Vector3.ZERO
var combo_apex: Vector3 = Vector3.ZERO
var combo_center: Vector3 = Vector3.ZERO
var combo_seed: int = 0
var combo_phantoms: Array = []
var combo_charge_idx: int = 0
var combo_from: Vector3 = Vector3.ZERO
var combo_to: Vector3 = Vector3.ZERO
var combo_charge_hit_done: bool = false
var combo_target_id: int = 0

# 究极大招按位置分配（0=天崩冲锋 1=雷霆引导 2=召唤军团 3=巨兵天罚）+ 状态。
const ULTIMATE_COUNT := 4
const LIGHT_T := 3.5
const LIGHT_R := 11.0
const SUMMON_BOSS_WL := 6
const JUDG_CHARGE_T := 1.3
const JUDG_SLAM_T := 0.6
const JUDG_BEAM_T := 2.5
const JUDG_BEAM_TICK := 0.3
const JUDG_BEAM_LEN := 18.0
const JUDG_BEAM_W := 5.0
var ultimate_id: int = 0
var has_ultimate: bool = false     # 精英弱化版究极
var ult_power: float = 1.0
var lightning_active: bool = false
var lightning_timer: float = 0.0
var lightning_started: bool = false
# 召唤物 / 奶妈
var is_summoned: bool = false
var summon_ttl: float = 0.0
var is_healer: bool = false
var speed_buff_mult: float = 1.0   # 奶妈加速光环（>1），随时间衰减
var speed_buff_timer: float = 0.0
var heal_timer: float = 0.0        # 奶妈治疗节流（由 ServerMain 驱动）
# 巨兵天罚
var judg_active: bool = false
var judg_phase: int = 0
var judg_timer: float = 0.0
var judg_started: bool = false
var judg_dir: Vector3 = Vector3(0, 0, 1)
var judg_beam_acc: float = 0.0

func setup(data: Dictionary, mid: int, p_pos: Vector3, make_elite: bool, p_spawner: int) -> void:
	id = mid
	spawner_index = p_spawner
	kind = String(data.get("kind", kind))
	name = String(data.get("name", name))
	is_boss = bool(data.get("boss", false))
	max_hp = int(data.get("hp", max_hp))
	attack = int(data.get("attack", attack))
	defense = int(data.get("defense", defense))
	speed = float(data.get("speed", speed))
	detect = float(data.get("detect", detect))
	atk_range = float(data.get("range", atk_range))
	interval = float(data.get("interval", interval))
	exp_reward = int(data.get("exp", exp_reward))
	rank = int(data.get("rank", 1))
	ranged = bool(data.get("ranged", false))
	flying = bool(data.get("flying", false))
	hover = float(data.get("hover", hover))
	is_healer = bool(data.get("healer", false))
	is_barrage = bool(data.get("barrage", false))
	danmaku_list = (data.get("danmaku", []) as Array).duplicate()
	color = data.get("color", color)
	elite = make_elite
	if elite:
		max_hp = int(max_hp * 1.9)
		attack = int(attack * 1.45)
		defense += 2
		exp_reward = int(exp_reward * 2.2)
		name = "精英·" + name
		rank += 2
	if is_boss:
		# Boss = 同级精英的 2 倍攻击、20 倍血量（与客户端 Monster.gd 一致）。
		max_hp = int(90.0 * 1.9 * 20.0)
		attack = int(14.0 * 1.45 * 2.0)
		defense += 5
	# 世界等级缩放（与客户端 Monster.gd 公式一致）：每提升一级世界等级，怪物 +3 级。
	# 整体增幅（移速除外）：伤害 +25%、出手更快，并随等级继续提升。
	resident = bool(data.get("resident", false))
	world_level = int(data.get("world_level", 1))
	level = int(data.get("level", 1))
	var lvl_bonus: int = (world_level - 1) * 3
	attack = int(attack * 1.25)
	interval = maxf(0.4, interval * 0.9)
	if lvl_bonus > 0:
		max_hp = int(max_hp * (1.0 + 0.12 * float(lvl_bonus)))
		attack = int(attack * (1.0 + 0.13 * float(lvl_bonus)))
		defense += int(lvl_bonus / 2)
		interval = maxf(0.32, interval * pow(0.955, float(lvl_bonus)))
		exp_reward = int(exp_reward * (1.0 + 0.09 * float(lvl_bonus)))
		rank += world_level - 1
	hp = float(max_hp)
	pos = p_pos
	home_pos = p_pos
	if flying:
		pos.y = hover
	if is_boss:
		ultimate_id = int(data.get("ultimate", 0))
	if bool(data.get("weak_ult", false)):
		has_ultimate = true
		ult_power = 0.5
		ultimate_id = int(data.get("ultimate", 0))

# AI 步进。players: { peer_id -> {"pos": Vector3, "hp": float} }。
# 返回本帧产生的攻击事件数组（命中玩家），由 ServerNetwork 下发。
func tick(delta: float, players: Dictionary, unlocked_radius: float) -> Array:
	var events: Array = []
	if dead:
		return events
	# 奶妈加速光环衰减。
	if speed_buff_timer > 0.0:
		speed_buff_timer = max(0.0, speed_buff_timer - delta)
		if speed_buff_timer <= 0.0:
			speed_buff_mult = 1.0
	# 奶妈：不打玩家；移动与治疗由 ServerMain._update_healer 驱动。
	if is_healer:
		return events
	# Boss / 带究极的精英：进行中则接管移动并产出事件；冷却好且有近处玩家则起手。
	if is_boss or has_ultimate:
		combo_cd = max(0.0, combo_cd - delta)
		if combo_active:
			return _combo_tick(delta, players)
		if lightning_active:
			return _lightning_tick(delta, players)
		if judg_active:
			return _judgment_tick(delta, players)
		if combo_cd <= 0.0:
			var np: Dictionary = _nearest_player(players)
			if int(np["id"]) != 0 and float(np["dist"]) <= detect * 1.5:
				var ult: int = ultimate_id
				if is_summoned and ult >= 2:   # 防级联：被召唤的 Boss 不开重型大招
					ult = 0
				match ult:
					1:
						_start_lightning()
					2:
						combo_cd = COMBO_CD
						events.append(_summon_event(np))
					3:
						_start_judgment(np)
					_:
						_start_combo(np)
				return events
	attack_timer = max(0.0, attack_timer - delta)
	# 选最近的存活玩家
	var target_id: int = 0
	var best: float = detect
	var target_pos: Vector3 = Vector3.ZERO
	for pid: int in players.keys():
		var pinfo: Dictionary = players[pid]
		if float(pinfo.get("hp", 0.0)) <= 0.0:
			continue
		if int(pinfo.get("instance_id", 0)) != inst:
			continue   # 只锁定同实例玩家（大世界怪锁大世界玩家、副本怪锁副本玩家）
		var ppos: Vector3 = pinfo.get("pos", Vector3.ZERO)
		var d: float = Vector2(ppos.x - pos.x, ppos.z - pos.z).length()
		if d < best:
			best = d
			target_id = pid
			target_pos = ppos
	if target_id == 0:
		return events  # 无目标：原地待命（模板阶段不做巡逻）
	# 飞天弹幕精英：周期循环三套弹幕（origin/target/seed 同步，客户端本地渲染并对各自玩家结算）。
	if is_barrage:
		barrage_cd = max(0.0, barrage_cd - delta)
		if barrage_cd <= 0.0:
			barrage_cd = BARRAGE_CD
			barrage_sub = (barrage_sub % 3) + 1
			events.append({"type": "barrage", "sub": barrage_sub, "origin": pos + Vector3(0, 0.6, 0), "target": target_pos, "seed": randi(), "atk": attack})
	# Boss 弹幕术式：循环施放
	if not danmaku_list.is_empty():
		danmaku_cd = max(0.0, danmaku_cd - delta)
		if danmaku_cd <= 0.0:
			danmaku_cd = DANMAKU_CD
			var pat: String = String(danmaku_list[danmaku_idx % danmaku_list.size()])
			danmaku_idx += 1
			events.append({"type": "danmaku", "pat": pat, "origin": pos + Vector3(0, 1.4, 0), "target": target_pos, "seed": randi(), "atk": attack})
	var flat: Vector2 = Vector2(target_pos.x - pos.x, target_pos.z - pos.z)
	var dist: float = flat.length()
	if dist > atk_range:
		var step: Vector2 = flat.normalized() * speed * speed_buff_mult * delta
		pos.x += step.x
		pos.z += step.y
		# 限制在已解锁半径内
		var r: float = Vector2(pos.x, pos.z).length()
		if r > unlocked_radius:
			var clamped: Vector2 = Vector2(pos.x, pos.z).normalized() * unlocked_radius
			pos.x = clamped.x
			pos.z = clamped.y
	elif attack_timer <= 0.0:
		# 攻击距离计入高差：玩家与怪物垂直差超过 vreach 则够不着（御云/升空可躲，含远程）。
		var vgap: float = absf(target_pos.y - pos.y)
		var vreach: float = 6.0 if ranged else (3.2 if is_boss else 2.4)
		if vgap <= vreach:
			attack_timer = interval
			events.append({"type": "hit_player", "target": target_id, "amount": attack})
	if flying:
		pos.y = hover
	return events

# 受到伤害（来自客户端上报，服务器为权威）。返回是否致死。
func take_damage(amount: int, attacker_id: int) -> bool:
	if dead:
		return false
	last_attacker = attacker_id
	hp -= max(1.0, float(amount - defense * 0.5))
	if hp <= 0.0:
		hp = 0.0
		dead = true
		return true
	return false

# 用于全量定义下发（客户端据此创建傀儡可视）。
func to_def() -> Dictionary:
	return {
		"id": id, "kind": kind, "name": name, "max_hp": max_hp,
		"rank": rank, "elite": elite, "boss": is_boss,
		"flying": flying, "hover": hover, "color": color, "pos": pos,
		"world_level": world_level, "level": level, "resident": resident,
	}

# 用于高频快照（位置/血量/状态）。
func to_snapshot() -> Dictionary:
	return {"id": id, "pos": pos, "hp": hp}

# ================= Boss 连招（服务器权威） =================

func _nearest_player(players: Dictionary) -> Dictionary:
	var best: float = 1e9
	var id_out: int = 0
	var p_out: Vector3 = Vector3.ZERO
	for pid: int in players.keys():
		var pi: Dictionary = players[pid]
		if not pi.get("authed", false) or float(pi.get("hp", 0.0)) <= 0.0:
			continue
		if int(pi.get("instance_id", 0)) != inst:
			continue
		var pp: Vector3 = pi.get("pos", Vector3.ZERO)
		var d: float = Vector2(pp.x - pos.x, pp.z - pos.z).length()
		if d < best:
			best = d
			id_out = pid
			p_out = pp
	return {"id": id_out, "pos": p_out, "dist": best}

func _target_pos(players: Dictionary) -> Vector3:
	if players.has(combo_target_id):
		var pi: Dictionary = players[combo_target_id]
		if pi.get("authed", false) and float(pi.get("hp", 0.0)) > 0.0:
			return pi.get("pos", combo_center)
	var np: Dictionary = _nearest_player(players)
	if int(np["id"]) != 0:
		combo_target_id = int(np["id"])
		return np["pos"]
	return combo_center

func _start_combo(np: Dictionary) -> void:
	combo_active = true
	combo_phase = 1
	combo_timer = 0.0
	combo_charge_idx = 0
	combo_phantoms = []
	combo_start_pos = pos
	combo_target_id = int(np["id"])
	var pp: Vector3 = np["pos"]
	combo_apex = Vector3(lerpf(pos.x, pp.x, 0.5), COMBO_LEAP_H, lerpf(pos.z, pp.z, 0.5))

func _combo_tick(delta: float, players: Dictionary) -> Array:
	var events: Array = []
	combo_timer += delta
	var tp: Vector3 = _target_pos(players)
	match combo_phase:
		1:  # 跃起
			var t: float = clampf(combo_timer / COMBO_LEAP_T, 0.0, 1.0)
			pos.x = lerpf(combo_start_pos.x, combo_apex.x, t)
			pos.z = lerpf(combo_start_pos.z, combo_apex.z, t)
			pos.y = lerpf(combo_start_pos.y, COMBO_LEAP_H, sin(t * PI * 0.5))
			if combo_timer >= COMBO_LEAP_T:
				combo_phase = 2
				combo_timer = 0.0
		2:  # 停留 → 锁定砸点并下发表现事件
			pos = combo_apex
			if combo_timer >= COMBO_HOVER_T:
				combo_center = Vector3(tp.x, COMBO_GROUND_Y, tp.z)
				combo_seed = randi()
				events.append({"type": "combo_start", "center": combo_center, "seed": combo_seed})
				combo_phase = 3
				combo_timer = 0.0
		3:  # 砸下 → AOE 友伤
			var t3: float = clampf(combo_timer / COMBO_SLAM_T, 0.0, 1.0)
			pos.x = lerpf(combo_apex.x, combo_center.x, t3 * t3)
			pos.z = lerpf(combo_apex.z, combo_center.z, t3 * t3)
			pos.y = lerpf(combo_apex.y, COMBO_GROUND_Y, t3 * t3)
			if combo_timer >= COMBO_SLAM_T:
				events.append({"type": "aoe", "center": combo_center, "radius": COMBO_SLAM_R, "amount": int(float(attack + 22) * ult_power)})
				_build_phantoms()
				combo_charge_idx = 0
				_begin_charge(tp)
				combo_phase = 4
				combo_timer = 0.0
		4:  # 连续冲锋
			var t4: float = clampf(combo_timer / COMBO_CHARGE_T, 0.0, 1.0)
			pos = combo_from.lerp(combo_to, t4)
			if t4 >= 0.5 and not combo_charge_hit_done:
				combo_charge_hit_done = true
				# 冲锋命中：玩家浮空+眩晕、其他怪友伤，并 0.5s 后落缩小天星（由 ServerMain 结算）。
				events.append({"type": "charge_hit", "center": pos, "radius": COMBO_CHARGE_R, "amount": int((float(attack) * 0.6 + 2.0) * ult_power)})
			if combo_timer >= COMBO_CHARGE_T + COMBO_CHARGE_GAP:
				combo_charge_idx += 1
				if combo_charge_idx >= COMBO_CHARGES:
					combo_active = false
					combo_phase = 0
					combo_cd = COMBO_CD
					pos.y = COMBO_GROUND_Y
				else:
					_begin_charge(tp)
					combo_timer = 0.0
	return events

func _build_phantoms() -> void:
	combo_phantoms = []
	var base_ang: float = float(combo_seed % 360) * (PI / 180.0)
	for i: int in range(4):
		var a: float = base_ang + TAU * float(i) / 4.0
		combo_phantoms.append(combo_center + Vector3(cos(a), 0, sin(a)) * COMBO_PHANTOM_R)
	# 第 5 道残影 = 天上坠落点（砸点正上方）。
	combo_phantoms.append(combo_center + Vector3(0, COMBO_LEAP_H, 0))

func _begin_charge(tp: Vector3) -> void:
	combo_charge_hit_done = false
	combo_timer = 0.0
	if combo_phantoms.is_empty():
		combo_active = false
		combo_phase = 0
		combo_cd = COMBO_CD
		return
	var from_i: int = randi() % combo_phantoms.size()
	combo_from = combo_phantoms[from_i]   # 保留虚影自身高度（空中残影 y=LEAP_H）
	var want: Vector3 = Vector3(tp.x - combo_from.x, 0, tp.z - combo_from.z)
	want = want.normalized() if want.length() > 0.05 else Vector3(0, 0, 1)
	var best_i: int = from_i
	var best_dot: float = -2.0
	for i: int in range(combo_phantoms.size()):
		if i == from_i:
			continue
		var d: Vector3 = combo_phantoms[i] - combo_from
		d.y = 0
		if d.length() < 0.05:
			continue
		var dot: float = d.normalized().dot(want)
		if dot > best_dot:
			best_dot = dot
			best_i = i
	combo_to = combo_phantoms[best_i]
	pos = combo_from

# ================= 究极大招：雷霆引导（服务器权威） =================

func _ultimate_for_pos(p: Vector3) -> int:
	return 1 if ((p.x >= 0.0) == (p.z >= 0.0)) else 0

func _start_lightning() -> void:
	lightning_active = true
	lightning_timer = 0.0
	lightning_started = false

# 召唤军团事件（一次性）：身后方向 + 缩放参数，交给 ServerMain 实际刷怪。
func _summon_event(np: Dictionary) -> Dictionary:
	var back := Vector3(0, 0, 1)
	if int(np.get("id", 0)) != 0:
		var pp: Vector3 = np["pos"]
		var to_p := Vector3(pp.x - pos.x, 0, pp.z - pos.z)
		if to_p.length() > 0.1:
			back = -to_p.normalized()
	return {
		"type": "summon",
		"behind": pos + back * 4.0,
		"back": back,
		"wl": world_level + 1,
		"count": maxi(1, int(clampi(3 + int(world_level / 3), 3, 6) * ult_power)),
		"speed_mul": minf(1.5, 1.0 + 0.04 * float(world_level - 1)),
		"boss_chance": (0.15 if world_level >= SUMMON_BOSS_WL else 0.0),
		"center": pos,
		"seed": randi(),
	}

# ================= 究极大招：巨兵天罚（服务器权威） =================

func _start_judgment(np: Dictionary) -> void:
	judg_active = true
	judg_phase = 1
	judg_timer = 0.0
	judg_started = false
	judg_beam_acc = 0.0
	judg_dir = Vector3(0, 0, 1)
	if int(np.get("id", 0)) != 0:
		var pp: Vector3 = np["pos"]
		var to_p := Vector3(pp.x - pos.x, 0, pp.z - pos.z)
		if to_p.length() > 0.1:
			judg_dir = to_p.normalized()

func _judgment_tick(delta: float, _players: Dictionary) -> Array:
	var events: Array = []
	if not judg_started:
		judg_started = true
		events.append({"type": "giant_start", "origin": pos, "dir": judg_dir, "len": JUDG_BEAM_LEN, "width": JUDG_BEAM_W, "charge_t": JUDG_CHARGE_T, "slam_t": JUDG_SLAM_T, "beam_t": JUDG_BEAM_T, "seed": randi()})
	judg_timer += delta
	match judg_phase:
		1:
			if judg_timer >= JUDG_CHARGE_T:
				judg_phase = 2
				judg_timer = 0.0
		2:
			if judg_timer >= JUDG_SLAM_T:
				events.append({"type": "giant_slam", "origin": pos, "dir": judg_dir, "len": JUDG_BEAM_LEN, "width": JUDG_BEAM_W, "amount": int(float(attack + 20) * ult_power)})
				judg_phase = 3
				judg_timer = 0.0
				judg_beam_acc = 0.0
		3:
			judg_beam_acc -= delta
			if judg_beam_acc <= 0.0:
				judg_beam_acc = JUDG_BEAM_TICK
				events.append({"type": "giant_beam", "origin": pos, "dir": judg_dir, "len": JUDG_BEAM_LEN, "width": JUDG_BEAM_W, "amount": int(float(attack) * 0.7 * ult_power)})
			if judg_timer >= JUDG_BEAM_T:
				judg_active = false
				judg_phase = 0
				combo_cd = COMBO_CD
	return events

func _lightning_tick(delta: float, _players: Dictionary) -> Array:
	var events: Array = []
	if not lightning_started:
		lightning_started = true
		events.append({"type": "lightning_start", "center": pos, "radius": LIGHT_R, "duration": LIGHT_T, "seed": randi()})
	lightning_timer += delta
	if lightning_timer >= LIGHT_T:
		var dmg: int = int((attack + 10 + float(attack) * 0.9) * ult_power)
		events.append({"type": "lightning_strike", "center": pos, "radius": LIGHT_R, "amount": dmg, "slow": 0.4, "slow_dur": 3.0})
		lightning_active = false
		combo_cd = COMBO_CD
	return events
