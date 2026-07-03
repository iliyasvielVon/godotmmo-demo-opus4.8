extends Node

# TapTap SDK GDScript 包装（适配 godothub/godot-taptap）。
# 正式打 Android 包前，请把官方仓库/Release 中 addons/GodotTapTapSDK 的
# .gdap / .aar / Android 插件文件一并复制进本目录。
# 本脚本只负责把 Engine 单例包装成 Godot 信号和方法，便于场景或 Autoload 调用。

signal onLoginResult(code, json)
signal onAntiAddictionCallback(code)
signal onTapMomentCallBack(code)
signal onRewardVideoAdCallBack(code)

var singleton: Object = null

func _ready() -> void:
	if not Engine.has_singleton("GodotTapTapSDK"):
		push_warning("GodotTapTapSDK Android singleton not found. This is normal in editor/PC builds.")
		return
	singleton = Engine.get_singleton("GodotTapTapSDK")
	_connect_signal("onLoginResult", Callable(self, "_on_login_result"))
	_connect_signal("onAntiAddictionCallback", Callable(self, "_on_anti_addiction_callback"))
	_connect_signal("onTapMomentCallBack", Callable(self, "_on_tap_moment_callback"))
	_connect_signal("onRewardVideoAdCallBack", Callable(self, "_on_reward_video_ad_callback"))

func init(client_id: String, client_token: String, server_url: String) -> void:
	if singleton != null and singleton.has_method("init"):
		singleton.call("init", client_id, client_token, server_url)

func tap_login() -> void:
	if singleton != null and singleton.has_method("login"):
		singleton.call("login")

func isLogin() -> bool:
	return bool(singleton.call("isLogin")) if singleton != null and singleton.has_method("isLogin") else false

func getCurrentProfile() -> String:
	return String(singleton.call("getCurrentProfile")) if singleton != null and singleton.has_method("getCurrentProfile") else ""

func logOut() -> void:
	if singleton != null and singleton.has_method("logOut"):
		singleton.call("logOut")

func quickCheck(id = null) -> void:
	if id == null:
		id = OS.get_unique_id()
	if singleton != null and singleton.has_method("quickCheck"):
		singleton.call("quickCheck", id)

func antiExit() -> void:
	if singleton != null and singleton.has_method("antiExit"):
		singleton.call("antiExit")

func setTestEnvironment(enable: bool) -> void:
	if singleton != null and singleton.has_method("setTestEnvironment"):
		singleton.call("setTestEnvironment", enable)

func setEntryVisible(enable: bool) -> void:
	if singleton != null and singleton.has_method("setEntryVisible"):
		singleton.call("setEntryVisible", enable)

func momentOpen(ori: int = -1) -> void:
	if singleton != null and singleton.has_method("momentOpen"):
		singleton.call("momentOpen", ori)

func initAd(media_id: String, media_name: String, media_key: String) -> void:
	if singleton == null:
		return
	if singleton.has_method("adnInit"):
		singleton.call("adnInit", media_id, media_name, media_key)
	elif singleton.has_method("initAd"):
		singleton.call("initAd", media_id, media_name, media_key)

func initRewardVideoAd(space_id: String, reward_name: String, extra_info: String, user_id: String) -> void:
	if singleton != null and singleton.has_method("initRewardVideoAd"):
		singleton.call("initRewardVideoAd", space_id, reward_name, extra_info, user_id)

func showRewardVideoAd() -> void:
	if singleton != null and singleton.has_method("showRewardVideoAd"):
		singleton.call("showRewardVideoAd")

func _connect_signal(signal_name: String, callable: Callable) -> void:
	if singleton != null and singleton.has_signal(signal_name) and not singleton.is_connected(signal_name, callable):
		singleton.connect(signal_name, callable)

func _on_login_result(code, json) -> void:
	onLoginResult.emit(code, json)

func _on_anti_addiction_callback(code) -> void:
	onAntiAddictionCallback.emit(code)

func _on_tap_moment_callback(code) -> void:
	onTapMomentCallBack.emit(code)

func _on_reward_video_ad_callback(code) -> void:
	onRewardVideoAdCallBack.emit(code)
