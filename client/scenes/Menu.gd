extends Control

# 欢迎页 / 主菜单：星空背景 + 启动器卡片（单机 / 联机两个标签），美化的网游登录界面。
# 功能：单机即点即玩、新开档案、联机账号登录（记住账号）、关于、退出。

# —— 联机服务器（脚本内固定，玩家不可见/不可改）——43.142.159.66 127.0.0.1
const SERVER_HOST := "43.142.159.66"
#const SERVER_HOST := "127.0.0.1"
const SERVER_PORT := 9000

# —— 配色 ——
const BG_TOP := Color(0.05, 0.07, 0.16, 1)
const BG_BOT := Color(0.015, 0.02, 0.05, 1)
const ACCENT := Color(0.45, 0.85, 1.0, 1)      # 主题青
const ACCENT2 := Color(1.0, 0.82, 0.38, 1)     # 点缀金
const PANEL_BG := Color(0.07, 0.09, 0.17, 0.94)
const PANEL_BORDER := Color(0.32, 0.55, 0.85, 0.55)
const FIELD_BG := Color(0.05, 0.07, 0.13, 0.96)
const TEXT := Color(0.84, 0.91, 1.0, 1)
const TEXT_DIM := Color(0.56, 0.67, 0.86, 1)

var about_panel: Panel = null
var host_edit: LineEdit
var port_edit: LineEdit
var user_edit: LineEdit
var pass_edit: LineEdit
var nick_edit: LineEdit
var connect_btn: Button
var register_btn: Button
var reg_section: Control = null       # 注册专属区域（昵称+头像），登录时隐藏
var avatar_preview: TextureRect = null
var reg_avatar_b64: String = ""       # 上传的头像（base64 PNG）；空=默认随机色
var _reg_mode: bool = false           # 是否处于「注册」展开态
var _avatar_dialog: FileDialog = null
var status_label: Label
var account_picker: OptionButton
var remember_check: CheckBox

var solo_panel: Control = null
var online_panel: Control = null
var tab_solo_btn: Button = null
var tab_online_btn: Button = null
var title_label: Label = null

# 背景动效状态
var _t: float = 0.0
var stars: Array = []      # [{node, base, phase, speed}]
var orbs: Array = []       # [{node, home, amp, speed, phase}]

# 本地记住的账号（明文存于 user://login_accounts.json，仅本机便捷登录用，非安全存储）。
var saved: Dictionary = {}
var _attempt: Dictionary = {}   # 本次尝试的 host/port/user/pass，登录成功后据此记住

func _notification(what: int) -> void:
	# auto_accept_quit=false：菜单场景需自行处理关窗退出。
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		get_tree().quit()

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)   # 菜单一定显示鼠标
	if not get_window().files_dropped.is_connected(_on_files_dropped):
		get_window().files_dropped.connect(_on_files_dropped)   # 拖拽图片当头像

	# 本地快速测试：命令行带 --solo / --solo-load 直接进单机，跳过登录菜单。
	var cli_args := OS.get_cmdline_user_args() + OS.get_cmdline_args()
	if cli_args.has("--solo") or cli_args.has("--solo-load"):
		_on_solo_play()
		return

	Audio.play_music("menu")
	saved = _load_creds()
	theme = _build_theme()

	_build_background()
	_build_title()
	_build_card()
	_build_bottom_bar()
	_build_about_panel()

	_refresh_account_picker()
	var last_user := String(saved.get("last", ""))
	if last_user != "" and _accounts().has(last_user):
		user_edit.text = last_user
		pass_edit.text = String((_accounts()[last_user] as Dictionary).get("pass", ""))

	_show_tab("solo")

# ====================================================================
#  背景：渐变 + 星点 + 光晕球
# ====================================================================

func _build_background() -> void:
	var vp: Vector2 = get_viewport_rect().size

	# 竖直渐变底
	var bg := TextureRect.new()
	bg.texture = _gradient_tex(BG_TOP, BG_BOT, false)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 柔光球（缓慢漂浮，营造星云氛围）
	for cfg in [
		{"c": ACCENT, "size": 620.0, "pos": Vector2(vp.x * 0.18, vp.y * 0.24), "a": 0.16},
		{"c": Color(0.7, 0.4, 1.0, 1), "size": 540.0, "pos": Vector2(vp.x * 0.84, vp.y * 0.72), "a": 0.14},
		{"c": ACCENT2, "size": 420.0, "pos": Vector2(vp.x * 0.70, vp.y * 0.16), "a": 0.10},
	]:
		var orb := TextureRect.new()
		orb.texture = _radial_tex(cfg["c"] as Color)
		var s: float = cfg["size"]
		orb.custom_minimum_size = Vector2(s, s)
		orb.size = Vector2(s, s)
		orb.modulate = Color(1, 1, 1, cfg["a"])
		var home: Vector2 = (cfg["pos"] as Vector2) - Vector2(s, s) * 0.5
		orb.position = home
		orb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(orb)
		orbs.append({"node": orb, "home": home, "amp": randf_range(14.0, 30.0), "speed": randf_range(0.12, 0.28), "phase": randf() * TAU})

	# 星点（轻微闪烁）
	var star_layer := Control.new()
	star_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	star_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(star_layer)
	for i in range(90):
		var star := ColorRect.new()
		var sz: float = randf_range(1.0, 2.6)
		star.size = Vector2(sz, sz)
		star.position = Vector2(randf() * vp.x, randf() * vp.y)
		var warm: bool = randf() < 0.25
		star.color = ACCENT2 if warm else Color(0.85, 0.93, 1.0, 1)
		star.mouse_filter = Control.MOUSE_FILTER_IGNORE
		star_layer.add_child(star)
		var base_a: float = randf_range(0.25, 0.9)
		star.modulate = Color(1, 1, 1, base_a)
		stars.append({"node": star, "base": base_a, "phase": randf() * TAU, "speed": randf_range(0.6, 2.2)})

func _process(delta: float) -> void:
	_t += delta
	for s in stars:
		var a: float = float(s["base"]) * (0.45 + 0.55 * sin(_t * float(s["speed"]) + float(s["phase"])))
		(s["node"] as ColorRect).modulate.a = clampf(a, 0.0, 1.0)
	for o in orbs:
		var home: Vector2 = o["home"]
		var amp: float = o["amp"]
		var sp: float = o["speed"]
		var ph: float = o["phase"]
		(o["node"] as TextureRect).position = home + Vector2(sin(_t * sp + ph) * amp, cos(_t * sp * 0.8 + ph) * amp)
	if title_label != null:
		# 标题的描边随呼吸轻微发光。
		var glow: float = 0.55 + 0.25 * sin(_t * 1.6)
		title_label.add_theme_color_override("font_outline_color", Color(ACCENT.r, ACCENT.g, ACCENT.b, glow))

# ====================================================================
#  标题
# ====================================================================

func _build_title() -> void:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	box.position = Vector2(-460, 44)
	box.size = Vector2(920, 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)

	title_label = Label.new()
	title_label.text = "星  辉  荣  耀"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 58)
	title_label.add_theme_color_override("font_color", Color(0.92, 0.97, 1.0, 1))
	title_label.add_theme_constant_override("outline_size", 10)
	title_label.add_theme_color_override("font_outline_color", ACCENT)
	box.add_child(title_label)

	var en := Label.new()
	en.text = "S T A R   G L O R Y   M M O"
	en.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	en.add_theme_font_size_override("font_size", 18)
	en.add_theme_color_override("font_color", ACCENT2)
	box.add_child(en)

	var tagline := Label.new()
	tagline.text = "无缝大世界 · 御云飞行 · 技能进阶 · 多人共斗"
	tagline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tagline.add_theme_font_size_override("font_size", 15)
	tagline.add_theme_color_override("font_color", TEXT_DIM)
	box.add_child(tagline)

# ====================================================================
#  启动器卡片
# ====================================================================

func _build_card() -> void:
	var card := Panel.new()
	card.custom_minimum_size = Vector2(480, 452)
	card.size = Vector2(480, 452)
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.position = Vector2(-240, -176)
	add_child(card)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 22)
	card.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	pad.add_child(col)

	# —— 标签切换 ——
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 10)
	col.add_child(tabs)
	tab_solo_btn = _tab_button("单机模式")
	tab_solo_btn.pressed.connect(func() -> void: _show_tab("solo"))
	tabs.add_child(tab_solo_btn)
	tab_online_btn = _tab_button("联机大世界")
	tab_online_btn.pressed.connect(func() -> void: _show_tab("online"))
	tabs.add_child(tab_online_btn)

	var sep := HSeparator.new()
	col.add_child(sep)

	# —— 内容区（两个面板叠放，按标签切换可见）——
	var content := Control.new()
	content.custom_minimum_size = Vector2(436, 300)
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(content)

	solo_panel = _build_solo_panel()
	content.add_child(solo_panel)
	online_panel = _build_online_panel()
	content.add_child(online_panel)

func _build_solo_panel() -> Control:
	var v := VBoxContainer.new()
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 12)
	v.alignment = BoxContainer.ALIGNMENT_CENTER

	var has_save: bool = SaveSystem.has_save()
	var hint := Label.new()
	hint.text = "本地即点即玩，无需服务器或登录。\n世界会随主线进度无缝解锁。"
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", TEXT_DIM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(hint)

	var play := _primary_button("▶   进入单机世界" + ("（继续存档）" if has_save else ""))
	play.pressed.connect(_on_solo_play)
	v.add_child(play)

	var new_btn := _ghost_button("新开档案（清空存档重来）")
	new_btn.pressed.connect(_on_new_game)
	v.add_child(new_btn)

	var status := Label.new()
	status.text = ("检测到本地存档，将从上次进度继续。" if has_save else "暂无存档，将开启全新冒险。")
	status.add_theme_font_size_override("font_size", 13)
	status.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7, 1) if has_save else TEXT_DIM)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(status)
	return v

func _build_online_panel() -> Control:
	var v := VBoxContainer.new()
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 8)

	# 服务器地址/端口在脚本内固定（SERVER_HOST/SERVER_PORT），此处不暴露输入框。
	account_picker = _make_picker_row(v, "已存账号")
	account_picker.item_selected.connect(_on_pick_account)

	user_edit = _make_field(v, "用户名", "")
	pass_edit = _make_field(v, "密码", "", true)
	pass_edit.text_submitted.connect(func(_t2: String) -> void: _on_connect())

	# 登录 / 注册：并排小按钮。
	var brow := HBoxContainer.new(); brow.add_theme_constant_override("separation", 10)
	v.add_child(brow)
	connect_btn = _primary_button("登录")
	connect_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	connect_btn.custom_minimum_size = Vector2(0, 40)
	connect_btn.pressed.connect(_on_connect)
	brow.add_child(connect_btn)
	register_btn = _primary_button("注册")
	register_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	register_btn.custom_minimum_size = Vector2(0, 40)
	register_btn.pressed.connect(_on_register)
	brow.add_child(register_btn)

	# 注册专属区域（昵称 + 头像上传），默认隐藏，点「注册」展开。
	reg_section = VBoxContainer.new()
	reg_section.add_theme_constant_override("separation", 6)
	reg_section.visible = false
	v.add_child(reg_section)
	nick_edit = _make_field(reg_section, "昵称（可留空=玩家序号）", "")
	var arow := HBoxContainer.new(); arow.add_theme_constant_override("separation", 8)
	reg_section.add_child(arow)
	avatar_preview = TextureRect.new()
	avatar_preview.custom_minimum_size = Vector2(48, 48)
	avatar_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	arow.add_child(avatar_preview)
	var up_btn := Button.new(); up_btn.text = "上传头像 (png/jpg)"
	up_btn.pressed.connect(_pick_avatar)
	arow.add_child(up_btn)
	var av_hint := Label.new(); av_hint.text = "或把图片拖到窗口；留空则随机默认"
	av_hint.add_theme_font_size_override("font_size", 12); av_hint.add_theme_color_override("font_color", TEXT_DIM)
	reg_section.add_child(av_hint)

	remember_check = CheckBox.new()
	remember_check.text = "记住账号密码"
	remember_check.button_pressed = true
	remember_check.add_theme_font_size_override("font_size", 14)
	remember_check.add_theme_color_override("font_color", TEXT_DIM)
	v.add_child(remember_check)

	status_label = Label.new()
	status_label.text = "已有账号点「登录」；新玩家点「注册」填昵称/头像。"
	status_label.add_theme_font_size_override("font_size", 13)
	status_label.add_theme_color_override("font_color", TEXT_DIM)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(status_label)
	return v

func _show_tab(which: String) -> void:
	var is_solo: bool = which == "solo"
	if solo_panel != null:
		solo_panel.visible = is_solo
	if online_panel != null:
		online_panel.visible = not is_solo
	_style_tab(tab_solo_btn, is_solo)
	_style_tab(tab_online_btn, not is_solo)

# ====================================================================
#  底部栏 + 关于
# ====================================================================

func _build_bottom_bar() -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 12)
	bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	bar.position = Vector2(-200, -64)
	bar.size = Vector2(400, 0)
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(bar)

	var about_btn := _ghost_button("关于我们")
	about_btn.custom_minimum_size = Vector2(180, 40)
	about_btn.pressed.connect(_on_about)
	bar.add_child(about_btn)

	var quit_btn := _ghost_button("退出游戏")
	quit_btn.custom_minimum_size = Vector2(180, 40)
	quit_btn.pressed.connect(_on_quit)
	bar.add_child(quit_btn)

	var ver := Label.new()
	ver.text = "Star Glory · Godot 4.6 原型  v0.4"
	ver.add_theme_font_size_override("font_size", 12)
	ver.add_theme_color_override("font_color", Color(0.4, 0.5, 0.68, 1))
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ver.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	ver.position = Vector2(-280, -26)
	ver.size = Vector2(264, 18)
	ver.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ver)

func _build_about_panel() -> void:
	var dim := ColorRect.new()
	dim.name = "AboutDim"
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.visible = false
	add_child(dim)

	about_panel = Panel.new()
	about_panel.custom_minimum_size = Vector2(540, 340)
	about_panel.size = Vector2(540, 340)
	about_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	about_panel.position = Vector2(-270, -170)
	dim.add_child(about_panel)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP

	var title := Label.new()
	title.text = "关于我们"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.position = Vector2(20, 22)
	title.size = Vector2(500, 34)
	about_panel.add_child(title)

	var label := Label.new()
	label.text = "星辉荣耀（Star Glory MMO）\n\n基于 Godot 4.6 制作的动作 RPG 原型，支持共享世界联机。\n\n· 程序化无缝大世界，流式分块加载\n· 御云飞行 · 六系技能进阶 · 磁石等实用道具\n· 服务器权威怪物 · 多人共斗 · 账号云存档\n\n感谢游玩，愿你在星海中闪耀。"
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", TEXT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector2(30, 66)
	label.size = Vector2(480, 210)
	about_panel.add_child(label)

	var close := _ghost_button("关闭")
	close.custom_minimum_size = Vector2(140, 42)
	close.position = Vector2(200, 282)
	close.pressed.connect(func() -> void: dim.visible = false)
	about_panel.add_child(close)

func _on_about() -> void:
	var dim := get_node_or_null("AboutDim")
	if dim != null:
		(dim as Control).visible = true

# ====================================================================
#  样式工具
# ====================================================================

func _build_theme() -> Theme:
	var t := Theme.new()
	# 按钮（默认 = 幽灵描边样式）
	t.set_stylebox("normal", "Button", _flat(Color(0.10, 0.13, 0.23, 0.85), Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.45), 1, 9))
	t.set_stylebox("hover", "Button", _flat(Color(0.16, 0.22, 0.37, 0.95), ACCENT, 1, 9))
	t.set_stylebox("pressed", "Button", _flat(Color(0.06, 0.09, 0.16, 0.95), ACCENT, 1, 9))
	t.set_stylebox("disabled", "Button", _flat(Color(0.08, 0.09, 0.13, 0.7), Color(0.3, 0.35, 0.45, 0.4), 1, 9))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color(1, 1, 1, 1))
	t.set_color("font_pressed_color", "Button", ACCENT)
	t.set_color("font_disabled_color", "Button", Color(0.5, 0.55, 0.65, 1))
	t.set_font_size("font_size", "Button", 17)

	# 输入框
	t.set_stylebox("normal", "LineEdit", _flat(FIELD_BG, Color(0.26, 0.4, 0.6, 0.5), 1, 7))
	t.set_stylebox("focus", "LineEdit", _flat(FIELD_BG, ACCENT, 2, 7))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", Color(0.5, 0.58, 0.72, 0.7))
	t.set_color("caret_color", "LineEdit", ACCENT)
	t.set_font_size("font_size", "LineEdit", 16)

	# 下拉
	t.set_stylebox("normal", "OptionButton", _flat(FIELD_BG, Color(0.26, 0.4, 0.6, 0.5), 1, 7))
	t.set_stylebox("hover", "OptionButton", _flat(Color(0.12, 0.16, 0.26, 0.95), ACCENT, 1, 7))
	t.set_stylebox("pressed", "OptionButton", _flat(FIELD_BG, ACCENT, 1, 7))
	t.set_stylebox("focus", "OptionButton", StyleBoxEmpty.new())
	t.set_color("font_color", "OptionButton", TEXT)
	t.set_font_size("font_size", "OptionButton", 15)

	# 卡片 / 弹窗面板
	var panel_box := _flat(PANEL_BG, PANEL_BORDER, 1, 16)
	panel_box.shadow_color = Color(0, 0, 0, 0.45)
	panel_box.shadow_size = 18
	t.set_stylebox("panel", "Panel", panel_box)

	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_color", "CheckBox", TEXT_DIM)
	return t

func _flat(bg: Color, border: Color, bw: int, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_border_width_all(bw)
	s.border_color = border
	s.set_corner_radius_all(radius)
	s.content_margin_left = 14.0
	s.content_margin_right = 14.0
	s.content_margin_top = 9.0
	s.content_margin_bottom = 9.0
	return s

func _gradient_tex(top: Color, bottom: Color, _radial: bool) -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, top)
	g.set_color(1, bottom)
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 8
	gt.height = 256
	gt.fill = GradientTexture2D.FILL_LINEAR
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	return gt

func _radial_tex(c: Color) -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(c.r, c.g, c.b, 1.0))
	g.set_color(1, Color(c.r, c.g, c.b, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 256
	gt.height = 256
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(0.5, 0.0)
	return gt

func _primary_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 50)
	b.add_theme_font_size_override("font_size", 21)
	b.add_theme_stylebox_override("normal", _flat(Color(0.16, 0.34, 0.54, 0.95), ACCENT2, 1, 10))
	b.add_theme_stylebox_override("hover", _flat(Color(0.22, 0.46, 0.70, 1.0), Color(1.0, 0.92, 0.6, 1), 2, 10))
	b.add_theme_stylebox_override("pressed", _flat(Color(0.12, 0.26, 0.42, 1.0), ACCENT2, 1, 10))
	b.add_theme_stylebox_override("disabled", _flat(Color(0.12, 0.16, 0.22, 0.7), Color(0.4, 0.45, 0.5, 0.4), 1, 10))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", Color(0.96, 0.99, 1.0, 1))
	return b

func _ghost_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 40)
	b.add_theme_font_size_override("font_size", 16)
	return b

func _tab_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = false
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 44)
	b.add_theme_font_size_override("font_size", 18)
	return b

func _style_tab(b: Button, active: bool) -> void:
	if b == null:
		return
	if active:
		var box := _flat(Color(0.15, 0.28, 0.46, 0.95), ACCENT, 2, 9)
		b.add_theme_stylebox_override("normal", box)
		b.add_theme_stylebox_override("hover", box)
		b.add_theme_stylebox_override("pressed", box)
		b.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	else:
		b.add_theme_stylebox_override("normal", _flat(Color(0.08, 0.10, 0.17, 0.7), Color(0.25, 0.35, 0.5, 0.3), 1, 9))
		b.add_theme_stylebox_override("hover", _flat(Color(0.12, 0.16, 0.26, 0.85), ACCENT, 1, 9))
		b.add_theme_stylebox_override("pressed", _flat(Color(0.10, 0.13, 0.22, 0.9), ACCENT, 1, 9))
		b.add_theme_color_override("font_color", TEXT_DIM)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

func _make_field(parent: Node, label_text: String, default_text: String, secret: bool = false) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(72, 36)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", TEXT_DIM)
	row.add_child(lbl)
	var edit := LineEdit.new()
	edit.text = default_text
	edit.secret = secret
	edit.placeholder_text = label_text
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.custom_minimum_size = Vector2(0, 36)
	row.add_child(edit)
	return edit

# 同一行内放一个带标签的输入框（用于「服务器 + 端口」并排）。
func _field_into(row: HBoxContainer, label_text: String, default_text: String, secret: bool, width: float) -> LineEdit:
	var lbl := Label.new()
	lbl.text = label_text
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", TEXT_DIM)
	row.add_child(lbl)
	var edit := LineEdit.new()
	edit.text = default_text
	edit.secret = secret
	edit.placeholder_text = label_text
	edit.custom_minimum_size = Vector2(width, 36)
	row.add_child(edit)
	return edit

func _make_picker_row(parent: Node, label_text: String) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(72, 36)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", TEXT_DIM)
	row.add_child(lbl)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.custom_minimum_size = Vector2(0, 36)
	row.add_child(opt)
	return opt

func _set_status(text: String, is_error: bool) -> void:
	status_label.text = text
	status_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.5, 1) if is_error else Color(0.65, 0.95, 0.75, 1))

# ====================================================================
#  联机
# ====================================================================

func _on_connect() -> void:
	# 登录：收起注册专属区。服务器地址/端口固定在脚本内（不可见、不可改）。
	_reg_mode = false
	if reg_section != null:
		reg_section.visible = false
	var host := SERVER_HOST
	var port := SERVER_PORT
	var user := user_edit.text.strip_edges()
	var pw := pass_edit.text
	if user == "" or pw == "":
		_set_status("请输入用户名和密码", true)
		return
	_attempt = {"host": host, "port": port, "user": user, "pass": pw}
	_set_status("连接中……", false)
	connect_btn.disabled = true
	if register_btn != null:
		register_btn.disabled = true
	if not Net.login_result.is_connected(_on_login_result):
		Net.login_result.connect(_on_login_result)
	Net.connect_and_login(host, port, user, pw)

func _on_login_result(ok: bool, reason: String) -> void:
	if ok:
		if remember_check != null and remember_check.button_pressed:
			_remember_account(_attempt)
		_set_status("登录成功，进入世界……", false)
		get_tree().change_scene_to_file("res://scenes/Main.tscn")
	else:
		connect_btn.disabled = false
		if register_btn != null:
			register_btn.disabled = false
		Net.disconnect_from_server()
		_set_status("失败：%s" % reason, true)

func _on_register() -> void:
	# 首次点「注册」展开注册区（昵称/头像）；再次点才真正注册。
	if not _reg_mode:
		_reg_mode = true
		if reg_section != null:
			reg_section.visible = true
		_set_status("填昵称/头像（都可留空），再次点「注册」完成。", false)
		return
	var user := user_edit.text.strip_edges()
	var pw := pass_edit.text
	if user == "" or pw == "":
		_set_status("请输入用户名和密码", true)
		return
	_attempt = {"host": SERVER_HOST, "port": SERVER_PORT, "user": user, "pass": pw}
	_set_status("注册中……", false)
	connect_btn.disabled = true
	register_btn.disabled = true
	if not Net.login_result.is_connected(_on_login_result):
		Net.login_result.connect(_on_login_result)
	Net.connect_and_register(SERVER_HOST, SERVER_PORT, user, pw, nick_edit.text.strip_edges(), reg_avatar_b64)

func _pick_avatar() -> void:
	if _avatar_dialog == null:
		_avatar_dialog = FileDialog.new()
		_avatar_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_avatar_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_avatar_dialog.filters = PackedStringArray(["*.png ; PNG 图片", "*.jpg,*.jpeg ; JPEG 图片"])
		_avatar_dialog.file_selected.connect(_load_avatar_file)
		add_child(_avatar_dialog)
	_avatar_dialog.popup_centered(Vector2i(760, 520))

func _load_avatar_file(path: String) -> void:
	var img := Image.new()
	if img.load(path) != OK:
		_set_status("图片加载失败，请选 png/jpg。", true)
		return
	_set_avatar_image(img)

func _set_avatar_image(img: Image) -> void:
	img.resize(64, 64, Image.INTERPOLATE_LANCZOS)
	reg_avatar_b64 = Marshalls.raw_to_base64(img.save_png_to_buffer())
	if avatar_preview != null:
		avatar_preview.texture = ImageTexture.create_from_image(img)
	if reg_section != null and not reg_section.visible:
		reg_section.visible = true
		_reg_mode = true
	_set_status("头像已选择。", false)

func _on_files_dropped(files: PackedStringArray) -> void:
	if files.is_empty():
		return
	var p: String = files[0]
	var pl: String = p.to_lower()
	if pl.ends_with(".png") or pl.ends_with(".jpg") or pl.ends_with(".jpeg"):
		var img := Image.new()
		if img.load(p) == OK:
			_set_avatar_image(img)

# ---------------- 记住账号 ----------------

func _accounts() -> Dictionary:
	if not (saved.get("accounts", null) is Dictionary):
		saved["accounts"] = {}
	return saved["accounts"]

func _refresh_account_picker() -> void:
	account_picker.clear()
	account_picker.add_item("▼ 选择已保存账号", 0)
	for uname: String in _accounts().keys():
		account_picker.add_item(uname)
	account_picker.disabled = _accounts().is_empty()

func _on_pick_account(index: int) -> void:
	if index <= 0:
		return
	var uname := account_picker.get_item_text(index)
	var acc := _accounts()
	if acc.has(uname):
		user_edit.text = uname
		pass_edit.text = String((acc[uname] as Dictionary).get("pass", ""))
		_set_status("已填入账号「%s」" % uname, false)

func _remember_account(att: Dictionary) -> void:
	saved["host"] = String(att.get("host", ""))
	saved["port"] = int(att.get("port", 9000))
	saved["last"] = String(att.get("user", ""))
	_accounts()[String(att.get("user", ""))] = {"pass": String(att.get("pass", ""))}
	_save_creds(saved)

func _creds_path() -> String:
	return "user://login_accounts.json"

func _load_creds() -> Dictionary:
	if not FileAccess.file_exists(_creds_path()):
		return {}
	var f := FileAccess.open(_creds_path(), FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}

func _save_creds(data: Dictionary) -> void:
	var f := FileAccess.open(_creds_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

# ---------------- 单机 ----------------

# 一键进入单机：有本地存档则续档，没有则开新档（不删存档，安全）。单机存档独立于联机账号。
func _on_solo_play() -> void:
	Net.online = false
	SaveSystem.pending_load = SaveSystem.has_save()
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_new_game() -> void:
	Net.online = false
	SaveSystem.delete_save()
	SaveSystem.pending_load = false
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_load_game() -> void:
	if not SaveSystem.has_save():
		return
	Net.online = false
	SaveSystem.pending_load = true
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_quit() -> void:
	get_tree().quit()
