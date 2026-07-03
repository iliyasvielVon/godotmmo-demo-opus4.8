extends Node

# 单机单存档系统（autoload，名 SaveSystem）。存档为 JSON，放在可执行文件所在目录。
# 编辑器内运行时，路径指向 Godot 可执行文件目录（导出后即游戏 exe 目录）。

var pending_load: bool = false   # 菜单→Main：本局是否读档开局

# 单机存档加密口令（AES）。本地存档不再以明文落盘，防止直接改档。
const SAVE_PASS := "StarGloryMMO::save::v1::a7f3c19e"

func _save_path() -> String:
	return OS.get_executable_path().get_base_dir().path_join("starglory_save.json")

func has_save() -> bool:
	return FileAccess.file_exists(_save_path())

func save_game(data: Dictionary) -> bool:
	# 加密写入：FileAccess.open_encrypted_with_pass 内部用 AES 加密整文件。
	var f := FileAccess.open_encrypted_with_pass(_save_path(), FileAccess.WRITE, SAVE_PASS)
	if f == null:
		push_error("存档写入失败：%s" % _save_path())
		return false
	f.store_string(JSON.stringify(data))
	f.close()
	return true

func load_data() -> Dictionary:
	if not has_save():
		return {}
	# 先按加密格式读取。
	var f := FileAccess.open_encrypted_with_pass(_save_path(), FileAccess.READ, SAVE_PASS)
	if f != null:
		var txt := f.get_as_text()
		f.close()
		var parsed: Variant = JSON.parse_string(txt)
		if parsed is Dictionary:
			return parsed
	# 兼容旧明文存档：读出后下次保存会自动转为加密。
	var f2 := FileAccess.open(_save_path(), FileAccess.READ)
	if f2 == null:
		return {}
	var txt2 := f2.get_as_text()
	f2.close()
	var legacy: Variant = JSON.parse_string(txt2)
	return legacy if legacy is Dictionary else {}

func delete_save() -> void:
	if has_save():
		DirAccess.remove_absolute(_save_path())
