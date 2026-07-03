extends Node

# NetworkClient —— 客户端网络层（autoload "Net"）。负责连接服务器、登录、收发快照，并把
# 最新世界状态缓存成普通数据，供 Main 每帧对账（创建/更新 远端玩家与怪物傀儡）。
#
# 重要：这里的 @rpc 方法集合必须与服务器 server/net/ServerNetwork.gd 完全一致（同名、同标注、
# 同数量）。req_* = 本端调用、服务器执行（本端空实现）；rpc_* = 服务器调用、本端执行。

signal login_result(ok: bool, reason: String)
signal logout_permission(allowed: bool, reason: String)
signal connection_lost()                # 心跳超时/断线，Main 据此返回菜单

var online: bool = false
var my_id: int = 0
var login_save: Dictionary = {}

# 心跳：定时 ping，长时间无 pong 即判定掉线。
const HEARTBEAT_INTERVAL := 3.0
const HEARTBEAT_TIMEOUT_MS := 20000.0
var _ping_accum: float = 0.0
var _last_pong_ms: float = 0.0

var local_player: Node = null          # Main 注入；用于上报本地玩家状态
var _pending_user: String = ""
var _pending_pass: String = ""
var _pending_mode: String = "login"    # login / register
var _pending_nickname: String = ""
var _pending_avatar: String = ""       # base64 PNG（空=默认随机色）
var roster_avatar: Dictionary = {}     # id -> avatar(base64 或 "")

# 缓存的世界状态（Main 每帧读取并对账）
var roster: Dictionary = {}            # id -> name
var players_state: Dictionary = {}     # id -> {pos,yaw,hp,max_hp,mp,max_mp,st,max_st,level,anim,flying}（仅 AOI 范围内）
var monster_defs: Dictionary = {}      # id -> 定义（创建傀儡用，仅 AOI 范围内）
var monsters_state: Dictionary = {}    # id -> {pos,hp}
var player_despawn_queue: Array = []   # 离开 AOI 的玩家 id：Main 据此移除傀儡
var monster_despawn_queue: Array = []  # 离开 AOI 的怪物 id：Main 据此移除傀儡
var monster_combo_queue: Array = []    # Boss 连招表现事件：[{mid, info}]，Main 派发给傀儡
var player_control_queue: Array = []   # 服务器对本地玩家的控制：[{from,launch,vertical,stun,on_landing}]
var chat_queue: Array = []             # 聊天消息：[{channel, from, text}]
var party_id: int = 0                  # 当前队伍 id（0=无队）
var party_members: Array = []          # 当前队伍成员 [{id,name}]
var party_dirty: bool = false          # 队伍更新，Main 据此刷新
var admin_level: int = 0               # 本账号管理员等级（0=非管理员）
var admin_dirty: bool = false          # 管理员等级更新，Main 据此刷新
var admin_console_queue: Array = []    # 操作台占用结果：[{state, who}]（grant/deny/kicked）
var dungeon_queue: Array = []          # 副本事件：[{state, info}]（enter/leave）
var outpost_queue: Array = []          # 据点/城墙状态同步
var world_nodes_data: Array = []       # 全服共享材料节点列表
var world_nodes_dirty: bool = true     # 节点列表有更新，Main 重建渲染
var gather_result_queue: Array = []    # 采集回执:[{mat, amount}]
var leaderboard_data: Dictionary = {}  # 全服建造贡献榜:{total, top:[{name,points}], ends_in}
var leaderboard_dirty: bool = false
var rewards_queue: Array = []          # 待发奖励:[[{mat,amount}...], ...]
var death_queue: Array = []            # 待 Main 处理的死亡事件
var cast_queue: Array = []             # 其他玩家的施法事件（Main 据此播放动作/特效）
var damage_queue: Array = []           # 他人对怪物造成的伤害飘字
var action_queue: Array = []           # 怪物动作（攻击）事件
var drop_taken_queue: Array = []       # 掉落物被拾取/过期事件
var pending_player_damage: int = 0     # 怪物对本地玩家造成、待结算的伤害
var world_stage: int = 0
var world_radius: float = 58.0
var region_locks: Array = []           # 当前锁定（更新中）的区域 id 列表
var region_locks_dirty: bool = true    # 锁定列表有更新，Main 需重建屏障/状态
var force_pos: Variant = null          # 服务器强制传送（区域弹出），Main 消费后置空

var _send_accum: float = 0.0
var _send_interval: float = 0.05
var admin_players: Array = []
var admin_players_dirty: bool = false
const EQUIP_TYPES: Array[String] = ["weapon", "offhand", "helmet", "chest", "legs", "boots", "shoulder", "gloves", "belt", "necklace", "ring"]

func _touch_server() -> void:
	_last_pong_ms = float(Time.get_ticks_msec())

# ---------------- 连接 / 登录 ----------------

func connect_and_login(host: String, port: int, user: String, password: String) -> void:
	_pending_mode = "login"
	_start_connection(host, port, user, password)

func connect_and_register(host: String, port: int, user: String, password: String, nickname: String, avatar: String) -> void:
	_pending_mode = "register"
	_pending_nickname = nickname
	_pending_avatar = avatar
	_start_connection(host, port, user, password)

func _start_connection(host: String, port: int, user: String, password: String) -> void:
	online = true
	_pending_user = user
	_pending_pass = password
	_send_interval = 1.0 / maxf(1.0, float(GameData.proto("player_state_hz", 20)))
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, port)
	if err != OK:
		online = false
		login_result.emit(false, "无法创建连接（错误码 %d）" % err)
		return
	multiplayer.multiplayer_peer = peer
	if not multiplayer.connected_to_server.is_connected(_on_connected):
		multiplayer.connected_to_server.connect(_on_connected)
		multiplayer.connection_failed.connect(_on_connection_failed)
		multiplayer.server_disconnected.connect(_on_server_disconnected)

func _on_connected() -> void:
	_last_pong_ms = float(Time.get_ticks_msec())
	_ping_accum = 0.0
	var ver: int = int(GameData.proto("protocol_version", 1))
	if _pending_mode == "register":
		rpc_id(1, "req_register", _pending_user, _pending_pass, _pending_nickname, _pending_avatar, ver)
	else:
		rpc_id(1, "req_login", _pending_user, _pending_pass, ver)

func send_set_profile(nickname: String, avatar: String) -> void:
	if online and my_id != 0:
		rpc_id(1, "req_set_profile", nickname, avatar)

func _on_connection_failed() -> void:
	online = false
	login_result.emit(false, "连接服务器失败（地址/端口/防火墙？）")

func _on_server_disconnected() -> void:
	online = false
	login_result.emit(false, "与服务器断开连接")

func disconnect_from_server() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	online = false
	_reset_state()

func _reset_state() -> void:
	roster.clear()
	roster_avatar.clear()
	players_state.clear()
	monster_defs.clear()
	monsters_state.clear()
	death_queue.clear()
	cast_queue.clear()
	damage_queue.clear()
	action_queue.clear()
	drop_taken_queue.clear()
	player_despawn_queue.clear()
	monster_despawn_queue.clear()
	monster_combo_queue.clear()
	player_control_queue.clear()
	chat_queue.clear()
	party_id = 0
	party_members.clear()
	party_dirty = true
	admin_level = 0
	admin_dirty = true
	admin_console_queue.clear()
	admin_players.clear()
	admin_players_dirty = true
	dungeon_queue.clear()
	outpost_queue.clear()
	world_nodes_data.clear()
	world_nodes_dirty = true
	gather_result_queue.clear()
	leaderboard_data = {}
	leaderboard_dirty = false
	rewards_queue.clear()
	region_locks.clear()
	region_locks_dirty = true
	force_pos = null
	pending_player_damage = 0

# ---------------- 上报本地玩家状态 ----------------

func _physics_process(delta: float) -> void:
	# 心跳：定时 ping；超时无 pong → 判定掉线。
	if online:
		_ping_accum += delta
		if _ping_accum >= HEARTBEAT_INTERVAL:
			_ping_accum = 0.0
			rpc_id(1, "req_ping", Time.get_ticks_msec())
		if float(Time.get_ticks_msec()) - _last_pong_ms > HEARTBEAT_TIMEOUT_MS:
			online = false
			disconnect_from_server()
			connection_lost.emit()
			return
	if not online or my_id == 0 or local_player == null or not is_instance_valid(local_player):
		return
	_send_accum += delta
	if _send_accum < _send_interval:
		return
	_send_accum = 0.0
	var facing: Vector3 = local_player.last_facing_dir
	var yaw: float = atan2(-facing.x, -facing.z)
	rpc_id(1, "req_player_state", {
		"pos": local_player.global_position, "yaw": yaw,
		"hp": local_player.hp, "max_hp": local_player.max_hp, "level": local_player.level,
		"flying": local_player.flying_cloud,
		"mp": local_player.mp, "max_mp": local_player.max_mp,
		"st": local_player.stamina, "max_st": local_player.max_stamina,
		"equip_tier": _local_equip_tier(),
	})

func _local_equip_tier() -> int:
	if local_player == null or not is_instance_valid(local_player):
		return 0
	var main_ref: Object = local_player.get("main") as Object
	if main_ref == null or not is_instance_valid(main_ref):
		return 0
	var inv: Object = main_ref.get("inv") as Object
	if inv == null or not is_instance_valid(inv) or not inv.has_method("best_tier"):
		return 0
	var total: int = 0
	var count: int = 0
	for t: String in EQUIP_TYPES:
		var tier: int = int(inv.call("best_tier", t))
		if tier > 0:
			total += tier
			count += 1
	return int(round(float(total) / float(count))) if count > 0 else 0

# Main / 技能在线时通过这里上报对怪物的伤害（服务器为权威）。
func report_monster_damage(monster_net_id: int, amount: int) -> void:
	if online and my_id != 0:
		rpc_id(1, "req_monster_damage", monster_net_id, amount, "")

# 本地玩家施法时上报，服务器转发给其他玩家做表现。
func send_cast(skill_id: String, pos: Vector3, dir: Vector3, level: int) -> void:
	if online and my_id != 0:
		rpc_id(1, "req_cast", skill_id, pos, dir, level)

func request_respawn() -> void:
	if online and my_id != 0:
		rpc_id(1, "req_respawn")

# 请求拾取某个共享掉落物（服务器裁决先到先得）。
func send_pickup(drop_id: int) -> void:
	if online and my_id != 0:
		rpc_id(1, "req_pickup", drop_id)

func send_save(save: Dictionary) -> void:
	if online and my_id != 0:
		rpc_id(1, "req_save", save)

# 聊天/组队发送。
# 聊天加密：玩家聊天内容用 AES-256-ECB 加密 + base64，带标记前缀。
# 服务器只转发（看不到明文），系统消息无标记按明文显示。
const CHAT_MARKER := "#ENC1#"   # 加密标记前缀，不与明文/系统消息冲突
const CHAT_KEY := "StarGloryMMOchatkeyv1_0123456789"   # 32 字节 = AES-256

func _chat_enc(text: String) -> String:
	var data: PackedByteArray = text.to_utf8_buffer()
	var pad: int = 16 - (data.size() % 16)   # PKCS7
	for i in range(pad):
		data.append(pad)
	var aes := AESContext.new()
	if aes.start(AESContext.MODE_ECB_ENCRYPT, CHAT_KEY.to_utf8_buffer()) != OK:
		return text
	var enc: PackedByteArray = aes.update(data)
	aes.finish()
	return CHAT_MARKER + Marshalls.raw_to_base64(enc)

func _chat_dec(payload: String) -> String:
	if not payload.begins_with(CHAT_MARKER):
		return payload   # 系统/明文消息原样显示
	var enc: PackedByteArray = Marshalls.base64_to_raw(payload.substr(CHAT_MARKER.length()))
	if enc.is_empty() or enc.size() % 16 != 0:
		return "[加密消息]"
	var aes := AESContext.new()
	if aes.start(AESContext.MODE_ECB_DECRYPT, CHAT_KEY.to_utf8_buffer()) != OK:
		return "[加密消息]"
	var dec: PackedByteArray = aes.update(enc)
	aes.finish()
	if dec.size() > 0:
		var p: int = dec[dec.size() - 1]   # 去 PKCS7 填充
		if p >= 1 and p <= 16 and p <= dec.size():
			dec = dec.slice(0, dec.size() - p)
	return dec.get_string_from_utf8()

func send_chat(channel: String, text: String, target: String = "") -> void:
	if online and my_id != 0:
		# 客户端先净化(去BBCode/限长)再加密；服务器对加密负载不再净化。
		var safe: String = text.replace("[", "［").strip_edges()
		if safe.length() > 200:
			safe = safe.substr(0, 200)
		if safe == "":
			return
		rpc_id(1, "req_chat", channel, _chat_enc(safe), target)

func send_ad_view() -> void:
	if online and my_id != 0:
		rpc_id(1, "req_ad_view")

# 采集全服共享节点（先到先得，服务器裁决）。
func send_gather_node(node_id: int) -> void:
	if online and my_id != 0:
		rpc_id(1, "req_gather_node", node_id)

# 向据点捐献材料建造/加固。
func send_deposit(op: int, mat: String, amount: int) -> void:
	if online and my_id != 0:
		rpc_id(1, "req_deposit", op, mat, amount)

func send_beast_tide(pos: Vector3) -> void:
	if online and my_id != 0:
		rpc_id(1, "req_use_beast_token", pos)

# 请求全服建造贡献榜。
func send_leaderboard_req() -> void:
	if online and my_id != 0:
		rpc_id(1, "req_leaderboard")

# 请求重建某据点的城墙段（服务器权威恢复）。
func send_rebuild(op: int, seg: int) -> void:
	if online and my_id != 0:
		rpc_id(1, "req_rebuild", op, seg)

func send_party(action: String, arg: String = "") -> void:
	if online and my_id != 0:
		rpc_id(1, "req_party", action, arg)

func send_admin(action: String, args: Dictionary) -> void:
	if online and my_id != 0:
		rpc_id(1, "req_admin", action, args)

func send_dungeon(action: String, arg: int) -> void:
	if online and my_id != 0:
		rpc_id(1, "req_dungeon", action, arg)

# 请求服务器裁决是否脱战（可安全退出）。结果通过 logout_permission 信号返回。
func request_logout_check() -> void:
	if online and my_id != 0:
		rpc_id(1, "req_can_logout")
	else:
		logout_permission.emit(true, "")

# ---------------- 客户端 -> 服务器 的占位（本端不接收，空实现以对齐 RPC id） ----------------
@rpc("any_peer", "call_remote", "reliable")
func req_login(_username: String, _password: String, _version: int) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_register(_username: String, _password: String, _nickname: String, _avatar: String, _version: int) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_set_profile(_nickname: String, _avatar: String) -> void: pass
@rpc("any_peer", "call_remote", "unreliable_ordered")
func req_player_state(_state: Dictionary) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_monster_damage(_mid: int, _amount: int, _element: String) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_respawn() -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_save(_save: Dictionary) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_cast(_skill_id: String, _pos: Vector3, _dir: Vector3, _level: int) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_pickup(_drop_id: int) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_can_logout() -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_chat(_channel: String, _text: String, _target: String) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_party(_action: String, _arg: String) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_admin(_action: String, _args: Dictionary) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_dungeon(_action: String, _arg: int) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_ad_view() -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_rebuild(_op: int, _seg: int) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_gather_node(_node_id: int) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_deposit(_op: int, _mat: String, _amount: int) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_use_beast_token(_pos: Vector3) -> void: pass
@rpc("any_peer", "call_remote", "reliable")
func req_leaderboard() -> void: pass
@rpc("any_peer", "call_remote", "unreliable")
func req_ping(_t: int) -> void: pass

# ---------------- 服务器 -> 客户端（真正的接收端实现） ----------------

@rpc("authority", "call_remote", "reliable")
func rpc_login_result(ok: bool, reason: String, save: Dictionary, your_id: int) -> void:
	_touch_server()
	if ok:
		my_id = your_id
		login_save = save
	login_result.emit(ok, reason)

@rpc("authority", "call_remote", "reliable")
func rpc_logout_result(allowed: bool, reason: String) -> void:
	logout_permission.emit(allowed, reason)

@rpc("authority", "call_remote", "reliable")
func rpc_roster(list: Array) -> void:
	roster.clear()
	roster_avatar.clear()
	for e_v: Variant in list:
		var e: Dictionary = e_v
		roster[int(e["id"])] = String(e.get("name", ""))
		roster_avatar[int(e["id"])] = String(e.get("avatar", ""))

@rpc("authority", "call_remote", "reliable")
func rpc_player_joined(id: int, name: String, avatar: String) -> void:
	roster[id] = name
	roster_avatar[id] = avatar

@rpc("authority", "call_remote", "reliable")
func rpc_player_left(id: int) -> void:
	roster.erase(id)
	players_state.erase(id)

@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_players_snapshot(states: Array) -> void:
	_touch_server()
	for s_v: Variant in states:
		var s: Dictionary = s_v
		players_state[int(s["id"])] = s

# 玩家离开本端 AOI：清缓存并排队，Main 移除其傀儡。
@rpc("authority", "call_remote", "reliable")
func rpc_players_despawn(ids: Array) -> void:
	_touch_server()
	for v: Variant in ids:
		var pid: int = int(v)
		players_state.erase(pid)
		player_despawn_queue.append(pid)

@rpc("authority", "call_remote", "reliable")
func rpc_monsters_full(defs: Array) -> void:
	_touch_server()
	for d_v: Variant in defs:
		var d: Dictionary = d_v
		monster_defs[int(d["id"])] = d

@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_monsters_snapshot(snaps: Array) -> void:
	_touch_server()
	for s_v: Variant in snaps:
		var s: Dictionary = s_v
		monsters_state[int(s["id"])] = s

# 怪物离开本端 AOI：清缓存并排队，Main 移除其傀儡。
@rpc("authority", "call_remote", "reliable")
func rpc_monsters_despawn(ids: Array) -> void:
	_touch_server()
	for v: Variant in ids:
		var mid: int = int(v)
		monster_defs.erase(mid)
		monsters_state.erase(mid)
		monster_despawn_queue.append(mid)

@rpc("authority", "call_remote", "reliable")
func rpc_monster_died(info: Dictionary) -> void:
	death_queue.append(info)
	var mid: int = int(info.get("id", 0))
	monster_defs.erase(mid)
	monsters_state.erase(mid)

@rpc("authority", "call_remote", "reliable")
func rpc_monster_hit_player(amount: int) -> void:
	_touch_server()
	pending_player_damage += amount

# 服务器权威控制本地玩家（浮空 + 眩晕/落地眩晕 + 减速）；交给 Main 施加。
@rpc("authority", "call_remote", "reliable")
func rpc_player_control(from: Vector3, launch: float, vertical: float, stun: float, on_landing: bool, slow_power: float, slow_dur: float) -> void:
	player_control_queue.append({"from": from, "launch": launch, "vertical": vertical, "stun": stun, "on_landing": on_landing, "slow_power": slow_power, "slow_dur": slow_dur})

@rpc("authority", "call_remote", "reliable")
func rpc_world_unlock(stage: int, radius: float) -> void:
	world_stage = stage
	world_radius = radius

@rpc("authority", "call_remote", "reliable")
func rpc_player_cast(caster_id: int, skill_id: String, pos: Vector3, dir: Vector3, level: int) -> void:
	cast_queue.append({"caster": caster_id, "skill_id": skill_id, "pos": pos, "dir": dir, "level": level})

@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_monster_damaged(mid: int, amount: int, pos: Vector3) -> void:
	damage_queue.append({"mid": mid, "amount": amount, "pos": pos})

@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_monster_action(mid: int, pos: Vector3) -> void:
	action_queue.append({"mid": mid, "pos": pos})

# Boss 连招表现事件：交给 Main 派发给对应 Boss 傀儡播放表现。
@rpc("authority", "call_remote", "reliable")
func rpc_monster_combo(mid: int, info: Dictionary) -> void:
	_touch_server()
	monster_combo_queue.append({"mid": mid, "info": info})

# 聊天消息：入队由 Main 显示。
@rpc("authority", "call_remote", "reliable")
func rpc_chat(channel: String, from_name: String, text: String, avatar: String) -> void:
	chat_queue.append({"channel": channel, "from": from_name, "text": _chat_dec(text), "avatar": avatar})

# 据点/城墙状态同步（服务器权威）。
@rpc("authority", "call_remote", "reliable")
func rpc_outpost_state(state: Array) -> void:
	outpost_queue.append(state)

# 全服共享材料节点同步。
@rpc("authority", "call_remote", "reliable")
func rpc_world_nodes(nodes: Array) -> void:
	world_nodes_data = nodes
	world_nodes_dirty = true

# 采集成功回执（本地入包）。
@rpc("authority", "call_remote", "reliable")
func rpc_gather_result(mat: String, amount: int) -> void:
	gather_result_queue.append({"mat": mat, "amount": amount})

# 全服建造贡献榜数据。
@rpc("authority", "call_remote", "reliable")
func rpc_leaderboard(data: Dictionary) -> void:
	leaderboard_data = data
	leaderboard_dirty = true

# 周榜奖励发放（登录时）。
@rpc("authority", "call_remote", "reliable")
func rpc_rewards(items: Array) -> void:
	rewards_queue.append(items)

# 队伍更新：缓存成员并置脏，Main 据此刷新。
@rpc("authority", "call_remote", "reliable")
func rpc_party_update(pid_party: int, members: Array) -> void:
	party_id = pid_party
	party_members = members.duplicate()
	party_dirty = true

# 心跳回包：刷新最近 pong 时间。
@rpc("authority", "call_remote", "unreliable")
func rpc_pong(_t: int) -> void:
	_touch_server()

# 管理员等级下发。
@rpc("authority", "call_remote", "reliable")
func rpc_admin_level(level: int) -> void:
	admin_level = level
	admin_dirty = true

# 操作台占用仲裁结果。
@rpc("authority", "call_remote", "reliable")
func rpc_admin_console(state: String, who: String) -> void:
	admin_console_queue.append({"state": state, "who": who})

@rpc("authority", "call_remote", "reliable")
func rpc_admin_players(players: Array) -> void:
	admin_players = players.duplicate(true)
	admin_players_dirty = true

@rpc("authority", "call_remote", "reliable")
func rpc_player_admin_update(data: Dictionary) -> void:
	_touch_server()
	_apply_player_admin_update(data)

# 副本进出事件。
@rpc("authority", "call_remote", "reliable")
func rpc_dungeon(state: String, info: Dictionary) -> void:
	dungeon_queue.append({"state": state, "info": info})

@rpc("authority", "call_remote", "reliable")
func rpc_drop_taken(drop_id: int, taker_id: int) -> void:
	drop_taken_queue.append({"id": drop_id, "taker": taker_id})

@rpc("authority", "call_remote", "reliable")
func rpc_region_locks(locked: Array) -> void:
	region_locks = locked.duplicate()
	region_locks_dirty = true

@rpc("authority", "call_remote", "reliable")
func rpc_force_position(pos: Vector3) -> void:
	force_pos = pos

func _apply_player_admin_update(data: Dictionary) -> void:
	if local_player == null or not is_instance_valid(local_player):
		return
	var main_ref: Object = local_player.get("main") as Object
	if data.has("name") and main_ref != null and is_instance_valid(main_ref):
		main_ref.set("local_player_name", String(data.get("name", "")))
	if data.has("level"):
		var lvl: int = clampi(int(data.get("level", 1)), 1, 999)
		_apply_local_level(lvl)
		local_player.next_level_exp = _next_exp_for_level(lvl)
		local_player.exp_points = mini(int(local_player.exp_points), maxi(0, local_player.next_level_exp - 1))
		if main_ref != null and is_instance_valid(main_ref) and ("level_cap" in main_ref):
			main_ref.set("level_cap", maxi(int(main_ref.get("level_cap")), lvl))
	if data.has("equip_tier"):
		_apply_local_equip_tier(clampi(int(data.get("equip_tier", 0)), 0, 60))
	if data.has("max_skills") and bool(data.get("max_skills", false)):
		_apply_local_max_skills()
	if data.has("godmode") and main_ref != null and is_instance_valid(main_ref):
		var god_on: bool = bool(data.get("godmode", false))
		main_ref.set("admin_godmode", god_on)
		if god_on and local_player.get("buff") != null:
			local_player.buff.apply_invuln(2.0)
	if data.has("gm_speed_mult"):
		local_player.gm_speed_mult = clampf(float(data.get("gm_speed_mult", 1.0)), 1.0, 3.0)
	if local_player.has_method("recalculate_stats"):
		local_player.recalculate_stats()
	if data.has("heal_full") and bool(data.get("heal_full", false)):
		local_player.hp = float(local_player.max_hp)
		local_player.mp = float(local_player.max_mp)
		local_player.stamina = float(local_player.max_stamina)
	elif data.has("level") or data.has("equip_tier"):
		local_player.hp = float(local_player.max_hp)
		local_player.mp = float(local_player.max_mp)
	if main_ref != null and is_instance_valid(main_ref):
		if main_ref.has_method("_on_inventory_changed"):
			main_ref.call("_on_inventory_changed")
		if main_ref.has_method("flash_message"):
			main_ref.call("flash_message", "[GM] 角色数据已由管理员调整。")

func _apply_local_equip_tier(tier: int) -> void:
	if local_player == null or not is_instance_valid(local_player):
		return
	var main_ref: Object = local_player.get("main") as Object
	if main_ref == null or not is_instance_valid(main_ref):
		return
	var inv: Object = main_ref.get("inv") as Object
	if inv == null or not is_instance_valid(inv):
		return
	var pages: Dictionary = inv.get("pages")
	var caps: Dictionary = inv.get("caps")
	for t: String in EQUIP_TYPES:
		pages[t] = ([tier] if tier > 0 else [])
		caps[t] = maxi(int(caps.get(t, 2)), 2)
	inv.set("pages", pages)
	inv.set("caps", caps)
	if inv.has_method("_on_change"):
		inv.call("_on_change")

func _apply_local_level(lvl: int) -> void:
	local_player.level = lvl
	var growth: int = maxi(0, lvl - 1)
	local_player.base_max_hp = 280 + 24 * growth
	local_player.base_max_mp = 180 + 14 * growth
	local_player.base_attack = 18 + 2 * growth
	local_player.base_magic = 14 + 2 * growth
	local_player.base_defense = 3 + growth
	local_player.base_toughness = 6 + growth

func _apply_local_max_skills() -> void:
	var main_ref: Object = local_player.get("main") as Object
	if main_ref == null or not is_instance_valid(main_ref):
		return
	var skills_ref: Object = main_ref.get("skills") as Object
	if skills_ref == null or not is_instance_valid(skills_ref):
		return
	var levels: Dictionary = skills_ref.get("skill_levels")
	for sid: String in SkillManager.ORDER:
		levels[sid] = SkillManager.MAX_LEVEL
	skills_ref.set("skill_levels", levels)

func _next_exp_for_level(lvl: int) -> int:
	var nx: int = 80
	for _i in range(maxi(0, lvl - 1)):
		nx = int(float(nx) * 1.32 + 30.0)
	return nx
