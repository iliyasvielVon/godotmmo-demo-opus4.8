extends Node

# 服务器管理控制台：设管理员/等级、发公告。
# 有显示（窗口模式）→ 2D 面板；无头模式（Ubuntu --headless）→ HTTP 管理 API。
# 两种入口共用 op_* 操作，落盘到服务器 DB（admins.json / announcements.json）。

const AdminApiScript = preload("res://main/AdminApi.gd")

var _ui: CanvasLayer = null
var _user_in: LineEdit = null
var _level_in: LineEdit = null
var _ann_in: LineEdit = null
var _admins_lbl: RichTextLabel = null
var _status_lbl: Label = null

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		var api := AdminApiScript.new()
		api.name = "AdminApi"
		add_child(api)
		api.setup(self)
		print("[Admin] 无头模式：启用 HTTP 管理 API。")
	else:
		_build_ui()
		print("[Admin] 窗口模式：启用 2D 管理面板。")

# ---------------- 共享操作（UI 与 API 都调用） ----------------
func op_set_admin(user: String, level: int) -> Dictionary:
	if user.strip_edges() == "":
		return {"ok": false, "msg": "用户名为空"}
	Accounts.set_admin_level(user, level)
	Net.push_admin_level_for_user(user)
	_refresh_admins()
	var actual: int = Accounts.admin_level(user)
	if actual != level:
		return {"ok": true, "msg": "%s 是固定管理员，保持 L%d。" % [user.strip_edges(), actual]}
	return {"ok": true, "msg": "已设置 %s = L%d" % [user.strip_edges(), level]}

func op_announce(text: String) -> Dictionary:
	if text.strip_edges() == "":
		return {"ok": false, "msg": "公告内容为空"}
	Net.broadcast_system("[公告] " + text)
	Accounts.set_motd(text)
	return {"ok": true, "msg": "已发布公告并保存。"}

func op_list_admins() -> Dictionary:
	return Accounts.admins.duplicate()

# ---------------- 2D 管理面板（窗口模式） ----------------
func _build_ui() -> void:
	_ui = CanvasLayer.new()
	add_child(_ui)
	var panel := Panel.new()
	panel.size = Vector2(580, 440)
	panel.position = Vector2(20, 20)
	_ui.add_child(panel)

	var title := Label.new()
	title.text = "服务器管理面板"
	title.position = Vector2(16, 10)
	title.add_theme_font_size_override("font_size", 22)
	panel.add_child(title)

	# 管理员设置
	_user_in = _field(panel, "用户名", Vector2(16, 74), Vector2(220, 30))
	_level_in = _field(panel, "等级(0=移除)", Vector2(250, 74), Vector2(120, 30))
	_level_in.text = "1"
	var setb := Button.new()
	setb.text = "设为管理员"
	setb.position = Vector2(386, 74)
	setb.size = Vector2(130, 30)
	setb.pressed.connect(func() -> void: op_set_admin(_user_in.text, _level_in.text.to_int()))
	panel.add_child(setb)

	# 公告
	_ann_in = _field(panel, "公告内容", Vector2(16, 140), Vector2(354, 30))
	var annb := Button.new()
	annb.text = "发布公告"
	annb.position = Vector2(386, 140)
	annb.size = Vector2(130, 30)
	annb.pressed.connect(func() -> void: op_announce(_ann_in.text))
	panel.add_child(annb)

	_status_lbl = Label.new()
	_status_lbl.position = Vector2(16, 178)
	_status_lbl.add_theme_color_override("font_color", Color(0.6, 0.9, 1.0, 1))
	panel.add_child(_status_lbl)

	# 当前管理员列表
	_admins_lbl = RichTextLabel.new()
	_admins_lbl.bbcode_enabled = true
	_admins_lbl.position = Vector2(16, 206)
	_admins_lbl.size = Vector2(548, 220)
	panel.add_child(_admins_lbl)
	_refresh_admins()

func _field(parent: Control, label: String, pos: Vector2, size: Vector2) -> LineEdit:
	var l := Label.new()
	l.text = label
	l.position = pos + Vector2(0, -22)
	l.add_theme_font_size_override("font_size", 13)
	parent.add_child(l)
	var e := LineEdit.new()
	e.position = pos
	e.size = size
	parent.add_child(e)
	return e

func _refresh_admins() -> void:
	if _admins_lbl == null:
		return
	var lines: Array = ["[b]当前管理员（admins.json）[/b]"]
	var keys: Array = Accounts.admins.keys()
	keys.sort()
	for k: String in keys:
		lines.append("• %s : 等级 %d" % [k, int(Accounts.admins[k])])
	if keys.is_empty():
		lines.append("(空)")
	_admins_lbl.text = "\n".join(lines)
	if _status_lbl != null:
		_status_lbl.text = "在线 %d 人" % Net.authed_ids().size()
