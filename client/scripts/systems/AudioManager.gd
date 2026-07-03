extends Node

# 程序化音频引擎（autoload: Audio）。
# 不依赖任何外部音频文件：所有音效与背景音乐都用波形合成（正弦/噪声/包络）实时生成为
# AudioStreamWAV，避免版权问题。音效用 AudioStreamPlayer3D 做「按远近距离衰减」的定位播放，
# UI/音乐用 AudioStreamPlayer。背景音乐为无缝循环（频率取 1/时长 的整数倍，循环点连续）。

const SR := 22050        # 音效采样率
const MR := 16000        # 音乐采样率
const POOL_2D := 6
const POOL_3D := 18

var _sfx: Dictionary = {}
var _music: Dictionary = {}
var _music_player: AudioStreamPlayer
var _pool2d: Array[AudioStreamPlayer] = []
var _pool3d: Array[AudioStreamPlayer3D] = []
var _i2d: int = 0
var _i3d: int = 0
var _cur_music: String = ""

func _ready() -> void:
	_build_sfx()
	_build_music()
	_music_player = AudioStreamPlayer.new()
	_music_player.volume_db = -10.0
	add_child(_music_player)
	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool2d.append(p)
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 6.0
		p.max_distance = 55.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_pool3d.append(p)

# ---------------- 播放接口 ----------------
func play_music(name: String) -> void:
	if name == _cur_music and _music_player != null and _music_player.playing:
		return
	_cur_music = name
	var s: AudioStream = _music.get(name)
	if s == null or _music_player == null:
		return
	_music_player.stream = s
	_music_player.play()

func stop_music() -> void:
	if _music_player != null:
		_music_player.stop()
	_cur_music = ""

func sfx(name: String, vol_db: float = 0.0) -> void:
	var s: AudioStream = _sfx.get(name)
	if s == null or _pool2d.is_empty():
		return
	var p: AudioStreamPlayer = _pool2d[_i2d]
	_i2d = (_i2d + 1) % _pool2d.size()
	p.stream = s
	p.volume_db = vol_db
	p.play()

func stream_of(name: String) -> AudioStream:
	return _sfx.get(name)

func sfx_at(name: String, pos: Vector3, vol_db: float = 0.0, pitch: float = 1.0) -> void:
	var s: AudioStream = _sfx.get(name)
	if s == null or _pool3d.is_empty():
		return
	var p: AudioStreamPlayer3D = _pool3d[_i3d]
	_i3d = (_i3d + 1) % _pool3d.size()
	p.stream = s
	p.global_position = pos
	p.volume_db = vol_db
	p.pitch_scale = clampf(pitch, 0.4, 2.5)
	p.play()

# ---------------- 合成 ----------------
func _render(gen: Callable, dur: float, rate: int, loop: bool) -> AudioStreamWAV:
	var n: int = int(dur * float(rate))
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t: float = float(i) / float(rate)
		var s: float = clampf(float(gen.call(t, dur)), -1.0, 1.0)
		data.encode_s16(i * 2, int(s * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = n
	return w

func _build_sfx() -> void:
	# 脚步：低频闷响 + 一点噪声
	_sfx["step"] = _render(func(t: float, d: float) -> float:
		return (sin(t * TAU * 70.0) * 0.5 + (randf() * 2.0 - 1.0) * 0.35) * exp(-t * 26.0), 0.16, SR, false)
	# 挥砍：噪声扫频
	_sfx["slash"] = _render(func(t: float, d: float) -> float:
		return (randf() * 2.0 - 1.0) * sin(PI * clampf(t / d, 0.0, 1.0)) * 0.55, 0.2, SR, false)
	# 焰弹：低吼 whoosh
	_sfx["fire"] = _render(func(t: float, d: float) -> float:
		return (sin(t * TAU * (60.0 + 90.0 * exp(-t * 8.0))) + (randf() * 2.0 - 1.0) * 0.4) * exp(-t * 4.5) * 0.5, 0.45, SR, false)
	# 霜环：高频闪烁
	_sfx["ice"] = _render(func(t: float, d: float) -> float:
		return (sin(t * TAU * 900.0) + sin(t * TAU * 1320.0) * 0.6) * exp(-t * 5.0) * (0.5 + 0.5 * sin(t * TAU * 30.0)) * 0.3, 0.5, SR, false)
	# 魔法/闪现：下滑电音
	_sfx["magic"] = _render(func(t: float, d: float) -> float:
		return sin(t * TAU * (1000.0 * exp(-t * 7.0) + 120.0)) * exp(-t * 7.0) * 0.5, 0.4, SR, false)
	# 命中：冲击
	_sfx["hit"] = _render(func(t: float, d: float) -> float:
		return (sin(t * TAU * 130.0) * 0.5 + (randf() * 2.0 - 1.0) * 0.6) * exp(-t * 22.0), 0.18, SR, false)
	# 怪物攻击：低沉一击
	_sfx["mhit"] = _render(func(t: float, d: float) -> float:
		return (sin(t * TAU * (180.0 - 120.0 * t)) + (randf() * 2.0 - 1.0) * 0.3) * exp(-t * 14.0) * 0.5, 0.22, SR, false)
	# 流水/瀑布：连续过滤噪声 + 低频轰鸣（无缝循环）
	_sfx["water"] = _render(func(t: float, d: float) -> float:
		return ((randf() * 2.0 - 1.0) * 0.45 + sin(t * TAU * 38.0) * 0.12) * (0.75 + 0.25 * sin(t / d * TAU)), 1.6, SR, true)
	# 升级：上扬
	_sfx["levelup"] = _render(func(t: float, d: float) -> float:
		return sin(t * TAU * (440.0 + 700.0 * (t / d))) * (1.0 - t / d) * 0.45, 0.6, SR, false)
	# UI 点击
	_sfx["ui"] = _render(func(t: float, d: float) -> float:
		return sin(t * TAU * 660.0) * exp(-t * 30.0) * 0.4, 0.1, SR, false)

func _build_music() -> void:
	# 欢迎页：舒缓和弦垫 + 慢琶音（6s 无缝循环）。
	_music["menu"] = _render(func(t: float, d: float) -> float:
		return ((sin(t * TAU * 110.0) + sin(t * TAU * 165.0) + sin(t * TAU * 220.0)) * 0.12 * (0.6 + 0.4 * sin(t * TAU / 6.0)) \
			+ sin(t * TAU * (220.0 if fmod(t, 2.0) < 0.5 else (275.0 if fmod(t, 2.0) < 1.0 else (330.0 if fmod(t, 2.0) < 1.5 else 440.0)))) * 0.06 * exp(-fmod(t, 0.5) * 5.0)) * 0.5, 6.0, MR, true)
	# 游戏内：更有律动，低音脉冲 + 较快琶音（6s 无缝循环）。
	_music["game"] = _render(func(t: float, d: float) -> float:
		return ((sin(t * TAU * 98.0) + sin(t * TAU * 147.0) + sin(t * TAU * 196.0)) * 0.10 * (0.6 + 0.4 * sin(t * TAU / 6.0)) \
			+ sin(t * TAU * 49.0) * 0.18 * exp(-fmod(t, 0.5) * 6.0) \
			+ sin(t * TAU * (294.0 if fmod(t, 1.0) < 0.25 else (392.0 if fmod(t, 1.0) < 0.5 else (440.0 if fmod(t, 1.0) < 0.75 else 587.0)))) * 0.07 * exp(-fmod(t, 0.25) * 9.0)) * 0.5, 6.0, MR, true)
