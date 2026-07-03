extends Node

# ServerNetwork —— 服务器网络层（autoload "Net"）。拥有 ENet peer，处理连接/登录/收发，
# 并提供广播辅助。世界模拟在 ServerMain（场景根 "World"）里，启动时通过 Net.world 互相引用。
#
# 重要：本脚本声明的 @rpc 方法集合，必须与客户端 client/scripts/net/NetworkClient.gd 完全一致
# （同名、同标注、同数量）——Godot 按“节点上所有 @rpc 方法名排序”分配 RPC id，两端不一致会错位。
# req_*  = 客户端调用、服务器执行；rpc_* = 服务器调用、客户端执行（服务器这边为空实现）。

var world: Node = null                 # ServerMain，启动时注入
var peer: ENetMultiplayerPeer = null

# peer_id -> 玩家状态。AOI 扩展点：将来按区域裁剪广播对象即可。
var players: Dictionary = {}

# 上下线限制：仅脱战可下线；战斗中强退则一段时间内禁止登录。
const COMBAT_WINDOW_MS := 10000     # 受击/出手后 10 秒内算「战斗中」
const LOGOUT_PENALTY_MS := 60000    # 战斗中强退后禁登 60 秒
const PROXY_TTL_MS := 45000         # 强退后「挨打代理」存活时长
var combat_until: Dictionary = {}   # peer_id -> 战斗状态到期时间(ms)
var login_bans: Dictionary = {}     # 小写用户名 -> 禁登到期时间(ms)

# 聊天加密标记：带此前缀的内容为 AES 密文，服务器只转发不解密/净化。
const CHAT_MARKER := "#ENC1#"

# 最小组队：party_id -> {leader:int, members:Array[int]}；pending_invite: 被邀请者 pid -> party_id。
var parties: Dictionary = {}
var next_party_id: int = 1
var pending_invite: Dictionary = {}

func _mark_combat(id: int) -> void:
	combat_until[id] = Time.get_ticks_msec() + COMBAT_WINDOW_MS

func start_server(port: int, max_players: int) -> bool:
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_players)
	if err != OK:
		push_error("[Net] 监听端口 %d 失败（错误码 %d）。" % [port, err])
		return false
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[Net] 服务器已监听端口 %d（最大 %d 人）。" % [port, max_players])
	return true

func _on_peer_connected(id: int) -> void:
	players[id] = {"user": "", "name": "", "authed": false,
		"pos": Vector3.ZERO, "yaw": 0.0, "hp": 1.0, "max_hp": 1, "level": 1, "anim": 0, "flying": false,
		"mp": 0.0, "max_mp": 1, "st": 0.0, "max_st": 1,
		"equip_tier": 0,
		# AOI 兴趣区：该客户端当前「可见」的实体集合（id -> true），用于增量进入/离开。
		"seen_players": {}, "seen_monsters": {},
		"party_id": 0, "admin_level": 0, "avatar": "",
		# 副本实例（0=大世界）；强退挨打代理。
		"instance_id": 0, "dungeon_enter_ms": 0,
		"proxy": false, "proxy_hp": 0.0, "proxy_until": 0}
	print("[Net] 连接: peer %d（待登录）" % id)

func _on_peer_disconnected(id: int) -> void:
	if players.has(id):
		var was_authed: bool = players[id].get("authed", false)
		# 战斗中强制下线 → 该账号一段时间内禁止登录。
		if was_authed and int(combat_until.get(id, 0)) > Time.get_ticks_msec():
			var uname: String = String(players[id].get("user", "")).to_lower()
			if uname != "":
				login_bans[uname] = Time.get_ticks_msec() + LOGOUT_PENALTY_MS
				print("[Net] %s 战斗中强退 → 禁登 %d 秒" % [uname, LOGOUT_PENALTY_MS / 1000])
		_leave_party(id)
		pending_invite.erase(id)
		combat_until.erase(id)
		if world != null and world.has_method("admin_player_left"):
			world.admin_player_left(id)
		if world != null and world.has_method("dungeon_player_left"):
			world.dungeon_player_left(id)
		if was_authed:
			# 强退 → 转为「挨打代理」：保留位置，仅挨打；超时或被打死才移除。
			var p: Dictionary = players[id]
			p["proxy"] = true
			p["proxy_hp"] = float(p.get("hp", 1.0))
			p["proxy_until"] = Time.get_ticks_msec() + PROXY_TTL_MS
			p["instance_id"] = 0
			# 持久化下线时的即时状态，供重连恢复（离线超时后也能恢复到下线状态）。
			var dpos: Vector3 = p.get("pos", Vector3.ZERO)
			Accounts.set_resume(String(p.get("user", "")), {
				"pos": [dpos.x, dpos.y, dpos.z], "hp": float(p.get("hp", 1.0)),
				"mp": float(p.get("mp", 0.0)), "st": float(p.get("st", 0.0))})
			print("[Net] %s 断开 → 挨打代理(%ds)" % [String(p.get("user", "")), PROXY_TTL_MS / 1000])
		else:
			players.erase(id)
			print("[Net] 断开: peer %d（未登录）" % id)

# 在线可收包的玩家（不含挨打代理，代理已无连接）。
func authed_ids() -> Array:
	var out: Array = []
	for pid: int in players.keys():
		if players[pid].get("authed", false) and not players[pid].get("proxy", false):
			out.append(pid)
	return out

# 可被其他玩家「看见」的实体（含挨打代理）。
func visible_ids() -> Array:
	var out: Array = []
	for pid: int in players.keys():
		if players[pid].get("authed", false):
			out.append(pid)
	return out

# ---------------- 客户端 -> 服务器 ----------------

@rpc("any_peer", "call_remote", "reliable")
func req_login(username: String, password: String, version: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id):
		return
	if version != int(GameData.proto("protocol_version", 1)):
		rpc_id(id, "rpc_login_result", false, "协议版本不一致，请更新客户端", {}, id)
		return
	var res: Dictionary = Accounts.authenticate(username, password)
	if not res.get("ok", false):
		rpc_id(id, "rpc_login_result", false, String(res.get("reason", "登录失败")), {}, id)
		return
	_finish_login(id, res)

@rpc("any_peer", "call_remote", "reliable")
func req_register(username: String, password: String, nickname: String, avatar: String, version: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id):
		return
	if version != int(GameData.proto("protocol_version", 1)):
		rpc_id(id, "rpc_login_result", false, "协议版本不一致，请更新客户端", {}, id)
		return
	var res: Dictionary = Accounts.register(username, password, nickname, avatar)
	if not res.get("ok", false):
		rpc_id(id, "rpc_login_result", false, String(res.get("reason", "注册失败")), {}, id)
		return
	_finish_login(id, res)

# 登录/注册成功后的共同流程。uid=登录标识（唯一），nick=显示昵称，av=头像。
func _finish_login(id: int, res: Dictionary) -> void:
	var uid: String = String(res.get("user", ""))
	var nick: String = String(res.get("name", uid))
	var av: String = String(res.get("avatar", ""))
	# 拒绝同账号重复登录（按登录标识）。若存在托管代理，取其「当前」状态覆盖恢复点。
	var resume_override: Dictionary = {}
	for pid: int in players.keys():
		if pid != id and players[pid].get("authed", false) and String(players[pid].get("user", "")).to_lower() == uid.to_lower():
			if players[pid].get("proxy", false):
				var pp: Dictionary = players[pid]
				var ppos: Vector3 = pp.get("pos", Vector3.ZERO)
				resume_override = {"pos": [ppos.x, ppos.y, ppos.z], "hp": float(pp.get("proxy_hp", pp.get("hp", 1.0))),
					"mp": float(pp.get("mp", 0.0)), "st": float(pp.get("st", 0.0))}
				remove_proxy(pid)
				continue
			rpc_id(id, "rpc_login_result", false, "该账号已在线", {}, id)
			return
	var ban_until: int = int(login_bans.get(uid.to_lower(), 0))
	if ban_until > Time.get_ticks_msec():
		var left: int = int(ceil(float(ban_until - Time.get_ticks_msec()) / 1000.0))
		rpc_id(id, "rpc_login_result", false, "战斗中强制下线，请 %d 秒后再登录。" % left, {}, id)
		return
	players[id]["authed"] = true
	players[id]["user"] = uid
	players[id]["name"] = nick
	players[id]["avatar"] = av
	var save: Dictionary = Accounts.load_save(uid)
	if not resume_override.is_empty():
		save["_resume"] = resume_override   # 托管中重连：用代理当前状态
	players[id]["admin_level"] = Accounts.admin_level(uid)
	print("[Net] 登录成功: %s（%s）(peer %d)%s" % [uid, nick, id, "（新注册）" if res.get("created", false) else ""])
	rpc_id(id, "rpc_login_result", true, "", save, id)
	if int(players[id]["admin_level"]) > 0:
		rpc_id(id, "rpc_admin_level", int(players[id]["admin_level"]))
	rpc_id(id, "rpc_roster", _roster_array())
	rpc("rpc_player_joined", id, nick, av)
	var motd: String = Accounts.motd()
	if motd != "":
		_sys_to(id, "[公告] " + motd)
	if world != null:
		world.send_world_to(id)
		if world.has_method("send_outposts_to"):
			world.send_outposts_to(id)
		if world.has_method("send_world_nodes_to"):
			world.send_world_nodes_to(id)
		if world.has_method("take_pending_rewards"):
			var rewards: Array = world.take_pending_rewards(uid)
			if not rewards.is_empty():
				rpc_id(id, "rpc_rewards", rewards)

func _roster_array() -> Array:
	var roster: Array = []
	for pid: int in authed_ids():
		roster.append({"id": pid, "name": String(players[pid].get("name", "")), "avatar": String(players[pid].get("avatar", ""))})
	return roster

# 修改个人资料（昵称/头像）：仅脱战或在安全区可改。
@rpc("any_peer", "call_remote", "reliable")
func req_set_profile(nickname: String, avatar: String) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	var in_combat: bool = int(combat_until.get(id, 0)) > Time.get_ticks_msec()
	var safe: bool = world != null and world.has_method("_outpost_safe") and world._outpost_safe(players[id].get("pos", Vector3.ZERO))
	if in_combat and not safe:
		_sys_to(id, "修改资料需脱战或身处安全区。")
		return
	var r: Dictionary = Accounts.set_profile(String(players[id].get("user", "")), nickname, avatar)
	if not r.get("ok", false):
		return
	players[id]["name"] = String(r["name"])
	players[id]["avatar"] = String(r.get("avatar", ""))
	# 全服刷新花名册，让所有人看到新昵称/头像。
	var ra: Array = _roster_array()
	for pid: int in authed_ids():
		rpc_id(pid, "rpc_roster", ra)
	_sys_to(id, "资料已更新：%s。" % String(r["name"]))

@rpc("any_peer", "call_remote", "unreliable_ordered")
func req_player_state(state: Dictionary) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	var p: Dictionary = players[id]
	p["pos"] = state.get("pos", p["pos"])
	p["yaw"] = float(state.get("yaw", p["yaw"]))
	p["hp"] = float(state.get("hp", p["hp"]))
	p["max_hp"] = int(state.get("max_hp", p["max_hp"]))
	p["level"] = int(state.get("level", p["level"]))
	p["anim"] = int(state.get("anim", p["anim"]))
	p["flying"] = bool(state.get("flying", p.get("flying", false)))
	p["mp"] = float(state.get("mp", p.get("mp", 0.0)))
	p["max_mp"] = int(state.get("max_mp", p.get("max_mp", 1)))
	p["st"] = float(state.get("st", p.get("st", 0.0)))
	p["max_st"] = int(state.get("max_st", p.get("max_st", 1)))
	p["equip_tier"] = int(state.get("equip_tier", p.get("equip_tier", 0)))
	# 区域锁定：不允许停留在更新中的区域，强制纠正其位置（客户端通常已自行阻挡，这里是权威兜底）。
	if world != null and world.is_region_locked(p["pos"]):
		var safe: Vector3 = world.eject_pos(p["pos"])
		p["pos"] = safe
		rpc_id(id, "rpc_force_position", safe)

@rpc("any_peer", "call_remote", "reliable")
func req_monster_damage(mid: int, amount: int, _element: String) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	_mark_combat(id)   # 玩家出手 → 进入战斗
	if world != null:
		world.apply_monster_damage(mid, amount, id)

@rpc("any_peer", "call_remote", "reliable")
func req_respawn() -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	if float(players[id].get("hp", 1.0)) > 0.0:
		return
	if world != null:
		players[id]["pos"] = world.player_spawn()
		players[id]["hp"] = float(players[id].get("max_hp", 1))

@rpc("any_peer", "call_remote", "reliable")
func req_save(save: Dictionary) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	Accounts.store_save(String(players[id].get("user", "")), save)

@rpc("any_peer", "call_remote", "reliable")
func req_cast(skill_id: String, pos: Vector3, dir: Vector3, level: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	# 只发给「能看见施法者」的其他玩家（AOI）；不回发给施法者本人，本地已自行表现。
	for pid: int in authed_ids():
		if pid != id and (players[pid]["seen_players"] as Dictionary).has(id):
			rpc_id(pid, "rpc_player_cast", id, skill_id, pos, dir, level)

@rpc("any_peer", "call_remote", "reliable")
func req_pickup(drop_id: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	if world != null:
		world.handle_pickup(drop_id, id)

# 客户端请求安全退出：服务器按战斗状态裁决。
@rpc("any_peer", "call_remote", "reliable")
func req_can_logout() -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	var fighting: bool = int(combat_until.get(id, 0)) > Time.get_ticks_msec()
	rpc_id(id, "rpc_logout_result", not fighting, "战斗中" if fighting else "")

# 服务器 -> 客户端：脱战裁决结果（占位，服务器不接收）。
@rpc("authority", "call_remote", "reliable")
func rpc_logout_result(_allowed: bool, _reason: String) -> void: pass

# ---------------- 聊天 / 组队 ----------------

func _sanitize_chat(text: String) -> String:
	# 去 BBCode 注入 + 长度上限。
	var t: String = text.replace("[", "［").strip_edges()
	if t.length() > 200:
		t = t.substr(0, 200)
	return t

func _find_player_by_name(name: String) -> int:
	var key: String = name.strip_edges().to_lower()
	if key == "":
		return 0
	for pid: int in authed_ids():
		if String(players[pid].get("name", "")).to_lower() == key:
			return pid
	return 0

func _sys_to(id: int, text: String) -> void:
	if players.has(id):
		rpc_id(id, "rpc_chat", "system", "", text, "")

# 供 ServerMain 发系统消息（如 GM 操作回执）。
func send_system(id: int, text: String) -> void:
	_sys_to(id, text)

# 全服系统广播（公告）。
func broadcast_system(text: String) -> void:
	for pid: int in authed_ids():
		rpc_id(pid, "rpc_chat", "system", "", text, "")

# ---- 队伍辅助（供副本流程用）----
func party_leader(party_id: int) -> int:
	return int((parties.get(party_id, {}) as Dictionary).get("leader", 0))

func party_members(party_id: int) -> Array:
	return ((parties.get(party_id, {}) as Dictionary).get("members", []) as Array).duplicate()

# 向某队伍频道推送一条消息（发给全体在线队员）。
func send_party(party_id: int, from_name: String, text: String) -> void:
	for mid: int in party_members(party_id):
		if players.has(mid) and players[mid].get("authed", false) and not players[mid].get("proxy", false):
			rpc_id(mid, "rpc_chat", "party", from_name, text, "")

# 某用户的管理员等级被改：在线则热更并下发新等级。
func push_admin_level_for_user(user: String) -> void:
	var key: String = user.strip_edges().to_lower()
	var lvl: int = Accounts.admin_level(user)
	for pid: int in authed_ids():
		if String(players[pid].get("user", "")).to_lower() == key:
			players[pid]["admin_level"] = lvl
			rpc_id(pid, "rpc_admin_level", lvl)
			_sys_to(pid, "你的管理员等级已更新为 %d。" % lvl)

@rpc("any_peer", "call_remote", "reliable")
func req_chat(channel: String, text: String, target: String) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	# 加密负载（带标记）只转发不净化；明文走净化。
	var msg: String = text if text.begins_with(CHAT_MARKER) else _sanitize_chat(text)
	if text.begins_with(CHAT_MARKER) and msg.length() > 1200:
		return
	if msg == "":
		return
	var from_name: String = String(players[id].get("name", ""))
	var av: String = String(players[id].get("avatar", ""))
	match channel:
		"public":
			# 当前加载区域(AOI)：发给「能看见发送者」的客户端 + 本人。
			for pid: int in authed_ids():
				if pid == id or (players[pid]["seen_players"] as Dictionary).has(id):
					rpc_id(pid, "rpc_chat", "public", from_name, msg, av)
		"party":
			var party: int = int(players[id].get("party_id", 0))
			if party == 0 or not parties.has(party):
				_sys_to(id, "你当前没有队伍。用 /invite 名字 邀请。")
				return
			for mid: int in (parties[party]["members"] as Array):
				if players.has(mid) and not players[mid].get("proxy", false):
					rpc_id(mid, "rpc_chat", "party", from_name, msg, av)
		"whisper":
			var tid: int = _find_player_by_name(target)
			if tid == 0:
				_sys_to(id, "玩家「%s」不在线。" % target)
				return
			rpc_id(tid, "rpc_chat", "whisper", from_name, msg, av)
			if tid != id:
				rpc_id(id, "rpc_chat", "whisper", "→" + String(players[tid].get("name", target)), msg, av)

@rpc("any_peer", "call_remote", "reliable")
func req_party(action: String, arg: String) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	match action:
		"invite":
			var tid: int = _find_player_by_name(arg)
			if tid == 0 or tid == id:
				_sys_to(id, "找不到玩家「%s」。" % arg)
				return
			var party: int = _ensure_party(id)
			pending_invite[tid] = party
			_sys_to(tid, "%s 邀请你加入队伍，输入 /accept 加入。" % String(players[id].get("name", "")))
			_sys_to(id, "已邀请「%s」。" % arg)
		"accept":
			var party: int = int(pending_invite.get(id, 0))
			if party == 0 or not parties.has(party):
				_sys_to(id, "没有待处理的队伍邀请。")
				return
			pending_invite.erase(id)
			_join_party(id, party)
		"leave":
			if int(players[id].get("party_id", 0)) == 0:
				_sys_to(id, "你当前没有队伍。")
				return
			_leave_party(id)

func _ensure_party(id: int) -> int:
	var party: int = int(players[id].get("party_id", 0))
	if party != 0 and parties.has(party):
		return party
	party = next_party_id
	next_party_id += 1
	parties[party] = {"leader": id, "members": [id]}
	players[id]["party_id"] = party
	_broadcast_party(party)
	return party

func _join_party(id: int, party: int) -> void:
	if int(players[id].get("party_id", 0)) == party:
		return
	if int(players[id].get("party_id", 0)) != 0:
		_leave_party(id)
	var members: Array = parties[party]["members"]
	if not members.has(id):
		members.append(id)
	players[id]["party_id"] = party
	for mid: int in members:
		_sys_to(mid, "%s 加入了队伍。" % String(players[id].get("name", "")))
	_broadcast_party(party)

func _leave_party(id: int) -> void:
	var party: int = int(players[id].get("party_id", 0))
	if party == 0 or not parties.has(party):
		players[id]["party_id"] = 0
		return
	var members: Array = parties[party]["members"]
	members.erase(id)
	players[id]["party_id"] = 0
	rpc_id(id, "rpc_party_update", 0, [])   # 通知本人已离队
	if members.is_empty():
		parties.erase(party)
		return
	if int(parties[party]["leader"]) == id:
		parties[party]["leader"] = int(members[0])
	for mid: int in members:
		_sys_to(mid, "有队员离开了队伍。")
	_broadcast_party(party)

func _broadcast_party(party: int) -> void:
	if not parties.has(party):
		return
	var members: Array = []
	for mid: int in (parties[party]["members"] as Array):
		if players.has(mid):
			members.append({"id": mid, "name": String(players[mid].get("name", ""))})
	for mid: int in (parties[party]["members"] as Array):
		if players.has(mid):
			rpc_id(mid, "rpc_party_update", party, members)

# 服务器 -> 客户端：聊天 / 队伍（占位，服务器不接收）。
@rpc("authority", "call_remote", "reliable")
func rpc_chat(_channel: String, _from_name: String, _text: String, _avatar: String) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_party_update(_party_id: int, _members: Array) -> void: pass

# ---------------- 管理员（GM）----------------
# 各权能所需的最低管理员等级（自身类不过服务器，由客户端按 admin_level 自行放行）。
const _ADMIN_MIN := {"console_open": 1, "console_close": 1, "player_list": 1, "set_player": 2, "player_effect": 2, "kill_area": 2, "reset_monsters": 2, "monster_strength": 3, "drop_rate": 3}

# 心跳：原样回包。
@rpc("any_peer", "call_remote", "unreliable")
func req_ping(t: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if players.has(id):
		rpc_id(id, "rpc_pong", t)

@rpc("any_peer", "call_remote", "reliable")
func req_admin(action: String, args: Dictionary) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	var lvl: int = int(players[id].get("admin_level", 0))
	var need: int = int(_ADMIN_MIN.get(action, 99))
	if lvl < need:
		_sys_to(id, "权限不足：需要管理员等级 %d（你 %d）。" % [need, lvl])
		return
	if world != null and world.has_method("admin_action"):
		world.admin_action(action, args, lvl, id)

# 操作台占用仲裁结果下发（grant/deny/kicked）。
func send_console(id: int, state: String, who: String) -> void:
	if players.has(id):
		rpc_id(id, "rpc_admin_console", state, who)

func send_admin_players(id: int, list: Array) -> void:
	if players.has(id):
		rpc_id(id, "rpc_admin_players", list)

func send_player_admin_update(id: int, data: Dictionary) -> void:
	if players.has(id) and not players[id].get("proxy", false):
		rpc_id(id, "rpc_player_admin_update", data)

func broadcast_roster() -> void:
	var ra: Array = _roster_array()
	for pid: int in authed_ids():
		rpc_id(pid, "rpc_roster", ra)

func player_name(id: int) -> String:
	return String(players[id].get("name", "")) if players.has(id) else ""

# ---------------- 副本 ----------------
@rpc("any_peer", "call_remote", "reliable")
func req_dungeon(action: String, arg: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	if world != null and world.has_method("dungeon_action"):
		world.dungeon_action(action, arg, id)

func send_dungeon(id: int, state: String, info: Dictionary) -> void:
	if players.has(id):
		rpc_id(id, "rpc_dungeon", state, info)

# 据点/城墙状态同步。
func broadcast_outpost_state(state: Array) -> void:
	for pid: int in authed_ids():
		rpc_id(pid, "rpc_outpost_state", state)

func send_outpost_state_to(id: int, state: Array) -> void:
	if players.has(id):
		rpc_id(id, "rpc_outpost_state", state)

# 全服共享材料节点 + 据点捐献材料。
func send_world_nodes_to(id: int, nodes: Array) -> void:
	if players.has(id):
		rpc_id(id, "rpc_world_nodes", nodes)

func broadcast_world_nodes(nodes: Array) -> void:
	for pid: int in authed_ids():
		rpc_id(pid, "rpc_world_nodes", nodes)

func send_gather_result(id: int, mat: String, amount: int) -> void:
	if players.has(id):
		rpc_id(id, "rpc_gather_result", mat, amount)

@rpc("any_peer", "call_remote", "reliable")
func req_gather_node(node_id: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	if world != null and world.has_method("gather_node"):
		world.gather_node(node_id, id)

@rpc("any_peer", "call_remote", "reliable")
func req_deposit(op: int, mat: String, amount: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	if world != null and world.has_method("deposit_material"):
		world.deposit_material(op, mat, amount, id)

@rpc("any_peer", "call_remote", "reliable")
func req_use_beast_token(pos: Vector3) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	if world != null and world.has_method("start_beast_tide"):
		world.start_beast_tide(id, pos)

# 全服建造贡献榜。
func send_leaderboard(id: int, data: Dictionary) -> void:
	if players.has(id):
		rpc_id(id, "rpc_leaderboard", data)

@rpc("any_peer", "call_remote", "reliable")
func req_leaderboard() -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	if world != null and world.has_method("send_leaderboard_to"):
		world.send_leaderboard_to(id)

@rpc("any_peer", "call_remote", "reliable")
func req_rebuild(op: int, seg: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	if world != null and world.has_method("rebuild_wall"):
		world.rebuild_wall(op, seg, id)

# 联机：记录玩家广告观看次数（持久化到服务器）。
@rpc("any_peer", "call_remote", "reliable")
func req_ad_view() -> void:
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or not players[id].get("authed", false):
		return
	var user: String = String(players[id].get("user", ""))
	if user == "":
		return
	var n: int = Accounts.add_ad_view(user)
	_sys_to(id, "已记录广告观看（累计 %d 次）。" % n)
	rpc_id(id, "rpc_rewards", [{"mat": "防御卷轴", "amount": 1}])

# 服务器 -> 客户端：下发管理员等级 / 操作台仲裁 / 副本（占位，服务器不接收）。
@rpc("authority", "call_remote", "reliable")
func rpc_dungeon(_state: String, _info: Dictionary) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_outpost_state(_state: Array) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_world_nodes(_nodes: Array) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_gather_result(_mat: String, _amount: int) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_leaderboard(_data: Dictionary) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_rewards(_items: Array) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_admin_level(_level: int) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_admin_console(_state: String, _who: String) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_admin_players(_players: Array) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_player_admin_update(_data: Dictionary) -> void: pass
@rpc("authority", "call_remote", "unreliable")
func rpc_pong(_t: int) -> void: pass

# ---------------- 广播辅助（服务器 -> 客户端） ----------------

# 单个玩家的完整状态（含血蓝体），供 AOI 快照按客户端拼装。
func player_state_dict(pid: int) -> Dictionary:
	var p: Dictionary = players[pid]
	return {"id": pid, "pos": p["pos"], "yaw": p["yaw"],
		"hp": p["hp"], "max_hp": p["max_hp"], "level": p["level"], "anim": p["anim"],
		"flying": p.get("flying", false),
		"mp": p.get("mp", 0.0), "max_mp": p.get("max_mp", 1),
		"st": p.get("st", 0.0), "max_st": p.get("max_st", 1)}

# 当前「能看见」某怪物的客户端列表（AOI）。
func viewers_of_monster(mid: int) -> Array:
	var out: Array = []
	for pid: int in players.keys():
		# 排除挨打代理：其已无连接，rpc_id 会报「unknown peer ID」。
		if players[pid].get("authed", false) and not players[pid].get("proxy", false) and (players[pid]["seen_monsters"] as Dictionary).has(mid):
			out.append(pid)
	return out

# ---- AOI 逐客户端发送（由 ServerMain 的兴趣区计算调用）----
func send_players_snapshot_to(id: int, states: Array) -> void:
	rpc_id(id, "rpc_players_snapshot", states)

func send_players_despawn_to(id: int, ids: Array) -> void:
	rpc_id(id, "rpc_players_despawn", ids)

func send_monsters_snapshot_to(id: int, snaps: Array) -> void:
	# 分批发送，单包保持在 MTU 以下（怪多时整包会超 1392 字节导致丢包）。
	var n: int = snaps.size()
	if n <= 16:
		rpc_id(id, "rpc_monsters_snapshot", snaps)
		return
	var i: int = 0
	while i < n:
		rpc_id(id, "rpc_monsters_snapshot", snaps.slice(i, mini(i + 16, n)))
		i += 16

func send_monsters_despawn_to(id: int, ids: Array) -> void:
	rpc_id(id, "rpc_monsters_despawn", ids)

func send_monster_defs_to(id: int, defs: Array) -> void:
	rpc_id(id, "rpc_monsters_full", defs)

# 怪物死亡：只发给「看得见它」的客户端 + 击杀者；并从所有人的可见集合移除。
func broadcast_monster_died(info: Dictionary) -> void:
	var mid: int = int(info.get("id", 0))
	var killer: int = int(info.get("killer", 0))
	for pid: int in players.keys():
		if not players[pid].get("authed", false):
			continue
		var seen: Dictionary = players[pid]["seen_monsters"]
		if (seen.has(mid) or pid == killer) and not players[pid].get("proxy", false):
			rpc_id(pid, "rpc_monster_died", info)   # 代理无连接，跳过发送
		seen.erase(mid)

func send_hit_player(target_id: int, amount: int) -> void:
	if not players.has(target_id):
		return
	var p: Dictionary = players[target_id]
	if p.get("proxy", false):
		# 挨打代理：服务器结算血量（让旁观者看到掉血）；归零则代理死亡。
		p["proxy_hp"] = float(p.get("proxy_hp", 1.0)) - float(amount)
		p["hp"] = maxf(0.0, float(p["proxy_hp"]))
		if float(p["proxy_hp"]) <= 0.0:
			_kill_proxy(target_id)
		return
	_mark_combat(target_id)   # 被怪命中 → 进入战斗
	rpc_id(target_id, "rpc_monster_hit_player", amount)

# 代理死亡：对账号存档结算死亡惩罚（扣经验/概率掉装备）并移除。
func _kill_proxy(id: int) -> void:
	if not players.has(id):
		return
	var u: String = String(players[id].get("user", ""))
	_penalize_save(u)
	Accounts.clear_resume(u)   # 代理阵亡 → 重连正常复活，不再恢复到死亡点
	players.erase(id)
	rpc("rpc_player_left", id)

# 代理超时移除（不结算惩罚，存档维持最近自动存档状态）。
func remove_proxy(id: int) -> void:
	if not players.has(id):
		return
	players.erase(id)
	rpc("rpc_player_left", id)

func _penalize_save(user: String) -> void:
	if user.strip_edges() == "":
		return
	var s: Dictionary = Accounts.load_save(user)
	if s.is_empty():
		return
	var nx: int = int(s.get("next_exp", 80))
	s["exp"] = maxi(0, int(s.get("exp", 0)) - int(float(nx) * 0.1))
	if randf() < 0.25 and s.get("inventory", null) is Dictionary:
		var pages: Variant = (s["inventory"] as Dictionary).get("pages", null)
		if pages is Dictionary:
			var avail: Array = []
			for t: String in (pages as Dictionary).keys():
				if (pages[t] is Array) and (pages[t] as Array).size() > 0:
					avail.append(t)
			if not avail.is_empty():
				var et: String = avail[randi() % avail.size()]
				(pages[et] as Array).remove_at(randi() % (pages[et] as Array).size())
	Accounts.store_save(user, s)

# 代理 TTL 轮询（每帧由自身 _process 驱动）。
func _process(_delta: float) -> void:
	if players.is_empty():
		return
	var now: int = Time.get_ticks_msec()
	for pid: int in players.keys():
		if players[pid].get("proxy", false) and now > int(players[pid].get("proxy_until", 0)):
			remove_proxy(pid)
			break   # 本帧最多清一个，避免遍历中改字典

# 服务器权威控制玩家：浮空(击退) + 眩晕（on_landing=true 落地后眩晕）+ 减速。
func send_player_control(target_id: int, from: Vector3, launch: float, vertical: float, stun: float, on_landing: bool, slow_power: float = 0.0, slow_dur: float = 0.0) -> void:
	if players.has(target_id):
		_mark_combat(target_id)
		rpc_id(target_id, "rpc_player_control", from, launch, vertical, stun, on_landing, slow_power, slow_dur)

func broadcast_world_unlock(stage: int, radius: float) -> void:
	rpc("rpc_world_unlock", stage, radius)

# 伤害飘字：只发给「看得见该怪」的客户端（除攻击者本人，本地已显示）。
func broadcast_monster_damaged(mid: int, amount: int, pos: Vector3, exclude_id: int) -> void:
	for pid: int in viewers_of_monster(mid):
		if pid != exclude_id:
			rpc_id(pid, "rpc_monster_damaged", mid, amount, pos)

# 怪物动作（攻击）：只发给「看得见该怪」的客户端。
func broadcast_monster_action(mid: int, pos: Vector3) -> void:
	for pid: int in viewers_of_monster(mid):
		rpc_id(pid, "rpc_monster_action", mid, pos)

# Boss 连招表现（标记/虚影/冲击）：只发给「看得见该 Boss」的客户端。
func broadcast_monster_combo(mid: int, info: Dictionary) -> void:
	for pid: int in viewers_of_monster(mid):
		rpc_id(pid, "rpc_monster_combo", mid, info)

# 掉落物被拾取/过期：让所有人移除该物品；taker_id 为拾取者（0 = 过期无人拾取）。
func broadcast_drop_taken(drop_id: int, taker_id: int) -> void:
	rpc("rpc_drop_taken", drop_id, taker_id)

# 区域热更新：广播当前锁定区域列表。
func broadcast_region_locks(locked: Array) -> void:
	rpc("rpc_region_locks", locked)

func send_region_locks_to(id: int, locked: Array) -> void:
	rpc_id(id, "rpc_region_locks", locked)

# 强制把某玩家传送到 pos（区域弹出用）。
func send_force_position(id: int, pos: Vector3) -> void:
	if players.has(id):
		rpc_id(id, "rpc_force_position", pos)

func send_world_unlock_to(id: int, stage: int, radius: float) -> void:
	rpc_id(id, "rpc_world_unlock", stage, radius)

# ---------------- 服务器 -> 客户端 的方法占位（服务器不接收，空实现以对齐 RPC id） ----------------
@rpc("authority", "call_remote", "reliable")
func rpc_login_result(_ok: bool, _reason: String, _save: Dictionary, _your_id: int) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_roster(_list: Array) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_player_joined(_id: int, _name: String, _avatar: String) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_player_left(_id: int) -> void: pass
@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_players_snapshot(_states: Array) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_players_despawn(_ids: Array) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_monsters_full(_defs: Array) -> void: pass
@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_monsters_snapshot(_snaps: Array) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_monsters_despawn(_ids: Array) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_monster_died(_info: Dictionary) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_monster_hit_player(_amount: int) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_player_control(_from: Vector3, _launch: float, _vertical: float, _stun: float, _on_landing: bool, _slow_power: float, _slow_dur: float) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_world_unlock(_stage: int, _radius: float) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_player_cast(_caster_id: int, _skill_id: String, _pos: Vector3, _dir: Vector3, _level: int) -> void: pass
@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_monster_damaged(_mid: int, _amount: int, _pos: Vector3) -> void: pass
@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_monster_action(_mid: int, _pos: Vector3) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_monster_combo(_mid: int, _info: Dictionary) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_drop_taken(_drop_id: int, _taker_id: int) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_region_locks(_locked: Array) -> void: pass
@rpc("authority", "call_remote", "reliable")
func rpc_force_position(_pos: Vector3) -> void: pass
