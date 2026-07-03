class_name SkillManager
extends Node

# 技能系统：技能数据库（元数据 + 图标 + 场景）与施放流程的唯一归属。
# 冷却(cooldowns)仍存放在每个施放者身上（属实体状态），本管理器负责校验与实例化技能场景。

const SCENES: Dictionary = {
	"star_slash": preload("res://scenes/skills/StarSlash.tscn"),
	"fireball": preload("res://scenes/skills/Fireball.tscn"),
	"frost_ring": preload("res://scenes/skills/FrostRing.tscn"),
	"blink": preload("res://scenes/skills/Blink.tscn"),
	"meteor": preload("res://scenes/skills/Meteor.tscn"),
	"fire_rain": preload("res://scenes/skills/FireRain.tscn")
}

const META: Dictionary = {
	"star_slash": {"name": "星斩", "key": "1", "cooldown": 0.35, "mp": 0, "desc": "近身连击斩（三段）", "icon": "✦"},
	"fireball": {"name": "焰弹", "key": "2", "cooldown": 2.4, "mp": 13, "desc": "自动索敌发射；升阶后命中爆炸", "icon": "●"},
	"frost_ring": {"name": "霜环", "key": "3", "cooldown": 5.5, "mp": 24, "desc": "范围冰冻减速", "icon": "❄"},
	"blink": {"name": "闪现", "key": "4", "cooldown": 4.2, "mp": 10, "desc": "向准星方向位移", "icon": "◆"},
	"meteor": {"name": "天星", "key": "5", "cooldown": 12.0, "mp": 42, "desc": "升空召唤陨石坠落", "icon": "☄"},
	"fire_rain": {"name": "火焰雨", "key": "6", "cooldown": 10.5, "mp": 38, "desc": "升空锁定区域，持续火伤", "icon": "🔥"}
}

const ORDER: Array[String] = ["star_slash", "fireball", "frost_ring", "blink", "meteor", "fire_rain"]

const PickupScript = preload("res://scripts/Pickup.gd")
const MAX_LEVEL := 5
const DMG_PER_LEVEL := 0.18

var main: Node = null
var skill_levels: Dictionary = {}          # id -> 0..MAX_LEVEL
var books: Dictionary = {}                 # id -> { tier(int) -> count(int) }

func setup(p_main: Node) -> void:
	main = p_main
	for id: String in ORDER:
		skill_levels[id] = 0
		books[id] = {}

# ---------- 技能等级 / 伤害倍率 ----------
func get_skill_level(skill_id: String) -> int:
	return int(skill_levels.get(skill_id, 0))

func get_damage_mult(skill_id: String) -> float:
	return 1.0 + DMG_PER_LEVEL * float(get_skill_level(skill_id))

# 升到 N 级需 2^(N-1) 本「该技能·N阶」书：从 n 升 n+1 需要 tier=(n+1) 的书 2^n 本。
func _books_needed(level_from: int) -> int:
	return 1 << level_from

# ---------- 技能书库存 ----------
func add_book(skill_id: String, tier: int) -> void:
	if not books.has(skill_id):
		books[skill_id] = {}
	var inv: Dictionary = books[skill_id]
	inv[tier] = int(inv.get(tier, 0)) + 1
	var meta: Dictionary = get_skill_meta(skill_id)
	if main != null:
		main.flash_message("获得技能书：%s·%d阶" % [String(meta.get("name", skill_id)), tier])
	_try_upgrade(skill_id)

func _try_upgrade(skill_id: String) -> void:
	var inv: Dictionary = books[skill_id]
	while true:
		var lvl: int = get_skill_level(skill_id)
		if lvl >= MAX_LEVEL:
			return
		var need_tier: int = lvl + 1
		var need_count: int = _books_needed(lvl)
		if int(inv.get(need_tier, 0)) < need_count:
			return
		inv[need_tier] = int(inv[need_tier]) - need_count
		skill_levels[skill_id] = lvl + 1
		if main != null:
			var meta: Dictionary = get_skill_meta(skill_id)
			main.flash_message("技能升级！%s 升至 Lv%d（伤害+%d%%）" % [String(meta.get("name", skill_id)), lvl + 1, int((lvl + 1) * DMG_PER_LEVEL * 100.0)])

# 下一级进度文本：当前 / 所需（按对应阶书计）。
func progress_text(skill_id: String) -> String:
	var lvl: int = get_skill_level(skill_id)
	if lvl >= MAX_LEVEL:
		return "MAX"
	var inv: Dictionary = books.get(skill_id, {})
	var need_tier: int = lvl + 1
	return "%d阶书 %d/%d" % [need_tier, int(inv.get(need_tier, 0)), _books_needed(lvl)]

# ---------- 掉落 ----------
func maybe_drop_book(monster: Node) -> void:
	var is_boss_m: bool = bool(monster.is_boss)
	var is_elite: bool = bool(monster.elite)
	var drop_chance: float = 1.0 if is_boss_m else (0.7 if is_elite else 0.3)
	if main.rng.randf() > drop_chance:
		return
	var skill_id: String = ORDER[main.rng.randi_range(0, ORDER.size() - 1)]
	var tier: int = _roll_tier(int(monster.rank), is_boss_m)
	_drop_book(monster.global_position + Vector3(0, 0.5, 0), skill_id, tier)

func _roll_tier(monster_rank: int, is_boss_m: bool) -> int:
	var max_tier: int = clampi(monster_rank, 1, MAX_LEVEL)
	if is_boss_m:
		return main.rng.randi_range(3, MAX_LEVEL)  # Boss 必掉高阶
	# 权重 ∝ 1/2^t：越高阶越稀有。
	var weights: Array[float] = []
	var total: float = 0.0
	for t in range(1, max_tier + 1):
		var w: float = 1.0 / pow(2.0, float(t - 1))
		weights.append(w)
		total += w
	var r: float = main.rng.randf() * total
	var acc: float = 0.0
	for t in range(1, max_tier + 1):
		acc += weights[t - 1]
		if r <= acc:
			return t
	return max_tier

# 确定性地构造一本技能书物品（无随机；联机时各端据相同 skill_id/tier 生成一致物品）。
func make_book_item(skill_id: String, tier: int) -> Dictionary:
	var meta: Dictionary = get_skill_meta(skill_id)
	var hue: Color = Color.from_hsv(clampf(0.08 * float(tier), 0.0, 0.92), 0.65, 1.0)
	return {
		"kind": "skillbook",
		"skill_id": skill_id,
		"tier": tier,
		"name": "%s·%d阶技能书" % [String(meta.get("name", skill_id)), tier],
		"color": hue
	}

func _drop_book(pos: Vector3, skill_id: String, tier: int) -> void:
	var pickup = PickupScript.new()
	pickup.main = main
	pickup.item_data = make_book_item(skill_id, tier)
	pickup.position = pos
	main.entity_root.add_child(pickup)
	main.pickups.append(pickup)

func has(skill_id: String) -> bool:
	return META.has(skill_id)

func get_skill_meta(skill_id: String) -> Dictionary:
	return META.get(skill_id, {}) as Dictionary

func get_icon(skill_id: String) -> String:
	return String((META.get(skill_id, {}) as Dictionary).get("icon", "?"))

# 校验冷却/法力/锁定/存活并施放。caster 须具备 cooldowns/mp/hp/skill_lock_timer 与朝向接口。
func cast(caster: StarGloryPlayer, skill_id: String) -> bool:
	if not META.has(skill_id):
		return false
	if caster.hp <= 0.0:
		return false
	if caster.skill_lock_timer > 0.0:
		main.flash_message("动作未结束")
		return false
	var meta: Dictionary = META[skill_id] as Dictionary
	if float(caster.cooldowns.get(skill_id, 0.0)) > 0.0:
		main.flash_message("技能冷却中")
		return false
	var cost: float = float(meta.get("mp", 0))
	# 御云飞行中的普通攻击（星斩速射）额外消耗法力。
	var aerial_slash: bool = skill_id == "star_slash" and caster.flying_cloud
	if aerial_slash:
		cost += float(StarGloryPlayer.AERIAL_SLASH_MP)
	if caster.mp < cost:
		main.flash_message("法力不足")
		return false
	var forward: Vector3 = caster.get_cast_direction()
	# 地面普通攻击（星斩、非御云速射）：自动转向并瞄准最近的目标。
	if skill_id == "star_slash" and not caster.flying_cloud and main.has_method("get_nearest_target"):
		var tgt: Node = main.get_nearest_target(caster.global_position)
		if tgt != null and is_instance_valid(tgt):
			var to_tgt: Vector3 = (tgt as Node3D).global_position - caster.global_position
			to_tgt.y = 0.0
			if to_tgt.length() > 0.1 and to_tgt.length() <= 6.5:
				forward = to_tgt.normalized()
	caster.face_direction(forward)
	caster.mp -= cost
	var cd: float = float(meta.get("cooldown", 1.0))
	# 御云速射星斩：冷却随等级大幅降低（伤害在技能场景内按比例降低，并随等级提高）。
	if aerial_slash:
		cd = maxf(0.08, 0.18 - 0.006 * float(caster.level - 1))
	caster.cooldowns[skill_id] = cd
	caster.cast_seq += 1   # 新一次施法序号（被打断时 caster 端自增使本次失效）
	Audio.sfx_at(_cast_sound(skill_id), caster.global_position, -2.0, 0.8 if skill_id == "meteor" else 1.0)
	_spawn_scene(skill_id, caster, forward)
	# 联机：把施法广播给其他玩家做表现（傀儡不会走到这里）。
	# 天星/火焰雨是「落点型」技能：同步真正的瞄准落点（而不是只发方向），否则他端会落到固定距离处。
	if Net.online and not caster.is_puppet:
		var sync_pos: Vector3 = caster.global_position
		if (skill_id == "meteor" or skill_id == "fire_rain") and main.has_method("get_mouse_aim_world"):
			sync_pos = main.get_mouse_aim_world(caster.global_position + forward * 10.0, 0.0)
		Net.send_cast(skill_id, sync_pos, forward, get_skill_level(skill_id))
	return true

# 联机：在本地把「其他玩家」的施法以纯表现方式复现（不结算伤害、不改其状态）。
# caster_puppet 为该玩家的傀儡；level 为同步过来的技能等级，用于还原特效层级。
func cast_remote(caster_puppet: StarGloryPlayer, skill_id: String, direction: Vector3, level: int, target: Vector3 = Vector3.ZERO) -> void:
	if main == null or not SCENES.has(skill_id) or caster_puppet == null:
		return
	var packed: PackedScene = SCENES[skill_id] as PackedScene
	var skill_node: Node3D = packed.instantiate() as Node3D
	skill_node.set("remote", true)
	skill_node.set("damage_mult", 1.0 + DMG_PER_LEVEL * float(level))
	skill_node.set("skill_level", level)
	skill_node.set("cast_seq", caster_puppet.cast_seq)
	# 落点型技能：传入同步过来的真实落点（天星/火焰雨用 remote_target 还原）。
	skill_node.set("remote_target", target)
	main.effect_root.add_child(skill_node)
	Audio.sfx_at(_cast_sound(skill_id), caster_puppet.global_position, -4.0, 0.8 if skill_id == "meteor" else 1.0)
	if skill_node.has_method("start"):
		skill_node.start(main, caster_puppet, direction)

# 各技能对应的合成音效名。
func _cast_sound(skill_id: String) -> String:
	match skill_id:
		"star_slash":
			return "slash"
		"fireball", "meteor", "fire_rain":
			return "fire"
		"frost_ring":
			return "ice"
		"blink":
			return "magic"
		_:
			return "magic"

func _spawn_scene(skill_id: String, caster: StarGloryPlayer, direction: Vector3) -> void:
	if not SCENES.has(skill_id):
		return
	var packed: PackedScene = SCENES[skill_id] as PackedScene
	var skill_node: Node3D = packed.instantiate() as Node3D
	skill_node.set("damage_mult", get_damage_mult(skill_id))
	skill_node.set("skill_level", get_skill_level(skill_id))
	skill_node.set("cast_seq", caster.cast_seq)
	main.effect_root.add_child(skill_node)
	if skill_node.has_method("start"):
		skill_node.start(main, caster, direction)
