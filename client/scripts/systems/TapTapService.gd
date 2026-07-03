extends Node

# TapTap 账号桥接（autoload: TapTap）。封装 addons/GodotTapTapSDK 的登录/昵称；
# 仅安卓真机有 SDK，PC/编辑器为空实现。用于把「游戏名」同步成 TapTap 昵称。
# 说明：登录/资料外，另提供单机数据同步（sync_save / sync_solo_stats，云存档为主，
# 见文件下方）；TapTap 排行榜仍未接，排名在本地实现（见 Main 的本地排行榜）。

signal login_changed(logged_in: bool)

var _tt: Object = null
var _name: String = ""
var logged_in: bool = false

func _ready() -> void:
	if Engine.has_singleton("GodotTapTapSDK"):
		_tt = Engine.get_singleton("GodotTapTapSDK")
		if _tt.has_signal("onLoginResult") and not _tt.is_connected("onLoginResult", _on_login_result):
			_tt.connect("onLoginResult", _on_login_result)
		_init_sdk()

func _init_sdk() -> void:
	var cid: String = String(ProjectSettings.get_setting("taptap/login/client_id", ""))
	var ctok: String = String(ProjectSettings.get_setting("taptap/login/client_token", ""))
	var surl: String = String(ProjectSettings.get_setting("taptap/login/server_url", ""))
	if _tt != null and _tt.has_method("init") and cid != "" and not cid.begins_with("TODO"):
		_tt.call("init", cid, ctok, surl)

func available() -> bool:
	return _tt != null

func is_logged_in() -> bool:
	if _tt != null and _tt.has_method("isLogin"):
		return bool(_tt.call("isLogin"))
	return logged_in

func login() -> void:
	if _tt != null and _tt.has_method("login"):
		_tt.call("login")

func logout() -> void:
	if _tt != null and _tt.has_method("logOut"):
		_tt.call("logOut")
	logged_in = false
	_name = ""
	login_changed.emit(false)

func _on_login_result(code: int, json) -> void:
	logged_in = int(code) == 200 or int(code) == 0
	_parse_name(str(json))
	login_changed.emit(logged_in)

func _parse_name(profile_json: String) -> void:
	var d: Variant = JSON.parse_string(profile_json)
	if d is Dictionary:
		var n: String = String((d as Dictionary).get("name", (d as Dictionary).get("nickname", "")))
		if n != "":
			_name = n

# ---------------------------------------------------------------------------
# 单机数据 → TapTap 同步（云存档为主 + 预留打点接口）
# 运行时若安卓单例提供对应方法则调用，否则在 PC/编辑器静默跳过（与本桥接其余方法一致）。
# 正式启用云存档：把官方 godot-taptap 云存档插件（含云存档方法的 .aar/.gdap）
# 复制进 addons/GodotTapTapSDK，使安卓单例暴露下列任一方法名即可自动接通。
# ---------------------------------------------------------------------------
const _CLOUD_SAVE_METHODS := ["saveToCloud", "cloudSave", "saveArchive", "updateArchive", "uploadArchive"]
const _STAT_METHODS := ["syncStats", "submitStats", "trackEvent"]
var _cloud_warned: bool = false

# 把整份存档（含等级 / 游戏时长 / Boss 击杀记录）推送到 TapTap 云存档。
func sync_save(save: Dictionary, summary: String = "") -> void:
	if _tt == null:
		return
	if summary == "":
		summary = "Lv.%d · %d秒" % [int(save.get("level", 1)), int(save.get("play_seconds", 0))]
	var json: String = JSON.stringify(save)
	for m: String in _CLOUD_SAVE_METHODS:
		if _tt.has_method(m):
			_tt.call(m, "starglory_save", summary, json)
			return
	if not _cloud_warned:
		_cloud_warned = true
		push_warning("TapTap 云存档方法不可用：请补齐 addons/GodotTapTapSDK 的云存档安卓插件后启用。")

# 单机 Boss 击杀打点：同步「等级 / 游戏时长 / 单场 Boss 战斗时长 / 击杀时属性」。
func sync_solo_stats(stats: Dictionary) -> void:
	if _tt == null:
		return
	var json: String = JSON.stringify(stats)
	for m: String in _STAT_METHODS:
		if _tt.has_method(m):
			_tt.call(m, "solo_boss_kill", json)
			return
	# 没有专用统计接口时退化为日志，便于排查/后续补接（数据仍随云存档同步）。
	print("[TapTap] solo boss-kill stats (pending sync): ", json)

# TapTap 昵称（没有则空串）。
func nickname() -> String:
	if _name != "":
		return _name
	if _tt != null and _tt.has_method("getCurrentProfile"):
		_parse_name(String(_tt.call("getCurrentProfile")))
	return _name
