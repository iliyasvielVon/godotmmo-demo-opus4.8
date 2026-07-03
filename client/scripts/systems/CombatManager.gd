class_name CombatManager
extends Node

# 战斗系统：集中所有范围伤害查询与统一的伤害入口。
# 实体的 take_damage / receive_dot 仍留在 Player / Monster（负责各自飘字偏移、Boss 身高、
# 死亡路由）；CombatManager 负责目标查询、源有效性校验与转发，是技能/状态的唯一战斗接口。

var main: Node = null

func setup(p_main: Node) -> void:
	main = p_main

# 把可能已被释放的施加者净化成 null（Godot 4 中已释放 Node 引用并不等于 null）。
func _safe(source: Node) -> Node:
	return source if is_instance_valid(source) else null

# 统一直接伤害入口。（联机时怪物傀儡的上报逻辑在 Monster.take_damage 内部统一处理。）
func damage(target: Node, amount: int, source: Node = null) -> void:
	if not is_instance_valid(target):
		return
	if target.has_method("take_damage"):
		target.take_damage(amount, _safe(source))

# 统一持续伤害(DoT)入口，供 BuffComponent 的灼烧结算调用。
func apply_dot(target: Node, dot_damage: int, source: Node = null) -> void:
	if not is_instance_valid(target):
		return
	if target.has_method("receive_dot"):
		target.receive_dot(dot_damage, _safe(source))

# 玩家技能对范围内建筑(炮塔等)造成伤害。
func damage_buildings(center: Vector3, radius: float, dmg: int, source: Node) -> void:
	for b in main.get_tree().get_nodes_in_group("building"):
		var bnode: Node3D = b as Node3D
		if bnode == null or not is_instance_valid(bnode) or not bnode.has_method("take_damage"):
			continue
		# 建筑（炮塔/塔）是竖直结构：用水平距离判定，使跳跃/空中的攻击也能命中地面的塔。
		var d: float = Vector2(bnode.global_position.x - center.x, bnode.global_position.z - center.z).length()
		if d <= radius:
			var f: float = clamp(1.1 - d / max(radius, 0.1) * 0.5, 0.5, 1.1)
			bnode.take_damage(int(float(dmg) * f), source)

func apply_area_damage(center: Vector3, radius: float, dmg: int, source: Node, slow_power: float = 0.0, knockback: float = 0.0) -> void:
	damage_buildings(center, radius, dmg, source)
	for node in main.monsters.duplicate():
		var monster: StarGloryMonster = node as StarGloryMonster
		if monster == null or not is_instance_valid(monster) or monster.dead:
			continue
		var d: float = monster.global_position.distance_to(center)
		if d <= radius:
			var scaled_damage: int = int(float(dmg) * clamp(1.15 - d / max(radius, 0.1) * 0.45, 0.55, 1.15))
			damage(monster, scaled_damage, source)
			if slow_power > 0.0 and monster.has_method("apply_slow"):
				monster.apply_slow(slow_power, 3.0)
			if knockback > 0.0 and source != null:
				var dir: Vector3 = monster.global_position - center
				dir.y = 0
				if dir.length() > 0.05:
					monster.velocity.x += dir.normalized().x * knockback
					monster.velocity.z += dir.normalized().z * knockback

func apply_fire_rain_tick(center: Vector3, radius: float, dmg: int, burn_damage: int, burn_duration: float, source: Node) -> void:
	damage_buildings(center, radius, dmg, source)
	for node in main.monsters.duplicate():
		var monster: StarGloryMonster = node as StarGloryMonster
		if monster == null or not is_instance_valid(monster) or monster.dead:
			continue
		var d: float = monster.global_position.distance_to(center)
		if d <= radius:
			var scaled_damage: int = int(float(dmg) * clamp(1.12 - d / max(radius, 0.1) * 0.28, 0.70, 1.12))
			damage(monster, scaled_damage, source)
			if is_instance_valid(monster) and not monster.dead and monster.has_method("apply_burn"):
				monster.apply_burn(burn_damage, burn_duration, source)

# 无差别范围爆炸：怪物、玩家、建筑都会被炸伤；可移动单位还会被炸飞。
func apply_universal_blast(center: Vector3, radius: float, dmg: int, source: Node, knockback: float = 0.0) -> void:
	# 竖直击飞按角色体型标定：原写死 5.0 太飘，改为随水平击退弱缩放。
	var vk: float = clamp(knockback * 0.3, 1.5, 3.5)
	# 怪物（不打自己=source）
	for node in main.monsters.duplicate():
		var monster: StarGloryMonster = node as StarGloryMonster
		if monster == null or not is_instance_valid(monster) or monster.dead or monster == source:
			continue
		var d: float = monster.global_position.distance_to(center)
		if d <= radius:
			var f: float = clamp(1.1 - d / max(radius, 0.1) * 0.5, 0.5, 1.1)
			damage(monster, int(float(dmg) * f), source)
			if knockback > 0.0 and is_instance_valid(monster) and not monster.dead and monster.has_method("apply_forced_knockback"):
				monster.apply_forced_knockback(center, knockback, vk, 0.36)
	# 玩家（不打自己=source，例如空中炮击不炸到自己）
	var player: StarGloryPlayer = main.player
	if player != null and is_instance_valid(player) and player.hp > 0.0 and player != source:
		var pd: float = player.global_position.distance_to(center)
		if pd <= radius:
			var pf: float = clamp(1.1 - pd / max(radius, 0.1) * 0.5, 0.5, 1.1)
			damage(player, int(float(dmg) * pf), main)
			if knockback > 0.0:
				player.apply_forced_knockback(center, knockback, vk, 0.36)
	# 建筑（静止，仅受伤不位移）
	for b in main.get_tree().get_nodes_in_group("building"):
		var bnode: Node3D = b as Node3D
		if bnode == null or not is_instance_valid(bnode) or not bnode.has_method("take_damage") or bnode == source:
			continue
		if bnode.global_position.distance_to(center) <= radius:
			bnode.take_damage(int(float(dmg) * 0.6), source)

# 冰霜爆炸：范围内减速（并覆冰霜），中心 1/3 半径内冰冻生根；建筑仅受伤。
func apply_frost_blast(center: Vector3, radius: float, dmg: int, source: Node, slow_power: float, slow_dur: float, freeze_dur: float) -> void:
	var inner: float = radius / 3.0
	for node in main.monsters.duplicate():
		var monster: StarGloryMonster = node as StarGloryMonster
		if monster == null or not is_instance_valid(monster) or monster.dead:
			continue
		var d: float = monster.global_position.distance_to(center)
		if d <= radius:
			damage(monster, dmg, source)
			if is_instance_valid(monster) and not monster.dead and monster.buff != null:
				monster.buff.apply_slow(slow_power, slow_dur)
				if d <= inner:
					monster.buff.apply_freeze(freeze_dur)
	var player: StarGloryPlayer = main.player
	if player != null and is_instance_valid(player) and player.hp > 0.0:
		var pd: float = player.global_position.distance_to(center)
		if pd <= radius:
			damage(player, dmg, main)
			if player.buff != null:
				player.buff.apply_slow(slow_power, slow_dur)
				if pd <= inner:
					player.buff.apply_freeze(freeze_dur)
	for b in main.get_tree().get_nodes_in_group("building"):
		var bnode: Node3D = b as Node3D
		if bnode == null or not is_instance_valid(bnode) or not bnode.has_method("take_damage") or bnode == source:
			continue
		if bnode.global_position.distance_to(center) <= radius:
			bnode.take_damage(int(float(dmg) * 0.6), source)

func apply_player_area_damage(center: Vector3, radius: float, dmg: int) -> void:
	var player: StarGloryPlayer = main.player
	if player == null or not is_instance_valid(player) or player.hp <= 0.0:
		return
	if player.global_position.distance_to(center) <= radius:
		damage(player, dmg, main)

func apply_meteor_body_collision(hit_pos: Vector3, radius: float, dmg: int, source: Node, push_power: float, already_hit: Dictionary) -> void:
	damage_buildings(hit_pos, radius, dmg, source)
	# 陨石飞行中只负责“强制碰撞”：不改变陨石轨迹，但把被撞到的单位弹开。
	for node in main.monsters.duplicate():
		var monster: StarGloryMonster = node as StarGloryMonster
		if monster == null or not is_instance_valid(monster) or monster.dead:
			continue
		var id: int = monster.get_instance_id()
		if already_hit.has(id):
			continue
		var body_center: Vector3 = monster.global_position + Vector3(0, 1.2 if not monster.is_boss else 2.4, 0)
		if body_center.distance_to(hit_pos) <= radius:
			already_hit[id] = true
			damage(monster, dmg, source)
			if is_instance_valid(monster) and not monster.dead and monster.has_method("apply_forced_knockback"):
				monster.apply_forced_knockback(hit_pos, push_power, 4.4, 0.36)
			main.spawn_skill_flash(monster.global_position + Vector3(0, 1.0, 0), Color(1.0, 0.48, 0.16, 1), 1.3, 0.18)
	var player: StarGloryPlayer = main.player
	if player != null and is_instance_valid(player) and player.hp > 0.0 and player != source:
		var player_id: int = player.get_instance_id()
		if not already_hit.has(player_id):
			var player_center: Vector3 = player.global_position + Vector3(0, 1.15, 0)
			if player_center.distance_to(hit_pos) <= radius:
				already_hit[player_id] = true
				damage(player, dmg, source)
				player.apply_forced_knockback(hit_pos, push_power, 4.4, 0.36)
				main.spawn_skill_flash(player.global_position + Vector3(0, 1.0, 0), Color(1.0, 0.28, 0.14, 1), 1.3, 0.18)

func apply_meteor_ground_impact(center: Vector3, radius: float, dmg: int, source: Node, push_power: float, stun_dur: float = 0.0) -> void:
	damage_buildings(center, radius, dmg, source)
	for node in main.monsters.duplicate():
		var monster: StarGloryMonster = node as StarGloryMonster
		if monster == null or not is_instance_valid(monster) or monster.dead:
			continue
		var d: float = monster.global_position.distance_to(center)
		if d <= radius:
			var scaled_damage: int = int(float(dmg) * clamp(1.2 - d / max(radius, 0.1) * 0.50, 0.55, 1.2))
			damage(monster, scaled_damage, source)
			if is_instance_valid(monster) and not monster.dead and monster.has_method("apply_forced_knockback"):
				monster.apply_forced_knockback(center, push_power * clamp(1.0 - d / max(radius, 0.1) * 0.35, 0.45, 1.0), 5.2, 0.42)
				if stun_dur > 0.0 and monster.buff != null:
					monster.buff.queue_stun_on_landing(stun_dur)   # 天星击飞落地后眩晕
	var player: StarGloryPlayer = main.player
	if player != null and is_instance_valid(player) and player.hp > 0.0 and player != source:
		var pd: float = player.global_position.distance_to(center)
		if pd <= radius:
			var p_damage: int = int(float(dmg) * clamp(1.05 - pd / max(radius, 0.1) * 0.45, 0.45, 1.05))
			damage(player, p_damage, source)
			player.apply_forced_knockback(center, push_power * clamp(1.0 - pd / max(radius, 0.1) * 0.35, 0.45, 1.0), 5.2, 0.42)
			if stun_dur > 0.0 and player.buff != null:
				player.buff.queue_stun_on_landing(stun_dur)   # 天星击飞落地后眩晕
