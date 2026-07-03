extends Node

# AccountDB —— 账号与角色存档持久化（autoload "Accounts"）。
# accounts.json: { 用户名: {salt, hash} }；saves/<用户名>.json: 角色存档字典。
# 密码以 SHA-256(salt + password) 存储，绝不明文落盘。首次登录某用户名即自动注册。

var data_dir: String = ""
var accounts: Dictionary = {}
var admins: Dictionary = {}   # 小写用户名 -> 管理员等级(int)；来自 data_dir/admins.json
var fixed_admins: Dictionary = {}   # Config-locked admins that cannot be lowered at runtime.

func setup(dir: String) -> void:
	data_dir = dir
	DirAccess.make_dir_recursive_absolute(data_dir)
	DirAccess.make_dir_recursive_absolute(_saves_dir())
	accounts = _read_json(_accounts_path())
	dungeon_records = _read_json(_dungeon_path())
	ad_views = _read_json(_adviews_path())
	_load_admins()
	print("[Accounts] 数据目录: %s（已注册账号 %d 个，管理员 %d 个）" % [data_dir, accounts.size(), admins.size()])

func _load_admins() -> void:
	admins = {}
	var raw: Dictionary = _read_json(data_dir.path_join("admins.json"))
	for k: String in raw.keys():
		admins[String(k).to_lower()] = int(raw[k])

# 管理员等级（非管理员为 0）。
func admin_level(user: String) -> int:
	var key: String = user.strip_edges().to_lower()
	return maxi(int(admins.get(key, 0)), int(fixed_admins.get(key, 0)))

func set_fixed_admin(user: String, level: int) -> void:
	var key: String = user.strip_edges().to_lower()
	if key == "" or level <= 0:
		return
	fixed_admins[key] = level
	if int(admins.get(key, 0)) < level:
		admins[key] = level
		_write_json(data_dir.path_join("admins.json"), admins)

func ensure_account_password(user: String, password: String, nickname: String = "") -> bool:
	var u: String = user.strip_edges()
	var pmin := int(GameData.proto("password_min", 3))
	var pmax := int(GameData.proto("password_max", 32))
	if u == "" or password.length() < pmin or password.length() > pmax:
		return false
	var key: String = u.to_lower()
	var rec: Dictionary = accounts.get(key, {})
	var salt := _new_salt()
	if rec.is_empty():
		var ordinal: int = accounts.size() + 1
		var nick: String = nickname.strip_edges()
		if nick == "":
			nick = u
		rec = {"name": nick.substr(0, 16), "avatar": "", "ordinal": ordinal}
	rec["salt"] = salt
	rec["hash"] = _hash(salt, password)
	accounts[key] = rec
	return _write_json(_accounts_path(), accounts)

# 设置/移除管理员（level<=0 移除），并落盘 admins.json。
func set_admin_level(user: String, level: int) -> void:
	var key: String = user.strip_edges().to_lower()
	if key == "":
		return
	var fixed_level: int = int(fixed_admins.get(key, 0))
	if fixed_level > 0 and level < fixed_level:
		admins[key] = fixed_level
		_write_json(data_dir.path_join("admins.json"), admins)
		return
	if level <= 0:
		admins.erase(key)
	else:
		admins[key] = level
	_write_json(data_dir.path_join("admins.json"), admins)

# ---------------- 公告 / MOTD（存 announcements.json）----------------
func _ann_path() -> String:
	return data_dir.path_join("announcements.json")

func motd() -> String:
	return String(_read_json(_ann_path()).get("motd", ""))

func set_motd(text: String) -> void:
	_write_json(_ann_path(), {"motd": text, "ts": int(Time.get_unix_time_from_system())})

# ---------------- 全服世界状态（据点建造/加固进度，存 world_state.json）----------------
func load_world_state() -> Dictionary:
	return _read_json(data_dir.path_join("world_state.json"))

func store_world_state(state: Dictionary) -> bool:
	return _write_json(data_dir.path_join("world_state.json"), state)

# ---------------- 广告观看次数（存 ad_views.json，按账号累计）----------------
var ad_views: Dictionary = {}

func _adviews_path() -> String:
	return data_dir.path_join("ad_views.json")

func add_ad_view(user: String) -> int:
	if ad_views.is_empty():
		ad_views = _read_json(_adviews_path())
	var k: String = user.strip_edges().to_lower()
	var n: int = int(ad_views.get(k, 0)) + 1
	ad_views[k] = n
	_write_json(_adviews_path(), ad_views)
	return n

func ad_view_count(user: String) -> int:
	if ad_views.is_empty():
		ad_views = _read_json(_adviews_path())
	return int(ad_views.get(user.strip_edges().to_lower(), 0))

# ---------------- 副本通关记录（存 dungeon_records.json）----------------
var dungeon_records: Dictionary = {}

func _dungeon_path() -> String:
	return data_dir.path_join("dungeon_records.json")

# 记录一次通关。返回 {first:bool}（是否全服首杀该类型）。eligible=队伍全员在准入等级+5 以内才计入记录。
func record_dungeon_clear(did: int, hidden: bool, secs: float, party: Array, levels: Array, eligible: bool) -> Dictionary:
	if dungeon_records.is_empty():
		dungeon_records = _read_json(_dungeon_path())
	var key: String = str(did)
	var rec: Dictionary = dungeon_records.get(key, {})
	var field: String = "hidden_first" if hidden else "boss_first"
	var first: bool = false
	var entry := {"party": party, "levels": levels, "time": snappedf(secs, 0.1), "ts": int(Time.get_unix_time_from_system())}
	if eligible and not rec.has(field):
		rec[field] = entry
		first = true
	if eligible and not hidden:
		if not rec.has("best") or secs < float((rec["best"] as Dictionary).get("time", 1.0e9)):
			rec["best"] = entry
	dungeon_records[key] = rec
	_write_json(_dungeon_path(), dungeon_records)
	return {"first": first}

func _accounts_path() -> String:
	return data_dir.path_join("accounts.json")

func _saves_dir() -> String:
	return data_dir.path_join("saves")

func _save_path(user: String) -> String:
	return _saves_dir().path_join("%s.json" % user.to_lower())

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}

func _write_json(path: String, value: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[Accounts] 写入失败: %s" % path)
		return false
	f.store_string(JSON.stringify(value, "\t"))
	f.close()
	return true

func _hash(salt: String, password: String) -> String:
	return (salt + ":" + password).sha256_text()

func _new_salt() -> String:
	var crypto := Crypto.new()
	return crypto.generate_random_bytes(16).hex_encode()

# 校验或注册。返回 {ok:bool, reason:String, created:bool}。
func authenticate(user: String, password: String) -> Dictionary:
	var u := user.strip_edges()
	var umin := int(GameData.proto("username_min", 2))
	var umax := int(GameData.proto("username_max", 16))
	var pmin := int(GameData.proto("password_min", 3))
	var pmax := int(GameData.proto("password_max", 32))
	if u.length() < umin or u.length() > umax:
		return {"ok": false, "reason": "用户名长度需 %d-%d" % [umin, umax], "created": false}
	if password.length() < pmin or password.length() > pmax:
		return {"ok": false, "reason": "密码长度需 %d-%d" % [pmin, pmax], "created": false}
	var key := u.to_lower()
	# 登录：要求账号已存在（不再自动注册）。返回登录标识 user 与显示昵称 name、头像 avatar。
	if not accounts.has(key):
		return {"ok": false, "reason": "账号不存在，请先注册", "created": false}
	var rec: Dictionary = accounts[key]
	if _hash(String(rec.get("salt", "")), password) != String(rec.get("hash", "")):
		return {"ok": false, "reason": "密码错误", "created": false}
	return {"ok": true, "reason": "", "created": false, "user": u, "name": String(rec.get("name", u)), "avatar": String(rec.get("avatar", ""))}

# 注册新账号：昵称留空则用「玩家<序号>」，头像为 base64 PNG（空=默认随机色）。
func register(user: String, password: String, nickname: String, avatar: String) -> Dictionary:
	var u := user.strip_edges()
	var umin := int(GameData.proto("username_min", 2))
	var umax := int(GameData.proto("username_max", 16))
	var pmin := int(GameData.proto("password_min", 3))
	var pmax := int(GameData.proto("password_max", 32))
	if u.length() < umin or u.length() > umax:
		return {"ok": false, "reason": "用户名长度需 %d-%d" % [umin, umax]}
	if password.length() < pmin or password.length() > pmax:
		return {"ok": false, "reason": "密码长度需 %d-%d" % [pmin, pmax]}
	var key := u.to_lower()
	if accounts.has(key):
		return {"ok": false, "reason": "该用户名已被注册，请直接登录"}
	var ordinal: int = accounts.size() + 1
	var nick := nickname.strip_edges()
	if nick == "":
		nick = "玩家%d" % ordinal
	elif nick.length() > 16:
		nick = nick.substr(0, 16)
	var av: String = avatar if avatar.length() < 40000 else ""   # 限制头像大小
	var salt := _new_salt()
	accounts[key] = {"salt": salt, "hash": _hash(salt, password), "name": nick, "avatar": av, "ordinal": ordinal}
	_write_json(_accounts_path(), accounts)
	return {"ok": true, "reason": "", "created": true, "user": u, "name": nick, "avatar": av}

func profile(user: String) -> Dictionary:
	var rec: Dictionary = accounts.get(user.to_lower(), {})
	return {"name": String(rec.get("name", user)), "avatar": String(rec.get("avatar", ""))}

# 修改昵称（留空不改）与头像（非空则更新；base64 PNG）。
func set_profile(user: String, nickname: String, avatar: String) -> Dictionary:
	var key := user.to_lower()
	if not accounts.has(key):
		return {"ok": false}
	var nick := nickname.strip_edges()
	if nick != "":
		accounts[key]["name"] = nick.substr(0, 16)
	if avatar != "" and avatar.length() < 40000:
		accounts[key]["avatar"] = avatar
	_write_json(_accounts_path(), accounts)
	return {"ok": true, "name": String(accounts[key]["name"]), "avatar": String(accounts[key].get("avatar", ""))}

func load_save(user: String) -> Dictionary:
	return _read_json(_save_path(user))

func store_save(user: String, save: Dictionary) -> bool:
	return _write_json(_save_path(user), save)

# 断线/托管快照：把下线时的即时状态（位置/血/蓝/耐力）写入存档，供重连恢复。
func set_resume(user: String, resume: Dictionary) -> void:
	if user.strip_edges() == "":
		return
	var s: Dictionary = load_save(user)
	s["_resume"] = resume
	store_save(user, s)

func clear_resume(user: String) -> void:
	if user.strip_edges() == "":
		return
	var s: Dictionary = load_save(user)
	if s.has("_resume"):
		s.erase("_resume")
		store_save(user, s)
