class_name EquipmentManager
extends Node

# 装备系统：掉落物品表、随机词条/品阶生成、掉落落地，以及穿戴编排。
# 玩家身上仍保留 equipment 字典与 recalculate_stats（属角色属性），本管理器负责世界侧
# 的物品生成与穿戴流程（写入字典 → 重算属性 → 让 AnimationController 重建外观）。

const PickupScript = preload("res://scripts/Pickup.gd")

var main: Node = null
var base_items: Array[Dictionary] = []

func setup(p_main: Node) -> void:
	main = p_main
	_build_item_table()

func _build_item_table() -> void:
	base_items = [
		{"slot": "weapon", "name": "星火长刃", "attack": 9, "magic": 3, "defense": 0, "speed": 0.0, "color": Color(1.0, 0.48, 0.22, 1)},
		{"slot": "weapon", "name": "苍穹法杖", "attack": 3, "magic": 12, "defense": 0, "speed": 0.0, "color": Color(0.42, 0.72, 1.0, 1)},
		{"slot": "armor", "name": "流光战衣", "attack": 0, "magic": 2, "defense": 8, "hp": 28, "speed": 0.0, "color": Color(0.45, 0.70, 1.0, 1)},
		{"slot": "armor", "name": "赤羽护甲", "attack": 2, "magic": 0, "defense": 10, "hp": 36, "speed": -0.15, "color": Color(1.0, 0.32, 0.28, 1)},
		{"slot": "boots", "name": "逐星短靴", "attack": 0, "magic": 0, "defense": 2, "speed": 1.15, "color": Color(0.7, 0.95, 1.0, 1)},
		{"slot": "boots", "name": "影步靴", "attack": 2, "magic": 0, "defense": 1, "speed": 1.55, "color": Color(0.45, 0.32, 0.9, 1)},
		{"slot": "accessory", "name": "月华耳饰", "attack": 0, "magic": 6, "defense": 1, "mp": 24, "speed": 0.0, "color": Color(0.9, 0.85, 1.0, 1)},
		{"slot": "accessory", "name": "荣耀徽记", "attack": 4, "magic": 4, "defense": 3, "hp": 18, "mp": 12, "speed": 0.0, "color": Color(1.0, 0.82, 0.35, 1)}
	]

func equip(player: StarGloryPlayer, item_data: Dictionary) -> void:
	var slot: String = String(item_data.get("slot", "weapon"))
	player.equipment[slot] = item_data.duplicate(true)
	player.recalculate_stats()
	if player.anim != null:
		player.anim.build_equipment_visual(slot, player.equipment[slot])
	main.flash_message("已穿戴：%s" % String(item_data.get("name", "装备")))

func base_item_count() -> int:
	return base_items.size()

# 确定性地按 base 索引 + 品阶/传说生成一件物品（无随机；联机时由服务器指定 base 索引，保证各端一致）。
func make_item(base_index: int, tier: int, legendary: bool) -> Dictionary:
	var idx: int = clampi(base_index, 0, base_items.size() - 1)
	var item: Dictionary = (base_items[idx] as Dictionary).duplicate(true)
	var tier_index: int = clampi(tier, 0, 3)
	var prefix: String = "传说·" if legendary else String(["新手·", "精良·", "史诗·", "星辉·"][tier_index])
	item["name"] = prefix + String(item["name"])
	var bonus: int = tier + (3 if legendary else 0)
	for stat: String in ["attack", "magic", "defense", "hp", "mp"]:
		if item.has(stat):
			item[stat] = int(item[stat]) + bonus * (2 if stat in ["attack", "magic", "defense"] else 8)
	if item.has("speed"):
		item["speed"] = float(item["speed"]) + bonus * 0.08
	if legendary:
		item["color"] = Color(1.0, 0.82, 0.18, 1)
	return item

# 单机：随机掷一件（base 索引由本地 rng 选）。联机请用 make_item + make_pickup。
func roll_item(tier: int, legendary: bool) -> Dictionary:
	return make_item(main.rng.randi_range(0, base_items.size() - 1), tier, legendary)

func spawn_drop(pos: Vector3, tier: int, legendary: bool) -> void:
	make_pickup(pos, roll_item(tier, legendary), -1)

# 落地一个掉落物（drop_id<0 为单机本地物品；>=0 为服务器同步的共享掉落）。返回该 Pickup。
func make_pickup(pos: Vector3, item: Dictionary, drop_id: int) -> StarGloryPickup:
	var pickup: StarGloryPickup = PickupScript.new()
	pickup.main = main
	pickup.item_data = item
	pickup.net_drop_id = drop_id
	pickup.position = pos
	main.entity_root.add_child(pickup)
	main.pickups.append(pickup)
	return pickup
