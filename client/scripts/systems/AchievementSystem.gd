extends Node
class_name AchievementSystem

# 成就系统（客户端个人进度，存档）。达成即自动解锁并提示,按 K 打开成就面板查看全部。
# 累计击杀/Boss 击杀自行计数;其余(等级/庇护所/材料/区域/副本)按当前状态轮询。

var main: Node = null
var unlocked: Dictionary = {}   # id -> true
var kills: int = 0
var boss_kills: int = 0
var _panel: Control = null
var _label: RichTextLabel = null

const ACHS := [
	{"id": "a_lv5", "title": "初入江湖", "desc": "角色升到 Lv.5。", "type": "level", "target": 5},
	{"id": "a_lv15", "title": "崭露头角", "desc": "角色升到 Lv.15。", "type": "level", "target": 15},
	{"id": "a_lv30", "title": "登峰造极", "desc": "角色升到 Lv.30。", "type": "level", "target": 30},
	{"id": "a_kill100", "title": "百人斩", "desc": "累计击杀 100 只魔物。", "type": "kills", "target": 100},
	{"id": "a_kill500", "title": "魔物克星", "desc": "累计击杀 500 只魔物。", "type": "kills", "target": 500},
	{"id": "a_boss5", "title": "屠龙勇士", "desc": "累计击杀 5 只 Boss。", "type": "boss", "target": 5},
	{"id": "a_shelter3", "title": "安家立业", "desc": "庇护所升到 Lv.3。", "type": "shelter", "target": 3},
	{"id": "a_mat30", "title": "囤矿大户", "desc": "持有 30 个寒霜晶矿。", "type": "material", "mat_name": "寒霜晶矿", "target": 30},
	{"id": "a_region6", "title": "深渊行者", "desc": "抵达最远的星界深渊。", "type": "region", "target": 6},
	{"id": "a_dungeon3", "title": "副本达人", "desc": "累计通关副本 3 次。", "type": "dungeon", "target": 3},
]

func setup(p_main: Node) -> void:
	main = p_main

func to_save() -> Dictionary:
	return {"unlocked": unlocked, "kills": kills, "boss_kills": boss_kills}

func from_save(d: Dictionary) -> void:
	unlocked = (d.get("unlocked", {}) as Dictionary).duplicate(true)
	kills = int(d.get("kills", 0))
	boss_kills = int(d.get("boss_kills", 0))

func on_kill(is_boss: bool) -> void:
	kills += 1
	if is_boss:
		boss_kills += 1

func _cur(a: Dictionary) -> int:
	var t: String = String(a["type"])
	if main == null:
		return 0
	match t:
		"level": return int(main.player.level) if main.player != null and is_instance_valid(main.player) else 0
		"kills": return kills
		"boss": return boss_kills
		"shelter": return int(main.shelter_level)
		"material": return main.inv.material_count(String(a.get("mat_name", ""))) if main.inv != null else 0
		"region":
			if main.player != null and is_instance_valid(main.player) and main.has_method("region_tier"):
				return main.region_tier(main.player.global_position)
			return 0
		"dungeon": return (main.dungeon_records as Array).size() if "dungeon_records" in main else 0
	return 0

func _process(_delta: float) -> void:
	if main == null:
		return
	for a_v: Variant in ACHS:
		var a: Dictionary = a_v
		var id: String = String(a["id"])
		if unlocked.has(id):
			continue
		if _cur(a) >= int(a["target"]):
			unlocked[id] = true
			if main.has_method("flash_message"):
				main.flash_message("🏆 成就达成：%s！" % String(a["title"]))
			if main.has_method("_save_quests"):
				main._save_quests()

func toggle() -> void:
	if _panel == null:
		_build()
	_panel.visible = not _panel.visible
	if _panel.visible:
		_refresh()

func is_open() -> bool: return _panel != null and _panel.visible
func close() -> void:
	if _panel != null: _panel.visible = false

func _refresh() -> void:
	if _label == null:
		return
	var got: int = unlocked.size()
	var out: String = "[b]已解锁 %d / %d[/b]\n\n" % [got, ACHS.size()]
	for a_v: Variant in ACHS:
		var a: Dictionary = a_v
		if unlocked.has(String(a["id"])):
			out += "  🏆 [color=#ffd24a]%s[/color] — [color=#9fb8cf]%s[/color]  [color=#7fdf9f]✔[/color]\n" % [String(a["title"]), String(a["desc"])]
		else:
			out += "  🔒 [color=#c9d4e0]%s[/color] — [color=#9fb8cf]%s[/color]  [color=#9fe0ff](%d/%d)[/color]\n" % [String(a["title"]), String(a["desc"]), _cur(a), int(a["target"])]
	_label.text = out

func _build() -> void:
	var layer := CanvasLayer.new(); layer.layer = 62; add_child(layer)
	_panel = Control.new(); _panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); layer.add_child(_panel)
	var dim := ColorRect.new(); dim.color = Color(0, 0, 0, 0.6); dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); _panel.add_child(dim)
	var card := Panel.new(); card.set_anchors_and_offsets_preset(Control.PRESET_CENTER); card.position = Vector2(-300, -250); card.size = Vector2(600, 500)
	var sb := StyleBoxFlat.new(); sb.bg_color = Color(0.09, 0.08, 0.05, 0.98); sb.set_border_width_all(2); sb.border_color = Color(1.0, 0.8, 0.35, 0.7); sb.set_corner_radius_all(14)
	card.add_theme_stylebox_override("panel", sb); _panel.add_child(card)
	var title := Label.new(); title.text = "🏆 成就"; title.position = Vector2(0, 14); title.size = Vector2(600, 34); title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24); title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4, 1)); card.add_child(title)
	var scroll := ScrollContainer.new(); scroll.position = Vector2(20, 54); scroll.size = Vector2(560, 390); card.add_child(scroll)
	_label = RichTextLabel.new(); _label.bbcode_enabled = true; _label.fit_content = true; _label.custom_minimum_size = Vector2(540, 0)
	_label.add_theme_font_size_override("normal_font_size", 15); scroll.add_child(_label)
	var close := Button.new(); close.text = "关闭 (K)"; close.position = Vector2(240, 450); close.size = Vector2(120, 38)
	close.pressed.connect(func() -> void: _panel.visible = false); card.add_child(close)
