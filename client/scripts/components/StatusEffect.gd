class_name StatusEffect
extends RefCounted

# 通用状态效果数据载体。Buff/Debuff 系统的最小单元，由 BuffComponent 持有与推进。
enum Kind { BURN, SLOW, INVULN }

var kind: int
var remaining: float          # 剩余持续时间
var magnitude: float          # burn=每跳伤害；slow=减速比例(0~0.75)；invuln 不用
var tick_interval: float      # 周期结算间隔（仅 DoT 用）
var tick_timer: float         # 距离下一次结算的倒计时
var source: Node = null       # 施加者（可能在结算前被释放，结算方需 is_instance_valid 校验）

func _init(p_kind: int, p_remaining: float, p_magnitude: float = 0.0, p_tick_interval: float = 0.0, p_tick_timer: float = 0.0, p_source: Node = null) -> void:
	kind = p_kind
	remaining = p_remaining
	magnitude = p_magnitude
	tick_interval = p_tick_interval
	tick_timer = p_tick_timer
	source = p_source
