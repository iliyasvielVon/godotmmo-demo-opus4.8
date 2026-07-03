@tool
extends EditorPlugin

var _export_plugin: EditorExportPlugin

func _enter_tree() -> void:
	_export_plugin = AndroidExportPlugin.new()
	add_export_plugin(_export_plugin)

func _exit_tree() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null

class AndroidExportPlugin:
	extends EditorExportPlugin

	const PLUGIN_NAME := "DirichletAd"

	func _get_name() -> String:
		return PLUGIN_NAME

	func _supports_platform(platform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(platform, debug: bool) -> PackedStringArray:
		# Paths are relative to res://addons/.
		return PackedStringArray([
			"DirichletAd/bin/DirichletAd.release.aar",
			"DirichletAd/bin/dirichlet_ad_4.2.5.0.aar"
		])

	func _get_android_dependencies(platform, debug: bool) -> PackedStringArray:
		# Dirichlet Ad SDK 4.2.5.0 uses the old android.support namespace plus
		# Glide/OkHttp. These Gradle dependencies mirror the official Android SDK
		# integration requirements and are only pulled for Android Gradle exports.
		return PackedStringArray([
			"com.android.support:support-v4:28.0.0",
			"com.android.support:appcompat-v7:28.0.0",
			"com.android.support:design:28.0.0",
			"com.android.support:recyclerview-v7:28.0.0",
			"com.android.support:multidex:1.0.3",
			"com.github.bumptech.glide:glide:4.9.0",
			"com.squareup.okhttp3:okhttp:3.12.13",
			"com.squareup.okio:okio:1.17.5"
		])

	func _get_android_dependencies_maven_repos(platform, debug: bool) -> PackedStringArray:
		return PackedStringArray([
			"https://maven.google.com",
			"https://repo1.maven.org/maven2"
		])
