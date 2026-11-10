extends SceneTree
## PRD 2 (#85): fleet-scale cost check. Main with n ships, every ship ordered 150 m north on the same tick.
## godot --headless --fixed-fps 60 --path . --script res://Tests/fleet_scale_test.gd [-- --n=<ships>] [-- --strict]
## Without --n it runs n = 3, 10, 20 and 40, each in its own child process, and prints one table row per n.
## Timings are report-only; --strict exits 1 when the whole-tick p95 at 40 ships exceeds STRICT_P95_USEC.

class Sampler extends Node:
	var sample: Callable
	func _physics_process(delta: float) -> void:
		sample.call(delta)

const DEFAULT_COUNTS: Array[int] = [3, 10, 20, 40]
## Test thresholds (#85), not game tuning: the overrun line every cost is counted against, and the provisional
## whole-tick p95 target at the largest battle (decision D1).
const OVERRUN_USEC := 1500
const STRICT_SHIPS := 40
const STRICT_P95_USEC := 4000
const TIME_LIMIT := 120.0
const MOVE := Vector3(0, 0, -150)

var _n := -1
var _strict := false

# Child state.
var _game: Node3D
var _ships: Array[ShipMovement] = []
var _names: Array[String] = []
var _warmup := 0
var _armed := false
var _elapsed := 0.0
var _done := false
var _tick_start := 0
var _whole := PackedInt32Array()
var _navigator := PackedInt32Array()
var _traffic := PackedInt32Array()


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--n="):
			_n = int(arg.trim_prefix("--n="))
		if arg == "--strict":
			_strict = true
	if _n < 0:
		_run_children()
		return
	_start.call_deferred()


## Runs every default ship count in a fresh child process (the navigation map and static registries carry state
## between scenes in one process) and prints their result lines and one summary table.
func _run_children() -> void:
	var rows: Array[String] = []
	var failed := false
	for n in DEFAULT_COUNTS:
		var output: Array = []
		var args := ["--headless", "--fixed-fps", "60", "--path", ProjectSettings.globalize_path("res://"),
			"--script", "res://Tests/fleet_scale_test.gd", "--", "--n=%d" % n]
		if _strict:
			args.push_back("--strict")
		var code := OS.execute(OS.get_executable_path(), args, output, true)
		var found := false
		for line in String("\n".join(output)).split("\n"):
			if line.begins_with("FLEET ") or line.begins_with("    ") or line.begins_with("STRICT "):
				print(line)
			if line.begins_with("ROW "):
				rows.push_back(line.trim_prefix("ROW "))
				found = true
		if not found:
			print("FLEET n=%d: no result (child process output missing)" % n)
			failed = true
		failed = failed or code != 0
	print("")
	print("| Ships | Whole tick p95 | Traffic pass p95 | Ticks over %d us (whole tick) | Arrived |" % OVERRUN_USEC)
	print("| --- | --- | --- | --- | --- |")
	for row in rows:
		print(row)
	print("FLEET_SCALE_TEST %s" % ("FAIL" if failed else "DONE"))
	quit(1 if failed else 0)


func _start() -> void:
	_game = load("res://Main/main.tscn").instantiate()
	var ship_scene := load("res://Ships/ship.tscn") as PackedScene
	for i in maxi(_n - 3, 0):
		var extra := ship_scene.instantiate() as ShipMovement
		extra.name = "Extra%d" % i
		extra.position = Vector3(-300 + 40 * (i % 7), 0, 60 + 40 * (i / 7))
		_game.add_child(extra)
	root.add_child(_game)
	for node in _game.get_children():
		if node is ShipMovement:
			_ships.push_back(node)
			_names.push_back(String(node.name))
	var before := Sampler.new()
	before.process_physics_priority = -100
	before.sample = func(_delta: float) -> void: _tick_start = Time.get_ticks_usec()
	root.add_child(before)
	var after := Sampler.new()
	after.process_physics_priority = 100
	after.sample = _sample
	root.add_child(after)


func _sample(delta: float) -> void:
	if _done:
		return
	if not _armed:
		_warmup += 1
		if _warmup < 12:
			return
		if not NavigationServer3D.map_get_closest_point_owner(_ships[0].get_world_3d().navigation_map, Vector3.ZERO).is_valid():
			return
		_armed = true
		for ship in _ships:
			(ship.get_node("%Orders") as ShipOrders).move(ship.global_position + MOVE)
		return
	_whole.push_back(Time.get_ticks_usec() - _tick_start)
	_navigator.push_back(Navigator.get_frame_used())
	_traffic.push_back(Traffic.get_last_usec())
	_elapsed += delta
	if _arrivals() == _ships.size() or _elapsed >= TIME_LIMIT:
		_done = true
		_finish()


func _arrivals() -> int:
	var count := 0
	for ship in _ships:
		if ship.get_order_status().begins_with("arrived"):
			count += 1
	return count


## End state of one ship without coordinates, times or ship names, so counts compare across runs.
func _end_state(ship: ShipMovement) -> String:
	var order := ship.get_order_status().get_slice(" ", 0)
	var traffic := ship.get_traffic_status()
	var words := traffic.split(" ")
	if words.size() > 1 and _names.has(words[-1]):
		traffic = " ".join(words.slice(0, -1)) + " <ship>"
	return "%s, blocked %s, planning %s, traffic %s" % [order, ship.is_blocked(), ship.is_planning(), traffic]


func _finish() -> void:
	var arrived := _arrivals()
	var states := {}
	for ship in _ships:
		var state := _end_state(ship)
		states[state] = states.get(state, 0) + 1
	var keys := states.keys()
	keys.sort()
	var state_lines: Array[String] = []
	for key in keys:
		state_lines.push_back("%d x %s" % [states[key], key])
	var whole := _stats(_whole)
	print("FLEET n=%d: arrived %d of %d after %.2f s over %d ticks" % [_n, arrived, _n, _elapsed, _whole.size()])
	print("    whole tick: %s" % _text(whole))
	print("    navigator (Navigator.get_frame_used): %s" % _text(_stats(_navigator)))
	print("    traffic pass (Traffic.get_last_usec): %s" % _text(_stats(_traffic)))
	print("    end states: %s" % "; ".join(state_lines))
	var traffic := _stats(_traffic)
	print("ROW | %d | %.1f ms | %.1f ms | %.1f%% | %d of %d |" % [_n, whole.p95 / 1000.0, traffic.p95 / 1000.0,
		100.0 * whole.over / whole.count, arrived, _n])
	var missed: bool = _strict and _n == STRICT_SHIPS and whole.p95 > STRICT_P95_USEC
	if _strict and _n == STRICT_SHIPS:
		print("STRICT %s: whole tick p95 %d us at %d ships, target %d us" % ["FAIL" if missed else "PASS", whole.p95, _n, STRICT_P95_USEC])
	quit(1 if missed else 0)


func _stats(values: PackedInt32Array) -> Dictionary:
	var sorted := values.duplicate()
	sorted.sort()
	var last := sorted.size() - 1
	var over := 0
	for value in sorted:
		if value > OVERRUN_USEC:
			over += 1
	return {count = sorted.size(), median = sorted[mini(int(0.5 * sorted.size()), last)],
		p95 = sorted[mini(int(0.95 * sorted.size()), last)], p99 = sorted[mini(int(0.99 * sorted.size()), last)],
		max = sorted[last], over = over}


func _text(stats: Dictionary) -> String:
	return "median %d us, p95 %d, p99 %d, max %d, over %d us: %d of %d (%.1f%%)" % [stats.median, stats.p95, stats.p99,
		stats.max, OVERRUN_USEC, stats.over, stats.count, 100.0 * stats.over / stats.count]
