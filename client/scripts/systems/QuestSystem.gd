extends Node3D
class_name QuestSystem

# 任务系统（原神式:去 NPC「任务向导」接取/提交）。分类:
#   主线 main(顺序,需接取) / 支线 side(独立,需接取) / 日常 daily(每日自动,提交即领) /
#   活动 event(timed 限时有倒计时/不限时常驻,自动进行,提交领取)。
# 目标类型: leave / level / kill / material / shelter / region / boss。
# NPC 在新手村内;走近按 E 打开「任务向导」面板:可接取 + 可提交。左上角追踪进行中任务,按 J 看全部。

var main: Node = null
var qstate: Dictionary = {}     # id -> {prog, status:"active"/"done"/"", date, start}
var main_index: int = 0
var daily_date: String = ""
var tracker_str: String = ""    # 当前追踪任务文字，供 Main 任务详情 Tab 读取
var tracked_id: String = ""     # 当前追踪(导航)的任务 id，同一时间仅一个
var _npc_panel: Control = null
var _npc_box: VBoxContainer = null
var _log_panel: Control = null
var _log_label: RichTextLabel = null

const NPC_POS := Vector3(7, 0, 30)   # 新手村内的任务向导
const NPC_R := 4.0

const QUESTS := [
	{"cat": "main", "id": "m1", "title": "走出新手村", "desc": "离开新手村,到外面的世界闯荡。", "type": "leave", "target": 1, "exp": 40},
	{"cat": "main", "id": "m2", "title": "初露锋芒", "desc": "升到 Lv.4。", "type": "level", "target": 4, "exp": 90},
	{"cat": "main", "id": "m3", "title": "扫荡魔物", "desc": "击杀 12 只魔物。", "type": "kill", "target": 12, "exp": 140, "mat": ["寒霜晶矿", 2]},
	{"cat": "main", "id": "m4", "title": "采集晶矿", "desc": "采集 6 个寒霜晶矿。", "type": "material", "mat_name": "寒霜晶矿", "target": 6, "exp": 150},
	{"cat": "main", "id": "m5", "title": "建立庇护所", "desc": "建成庇护所 Lv.1。", "type": "shelter", "target": 1, "exp": 180, "mat": ["星莹水晶", 2]},
	{"cat": "main", "id": "m6", "title": "扩建庇护所", "desc": "庇护所升级到 Lv.2。", "type": "shelter", "target": 2, "exp": 240},
	{"cat": "main", "id": "m7", "title": "讨伐世界 Boss", "desc": "击杀一只世界 Boss。", "type": "boss", "target": 1, "exp": 500, "mat": ["星莹水晶", 4]},
	{"cat": "side", "id": "s1", "title": "初级猎手", "desc": "累计击杀 25 只魔物。", "type": "kill", "target": 25, "exp": 220, "mat": ["寒霜晶矿", 3]},
	{"cat": "side", "id": "s2", "title": "晶石收藏家", "desc": "持有 15 个星莹水晶。", "type": "material", "mat_name": "星莹水晶", "target": 15, "exp": 240},
	{"cat": "side", "id": "s3", "title": "庇护所大师", "desc": "庇护所升到 Lv.3。", "type": "shelter", "target": 3, "exp": 300, "mat": ["星莹水晶", 5]},
	{"cat": "side", "id": "s4", "title": "远征者", "desc": "抵达最远的星界深渊。", "type": "region", "target": 6, "exp": 280},
	{"cat": "daily", "id": "d_hunt", "title": "每日狩猎", "desc": "今日击杀 20 只魔物。", "type": "kill", "target": 20, "exp": 150, "mat": ["寒霜晶矿", 2]},
	{"cat": "daily", "id": "d_boss", "title": "每日试炼", "desc": "今日击杀 1 只 Boss。", "type": "boss", "target": 1, "exp": 250, "mat": ["宠物蛋", 1]},
	{"cat": "event", "id": "ev_world", "title": "世界清剿(常驻)", "desc": "累计击杀 50 只魔物。", "type": "kill", "target": 50, "exp": 600, "mat": ["星莹水晶", 6], "timed": false},
	{"cat": "event", "id": "ev_rush", "title": "狩猎狂欢(限时7天)", "desc": "限时内击杀 40 只魔物。", "type": "kill", "target": 40, "exp": 900, "mat": ["星莹水晶", 12], "timed": true, "days": 7},
]
const CAT_NAMES := {"main": "主线", "side": "支线", "daily": "日常", "event": "活动"}

func setup(p_main: Node) -> void:
	main = p_main
	_build_npc()
	# 追踪文字不再独立显示，交给 Main 的「任务详情」Tab 呈现（见 tracker_text）。

# 当前追踪任务文字（Main 放进任务详情 Tab）。
func tracker_text() -> String:
	return tracker_str

func _quest_by_id(id: String) -> Dictionary:
	if id == "breakthrough":
		return {"id": "breakthrough", "cat": "main", "type": "breakthrough", "title": "突破等级上限"}
	for q_v: Variant in QUESTS:
		if String((q_v as Dictionary)["id"]) == id:
			return q_v
	return {}

func _is_done(q: Dictionary) -> bool:
	if String(q["id"]) == "breakthrough":
		return main == null or not main.has_method("breakthrough_gate") or main.breakthrough_gate().is_empty()
	var cat: String = String(q["cat"])
	var s: Dictionary = _st(String(q["id"]))
	if String(s.get("status", "")) == "done":
		return true
	if cat == "main" and _main_ids().find(String(q["id"])) < main_index:
		return true
	if cat == "daily" and String(s.get("date", "")) == _today():
		return true
	return false

# 点「追踪」按钮：设置/取消当前追踪任务（同一时间仅一个）。
func set_tracked(id: String) -> void:
	tracked_id = "" if id == tracked_id else id
	_save()
	_rebuild_sections()
	if main != null and main.has_method("flash_message") and tracked_id != "":
		var q: Dictionary = _quest_by_id(tracked_id)
		if not q.is_empty():
			main.flash_message("已追踪任务【%s】，循光柱/地图标记前往。" % String(q["title"]))

# 追踪任务的世界目标点（交给 Main 按类型解算）。
func tracked_waypoint() -> Dictionary:
	if tracked_id == "" or main == null or not main.has_method("quest_waypoint"):
		return {"has": false}
	var q: Dictionary = _quest_by_id(tracked_id)
	if q.is_empty() or _is_done(q):
		if not q.is_empty() and _is_done(q):
			tracked_id = ""   # 完成即自动取消追踪
		return {"has": false}
	return main.quest_waypoint(q)

# ---------------- 任务详情 Tab：按类别分栏(可收放) ----------------
var _sec_open: Dictionary = {"main": true, "side": true, "daily": true, "event": true}
var _tab_vbox: VBoxContainer = null

func build_sections(vbox: VBoxContainer) -> void:
	_tab_vbox = vbox
	_rebuild_sections()

func _status_str(q: Dictionary) -> String:
	var cat: String = String(q["cat"])
	var s: Dictionary = _st(String(q["id"]))
	if String(s.get("status", "")) == "done" or (cat == "main" and _main_ids().find(String(q["id"])) < main_index):
		return "[color=#7fdf9f]✔已完成[/color]"
	if cat == "daily" and String(s.get("date", "")) == _today():
		return "[color=#7fdf9f]✔今日已领[/color]"
	if _claimable(q):
		return "[color=#8fffbf]可提交(找NPC领)[/color]"
	if _tracked(q):
		return "[color=#9fe0ff]进行中 %d/%d[/color] %s" % [_cur(q), int(q["target"]), _timed_left(q)]
	if _available(q):
		return "[color=#ffd24a]可接取(找NPC)[/color]"
	return "[color=#8894a0]未开放[/color] %s" % _timed_left(q)

func _rebuild_sections() -> void:
	if _tab_vbox == null or not is_instance_valid(_tab_vbox):
		return
	for c in _tab_vbox.get_children():
		c.queue_free()
	for cat: String in ["main", "side", "daily", "event"]:
		var open: bool = bool(_sec_open[cat])
		# 统计该类进行中/可提交数量，做个角标
		var active_n: int = 0
		for q_v0: Variant in QUESTS:
			if String((q_v0 as Dictionary)["cat"]) == cat and (_tracked(q_v0 as Dictionary) or _available(q_v0 as Dictionary)):
				active_n += 1
		var hdr := Button.new()
		hdr.text = "%s 【%s】%s" % [("▼" if open else "▶"), String(CAT_NAMES[cat]), ("  ·%d" % active_n if active_n > 0 else "")]
		hdr.alignment = HORIZONTAL_ALIGNMENT_LEFT
		hdr.custom_minimum_size = Vector2(340, 26)
		hdr.add_theme_font_size_override("font_size", 15)
		hdr.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4, 1))
		var cc: String = cat
		hdr.pressed.connect(func() -> void: _sec_open[cc] = not bool(_sec_open[cc]); _rebuild_sections())
		_tab_vbox.add_child(hdr)
		if not open:
			continue
		# 主线栏顶部：等级卡上限时插入「突破等级上限」守关副本任务（可追踪）。
		if cat == "main" and main != null and main.has_method("breakthrough_gate"):
			var gate: Dictionary = main.breakthrough_gate()
			if not gate.is_empty():
				var brow := HBoxContainer.new()
				brow.add_theme_constant_override("separation", 4)
				var blbl := RichTextLabel.new()
				blbl.bbcode_enabled = true; blbl.fit_content = true; blbl.scroll_active = false
				blbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				blbl.custom_minimum_size = Vector2(278, 0); blbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				blbl.add_theme_font_size_override("normal_font_size", 13)
				var bstatus: String = "[color=#ff6a6a]卡级中·急需突破[/color]" if bool(gate.get("capped", false)) else "[color=#9fe0ff]可提前通关[/color]"
				blbl.text = "  · [b]★突破等级上限 Lv.%d→%d[/b]  %s\n    [color=#9fb8cf]通关守关副本「%s」(需Lv.%d进入)的首领 → 等级上限提升到 Lv.%d[/color]" % [int(gate["cap"]), int(gate["next"]), bstatus, String(gate["name"]), int(gate.get("level_req", 0)), int(gate["next"])]
				brow.add_child(blbl)
				var btb := Button.new()
				btb.custom_minimum_size = Vector2(52, 26); btb.add_theme_font_size_override("font_size", 12)
				var bon: bool = (tracked_id == "breakthrough")
				btb.text = "追踪中" if bon else "追踪"
				btb.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3, 1) if bon else Color(0.8, 0.9, 1.0, 1))
				btb.pressed.connect(func() -> void: set_tracked("breakthrough"))
				brow.add_child(btb)
				_tab_vbox.add_child(brow)
		for q_v: Variant in QUESTS:
			var q: Dictionary = q_v
			if String(q["cat"]) != cat:
				continue
			if cat == "main" and _main_ids().find(String(q["id"])) > main_index:
				continue   # 尚未解锁的后续主线不显示
			if _is_done(q):
				continue   # 已完成/今日已领的任务不再显示
			var qid: String = String(q["id"])
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			var lbl := RichTextLabel.new()
			lbl.bbcode_enabled = true; lbl.fit_content = true; lbl.scroll_active = false
			lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			lbl.custom_minimum_size = Vector2(278, 0)
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			lbl.add_theme_font_size_override("normal_font_size", 13)
			lbl.text = "  · [b]%s[/b]  %s\n    [color=#9fb8cf]%s[/color]" % [String(q["title"]), _status_str(q), String(q["desc"])]
			row.add_child(lbl)
			if not _is_done(q):
				var tb := Button.new()
				tb.custom_minimum_size = Vector2(52, 26)
				tb.add_theme_font_size_override("font_size", 12)
				var on: bool = (tracked_id == qid)
				tb.text = "追踪中" if on else "追踪"
				tb.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3, 1) if on else Color(0.8, 0.9, 1.0, 1))
				tb.pressed.connect(func() -> void: set_tracked(qid))
				row.add_child(tb)
			_tab_vbox.add_child(row)

func _build_npc() -> void:
	var npc := Node3D.new(); npc.position = NPC_POS
	var bmat := StandardMaterial3D.new(); bmat.albedo_color = Color(0.35, 0.6, 0.95, 1); bmat.emission_enabled = true; bmat.emission = Color(0.2, 0.4, 0.7, 1); bmat.emission_energy_multiplier = 0.5
	var body := MeshInstance3D.new(); var cm := CapsuleMesh.new(); cm.radius = 0.4; cm.height = 1.5
	body.mesh = cm; body.material_override = bmat; body.position = Vector3(0, 0.9, 0); npc.add_child(body)
	var head := MeshInstance3D.new(); var hm := SphereMesh.new(); hm.radius = 0.3; hm.height = 0.6
	head.mesh = hm; head.material_override = bmat; head.position = Vector3(0, 1.9, 0); npc.add_child(head)
	var lbl := Label3D.new(); lbl.text = "❗任务向导（按 E）"; lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.font_size = 30; lbl.outline_size = 6; lbl.modulate = Color(1.0, 0.9, 0.4, 1); lbl.position = Vector3(0, 2.7, 0); npc.add_child(lbl)
	add_child(npc)

# ---------------- 存档 ----------------
func to_save() -> Dictionary:
	return {"state": qstate, "main_index": main_index, "daily_date": daily_date, "tracked": tracked_id}

func from_save(d: Dictionary) -> void:
	qstate = (d.get("state", {}) as Dictionary).duplicate(true)
	main_index = int(d.get("main_index", 0))
	daily_date = String(d.get("daily_date", ""))
	tracked_id = String(d.get("tracked", ""))

func _save() -> void:
	if main != null and main.has_method("_save_quests"):
		main._save_quests()

# ---------------- 状态 ----------------
func _today() -> String: return Time.get_date_string_from_system()
func _now() -> int: return int(Time.get_unix_time_from_system())

func _st(id: String) -> Dictionary:
	if not qstate.has(id):
		qstate[id] = {"prog": 0, "status": "", "date": "", "start": 0}
	return qstate[id]

func _main_ids() -> Array:
	var out: Array = []
	for q_v: Variant in QUESTS:
		if String((q_v as Dictionary)["cat"]) == "main":
			out.append(String((q_v as Dictionary)["id"]))
	return out

func _is_current_main(q: Dictionary) -> bool:
	var ids: Array = _main_ids()
	return main_index < ids.size() and ids[main_index] == String(q["id"])

func _tracked(q: Dictionary) -> bool:
	var s: Dictionary = _st(String(q["id"]))
	match String(q["cat"]):
		"main", "side":
			return String(s.get("status", "")) == "active"
		"daily":
			return String(s.get("date", "")) != _today()
		"event":
			if String(s.get("status", "")) == "done":
				return false
			if bool(q.get("timed", false)):
				if int(s.get("start", 0)) == 0:
					s["start"] = _now()
				return _now() < int(s["start"]) + int(q.get("days", 7)) * 86400
			return true
	return false

func _available(q: Dictionary) -> bool:
	var s: Dictionary = _st(String(q["id"]))
	match String(q["cat"]):
		"main":
			return _is_current_main(q) and String(s.get("status", "")) != "active"
		"side":
			return String(s.get("status", "")) != "active" and String(s.get("status", "")) != "done"
	return false

func _cur(q: Dictionary) -> int:
	var s: Dictionary = _st(String(q["id"]))
	var t: String = String(q["type"])
	if main == null or main.player == null or not is_instance_valid(main.player):
		return int(s.get("prog", 0))
	match t:
		"leave":
			# 「走出新手村」是达成即记录：一旦踏出就永久记为已达成，回村不再回退。
			if int(s.get("prog", 0)) < 1 and Vector2(main.player.global_position.x, main.player.global_position.z - 20.0).length() > 30.0:
				s["prog"] = 1
				_save()
			return int(s.get("prog", 0))
		"level": return int(main.player.level)
		"material": return main.inv.material_count(String(q.get("mat_name", ""))) if main.inv != null else 0
		"shelter": return int(main.shelter_level)
		"region":
			# 「抵达某区域」同样是达成即记录（取历史最远，不回退）。
			var live: int = main.region_tier(main.player.global_position) if main.has_method("region_tier") else 1
			if live > int(s.get("prog", 0)):
				s["prog"] = live
				_save()
			return int(s.get("prog", 0))
		"kill", "boss": return int(s.get("prog", 0))
	return 0

func _claimable(q: Dictionary) -> bool:
	return _tracked(q) and _cur(q) >= int(q["target"])

func _timed_left(q: Dictionary) -> String:
	if not bool(q.get("timed", false)):
		return ""
	var s: Dictionary = _st(String(q["id"]))
	var left: int = int(s.get("start", _now())) + int(q.get("days", 7)) * 86400 - _now()
	if left <= 0:
		return "（已结束）"
	return "（剩 %d天%d时）" % [left / 86400, (left % 86400) / 3600]

func on_kill(is_boss: bool) -> void:
	for q_v: Variant in QUESTS:
		var q: Dictionary = q_v
		var t: String = String(q["type"])
		if (t == "kill" or (t == "boss" and is_boss)) and _tracked(q):
			var s: Dictionary = _st(String(q["id"]))
			s["prog"] = int(s.get("prog", 0)) + 1

func accept(id: String) -> void:
	_st(id)["status"] = "active"
	_refresh_npc()
	_save()

func claim(id: String) -> void:
	var q: Dictionary = {}
	for q_v: Variant in QUESTS:
		if String((q_v as Dictionary)["id"]) == id:
			q = q_v; break
	if q.is_empty() or not _claimable(q):
		return
	if main.player != null and is_instance_valid(main.player) and int(q.get("exp", 0)) > 0:
		main.player.gain_exp(int(q["exp"]))
	if q.has("mat") and main.inv != null:
		var mm: Array = q["mat"]
		main.inv.add_material(String(mm[0]), Color(0.5, 0.9, 1.0, 1), int(mm[1]))
	main.flash_message("✔ 【%s】%s 已领取!+%d 经验%s" % [String(CAT_NAMES[q["cat"]]), String(q["title"]), int(q.get("exp", 0)), ("，+材料" if q.has("mat") else "")])
	var s: Dictionary = _st(id)
	match String(q["cat"]):
		"main": main_index += 1; s["status"] = "done"
		"daily": s["date"] = _today(); s["prog"] = 0
		_: s["status"] = "done"
	_refresh_npc()
	_save()

func _process(_delta: float) -> void:
	if main == null:
		return
	var today: String = _today()
	if daily_date != today:
		daily_date = today
		for q_v: Variant in QUESTS:
			var q: Dictionary = q_v
			if String(q["cat"]) == "daily":
				var s: Dictionary = _st(String(q["id"]))
				if String(s.get("date", "")) != today:
					s["prog"] = 0
	_update_tracker()

func _update_tracker() -> void:
	for q_v: Variant in QUESTS:
		var q: Dictionary = q_v
		if _tracked(q):
			var c: int = _cur(q)
			var tag: String = "[color=#8fffbf]可提交![/color]" if c >= int(q["target"]) else "进度 %d/%d" % [c, int(q["target"])]
			tracker_str = "[color=#ffd24a]● %s：%s[/color]\n[color=#cfe8ff]%s[/color]\n[color=#9fe0ff]%s[/color]  [color=#9fb8cf]· J 任务 · 找NPC接取/提交[/color]" % [String(CAT_NAMES[q["cat"]]), String(q["title"]), String(q["desc"]), tag]
			return
	tracker_str = "[color=#9fb8cf]无进行中任务。到新手村找「任务向导」接取。（J 看全部）[/color]"

# ---------------- NPC 面板 ----------------
func try_npc(pos: Vector3) -> bool:
	if _npc_panel != null and _npc_panel.visible:
		_npc_panel.visible = false   # 已展开 → 再按 E 关闭
		return true
	if pos.distance_to(NPC_POS) > NPC_R:
		return false
	if _npc_panel == null:
		_build_npc_panel()
	_refresh_npc()
	_npc_panel.visible = true
	return true

func _add_quest_row(q: Dictionary, mode: String) -> void:
	var row := HBoxContainer.new()
	var info := RichTextLabel.new(); info.bbcode_enabled = true; info.fit_content = true
	info.custom_minimum_size = Vector2(390, 0); info.add_theme_font_size_override("normal_font_size", 14)
	var rew: String = "+%d经验%s" % [int(q.get("exp", 0)), ("+材料" if q.has("mat") else "")]
	info.text = "[b]%s[/b][color=#9fb8cf]（%s）[/color]\n%s  [color=#7fdf9f]%s[/color] %s" % [String(q["title"]), String(CAT_NAMES[q["cat"]]), String(q["desc"]), rew, _timed_left(q)]
	row.add_child(info)
	var btn := Button.new(); btn.custom_minimum_size = Vector2(80, 34)
	var id: String = String(q["id"])
	if mode == "accept":
		btn.text = "接取"; btn.pressed.connect(func() -> void: accept(id))
	else:
		btn.text = "领取"; btn.pressed.connect(func() -> void: claim(id))
	row.add_child(btn)
	_npc_box.add_child(row)

func _refresh_npc() -> void:
	if _npc_box == null:
		return
	for c in _npc_box.get_children():
		c.queue_free()
	var hdr1 := Label.new(); hdr1.text = "▼ 可提交（达成的任务来领奖）"; hdr1.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7, 1))
	_npc_box.add_child(hdr1)
	var any_r: bool = false
	for q_v: Variant in QUESTS:
		if _claimable(q_v as Dictionary):
			_add_quest_row(q_v as Dictionary, "claim"); any_r = true
	if not any_r:
		var n := Label.new(); n.text = "  （暂无可提交）"; n.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72, 1)); _npc_box.add_child(n)
	var hdr2 := Label.new(); hdr2.text = "▼ 可接取"; hdr2.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4, 1))
	_npc_box.add_child(hdr2)
	var any_a: bool = false
	for q_v2: Variant in QUESTS:
		if _available(q_v2 as Dictionary):
			_add_quest_row(q_v2 as Dictionary, "accept"); any_a = true
	if not any_a:
		var n2 := Label.new(); n2.text = "  （暂无可接取）"; n2.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72, 1)); _npc_box.add_child(n2)

func _build_npc_panel() -> void:
	var layer := CanvasLayer.new(); layer.layer = 61; add_child(layer)
	_npc_panel = Control.new(); _npc_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_npc_panel)
	var dim := ColorRect.new(); dim.color = Color(0, 0, 0, 0.6); dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_npc_panel.add_child(dim)
	var card := Panel.new(); card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.position = Vector2(-280, -240); card.size = Vector2(560, 480)
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(0.06, 0.08, 0.14, 0.98); sb.set_border_width_all(2); sb.border_color = Color(0.9, 0.8, 0.4, 0.7); sb.set_corner_radius_all(14)
	card.add_theme_stylebox_override("panel", sb); _npc_panel.add_child(card)
	var title := Label.new(); title.text = "任务向导"; title.position = Vector2(0, 14); title.size = Vector2(560, 34); title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24); title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5, 1)); card.add_child(title)
	var scroll := ScrollContainer.new(); scroll.position = Vector2(16, 54); scroll.size = Vector2(528, 370); card.add_child(scroll)
	_npc_box = VBoxContainer.new(); _npc_box.custom_minimum_size = Vector2(510, 0); _npc_box.add_theme_constant_override("separation", 8); scroll.add_child(_npc_box)
	var close := Button.new(); close.text = "关闭"; close.position = Vector2(230, 430); close.size = Vector2(100, 38)
	close.pressed.connect(func() -> void: _npc_panel.visible = false); card.add_child(close)

# ---------------- 任务日志（J）----------------
func toggle_log() -> void:
	if _log_panel == null:
		_build_log()
	_log_panel.visible = not _log_panel.visible
	if _log_panel.visible:
		_refresh_log()

func is_log_open() -> bool: return _log_panel != null and _log_panel.visible
func close_log() -> void:
	if _log_panel != null: _log_panel.visible = false
func is_npc_open() -> bool: return _npc_panel != null and _npc_panel.visible
func close_npc() -> void:
	if _npc_panel != null: _npc_panel.visible = false

func _refresh_log() -> void:
	if _log_label == null:
		return
	var out: String = ""
	for cat: String in ["main", "side", "daily", "event"]:
		out += "[b][color=#ffd24a]【%s】[/color][/b]\n" % String(CAT_NAMES[cat])
		for q_v: Variant in QUESTS:
			var q: Dictionary = q_v
			if String(q["cat"]) != cat:
				continue
			var s: Dictionary = _st(String(q["id"]))
			var status: String
			if String(s.get("status", "")) == "done" or (cat == "main" and _main_ids().find(String(q["id"])) < main_index):
				status = "[color=#7fdf9f]✔已完成[/color]"
			elif cat == "daily" and String(s.get("date", "")) == _today():
				status = "[color=#7fdf9f]✔今日已领[/color]"
			elif cat == "main" and _main_ids().find(String(q["id"])) > main_index:
				continue
			elif _claimable(q):
				status = "[color=#8fffbf]可提交(找NPC领)[/color]"
			elif _tracked(q):
				status = "[color=#9fe0ff]进行中 %d/%d[/color] %s" % [_cur(q), int(q["target"]), _timed_left(q)]
			elif _available(q):
				status = "[color=#ffd24a]可接取(找NPC)[/color]"
			else:
				status = "[color=#889]未开放[/color] %s" % _timed_left(q)
			out += "  · %s  %s\n    [color=#9fb8cf]%s[/color]\n" % [String(q["title"]), status, String(q["desc"])]
		out += "\n"
	_log_label.text = out

func _build_log() -> void:
	var layer := CanvasLayer.new(); layer.layer = 62; add_child(layer)
	_log_panel = Control.new(); _log_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_log_panel)
	var dim := ColorRect.new(); dim.color = Color(0, 0, 0, 0.6); dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_log_panel.add_child(dim)
	var card := Panel.new(); card.set_anchors_and_offsets_preset(Control.PRESET_CENTER); card.position = Vector2(-300, -260); card.size = Vector2(600, 520)
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(0.05, 0.07, 0.12, 0.98); sb.set_border_width_all(2); sb.border_color = Color(0.45, 0.7, 1.0, 0.7); sb.set_corner_radius_all(14)
	card.add_theme_stylebox_override("panel", sb); _log_panel.add_child(card)
	var title := Label.new(); title.text = "任务日志"; title.position = Vector2(0, 14); title.size = Vector2(600, 34); title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24); title.add_theme_color_override("font_color", Color(0.7, 0.95, 1.0, 1)); card.add_child(title)
	var scroll := ScrollContainer.new(); scroll.position = Vector2(20, 54); scroll.size = Vector2(560, 410); card.add_child(scroll)
	_log_label = RichTextLabel.new(); _log_label.bbcode_enabled = true; _log_label.fit_content = true; _log_label.custom_minimum_size = Vector2(540, 0)
	_log_label.add_theme_font_size_override("normal_font_size", 15); scroll.add_child(_log_label)
	var close := Button.new(); close.text = "关闭 (J)"; close.position = Vector2(240, 470); close.size = Vector2(120, 38)
	close.pressed.connect(func() -> void: _log_panel.visible = false); card.add_child(close)
