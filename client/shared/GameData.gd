extends Node

# GameData —— 跨端共享数据加载器（在 client 与 server 两个工程里都注册为 autoload "GameData"）。
# 物理文件位于各自工程的 res://shared/（由 tools/sync-shared 从仓库根 shared/ 同步而来），
# 因此客户端与服务器读到的怪物/技能/世界/协议数据完全一致。只用 Godot 标准库，无工程耦合。

var monsters: Dictionary = {}
var skills: Dictionary = {}
var world: Dictionary = {}
var protocol: Dictionary = {}

func _ready() -> void:
	monsters = _load_json("res://shared/data/monsters.json")
	skills = _load_json("res://shared/data/skills.json")
	world = _load_json("res://shared/data/world.json")
	protocol = _load_json("res://shared/net/protocol.json")
	if monsters.is_empty() or skills.is_empty() or world.is_empty() or protocol.is_empty():
		push_error("GameData：shared 数据缺失，请先运行 tools/sync-shared 同步 shared/。")

func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("GameData：找不到 %s（是否已运行 sync-shared？）" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}

# 取某种怪物的数值表副本（深拷贝，调用方可安全修改，例如附加 elite）。
func monster_data(kind: String) -> Dictionary:
	if monsters.has(kind):
		return (monsters[kind] as Dictionary).duplicate(true)
	return {"kind": kind, "name": "未知魔物", "hp": 50, "attack": 8, "exp": 20, "rank": 1}

# 协议常量读取（带默认值）。
func proto(key: String, fallback: Variant) -> Variant:
	return protocol.get(key, fallback)

# [r,g,b,a] 数组 -> Color，供客户端渲染。
func to_color(arr: Variant, fallback: Color = Color(0.85, 0.2, 0.45, 1)) -> Color:
	if arr is Array and (arr as Array).size() >= 3:
		var a: Array = arr
		var alpha: float = float(a[3]) if a.size() >= 4 else 1.0
		return Color(float(a[0]), float(a[1]), float(a[2]), alpha)
	return fallback
