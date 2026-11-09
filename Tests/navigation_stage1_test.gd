extends SceneTree
## Focused real-scene evidence for #60. No game controls or movement implementation.
## --script res://Tests/navigation_stage1_test.gd -- --case=clear --output=res://.godot/issue60/baseline
## A2 names explicitly distinguish command receipt from activation timing.

class Sampler extends Node:
	var sample: Callable
	func _physics_process(delta: float) -> void:
		sample.call(delta)

var _case := "clear"
var _output := "res://.godot/issue60/baseline"
var _game: Node3D
var _ship: ShipMovement
var _orders: ShipOrders
var _armed := false
var _warmup := 0
var _warmup_limit := 12
var _check := false
var _entered_mesh := false
var _intrusion_after_entry := 0.0
var _start := 0.0
var _redirect_at := -1.0
var _redirected := false
var _first_activation := -1.0
var _response := -1.0
var _planning_done := -1.0
var _arrival := -1.0
var _rest_ticks := 0
var _max_off_mesh := 0.0
var _worst_mesh_sample := {}
var _closest_centre := INF
var _min_speed := INF
var _contacts := 0
var _worst_navigation := 0
var _overruns := 0
var _overrun_events: Array = []
var _last_status := ""
var _events: Array = []
var _trace := PackedFloat64Array()
var _asteroids: Array[Node3D] = []
var _nw_refreshes := 0
var _nw_refresh_job: Navigator.Job
var _nw_translate_turn_ticks := 0
var _nw_terminal := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--case="):
			_case = arg.trim_prefix("--case=")
		if arg.begins_with("--output="):
			_output = arg.trim_prefix("--output=")
		if arg.begins_with("--warmup="):
			_warmup_limit = int(arg.trim_prefix("--warmup="))
		if arg == "--check":
			_check = true
	_start_scene.call_deferred()

func _start_scene() -> void:
	_game = load("res://Main/main.tscn").instantiate()
	root.add_child(_game)
	_ship = _game.get_node("Ship")
	_orders = _ship.get_node("%Orders")
	for body in get_nodes_in_group("navigation_source"):
		if body is StaticBody3D and body.get_node_or_null("CollisionShape3D").shape is SphereShape3D:
			_asteroids.push_back(body)
	var sampler := Sampler.new()
	sampler.process_physics_priority = 10
	sampler.sample = _sample
	root.add_child(sampler)

func _sample(_delta: float) -> void:
	if not _armed:
		_warmup += 1
		if _warmup < _warmup_limit:
			return
		# A fixed-fps headless run can advance many ticks before the nav worker finishes.
		# Map iteration alone is insufficient: wait for actual polygon ownership.
		if not NavigationServer3D.map_get_closest_point_owner(_ship.get_world_3d().navigation_map, Vector3.ZERO).is_valid():
			return
		_armed = true
		_start = _orders.get_clock()
		if _case == "nw_redirect":
			# Representative state, not a reconstruction of the owner's unknown original pose.
			# At activation the moving change is 95.9 degrees; the old fallback strands this same order.
			_ship.global_position = Vector3(-110, 0, -136)
			var toward := (Vector3(-134.6, 0, -131.8) - _ship.global_position).normalized()
			var previous := toward.rotated(Vector3.UP, deg_to_rad(-88))
			_ship.velocity = previous * 12.0
			_ship.rotation.y = atan2(-previous.x, -previous.z)
			_orders.move(Vector3(-134.6, 0, -131.8))
			_game.get_node("CameraRig").set_view(Vector3(-140, 0, -195), 110.0, 0.0)
			var key := InputEventKey.new()
			key.keycode = KEY_F3
			key.pressed = true
			_game.get_node("DebuggingSuite/MovementDebugOverlay")._unhandled_input(key)
		elif _case.begins_with("a2_"):
			_ship.global_position = Vector3(238, 0, -162)
			var seconds := float(_case.right(1))
			_redirect_at = seconds - (_orders.crew.reaction_delay if _case.begins_with("a2_activate") else 0.0)
			_orders.move(Vector3(170, 0, -90))
		elif _case == "detour":
			_orders.move(Vector3(130, 0, 0))
		elif _case == "tight":
			_ship.global_position = Vector3(120, 0, 235)
			_orders.move(Vector3(120, 0, 330))
		elif _case == "escape":
			_ship.global_position = Vector3(66.7, 0, 0)
			_ship.rotation.y = -PI / 2.0
			_orders.move(Vector3.ZERO)
		elif _case == "replacement":
			# Both commands become due on the same tick. The unresolved asteroid request must never take over later.
			_orders.move(Vector3(83, 0, 0))
			_orders.move(Vector3(60, 0, -40))
		elif _case == "redirect":
			_orders.move(Vector3(130, 0, 0))
			_redirect_at = 8.0
		elif _case == "crab10":
			_orders.move(Vector3(10, 0, 0))
		elif _case.begins_with("turn"):
			_ship.global_position = Vector3(1000, 0, 1000)
			_ship.velocity = Vector3.FORWARD * 15.0
			var angle := deg_to_rad(float(_case.trim_prefix("turn")))
			_orders.move(_ship.global_position + Vector3(sin(angle), 0, -cos(angle)) * 300.0)
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
		_orders.move(Vector3(240, 0, -201) if _case.begins_with("a2_") else Vector3(60, 0, -40))
		_events.push_back({event = "redirect_received", time = time, due = time + _orders.crew.reaction_delay})
	if _first_activation < 0.0 and _orders.get_last_activated_time() >= _start:
		_first_activation = time
	var status := _ship.get_order_status()
	if _case == "nw_redirect":
		if _ship._job != null and _ship._job.refresh and _ship._job != _nw_refresh_job:
			_nw_refresh_job = _ship._job
			_nw_refreshes += 1
		if status.contains("repositioning") and _ship.velocity.length() > 0.0 and absf(_ship.get_turn_rate()) > 0.0 and _ship.get_thruster_command().length() > 0.0:
			_nw_translate_turn_ticks += 1
		_nw_terminal = _nw_terminal or _ship._blocked
	if status != _last_status:
		_events.push_back({event = "status", time = time, status = status})
		_last_status = status
		if status.begins_with("static-contact"):
			_contacts += 1
	if _first_activation >= 0.0 and _response < 0.0 and (_ship.get_main_command() > 0.0 or _ship.get_thruster_command().length() > 0.0):
		_response = time
	if _first_activation >= 0.0 and _planning_done < 0.0 and not _ship.is_planning():
		_planning_done = time
	if status.begins_with("arrived") and _arrival < 0.0 and (_redirect_at < 0.0 or _redirected):
		_arrival = time
	var position := _ship.global_position
	var speed := _ship.velocity.length()
	for asteroid in _asteroids:
		_closest_centre = minf(_closest_centre, RouteGuidance.planar(position - asteroid.global_position).length())
	if absf(position.x) < 380.0 and absf(position.z) < 380.0:
		var closest := NavigationServer3D.map_get_closest_point(_ship.get_world_3d().navigation_map, position)
		var off_mesh := RouteGuidance.planar(closest - position).length()
		if off_mesh <= NavigationServer3D.map_get_cell_size(_ship.get_world_3d().navigation_map):
			_entered_mesh = true
		if _entered_mesh:
			_intrusion_after_entry = maxf(_intrusion_after_entry, off_mesh)
		if off_mesh > _max_off_mesh:
			_max_off_mesh = off_mesh
			_worst_mesh_sample = {time = time, position = str(position), closest = str(closest), iteration = NavigationServer3D.map_get_iteration_id(_ship.get_world_3d().navigation_map)}
	if _redirected and _ship.has_order() and position.distance_to(_ship.get_destination()) > 15.0:
		_min_speed = minf(_min_speed, speed)
	var used := Navigator.get_frame_used()
	_worst_navigation = maxi(_worst_navigation, used)
	if used > 1500:
		_overruns += 1
		_overrun_events.push_back({time = time, usec = used, status = status})
	_trace.append_array(PackedFloat64Array([time, position.x, position.z, _ship.velocity.x, _ship.velocity.z,
		_ship.rotation.y, _ship.get_turn_rate(), _ship.get_course_heading(), _ship.get_desired_speed(), float(_ship.has_order())]))
	if time > maxf(_redirect_at + 1.0, 1.0) and not _ship.has_order() and _orders.get_pending_count() == 0 and speed < 0.01:
		_rest_ticks += 1
	else:
		_rest_ticks = 0
	if _rest_ticks >= 30 or time >= 90.0:
		_finish(time)

func _finish(time: float) -> void:
	var bytes := _trace.to_byte_array()
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	var summary := {case = _case, engine = Engine.get_version_info().string, physics_hz = Engine.physics_ticks_per_second,
		first_activation = _first_activation, first_physical_response = _response, planning_done = _planning_done, arrival = _arrival, finish = time,
		position = [_ship.global_position.x, _ship.global_position.z], final_speed = _ship.velocity.length(),
		max_no_go_excursion = _max_off_mesh, no_go_after_mesh_entry = _intrusion_after_entry,
		worst_mesh_sample = _worst_mesh_sample, closest_asteroid_centre = _closest_centre,
		redirect_min_speed = _min_speed if _min_speed < INF else null, contacts = _contacts,
		worst_counted_navigation_usec = _worst_navigation, counted_overruns = _overruns, overrun_events = _overrun_events,
		status = _ship.get_order_status(), trace_sha256 = hashing.finish().hex_encode(), events = _events}
	if _case == "nw_redirect":
		summary.nw = {representative_not_exact_replay = true, course_change_degrees = _ship.get_reversal_angle(),
			path_refreshes = _nw_refreshes, translate_and_turn_ticks = _nw_translate_turn_ticks, terminal = _nw_terminal,
			same_order = is_equal_approx(_orders.get_last_activated_time() - _start, _first_activation),
			retained_destination = _ship.get_destination() == Vector3(-134.6, 0, -131.8)}
	DirAccess.make_dir_recursive_absolute(_output)
	var file := FileAccess.open(_output.path_join(_case + ".json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(summary, "\t"))
	file = FileAccess.open(_output.path_join(_case + ".trace"), FileAccess.WRITE)
	file.store_buffer(bytes)
	print("STAGE1_SCENE_RESULT ", JSON.stringify(summary))
	var finished := (_arrival >= 0.0) if _case != "stop" else (not _ship.has_order() and _ship.velocity.length() < 0.01)
	var passed := finished and _contacts == 0 and _intrusion_after_entry <= _ship.profile.no_go_tolerance + 1e-4 and _overruns == 0
	if _case == "nw_redirect":
		passed = passed and summary.nw.same_order and summary.nw.retained_destination and not _nw_terminal and _nw_refreshes == 1 and _nw_translate_turn_ticks > 0
		print("NW_CHECK ", JSON.stringify(summary.nw))
	if _check:
		print("SCENE_CHECK ", "PASS" if passed else "FAIL", " ", _case)
	quit(1 if _check and not passed else 0)
