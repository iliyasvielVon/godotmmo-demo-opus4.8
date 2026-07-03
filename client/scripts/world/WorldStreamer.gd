class_name WorldStreamer
extends Node3D

# 分块流式加载：按玩家所在区块，异步加载 load_radius 范围内、卸载 unload_radius 外的区块。
# 区块 .tscn 由 WorldBaker 烘焙生成（scenes/world/chunks/chunk_{cx}_{cz}.tscn）。

const CHUNK_SIZE := 64.0
const LOAD_RADIUS := 2      # 玩家周围 (2*2+1)^2 = 5x5 区块保持加载
const UNLOAD_RADIUS := 3    # 超出该切比雪夫距离才卸载（滞回，避免边界抖动）
const GRID_MIN := -3
const GRID_MAX := 2
const PATH_FMT := "res://scenes/world/chunks/chunk_%d_%d.tscn"

var main: Node = null
var loaded: Dictionary = {}    # Vector2i -> Node3D（已加载实例）
var loading: Dictionary = {}   # Vector2i -> true（异步加载中）

func setup(p_main: Node) -> void:
	main = p_main
	# 同步加载玩家初始位置周围 3x3，保证第一帧脚下就有地面碰撞，玩家不会下落穿地。
	if main != null and main.player != null:
		var center := _chunk_of(main.player.global_position)
		for cx in range(center.x - 1, center.x + 2):
			for cz in range(center.y - 1, center.y + 2):
				var coord := Vector2i(cx, cz)
				if not _in_grid(coord) or loaded.has(coord):
					continue
				var path := PATH_FMT % [coord.x, coord.y]
				if not ResourceLoader.exists(path):
					continue
				var packed: PackedScene = load(path) as PackedScene
				if packed != null:
					_instantiate_chunk(coord, packed)

func _physics_process(_delta: float) -> void:
	if main == null or main.player == null or not is_instance_valid(main.player):
		return
	var center := _chunk_of(main.player.global_position)

	# 1) 发起范围内未加载区块的异步加载请求。
	for cx in range(center.x - LOAD_RADIUS, center.x + LOAD_RADIUS + 1):
		for cz in range(center.y - LOAD_RADIUS, center.y + LOAD_RADIUS + 1):
			var coord := Vector2i(cx, cz)
			if not _in_grid(coord) or loaded.has(coord) or loading.has(coord):
				continue
			var path := PATH_FMT % [coord.x, coord.y]
			if not ResourceLoader.exists(path):
				continue
			ResourceLoader.load_threaded_request(path)
			loading[coord] = true

	# 2) 轮询加载中的请求，完成则实例化。
	for coord: Vector2i in loading.keys():
		var path := PATH_FMT % [coord.x, coord.y]
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var packed: PackedScene = ResourceLoader.load_threaded_get(path) as PackedScene
			loading.erase(coord)
			if packed != null and not loaded.has(coord):
				_instantiate_chunk(coord, packed)
		elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			loading.erase(coord)

	# 3) 卸载超出 unload 范围的区块。
	for coord: Vector2i in loaded.keys():
		var cheb: int = max(abs(coord.x - center.x), abs(coord.y - center.y))
		if cheb > UNLOAD_RADIUS:
			var node: Node = loaded[coord]
			loaded.erase(coord)
			if is_instance_valid(node):
				node.queue_free()

func _instantiate_chunk(coord: Vector2i, packed: PackedScene) -> void:
	var chunk: Node3D = packed.instantiate() as Node3D
	chunk.position = _chunk_origin(coord)
	add_child(chunk)
	loaded[coord] = chunk

func _chunk_of(world_pos: Vector3) -> Vector2i:
	return Vector2i(int(floor(world_pos.x / CHUNK_SIZE)), int(floor(world_pos.z / CHUNK_SIZE)))

func _chunk_origin(coord: Vector2i) -> Vector3:
	return Vector3(coord.x * CHUNK_SIZE, 0.0, coord.y * CHUNK_SIZE)

func _in_grid(coord: Vector2i) -> bool:
	return coord.x >= GRID_MIN and coord.x <= GRID_MAX and coord.y >= GRID_MIN and coord.y <= GRID_MAX
