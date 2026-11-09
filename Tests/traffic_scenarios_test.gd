extends SceneTree
## Task 38 (#79): ship traffic setups and single-ship regression, headless at the project physics rate.
## godot --headless --fixed-fps 60 --path . --script res://Tests/traffic_scenarios_test.gd [-- --case=<name>] [-- --record]
## Without --case it runs every traffic setup and every single-ship comparison case, each in its own child process (the
## default navigation map and Orders' float clock carry state between scenes in one process), and prints the results
## and the navigation tick cost over all traffic setups.

class Sampler extends Node:
	var sample: Callable
	func _physics_process(delta: float) -> void:
		sample.call(delta)

const SINGLE_CASES: Array[String] = ["clear", "detour", "replacement", "stop", "a2_activate5", "a2_activate6", "a2_activate7"]
const TRAFFIC_CASES: Array[String] = ["crossing", "acceleration_priority", "committed_priority", "tie", "back_out",
	"parked_blocker", "exhausted_recovery", "replacement_while_yielding", "contact"]
const BUDGET_USEC := 1500

var _queue: Array[String] = []
var _record := false
var _failures := 0
var _results: Array[String] = []

# Per-case state.
var _case := ""
var _game: Node
var _sampler: Sampler
var _done := false


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--case="):
			_queue.push_back(arg.trim_prefix("--case="))
		if arg == "--record":
			_record = true
	if _queue.is_empty():
		_run_children()
		return
	_next.call_deferred()


## Runs every case in a fresh child process and collects its result lines and tick costs.
func _run_children() -> void:
	var cases: Array[String] = []
	cases.append_array(TRAFFIC_CASES)
	cases.append_array(SINGLE_CASES)
	var costs := PackedInt32Array()
	var pass_costs := PackedInt32Array()
	for name in cases:
		var output: Array = []
		var args := ["--headless", "--fixed-fps", "60", "--path", ProjectSettings.globalize_path("res://"),
			"--script", "res://Tests/traffic_scenarios_test.gd", "--", "--case=" + name]
		if _record:
			args.push_back("--record")
		OS.execute(OS.get_executable_path(), args, output, true)
		var found := false
		for line in String("\n".join(output)).split("\n"):
			if line.begins_with("PASS ") or line.begins_with("FAIL ") or line.begins_with("    "):
				_results.push_back(line)
				found = found or not line.begins_with("    ")
				if line.begins_with("FAIL "):
					_failures += 1
			elif line.begins_with("COSTS "):
				var parts := line.split(" ")
				costs.append_array(PackedInt32Array(Array(parts[1].split_floats(",")).map(func(v: float) -> int: return int(v))))
				pass_costs.append_array(PackedInt32Array(Array(parts[2].split_floats(",")).map(func(v: float) -> int: return int(v))))
		if not found:
			_failures += 1
			_results.push_back("FAIL %s: no result (child process output missing)" % name)
	for line in _results:
		print(line)
	if not costs.is_empty():
		print("TICK_COST all traffic setups: %s" % _cost_text(costs))
		print("TICK_COST traffic pass alone: %s" % _cost_text(pass_costs))
	print("TRAFFIC_TEST %s (%d failed)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures > 0 else 0)


func _next() -> void:
	if _game != null:
		_game.queue_free()
		_game = null
	if _sampler != null:
		_sampler.queue_free()
		_sampler = null
	if _queue.is_empty():
		for line in _results:
			print(line)
		if not _costs.is_empty():
			var text := func(values: PackedInt32Array) -> String: return ",".join(Array(values).map(func(v: int) -> String: return str(v)))
			print("COSTS %s %s" % [text.call(_costs), text.call(_pass_costs)])
			print("TICK_COST: %s; traffic pass alone: %s" % [_cost_text(_costs), _cost_text(_pass_costs)])
		print("TRAFFIC_TEST %s (%d failed)" % ["PASS" if _failures == 0 else "FAIL", _failures])
		quit(1 if _failures > 0 else 0)
		return
	_case = _queue.pop_front()
	_done = false
	# Let freed ships leave the tree (and their registries) before the next scene starts.
	await process_frame
	await physics_frame
	if TRAFFIC_CASES.has(_case):
		_start_traffic()
	else:
		_start_single()


func _report(passed: bool, text: String) -> void:
	if not passed:
		_failures += 1
	_results.push_back("%s %s: %s" % ["PASS" if passed else "FAIL", _case, text])


# --- Single-ship comparison cases (one ship in Main) -------------------------------------------------------------

## Trace SHA-256 per case, recorded on main at 05af671 with this harness (--record).
const SINGLE_BASELINE := {
	clear = "78e148e14ccc1d54311198d208ec8072ec9cc6047adf66021154d26f62105611",
	detour = "d5f4b9930d5e65a4e670e272dcce70baa8b964ca5110790b96b658c56adfcec5",
	replacement = "78e148e14ccc1d54311198d208ec8072ec9cc6047adf66021154d26f62105611",
	stop = "3a4057ce3b14ce376e707975c813d26539221d221fc8b20887dd50514739a900",
	a2_activate5 = "c800438ced0520246857084c758c2ff4e9f6a13f7f2c0444412ba8f1cbe5901b",
	a2_activate6 = "93aac83fda2247dbe23f41bafeb7eca3db6257c3d8ac83ca21294cfe1177fd66",
	a2_activate7 = "05c89d45a7152e8b20d4699c5d8157335003673e4de7ff56c8cc07f7f1edc3c1",
}

var _ship: ShipMovement
var _orders: ShipOrders
var _armed := false
var _warmup := 0
var _start := 0.0
var _redirect_at := -1.0
var _redirected := false
var _arrival := -1.0
var _rest_ticks := 0
var _trace := PackedFloat64Array()


func _start_single() -> void:
	_game = load("res://Main/main.tscn").instantiate()
	var suite := _game.get_node("DebuggingSuite")
	var shapes: Array[CollisionShape3D] = []
	for shape in suite.collision_shapes:
		var owner_name := String(shape.get_parent().name)
		if owner_name != "ShipLeft" and owner_name != "ShipRight":
			shapes.push_back(shape)
	suite.collision_shapes = shapes
	for extra in ["ShipLeft", "ShipRight"]:
		var node := _game.get_node(extra)
		_game.remove_child(node)
		node.free()
	_ship = _game.get_node("ShipMiddle")
	var fleet := _game.get_node("FleetCommand") as FleetCommand
	var roster: Array[ShipMovement] = [_ship]
	fleet.roster = roster
	root.add_child(_game)
	_orders = _ship.get_node("%Orders")
	_armed = false
	_warmup = 0
	_redirect_at = -1.0
	_redirected = false
	_arrival = -1.0
	_rest_ticks = 0
	_trace = PackedFloat64Array()
	_sampler = Sampler.new()
	_sampler.process_physics_priority = 10
	_sampler.sample = _sample_single
	root.add_child(_sampler)


func _sample_single(_delta: float) -> void:
	if _done:
		return
	if not _armed:
		_warmup += 1
		if _warmup < 12:
			return
		if not NavigationServer3D.map_get_closest_point_owner(_ship.get_world_3d().navigation_map, Vector3.ZERO).is_valid():
			return
		_armed = true
		_start = _orders.get_clock()
		if _case.begins_with("a2_"):
			_ship.global_position = Vector3(238, 0, -162)
			_redirect_at = float(_case.right(1)) - _orders.crew.reaction_delay
			_orders.move(Vector3(170, 0, -90))
		elif _case == "detour":
			_orders.move(Vector3(130, 0, 0))
		elif _case == "replacement":
			_orders.move(Vector3(83, 0, 0))
			_orders.move(Vector3(60, 0, -40))
		elif _case == "stop":
			_ship.global_position = Vector3(1000, 0, 1000)
			_ship.velocity = Vector3.FORWARD * 15.0
			_orders.stop()
		else:
			_orders.move(Vector3(60, 0, -40))
		_ship.reset_physics_interpolation()
		return
	var time := _orders.get_clock() - _start
	if _redirect_at >= 0.0 and not _redirected and time + 1e-7 >= _redirect_at:
		_redirected = true
		_orders.move(Vector3(240, 0, -201))
	if _ship.get_order_status().begins_with("arrived") and _arrival < 0.0 and (_redirect_at < 0.0 or _redirected):
		_arrival = time
	var position := _ship.global_position
	_trace.append_array(PackedFloat64Array([time, position.x, position.z, _ship.velocity.x, _ship.velocity.z,
		_ship.rotation.y, _ship.get_turn_rate(), _ship.get_course_heading(), _ship.get_desired_speed(), float(_ship.has_order())]))
	if time > maxf(_redirect_at + 1.0, 1.0) and not _ship.has_order() and _orders.get_pending_count() == 0 and _ship.velocity.length() < 0.01:
		_rest_ticks += 1
	else:
		_rest_ticks = 0
	if _rest_ticks >= 30 or time >= 90.0:
		_done = true
		var hashing := HashingContext.new()
		hashing.start(HashingContext.HASH_SHA256)
		hashing.update(_trace.to_byte_array())
		var digest := hashing.finish().hex_encode()
		if _record:
			_report(true, "recorded %s (arrival %.2f s, %s)" % [digest, _arrival, _ship.get_order_status()])
		else:
			var expected: String = SINGLE_BASELINE.get(_case, "")
			_report(digest == expected, "trace %s, baseline %s; arrival %.2f s" % [digest.left(16), expected.left(16), _arrival])
		_next.call_deferred()


# --- Traffic setups (debugging/scenarios/setups) -------------------------------------------------------------------

var _scenario: Node
var _ships: Array[ShipMovement] = []
var _used := 0
## Per ship: traffic status changes (time -> status), first contact tick, pending commands and order state then,
## closest approach to the case's crossing point (distance, time), smallest x and largest |x|.
var _seen: Array[Dictionary] = []
var _contact_tick: Array[int] = []
var _contact_pending: Array[int] = []
var _contact_order: Array[bool] = []
var _closest: Array[Vector2] = []
var _min_x: Array[float] = []
var _max_abs_x: Array[float] = []
var _tick := 0
var _quiet := 0
var _costs := PackedInt32Array()
var _pass_costs := PackedInt32Array()
var _case_costs := PackedInt32Array()
var _worst_at := Vector2(0, -1)


func _start_traffic() -> void:
	_scenario = (load("res://debugging/scenarios/traffic_scenario.tscn") as PackedScene).instantiate()
	_scenario.setup = load("res://debugging/scenarios/setups/%s.tres" % _case)
	_game = _scenario
	root.add_child(_scenario)
	_ships = _scenario.get_ships()
	_used = _scenario.setup.positions.size()
	_seen.clear()
	_contact_tick.clear()
	_contact_pending.clear()
	_contact_order.clear()
	_closest.clear()
	_min_x.clear()
	_max_abs_x.clear()
	for i in _used:
		_seen.push_back({})
		_contact_tick.push_back(-1)
		_contact_pending.push_back(0)
		_contact_order.push_back(true)
		_closest.push_back(Vector2(INF, -1.0))
		_min_x.push_back(INF)
		_max_abs_x.push_back(0.0)
	_tick = 0
	_quiet = 0
	_case_costs = PackedInt32Array()
	_worst_at = Vector2(0, -1)
	_sampler = Sampler.new()
	_sampler.process_physics_priority = 10
	_sampler.sample = _sample_traffic
	root.add_child(_sampler)


func _crossing_point() -> Vector3:
	if _case == "crossing" or _case == "committed_priority":
		return Vector3(0, 0, -60)
	return Vector3(0, 0, -50)


func _sample_traffic(_delta: float) -> void:
	if _done:
		return
	_tick += 1
	var time: float = _scenario.get_elapsed()
	var cost := Navigator.get_frame_used()
	_costs.push_back(cost)
	_pass_costs.push_back(Traffic.get_last_usec())
	_case_costs.push_back(cost)
	if cost > _worst_at.x:
		_worst_at = Vector2(cost, time)
	var settled := true
	for i in _used:
		var ship := _ships[i]
		var orders := ship.get_node("%Orders") as ShipOrders
		var status := ship.get_traffic_status()
		if _seen[i].is_empty() or _seen[i].values()[-1] != status:
			_seen[i][time] = status
		if _contact_tick[i] < 0 and ship.get_order_status().contains("contact stop"):
			_contact_tick[i] = _tick
			_contact_pending[i] = orders.get_pending_count()
			_contact_order[i] = ship.has_order()
		var distance := RouteGuidance.planar(ship.global_position - _crossing_point()).length()
		if distance < _closest[i].x:
			_closest[i] = Vector2(distance, time)
		_min_x[i] = minf(_min_x[i], ship.global_position.x)
		_max_abs_x[i] = maxf(_max_abs_x[i], absf(ship.global_position.x))
		if (ship.has_order() and not ship.is_blocked()) or orders.get_pending_count() > 0 or ship.velocity.length() > 0.01:
			settled = false
	_quiet = _quiet + 1 if settled and time > 1.0 else 0
	if _quiet >= 30 or time >= 120.0:
		_done = true
		_check_traffic(time)
		_next.call_deferred()


func _statuses(i: int) -> String:
	var parts: Array[String] = []
	for time: float in _seen[i]:
		parts.push_back("%.2f %s" % [time, _seen[i][time]])
	return ", ".join(parts)


func _saw(i: int, prefix: String) -> bool:
	for status: String in _seen[i].values():
		if status.begins_with(prefix):
			return true
	return false


func _arrived(i: int) -> bool:
	return _ships[i].get_order_status().begins_with("arrived")


func _no_contact() -> bool:
	for tick in _contact_tick:
		if tick >= 0:
			return false
	return true


func _check_traffic(time: float) -> void:
	var lines: Array[String] = []
	for i in _used:
		var ship := _ships[i]
		lines.push_back("%s at (%.1f, %.1f): %s; closest to crossing %.1f m at %.2f s; min x %.1f; traffic: %s" % [ship.name,
			ship.global_position.x, ship.global_position.z, ship.get_order_status(), _closest[i].x, _closest[i].y, _min_x[i], _statuses(i)])
	var detail := "finished %.2f s; %s (worst at %.2f s)\n    %s" % [time, _cost_text(_case_costs), _worst_at.y, "\n    ".join(lines)]
	var passed := false
	match _case:
		"crossing":
			passed = _no_contact() and _arrived(0) and _arrived(1) and _arrived(2) \
				and _closest[0].y < _closest[1].y and _closest[1].y < _closest[2].y
		"acceleration_priority", "committed_priority":
			passed = _no_contact() and _arrived(0) and _arrived(1) and _closest[1].y < _closest[0].y and _saw(0, "yielding to Ship1")
		"tie":
			passed = _no_contact() and _arrived(0) and _arrived(1) and _closest[0].y < _closest[1].y and _saw(1, "yielding to Ship0")
		"back_out":
			passed = _no_contact() and _arrived(0) and _arrived(1) and _saw(1, "making room for Ship0") and _min_x[1] < -10.0
		"parked_blocker":
			passed = _no_contact() and _arrived(0) and _saw(0, "going around parked ship Ship1") and _max_abs_x[0] > 10.0
		"exhausted_recovery":
			passed = _no_contact() and _ships[0].is_blocked() and _ships[0].get_traffic_status() == "blocked by parked ship Ship1"
		"replacement_while_yielding":
			var yielded := false
			var released := false
			for t: float in _seen[1]:
				if t < 7.3 and _seen[1][t] == "yielding to Ship0":
					yielded = true
				if t >= 7.3 and _seen[1][t] != "yielding to Ship0":
					released = true
			passed = _no_contact() and yielded and released and _ships[1].get_order_status().begins_with("arrived at (60.0, 20.0)")
		"contact":
			var activated_after := true
			for i in 2:
				activated_after = activated_after and (_ships[i].get_node("%Orders") as ShipOrders).get_last_activated_time() > 1.0
			passed = _contact_tick[0] > 0 and _contact_tick[0] == _contact_tick[1] and not _contact_order[0] and not _contact_order[1] \
				and _contact_pending[0] > 0 and _contact_pending[1] > 0 and activated_after
			detail += "\n    contact ticks %d / %d, pending at contact %d / %d" % [_contact_tick[0], _contact_tick[1], _contact_pending[0], _contact_pending[1]]
	_report(passed, detail)


func _cost_text(costs: PackedInt32Array) -> String:
	var sorted := costs.duplicate()
	sorted.sort()
	var over := 0
	for cost in sorted:
		if cost > BUDGET_USEC:
			over += 1
	var last := sorted.size() - 1
	return "navigation tick cost over %d ticks: median %d us, p95 %d, p99 %d, worst %d, over %d us: %d" % [sorted.size(),
		sorted[mini(int(0.5 * sorted.size()), last)], sorted[mini(int(0.95 * sorted.size()), last)],
		sorted[mini(int(0.99 * sorted.size()), last)], sorted[last], BUDGET_USEC, over]
