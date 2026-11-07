extends SceneTree
## Focused #60 checks of cheap clear-space response, unsafe stopping room and the actual shared navigator cost.
## --script res://Tests/navigation_first_action_test.gd -- --ships=5
class Sampler extends Node:
	var sample: Callable
	func _physics_process(delta: float) -> void:
		sample.call(delta)

var _game: Node3D
var _ships: Array[ShipMovement] = []
var _count := 1
var _warmup := 0
var _armed := false
var _start := 0.0
var _failures := 0
var _worst := 0
var _overruns := 0
var _overrun_frames: Array = []
var _activated: Array = []
var _responded: Array = []
var _start_frames: Array = []
var _response_frames: Array = []
var _edge_declined := false
var _safe_open := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ships="):
			_count = int(arg.trim_prefix("--ships="))
	_start_scene.call_deferred()

func _start_scene() -> void:
	_game = load("res://Main/main.tscn").instantiate()
	root.add_child(_game)
	_ships.push_back(_game.get_node("Ship"))
	for i in _count - 1:
		var ship: ShipMovement = load("res://Ships/ship.tscn").instantiate()
		_game.add_child(ship)
		_ships.push_back(ship)
	for ship in _ships:
		ship.collision_layer = 0
		_activated.push_back(-1.0)
		_responded.push_back(-1.0)
		_start_frames.push_back(-1)
		_response_frames.push_back(-1)
	var sampler := Sampler.new()
	sampler.process_physics_priority = 10
	sampler.sample = _sample
	root.add_child(sampler)

func _sample(delta: float) -> void:
	var used := Navigator.get_frame_used()
	_worst = maxi(_worst, used)
	if used > Navigator.BUDGET.plan_time_per_tick:
		_overruns += 1
		_overrun_frames.push_back({frame = Engine.get_physics_frames(), armed = _armed, used = used})
	var map := _ships[0].get_world_3d().navigation_map
	if not _armed:
		_warmup += 1
		if _warmup < 12 or NavigationServer3D.map_get_iteration_id(map) == 0:
			return
		if not NavigationServer3D.map_get_closest_point_owner(map, Vector3.ZERO).is_valid():
			return
		_armed = true
		_start = _ships[0].get_clock()
		var probe := HullProbe.new(_ships[0], _ships[0].get_node("CollisionShape3D"))
		var state := _ships[0].get_pilot_state()
		state.velocity = Vector3.FORWARD * 15.0
		_safe_open = probe.open_stopping_room(_ships[0].profile, state, delta, map)
		_check(_safe_open, "cruise in clear space uses the geometric stopping envelope")
		state.position = Vector3(40, 0, 0)
		state.velocity = Vector3.RIGHT * 15.0
		state.yaw = -PI / 2.0
		state.bow = ShipPilot.bow_of(state.yaw)
		_edge_declined = not probe.open_stopping_room(_ships[0].profile, state, delta, map)
		_check(_edge_declined, "obstacle-edge envelope is inconclusive and requires local examination")
		_check(not HullProbe.capsule_on_mesh(map, Vector3(71.76439, 0, 16.01325), Vector3(78.0174, 0, 15.2489), 0.0),
			"a zero-width stopping line crossing the polygon edge is not clear")
		var targets := ShipPilot.Targets.new()
		targets.has_order = true
		targets.destination = Vector3(130, 0, 0)
		targets.has_course = true
		targets.course_yaw = state.yaw
		_check(not ManeuverRollout.local_clear(_ships[0].profile, probe, state, targets, delta, map),
			"clear first motion with unsafe stopping room is rejected locally")
		var superseded := Navigator.start_job(_ships[0], probe, Vector3(83, 0, 0))
		superseded.cancel()
		Navigator.service()
		_check(superseded.status == Navigator.Status.CANCELLED and superseded.plan == null,
			"cancelled pending route cannot publish stale guidance")
		for i in _ships.size():
			var ship := _ships[i]
			ship.global_position = Vector3(-25 + 5 * i, 0, -30)
			ship.velocity = Vector3.FORWARD * 15.0
			ship.reset_physics_interpolation()
			ship.move_to(ship.global_position + Vector3(0, 0, -300))
		return
	var elapsed := _ships[0].get_clock() - _start
	for i in _ships.size():
		var ship := _ships[i]
		if _activated[i] < 0.0 and ship.get_last_activated_time() >= _start:
			_activated[i] = ship.get_clock() - _start
			_start_frames[i] = Engine.get_physics_frames()
		if _activated[i] >= 0.0 and _responded[i] < 0.0 and ship.get_main_command() > 0.0:
			_responded[i] = ship.get_clock() - _start
			_response_frames[i] = Engine.get_physics_frames()
	if elapsed >= 1.0:
		for i in _ships.size():
			_check(_start_frames[i] >= 0 and _start_frames[i] == _response_frames[i],
				"ship %d responds on its activation tick" % i)
		_check(_overruns == 0, "shared navigation frame stays within 1500 us (worst %d, overruns %d)" % [_worst, _overruns])
		var result := {ships = _count, failures = _failures, activation = _activated, response = _responded,
			activation_frames = _start_frames, response_frames = _response_frames,
			worst_shared_navigation_usec = _worst, overruns = _overruns, overrun_frames = _overrun_frames,
			quick_open = _safe_open, obstacle_edge_needs_local = _edge_declined}
		DirAccess.make_dir_recursive_absolute("res://.godot/issue60/revised")
		var file := FileAccess.open("res://.godot/issue60/revised/response_%d.json" % _count, FileAccess.WRITE)
		file.store_string(JSON.stringify(result, "\t"))
		print("RESPONSE_RESULT ", JSON.stringify(result))
		quit(1 if _failures > 0 else 0)

func _check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		_failures += 1
