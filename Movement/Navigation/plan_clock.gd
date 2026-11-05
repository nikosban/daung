class_name PlanClock
extends RefCounted
## Wall-clock budget for one slice of planning work (Task #46). Planning code asks has_time() before each small work
## item (one predicted tick, one route sample, one path query) and calls item_done() after it. has_time() refuses an
## item that, at the longest item duration measured so far (shared by all ships, never more than half the slice),
## would end past the deadline, so a slice stays within its allowance instead of overrunning by its last item.

static var _item_max := 0

var deadline := 0
var _reserve_cap := 0
var _item_start := 0


func _init(p_deadline: int, allowance: int) -> void:
	deadline = p_deadline
	_reserve_cap = allowance / 2


## Whether one more work item fits before the deadline; starts timing that item.
func has_time() -> bool:
	_item_start = Time.get_ticks_usec()
	return _item_start + mini(_item_max, _reserve_cap) < deadline


## Records the duration of the item started by the last has_time().
func item_done() -> void:
	var duration := Time.get_ticks_usec() - _item_start
	if duration > _item_max:
		_item_max = duration
