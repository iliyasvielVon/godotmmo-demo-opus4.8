extends Node

# 激励广告服务（autoload: AdService）。
# 参考 towerads 项目的 ad_service 思路，做成与具体奖励解耦的通用版本：
#   - Android + DirichletAd 插件：走 Dirichlet/TapADN 激励视频。
#   - 编辑器 / PC / 未装插件：走内置 MockAdDialog（占位计时弹窗），便于本地测试。
# 调用方 AdService.show_rewarded_ad()，然后监听一次 ad_finished(rewarded) 决定是否发奖。
# Dirichlet 参数读取自 project.godot 的 [dirichlet]/[taptap]：ad/media_id, media_name, media_key, reward_space_id。
#
# 插件回调码：200 加载,201 展示,202 关闭,203 播放完成,204 错误,205 激励完成,206 跳过,207 点击,500 加载失败

signal ad_started
signal ad_finished(rewarded: bool)

const AD_DURATION: float = 8.0

const AD_LOAD_FAILED := 500
const AD_LOADED := 200
const AD_SHOWN := 201
const AD_CLOSED := 202
const AD_VIDEO_FINISHED := 203
const AD_VIDEO_ERROR := 204
const AD_REWARD_COMPLETED := 205
const AD_SKIPPED := 206
const AD_CLICKED := 207

var _busy: bool = false
var _dirichlet: Object = null
var _dirichlet_ready: bool = false
var _taptap: Object = null
var _taptap_ready: bool = false
var _sdk_show_pending: bool = false
var _sdk_reward_granted: bool = false
var _using_sdk: bool = false
var _using_dirichlet: bool = false
var _last_code: int = -1            # 最近一次 SDK 回调码（诊断用）
var _last_msg: String = ""          # 最近一次回调附带信息
var _last_path: String = "未触发"   # 上次走的路径：dirichlet/taptap/mock

# 真机诊断：把广告链路当前状态拼成一行，方便在死亡面板上直接看出卡在哪一步。
func sdk_status() -> String:
	var has_d: bool = Engine.has_singleton("DirichletAd")
	var d_init: bool = false
	if _dirichlet != null and _dirichlet.has_method("isInitialized"):
		d_init = bool(_dirichlet.call("isInitialized"))
	return "安卓=%s | DirichletAd单例=%s | 已初始化=%s | 路径=%s | 回调码=%d %s" % [
		str(_is_android_runtime()), str(has_d), str(d_init), _last_path, _last_code, _last_msg]

func _ready() -> void:
	_try_setup_dirichlet()
	_try_setup_taptap()

func is_available() -> bool:
	return not _busy

func show_rewarded_ad() -> void:
	if _busy:
		return
	_busy = true
	ad_started.emit()
	_play_ad()

# ---------------- 路由 ----------------
func _play_ad() -> void:
	if _should_use_dirichlet():
		_last_path = "dirichlet"
		_play_dirichlet()
		return
	if _should_use_taptap():
		_last_path = "taptap"
		_play_taptap()
		return
	_last_path = "mock(占位)"
	_play_mock()

func _is_android_runtime() -> bool:
	if OS.has_feature("editor"):
		return false
	return OS.has_feature("android") or OS.has_feature("mobile")

func _get_ad_setting(name: String, default_value: String = "") -> String:
	var v := String(ProjectSettings.get_setting("dirichlet/ad/%s" % name, ""))
	if v != "":
		return v
	return String(ProjectSettings.get_setting("taptap/ad/%s" % name, default_value))

# ---------------- Dirichlet ----------------
func _should_use_dirichlet() -> bool:
	if not _is_android_runtime():
		return false
	if _dirichlet == null:
		_try_setup_dirichlet()
	return _dirichlet != null

func _try_setup_dirichlet() -> void:
	if _dirichlet != null or not Engine.has_singleton("DirichletAd"):
		return
	_dirichlet = Engine.get_singleton("DirichletAd")
	if _dirichlet == null:
		return
	var cb := Callable(self, "_on_dirichlet_callback")
	if _dirichlet.has_signal("onRewardVideoAdCallBack") and not _dirichlet.is_connected("onRewardVideoAdCallBack", cb):
		_dirichlet.connect("onRewardVideoAdCallBack", cb)
	_init_dirichlet()

func _init_dirichlet() -> void:
	if _dirichlet == null or _dirichlet_ready:
		return
	var mid := _get_ad_setting("media_id")
	var mname := _get_ad_setting("media_name")
	var mkey := _get_ad_setting("media_key")
	if _missing(mid) or _missing(mname) or _missing(mkey):
		return
	if bool(_dirichlet.call("initAd", mid, mname, mkey, true)):
		_dirichlet_ready = bool(_dirichlet.call("isInitialized"))

func _play_dirichlet() -> void:
	if _dirichlet == null:
		_abort()
		return
	if not bool(_dirichlet.call("isInitialized")):
		_init_dirichlet()
	var space := _get_ad_setting("reward_space_id")
	if _missing(space):
		_play_mock()
		return
	_sdk_reward_granted = false
	_using_sdk = true
	_using_dirichlet = true
	var ok = _dirichlet.call("showRewardVideoAd", space, _get_ad_setting("reward_name", "复活"), _get_ad_setting("extra_info", "revive"), _user_id())
	if not bool(ok):
		_reset_sdk()
		_abort()

func _on_dirichlet_callback(code: int, message: String = "") -> void:
	if not _using_sdk or not _using_dirichlet:
		return
	_handle_callback(int(code), String(message))

# ---------------- TapTap 兜底 ----------------
func _should_use_taptap() -> bool:
	if not _is_android_runtime():
		return false
	if _taptap == null:
		_try_setup_taptap()
	return _taptap != null and _taptap_ready

func _try_setup_taptap() -> void:
	if _taptap != null or not Engine.has_singleton("GodotTapTapSDK"):
		return
	_taptap = Engine.get_singleton("GodotTapTapSDK")
	if _taptap == null:
		return
	var cb := Callable(self, "_on_taptap_callback")
	if _taptap.has_signal("onRewardVideoAdCallBack") and not _taptap.is_connected("onRewardVideoAdCallBack", cb):
		_taptap.connect("onRewardVideoAdCallBack", cb)
	var mid := _get_ad_setting("media_id")
	var mname := _get_ad_setting("media_name")
	var mkey := _get_ad_setting("media_key")
	if _missing(mid) or _missing(mname) or _missing(mkey):
		return
	if _taptap.has_method("adnInit"):
		_taptap.call("adnInit", mid, mname, mkey)
	elif _taptap.has_method("initAd"):
		_taptap.call("initAd", mid, mname, mkey)
	else:
		return
	_taptap_ready = true

func _play_taptap() -> void:
	var space := _get_ad_setting("reward_space_id")
	if _missing(space):
		_play_mock()
		return
	_sdk_show_pending = true
	_sdk_reward_granted = false
	_using_sdk = true
	_using_dirichlet = false
	if _taptap.has_method("initRewardVideoAd"):
		_taptap.call("initRewardVideoAd", space, _get_ad_setting("reward_name", "复活"), _get_ad_setting("extra_info", "revive"), _user_id())
	else:
		_reset_sdk()
		_play_mock()

func _on_taptap_callback(code: int) -> void:
	if not _using_sdk or _using_dirichlet:
		return
	if int(code) == AD_LOADED:
		if _sdk_show_pending and _taptap != null and _taptap.has_method("showRewardVideoAd"):
			_sdk_show_pending = false
			_taptap.call("showRewardVideoAd")
		return
	_handle_callback(int(code), "")

# ---------------- 回调处理 ----------------
func _handle_callback(code: int, message: String = "") -> void:
	_last_code = code
	_last_msg = message
	match code:
		AD_REWARD_COMPLETED:
			if not _sdk_reward_granted:
				_sdk_reward_granted = true
				_reset_sdk()
				_grant()
		AD_CLOSED:
			if not _sdk_reward_granted:
				_reset_sdk()
				_abort()
		AD_LOAD_FAILED, AD_VIDEO_ERROR, AD_SKIPPED:
			_reset_sdk()
			_abort()
		_:
			pass

func _missing(v: String) -> bool:
	return v == "" or v.begins_with("TODO")

func _user_id() -> String:
	return OS.get_unique_id()

func _reset_sdk() -> void:
	_sdk_show_pending = false
	_using_sdk = false
	_using_dirichlet = false

func _grant() -> void:
	_busy = false
	ad_finished.emit(true)

func _abort() -> void:
	_busy = false
	ad_finished.emit(false)

# ---------------- PC/编辑器占位广告 ----------------
func _play_mock() -> void:
	var dlg := MockAdDialog.new()
	dlg.duration = AD_DURATION
	dlg.completed.connect(_grant)
	dlg.skipped.connect(_abort)
	var tree := get_tree()
	if tree == null or tree.root == null:
		_abort()
		return
	tree.root.add_child(dlg)

class MockAdDialog:
	extends CanvasLayer

	signal completed
	signal skipped

	var duration: float = 8.0
	var _elapsed: float = 0.0
	var _emitted: bool = false
	var _time_label: Label
	var _progress: ProgressBar
	var _skip_button: Button

	func _ready() -> void:
		layer = 120
		var dim := ColorRect.new()
		dim.color = Color(0, 0, 0, 0.88)
		dim.anchor_right = 1.0
		dim.anchor_bottom = 1.0
		dim.mouse_filter = Control.MOUSE_FILTER_STOP
		add_child(dim)

		var stage := Panel.new()
		stage.anchor_left = 0.5
		stage.anchor_top = 0.5
		stage.anchor_right = 0.5
		stage.anchor_bottom = 0.5
		stage.offset_left = -280
		stage.offset_top = -160
		stage.offset_right = 280
		stage.offset_bottom = 160
		stage.add_theme_stylebox_override("panel", _style(Color(0.10, 0.12, 0.18, 1), Color(0.45, 0.85, 1.0, 0.95)))
		add_child(stage)

		var tag := Label.new()
		tag.text = "广告"
		tag.position = Vector2(16, 12)
		tag.add_theme_font_size_override("font_size", 14)
		tag.add_theme_color_override("font_color", Color(0.5, 0.9, 1.0, 1))
		stage.add_child(tag)

		var headline := Label.new()
		headline.text = "[激励广告占位]\n编辑器/PC 或未安装插件时显示\nAndroid 打包并配置参数后会调用真实激励广告\n\n看完即可复活"
		headline.anchor_right = 1.0
		headline.anchor_bottom = 1.0
		headline.offset_left = 16
		headline.offset_top = 54
		headline.offset_right = -16
		headline.offset_bottom = -90
		headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		headline.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		headline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		headline.add_theme_font_size_override("font_size", 20)
		headline.add_theme_color_override("font_color", Color(0.9, 0.94, 1.0, 1))
		stage.add_child(headline)

		_progress = ProgressBar.new()
		_progress.min_value = 0.0
		_progress.max_value = duration
		_progress.show_percentage = false
		_progress.anchor_top = 1.0
		_progress.anchor_right = 1.0
		_progress.anchor_bottom = 1.0
		_progress.offset_left = 16
		_progress.offset_top = -68
		_progress.offset_right = -16
		_progress.offset_bottom = -52
		stage.add_child(_progress)

		_time_label = Label.new()
		_time_label.text = "%d s" % int(ceil(duration))
		_time_label.anchor_top = 1.0
		_time_label.anchor_right = 1.0
		_time_label.anchor_bottom = 1.0
		_time_label.offset_left = 16
		_time_label.offset_top = -44
		_time_label.offset_right = -16
		_time_label.offset_bottom = -16
		_time_label.add_theme_font_size_override("font_size", 14)
		_time_label.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0, 1))
		stage.add_child(_time_label)

		_skip_button = Button.new()
		_skip_button.text = "跳过（不复活）"
		_skip_button.anchor_left = 1.0
		_skip_button.anchor_top = 1.0
		_skip_button.anchor_right = 1.0
		_skip_button.anchor_bottom = 1.0
		_skip_button.offset_left = -156
		_skip_button.offset_top = -42
		_skip_button.offset_right = -16
		_skip_button.offset_bottom = -14
		_skip_button.focus_mode = Control.FOCUS_NONE
		_skip_button.add_theme_font_size_override("font_size", 13)
		_skip_button.pressed.connect(_on_skip)
		stage.add_child(_skip_button)

	func _process(delta: float) -> void:
		if _emitted:
			return
		_elapsed += delta
		_progress.value = minf(_elapsed, duration)
		_time_label.text = "%d s" % int(ceil(maxf(0.0, duration - _elapsed)))
		if _elapsed >= duration:
			_emitted = true
			completed.emit()
			queue_free()

	func _on_skip() -> void:
		if _emitted:
			return
		_emitted = true
		skipped.emit()
		queue_free()

	func _style(bg: Color, border: Color) -> StyleBoxFlat:
		var s := StyleBoxFlat.new()
		s.bg_color = bg
		s.set_border_width_all(2)
		s.border_color = border
		s.set_corner_radius_all(12)
		return s
