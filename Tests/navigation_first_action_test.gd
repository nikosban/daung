extends SceneTree
## Focused #60 checks of cheap clear-space response, unsafe stopping room and the actual shared navigator cost.
## --script res://Tests/navigation_first_action_test.gd -- --ships=5 [--hazard]
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
var _hazard := false
var _redirected := false
var _activation_after := 0.0
var _local_ticks: Array = []
var _max_local_ships := 0
var _max_no_go: Array = []
var _entered: Array = []
var _contacts: Array = []
var _last_status: Array = []
var _stopped: Array = []
var _stop_events: Array = []
var _arrived: Array = []
var _redirect_received := -1.0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ships="):
			_count = int(arg.trim_prefix("--ships="))
		if arg == "--hazard":
			_hazard = true
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
		_local_ticks.push_back(0)
		_max_no_go.push_back(0.0)
		_entered.push_back(false)
		_contacts.push_back(0)
		_last_status.push_back("")
		_stopped.push_back(false)
		_arrived.push_back(-1.0)
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
		# Cold and reused cell queries must agree with the exact rule, including either side of a threshold.
		var inside := Vector3(83, 0, 0)
		var boundary := NavigationServer3D.map_get_closest_point(map, inside)
		var into_hole := (inside - boundary).normalized()
		var same := true
		for repeat in 2:
			for offset in [-0.2, 0.0, 0.0999, 0.1, 0.1001, 0.2499, 0.25, 0.2501, 0.4999, 0.5, 0.5001]:
				var point: Vector3 = boundary + into_hole * offset
				var exact := RouteGuidance.planar(NavigationServer3D.map_get_closest_point(map, point) - point).length()
				for limit in [0.0, 0.1, 0.25, 0.5]:
					same = same and HullProbe.centre_within(map, point, limit) == (exact <= limit)
		_check(same, "cold and reused clearance bounds preserve exact threshold decisions")
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
			ship.global_position = Vector3(238 + i * 0.05, 0, -162 - i * 0.05) if _hazard else Vector3(-25 + 5 * i, 0, -30)
			ship.velocity = Vector3.ZERO if _hazard else Vector3.FORWARD * 15.0
			ship.reset_physics_interpolation()
			ship.move_to(Vector3(170, 0, -90) if _hazard else ship.global_position + Vector3(0, 0, -300))
		return
	var elapsed := _ships[0].get_clock() - _start
	if _hazard and not _redirected and elapsed + 1e-7 >= 6.0 - _ships[0].profile.reaction_delay:
		_redirected = true
		_activation_after = _ships[0].get_clock()
		_redirect_received = elapsed
		for i in _ships.size():
			_activated[i] = -1.0
			_responded[i] = -1.0
			_start_frames[i] = -1
			_response_frames[i] = -1
			_ships[i].move_to(Vector3(240, 0, -201))
	var local_ships := 0
	for i in _ships.size():
		var ship := _ships[i]
		if _activated[i] < 0.0 and ship.get_last_activated_time() >= maxf(_start, _activation_after):
			_activated[i] = ship.get_clock() - _start
			_start_frames[i] = Engine.get_physics_frames()
		# This moving A2 redirect calls for braking. Count opposing thrust, not merely a continuing old engine command.
		var responding := ship.get_thruster_command().dot(ship.velocity) < 0.0 if _hazard and _redirected else (ship.get_main_command() > 0.0 or ship.get_thruster_command().length() > 0.0)
		if _activated[i] >= 0.0 and _responded[i] < 0.0 and responding:
			_responded[i] = ship.get_clock() - _start
			_response_frames[i] = Engine.get_physics_frames()
		if _hazard:
			var status := ship.get_order_status()
			var physical := status.contains("local hull/stop") or status.contains("physical clearance")
			if physical:
				_local_ticks[i] += 1
				local_ships += 1
			if status.begins_with("static-contact") and status != _last_status[i]:
				_contacts[i] += 1
			_last_status[i] = status
			var nearest := NavigationServer3D.map_get_closest_point(map, ship.global_position)
			var off_mesh := RouteGuidance.planar(nearest - ship.global_position).length()
			if off_mesh <= NavigationServer3D.map_get_cell_size(map):
				_entered[i] = true
			if _entered[i]:
				_max_no_go[i] = maxf(_max_no_go[i], off_mesh)
			if ship.velocity.length() > ship.profile.arrival_speed_tolerance:
				_stopped[i] = false
			if not _stopped[i] and elapsed > 1.0 and ship.velocity.length() <= ManeuverRollout.REST_SPEED and ship.global_position.distance_to(ship.get_destination()) > ship.profile.detour_lookahead_distance:
				_stopped[i] = true
				_stop_events.push_back({ship = i, time = elapsed, planning = ship.is_planning(), physical_clearance = physical or status.contains("blocked"), status = status})
			if _redirected and status.begins_with("arrived") and _arrived[i] < 0.0:
				_arrived[i] = elapsed
	_max_local_ships = maxi(_max_local_ships, local_ships)
	var complete := elapsed >= 1.0
	if _hazard:
		complete = (_redirected and not _arrived.has(-1.0) and elapsed > 30.0) or elapsed >= 60.0
	if complete:
		for i in _ships.size():
			_check(_start_frames[i] >= 0 and _start_frames[i] == _response_frames[i],
				"ship %d responds on its activation tick" % i)
		_check(_overruns == 0, "shared navigation frame stays within 1500 us (worst %d, overruns %d)" % [_worst, _overruns])
		if _hazard:
			_check(_max_local_ships == _count, "all ships simultaneously exercise local hazard clearance")
			_check(not _arrived.has(-1.0), "all moving cluster redirects arrive")
			_check(_stop_events.is_empty(), "no ship stops away from its destination")
			for i in _ships.size():
				_check(_contacts[i] == 0 and _max_no_go[i] <= _ships[i].profile.no_go_tolerance + 1e-4, "ship %d has no contact or forbidden centre intrusion" % i)
		var result := {ships = _count, failures = _failures, activation = _activated, response = _responded,
			activation_frames = _start_frames, response_frames = _response_frames,
			worst_shared_navigation_usec = _worst, overruns = _overruns, overrun_frames = _overrun_frames,
			quick_open = _safe_open, obstacle_edge_needs_local = _edge_declined,
			hazard = _hazard, redirect_received = _redirect_received, local_ticks = _local_ticks, max_simultaneous_local_ships = _max_local_ships,
			arrival_times = _arrived, contacts = _contacts, no_go_after_entry = _max_no_go, stop_events = _stop_events}
		DirAccess.make_dir_recursive_absolute("res://.godot/issue60/revised")
		var file := FileAccess.open("res://.godot/issue60/revised/%s_%d.json" % ["hazard" if _hazard else "response", _count], FileAccess.WRITE)
		file.store_string(JSON.stringify(result, "\t"))
		print("RESPONSE_RESULT ", JSON.stringify(result))
		quit(1 if _failures > 0 else 0)

func _check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		_failures += 1
