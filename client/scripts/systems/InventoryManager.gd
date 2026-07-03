class_name InventoryManager
extends Node

# 背包系统（2048 自动合成式装备 + 道具）：
# - 装备分 11 类（= 背包装备区 4+4+3 个分页），每页是一个 2048 网格，初始 2 格。
# - 拾取的装备按类放入对应分页；同页中相同「阶」的装备全自动合成为更高一阶（保留最强）。
# - 满格且无法合成时丢弃该页里最弱的，始终保留最强。
# - 每类装备「最强一件」自动生效，按其阶位加成玩家属性（无需手动穿戴）。
# - 道具区存放消耗品（药水/磁铁/背包扩展卷）。扩展卷可把某个装备分页 +1 格。

const TYPES: Array[String] = ["weapon", "offhand", "helmet", "chest", "legs", "boots", "shoulder", "gloves", "belt", "necklace", "ring"]
const TYPE_LABEL := {
	"weapon": "武器", "offhand": "副手", "helmet": "头盔", "chest": "胸甲", "legs": "护腿",
	"boots": "战靴", "shoulder": "护肩", "gloves": "护手", "belt": "腰带", "necklace": "项链", "ring": "戒指"
}
const TYPE_TAG := {
	"weapon": "武", "offhand": "盾", "helmet": "盔", "chest": "甲", "legs": "腿",
	"boots": "靴", "shoulder": "肩", "gloves": "手", "belt": "带", "necklace": "链", "ring": "戒"
}
# 各类装备「1 阶」基础属性；实际加成 = 基础 × 倍率(2^(阶-1))。
const PROFILE := {
	"weapon": {"attack": 7},
	"offhand": {"magic": 6, "defense": 2},
	"helmet": {"defense": 3, "hp": 12},
	"chest": {"defense": 5, "hp": 26},
	"legs": {"defense": 3, "hp": 16},
	"boots": {"defense": 1, "speed": 0.4},
	"shoulder": {"defense": 2, "hp": 10},
	"gloves": {"attack": 4},
	"belt": {"hp": 20, "toughness": 2},
	"necklace": {"magic": 4, "mp": 18},
	"ring": {"attack": 3, "magic": 3}
}
const TYPE_COLOR := {
	"weapon": Color(1.0, 0.5, 0.25, 1), "offhand": Color(0.5, 0.75, 1.0, 1), "helmet": Color(0.7, 0.8, 0.95, 1),
	"chest": Color(0.55, 0.7, 1.0, 1), "legs": Color(0.45, 0.6, 0.9, 1), "boots": Color(0.6, 0.9, 0.85, 1),
	"shoulder": Color(0.8, 0.7, 0.95, 1), "gloves": Color(1.0, 0.7, 0.4, 1), "belt": Color(0.9, 0.85, 0.5, 1),
	"necklace": Color(0.9, 0.8, 1.0, 1), "ring": Color(1.0, 0.82, 0.4, 1)
}

const INIT_CAP := 2
const MAX_CAP := 8

var main: Node = null
var pages: Dictionary = {}     # type -> Array[int]（各装备的阶位，升序保存）
var caps: Dictionary = {}      # type -> int（该页容量）
var items: Array = []          # 道具：[{kind:"potion"/"magnet"/"scroll", ...}]

func setup(p_main: Node) -> void:
	main = p_main
	for t: String in TYPES:
		pages[t] = [] as Array
		caps[t] = INIT_CAP

# ---------- 2048 数值 ----------
func value_of(tier: int) -> int:
	return int(pow(2.0, float(tier)))        # 显示值：2,4,8,16...

func mult_of(tier: int) -> float:
	return pow(2.0, float(tier - 1))          # 属性倍率：1,2,4,8...

func speed_mult_of(tier: int) -> float:
	if tier <= 1:
		return 1.0
	var total: float = 1.0
	var step: float = 0.75
	for _i in range(2, tier + 1):
		total += step
		step *= 0.72
	return total

# ---------- 装备：放入 + 自动合成 ----------
# 装等上限 = 由玩家等级决定；无法合成/获得超过该上限的装等。
func max_equip_tier() -> int:
	if main != null and "player" in main and main.player != null and is_instance_valid(main.player):
		return 2 + int(int(main.player.level) / 3)   # Lv1→2, Lv6→4, Lv30→12 …
	return 99

func add_equipment(etype: String, tier: int) -> void:
	if not pages.has(etype):
		etype = TYPES[0]
	var arr: Array = pages[etype]
	arr.append(clampi(maxi(1, tier), 1, max_equip_tier()))   # 入包即受装等上限约束
	_merge(arr)
	arr.sort()
	while arr.size() > int(caps[etype]):
		arr.pop_front()   # 超容：丢弃最弱，保留最强
	_on_change()

func _merge(arr: Array) -> void:
	var mt: int = max_equip_tier()
	while true:
		arr.sort()
		var merged: bool = false
		for i in range(arr.size() - 1):
			if int(arr[i]) == int(arr[i + 1]) and int(arr[i]) + 1 <= mt:   # 超过玩家等级允许的装等则不再合成
				arr[i] = int(arr[i]) + 1
				arr.remove_at(i + 1)
				merged = true
				break
		if not merged:
			break

func best_tier(etype: String) -> int:
	var arr: Array = pages.get(etype, [])
	return int(arr[arr.size() - 1]) if arr.size() > 0 else 0

func page_count() -> int:
	return TYPES.size()

# ---------- 道具 ----------
func add_item(item: Dictionary) -> void:
	items.append(item.duplicate(true))
	_on_change()

# 采集材料：按名称堆叠计数放入道具区。
func add_material(mat_name: String, color: Color, amount: int = 1) -> void:
	for it: Dictionary in items:
		if String(it.get("kind", "")) == "material" and String(it.get("name", "")) == mat_name:
			it["count"] = int(it.get("count", 1)) + amount
			_on_change()
			return
	items.append({"kind": "material", "name": mat_name, "color": color, "count": amount})
	_on_change()

func material_count(mat_name: String) -> int:
	for it: Dictionary in items:
		if String(it.get("kind", "")) == "material" and String(it.get("name", "")) == mat_name:
			return int(it.get("count", 0))
	return 0

# 消耗材料（够则扣除返回 true）。
func consume_material(mat_name: String, amount: int) -> bool:
	for i in range(items.size()):
		var it: Dictionary = items[i]
		if String(it.get("kind", "")) == "material" and String(it.get("name", "")) == mat_name:
			if int(it.get("count", 0)) < amount:
				return false
			it["count"] = int(it["count"]) - amount
			if int(it["count"]) <= 0:
				items.remove_at(i)
			_on_change()
			return true
	return false

func use_item(index: int) -> void:
	if index < 0 or index >= items.size():
		return
	var it: Dictionary = items[index]
	var kind: String = String(it.get("kind", ""))
	match kind:
		"potion":
			if main != null and main.has_method("_consume_potion"):
				main._consume_potion(it)
			items.remove_at(index)
		"magnet":
			if main != null and main.has_method("_activate_magnet"):
				main._activate_magnet()
			items.remove_at(index)
		"scroll":
			# 扩展卷不在此直接使用：需在某个装备分页上点「扩展」，见 expand_page。
			if main != null and main.has_method("flash_message"):
				main.flash_message("背包扩展卷：在装备分页点「扩展(+1格)」对该页使用。")
			return
	_on_change()

func scroll_count() -> int:
	var n: int = 0
	for it: Dictionary in items:
		if String(it.get("kind", "")) == "scroll":
			n += 1
	return n

# 某类药剂(ptype: hp/mp/vit)的数量。
func count_potion(ptype: String) -> int:
	var n: int = 0
	for it: Dictionary in items:
		if String(it.get("kind", "")) == "potion" and String(it.get("ptype", "vit")) == ptype:
			n += 1
	return n

# 取出一瓶某类药剂（从背包移除并返回）；没有则返回空字典。
func take_potion(ptype: String) -> Dictionary:
	for i in range(items.size()):
		var it: Dictionary = items[i]
		if String(it.get("kind", "")) == "potion" and String(it.get("ptype", "vit")) == ptype:
			items.remove_at(i)
			_on_change()
			return it
	return {}

# 用一张扩展卷给某装备分页 +1 格（每张只开一个页里的一格）。
func expand_page(etype: String) -> bool:
	if not caps.has(etype):
		return false
	if int(caps[etype]) >= MAX_CAP:
		if main != null and main.has_method("flash_message"):
			main.flash_message("该分页已达最大格数（%d）。" % MAX_CAP)
		return false
	var idx: int = -1
	for i in range(items.size()):
		if String((items[i] as Dictionary).get("kind", "")) == "scroll":
			idx = i
			break
	if idx < 0:
		if main != null and main.has_method("flash_message"):
			main.flash_message("没有背包扩展卷（仅 Boss 概率掉落）。")
		return false
	items.remove_at(idx)
	caps[etype] = int(caps[etype]) + 1
	if main != null and main.has_method("flash_message"):
		main.flash_message("已扩展「%s」分页：+1 格（现 %d 格）。" % [String(TYPE_LABEL.get(etype, etype)), int(caps[etype])])
	_on_change()
	return true

# ---------- 属性加成（每类最强一件生效） ----------
func get_bonus() -> Dictionary:
	var b := {"attack": 0, "magic": 0, "defense": 0, "hp": 0, "mp": 0, "speed": 0.0, "toughness": 0, "lifesteal": 0.0}
	for t: String in TYPES:
		var bt: int = best_tier(t)
		if bt <= 0:
			continue
		var m: float = mult_of(bt)
		var prof: Dictionary = PROFILE[t]
		for k: String in prof.keys():
			if k == "speed":
				b["speed"] = float(b["speed"]) + float(prof[k]) * speed_mult_of(bt)
			else:
				b[k] = int(b[k]) + int(round(float(prof[k]) * m))
		# 吸血仅主/副武器提供，且增幅压低：1 阶 1%，每阶 +2%，单件封顶 25%。
		if t == "weapon" or t == "offhand":
			b["lifesteal"] = float(b["lifesteal"]) + clampf(0.01 + 0.02 * float(bt - 1), 0.01, 0.25)
	b["lifesteal"] = minf(float(b["lifesteal"]), 0.25)
	return b

# HUD 简报：列出已生效（有装备）的分页与其最强阶位。
func summary() -> String:
	var parts: Array[String] = []
	for t: String in TYPES:
		var bt: int = best_tier(t)
		if bt > 0:
			parts.append("%s%d" % [String(TYPE_TAG.get(t, "?")), value_of(bt)])
	if parts.is_empty():
		return "暂无装备（击败怪物拾取，会自动按 2048 合成）"
	return " ".join(parts)

# 死亡惩罚：随机从一个非空装备页移除一个格子，返回被丢描述（空背包返回 ""）。
func lose_random_equipment() -> String:
	var avail: Array = []
	for t: String in TYPES:
		if (pages[t] as Array).size() > 0:
			avail.append(t)
	if avail.is_empty():
		return ""
	var etype: String = avail[randi() % avail.size()]
	var arr: Array = pages[etype]
	var idx: int = randi() % arr.size()
	var tier: int = int(arr[idx])
	arr.remove_at(idx)
	_on_change()
	return "%s(等级%d)" % [String(TYPE_LABEL.get(etype, etype)), tier]

func _on_change() -> void:
	if main == null:
		return
	if main.player != null and is_instance_valid(main.player):
		main.player.recalculate_stats()
	if main.has_method("_on_inventory_changed"):
		main._on_inventory_changed()

# ---------- 存档 ----------
func to_save() -> Dictionary:
	var pg := {}
	for t: String in TYPES:
		pg[t] = (pages[t] as Array).duplicate()
	var cp := {}
	for t: String in TYPES:
		cp[t] = int(caps[t])
	return {"pages": pg, "caps": cp, "items": items.duplicate(true)}

func from_save(data: Dictionary) -> void:
	setup(main)
	var pg: Dictionary = data.get("pages", {})
	for t: String in TYPES:
		if pg.has(t):
			var a: Array = []
			for v: Variant in pg[t]:
				a.append(int(v))
			a.sort()
			pages[t] = a
	var cp: Dictionary = data.get("caps", {})
	for t: String in TYPES:
		if cp.has(t):
			caps[t] = clampi(int(cp[t]), INIT_CAP, MAX_CAP)
	items.clear()
	for it_v: Variant in data.get("items", []):
		items.append((it_v as Dictionary).duplicate(true))
	_on_change()

func _roll_tier(world_level: int) -> int:
	var r: float = randf()
	var up: float = 0.12 + 0.04 * float(world_level - 1)
	if r < up * 0.4:
		return 3
	elif r < up:
		return 2
	return 1

# 普通掉落：排除主/副武器（带吸血属性的装备只由 Boss 掉落）。
func gen_random(world_level: int) -> Dictionary:
	var pool: Array[String] = []
	for t: String in TYPES:
		if t != "weapon" and t != "offhand":
			pool.append(t)
	return {"etype": pool[randi() % pool.size()], "tier": _roll_tier(world_level)}

# Boss 专属：主/副武器（带吸血）。
func gen_weapon(world_level: int) -> Dictionary:
	var t: String = "weapon" if randf() < 0.5 else "offhand"
	return {"etype": t, "tier": _roll_tier(world_level)}
