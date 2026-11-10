class_name PlanClock
extends RefCounted
## Work-item budget for one slice of planning work (Task #84). Planning code asks has_time() before each small work
## item (one route sample, one path query, one boundary-cache step) and calls item_done() after it. The budget is a
## count, never measured time, so the same order plans the same way on every run and a slow frame cannot stop
## planning.

var _remaining := 0


func _init(items: int) -> void:
	_remaining = items


## Whether one more work item fits in this slice.
func has_time() -> bool:
	return _remaining > 0


## Records that one work item was done.
func item_done() -> void:
	_remaining -= 1
