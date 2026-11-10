extends SceneTree
## PRD 2 (#85): 16-order asteroid cluster check. ShipMiddle crosses cluster C on a 300 m straight line through its
## centre, from rest or moving 12 m/s across the line; ShipLeft and ShipRight are moved out of the way.
## godot --headless --fixed-fps 60 --path . --script res://Tests/cluster_crossing_test.gd [-- --angle=<deg> --speed=<m/s>]
## Without arguments it runs angles 0 to 315 in steps of 45 at speeds 0 and 12, each in its own child process, and
## prints one table row per order and a summary.

class Sampler extends Node:
	var sample: Callable
	func _physics_process(delta: float) -> void:
		sample.call(delta)

const ANGLES: Array[int] = [0, 45, 90, 135, 180, 225, 270, 315]
const SPEEDS: Array[float] = [0.0, 12.0]
const CENTRE := Vector3(50, 0, 205)
const HALF_LENGTH := 150.0
const SLOW_SPEED := 2.0
const TIME_LIMIT := 180.0

var _angle := NAN
var _speed := NAN

# Child state.
var _game: Node3D
var _ship: ShipMovement
var _warmup := 0
var _armed := false
var _done := false
var _elapsed := 0.0
var _flown := 0.0
var _slow := 0.0
var _last := Vector3.ZERO


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--angle="):
			_angle = float(arg.trim_prefix("--angle="))
		if arg.begins_with("--speed="):
			_speed = float(arg.trim_prefix("--speed="))
	if is_nan(_angle) and is_nan(_speed):
		_run_children()
		return
	_angle = 0.0 if is_nan(_angle) else _angle
	_speed = 0.0 if is_nan(_speed) else _speed
	_start.call_deferred()


## Runs every default order in a fresh child process and prints the rows and a summary per speed.
func _run_children() -> void:
	var rows: Array[String] = []
	var results: Array[Dictionary] = []
	var failed := false
	for speed in SPEEDS:
		for angle in ANGLES:
			var output: Array = []
			var args := ["--headless", "--fixed-fps", "60", "--path", ProjectSettings.globalize_path("res://"),
				"--script", "res://Tests/cluster_crossing_test.gd", "--", "--angle=%d" % angle, "--speed=%s" % speed]
			OS.execute(OS.get_executable_path(), args, output, true)
			var found := false
			for line in String("\n".join(output)).split("\n"):
				if line.begins_with("CLUSTER "):
					rows.push_back(line.trim_prefix("CLUSTER "))
				if line.begins_with("RESULT "):
					results.push_back(JSON.parse_string(line.trim_prefix("RESULT ")))
					found = true
			if not found:
				rows.push_back("| %d deg | %s m/s | no result (child process output missing) | | | | |" % [angle, speed])
				failed = true
	print("| Angle | Speed | Outcome | Time | Flown | Below %s m/s | Route refresh |" % SLOW_SPEED)
	print("| --- | --- | --- | --- | --- | --- | --- |")
	for row in rows:
		print(row)
	print("")
	print("| Start | Arrived | Stuck planning | Blocked | Other | Arrival time |")
	print("| --- | --- | --- | --- | --- | --- |")
	for speed in SPEEDS:
		var arrived := 0
		var planning := 0
		var blocked := 0
		var other := 0
		var times: Array[float] = []
		for result in results:
			if result.speed != speed:
				continue
			match result.outcome:
				"arrived":
					arrived += 1
					times.push_back(result.seconds)
				"timeout (planning)":
					planning += 1
				"blocked":
					blocked += 1
				_:
					other += 1
		var span := "none" if times.is_empty() else "%.0f to %.0f s" % [times.min(), times.max()]
		print("| %s | %d of %d | %d | %d | %d | %s |" % ["from rest" if speed == 0.0 else "moving %s m/s" % speed, arrived,
			ANGLES.size(), planning, blocked, other, span])
	print("CLUSTER_CROSSING_TEST %s" % ("FAIL" if failed else "DONE"))
	quit(1 if failed else 0)


func _start() -> void:
	_game = load("res://Main/main.tscn").instantiate()
	root.add_child(_game)
	_ship = _game.get_node("ShipMiddle")
	var sampler := Sampler.new()
	sampler.process_physics_priority = 100
	sampler.sample = _sample
	root.add_child(sampler)


func _sample(delta: float) -> void:
	if _done:
		return
	if not _armed:
		_warmup += 1
		if _warmup < 12:
			return
		if not NavigationServer3D.map_get_closest_point_owner(_ship.get_world_3d().navigation_map, Vector3.ZERO).is_valid():
			return
		_armed = true
		_begin()
		return
	_elapsed += delta
	var position := _ship.global_position
	_flown += RouteGuidance.planar(position - _last).length()
	_last = position
	if _ship.velocity.length() < SLOW_SPEED:
		_slow += delta
	var outcome := _outcome()
	if outcome != "" or _elapsed >= TIME_LIMIT:
		_done = true
		if outcome == "":
			outcome = "timeout (planning)" if _ship.is_planning() else "timeout (%s)" % _ship.get_order_status().get_slice(" ", 0)
		_finish(outcome)


func _begin() -> void:
	var left := _game.get_node("ShipLeft") as ShipMovement
	var right := _game.get_node("ShipRight") as ShipMovement
	left.global_position = Vector3(-350, 0, -350)
	right.global_position = Vector3(-310, 0, -350)
	var a := deg_to_rad(_angle)
	var out := Vector3(sin(a), 0, -cos(a))
	_ship.global_position = CENTRE + out * HALF_LENGTH
	var bow := -out
	if _speed > 0.0:
		_ship.velocity = out.cross(Vector3.UP) * _speed
		bow = _ship.velocity.normalized()
	_ship.rotation.y = atan2(-bow.x, -bow.z)
	for ship in [_ship, left, right]:
		ship.reset_physics_interpolation()
	_last = _ship.global_position
	(_ship.get_node("%Orders") as ShipOrders).move(CENTRE - out * HALF_LENGTH)


## The terminal outcome so far, or "" while the order is still running.
func _outcome() -> String:
	var status := _ship.get_order_status()
	if status.begins_with("arrived"):
		return "arrived"
	if status.begins_with("declined"):
		return "declined"
	if status.contains("contact stop"):
		return "contact"
	if _ship.is_blocked():
		return "blocked"
	return ""


func _finish(outcome: String) -> void:
	# Test-only read (as in navigation_stage1_test.gd): set when the ship refreshed its route, until the next order.
	var refreshed: bool = _ship._route_refreshed
	print("CLUSTER | %d deg | %s m/s | %s | %.2f s | %.1f m | %.2f s | %s |" % [_angle, _speed, outcome, _elapsed, _flown, _slow,
		"yes" if refreshed else "no"])
	print("RESULT ", JSON.stringify({angle = _angle, speed = _speed, outcome = outcome, seconds = _elapsed, flown = _flown,
		slow = _slow, refresh = refreshed, status = _ship.get_order_status()}))
	quit()
