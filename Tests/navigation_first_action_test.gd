extends SceneTree
## #60's first-action stop gate, before live navigation cutover. Uses the existing pilot/hull in ManeuverRollout's
## segment mode. Actual ships brake normally while proofs run; stale results cannot be adopted. Path acquisition
## is deliberately excluded: these timings are an optimistic lower bound, not a claim of complete navigator cost.
## --script res://Tests/navigation_first_action_test.gd

class Sampler extends Node:
	var sample: Callable
	func _physics_process(delta: float) -> void:
		sample.call(delta)

var _game: Node3D
var _ships: Array[ShipMovement] = []
var _probes: Array[HullProbe] = []
var _jobs: Array[ManeuverRollout] = []
var _results: Array = []
var _counts := [1, 5, 10]
var _count := 0
var _next_count := 0
var _group_frame := -1
var _next_job := 0
var _ready_frames: Array = []
var _proof_times: Array = []
var _adopted := 0
var _group_worst := 0
var _overruns := 0
var _group_used := 0
var _failures := 0
var _functional_done := false
var _delta := 1.0 / 60.0
var _hz := 60

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--hz="):
			_hz = int(arg.trim_prefix("--hz="))
	Engine.physics_ticks_per_second = _hz
	_delta = 1.0 / _hz
	_start.call_deferred()

func _start() -> void:
	_game = load("res://Main/main.tscn").instantiate()
	root.add_child(_game)
	var first: ShipMovement = _game.get_node("Ship")
	# These ships share static geometry but do not collide with one another: ship avoidance is out of scope.
	first.collision_layer = 0
	_ships.push_back(first)
	for i in 9:
		var ship: ShipMovement = load("res://Ships/ship.tscn").instantiate()
		ship.collision_layer = 0
		_game.add_child(ship)
		_ships.push_back(ship)
	for ship in _ships:
		_probes.push_back(HullProbe.new(ship, ship.get_node("CollisionShape3D")))
	var sampler := Sampler.new()
	sampler.process_physics_priority = -10
	sampler.sample = _sample
	root.add_child(sampler)

func _sample(_tick_delta: float) -> void:
	var map := _ships[0].get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return
	if not NavigationServer3D.map_get_closest_point_owner(map, Vector3.ZERO).is_valid():
		return
	if not _functional_done:
		_functional_checks(map)
		_functional_done = true
		return
	if _group_frame < 0:
		if _next_count >= _counts.size():
			_finish()
			return
		_count = _counts[_next_count]
		_next_count += 1
		_group_frame = Engine.get_physics_frames()
		_next_job = 0
		_jobs.clear()
		_ready_frames.clear()
		_proof_times.clear()
		_adopted = 0
		_group_worst = 0
		_overruns = 0
		_group_used = 0
		for ship in _ships:
			ship.global_position = Vector3.ZERO
			ship.rotation.y = 0.0
			ship.velocity = Vector3.FORWARD * 15.0
			ship.reset_physics_interpolation()
	var started := Time.get_ticks_usec()
	var clock := PlanClock.new(started + Navigator.BUDGET.plan_time_per_tick, Navigator.BUDGET.plan_time_per_tick)
	while _next_job < _count:
		if _jobs.size() <= _next_job:
			if not clock.has_time():
				break
			# Allocate/snapshot under the same allowance. All first-action requests were activated on group_frame.
			var ship := _ships[_next_job]
			var start := ship.get_pilot_state()
			var plan := RouteGuidance.make_plan(RouteGuidance.Kind.DIRECT,
				PackedVector3Array([start.position, Vector3(0, 0, -300)]), Vector3(0, 0, -300), ship.profile.detour_lookahead_distance)
			var check := ManeuverRollout.new(plan, start, ship.profile, _probes[_next_job], [], false, _delta, map)
			# One tick is the shortest possible positive response, more optimistic than the 0.25 s maximum.
			check.verify_segment(1, 1, Engine.get_physics_frames())
			_jobs.push_back(check)
			_proof_times.push_back(0)
			clock.item_done()
		var check := _jobs[_next_job]
		var proof_started := Time.get_ticks_usec()
		var outcome := check.run(clock)
		_proof_times[_next_job] += Time.get_ticks_usec() - proof_started
		if outcome == ManeuverRollout.RUNNING:
			break
		var latency := Engine.get_physics_frames() - _group_frame
		_ready_frames.push_back(latency)
		var matches := check.segment_matches(_ships[_next_job].get_pilot_state(), 1, Engine.get_physics_frames())
		if matches:
			_adopted += 1
		print("FIRST_ACTION_JOB ", JSON.stringify({ships = _count, index = _next_job,
			ready_after_ticks = latency, predicted_ticks = check.simulated_ticks, proof_usec = _proof_times[_next_job],
			result = outcome, prefix_clear = check.segment_clear, verified = check.segment_verified,
			current_handoff = matches, reason = check.failure}))
		_next_job += 1
	var used := Time.get_ticks_usec() - started
	_group_used += used
	_group_worst = maxi(_group_worst, used)
	if used > Navigator.BUDGET.plan_time_per_tick:
		_overruns += 1
	if _next_job >= _count:
		var row := {ships = _count, hz = _hz, ready_after_ticks = _ready_frames.duplicate(),
			proof_usec = _proof_times.duplicate(), first_current_handoffs = _adopted,
			worst_shared_test_usec = _group_worst, shared_test_overruns = _overruns, total_test_usec = _group_used,
			includes_path_acquisition = false}
		_results.push_back(row)
		print("FIRST_ACTION_GROUP ", JSON.stringify(row))
		_group_frame = -1

func _functional_checks(map: RID) -> void:
	var ship := _ships[0]
	var state := ship.get_pilot_state()
	state.position = Vector3(40, 0, 0)
	state.velocity = Vector3.RIGHT * 15.0
	state.yaw = -PI / 2.0
	state.bow = ShipPilot.bow_of(state.yaw)
	var plan := RouteGuidance.make_plan(RouteGuidance.Kind.DIRECT,
		PackedVector3Array([state.position, Vector3(130, 0, 0)]), Vector3(130, 0, 0), ship.profile.detour_lookahead_distance)
	var check := ManeuverRollout.new(plan, state, ship.profile, _probes[0], [], false, _delta, map)
	check.verify_segment(1, 1, Engine.get_physics_frames())
	var result := check.run(PlanClock.new(Time.get_ticks_usec() + 1000000, 1000000))
	_assert(result == ManeuverRollout.FAIL and check.segment_clear and not check.segment_verified,
		"clear first segment with unsafe stopping tail is rejected: " + check.failure)
	_assert(not check.segment_matches(state, 1, Engine.get_physics_frames()), "failed stopping tail cannot hand over")
	# A safe, completed proof still cannot cross an order generation/frame or omit previous pilot state.
	state.position = Vector3.ZERO
	state.velocity = Vector3.FORWARD * 5.0
	state.yaw = 0.0
	state.bow = Vector3.FORWARD
	plan = RouteGuidance.make_plan(RouteGuidance.Kind.DIRECT, PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -100)]), Vector3(0, 0, -100), ship.profile.detour_lookahead_distance)
	check = ManeuverRollout.new(plan, state, ship.profile, _probes[0], [], false, _delta, map)
	check.verify_segment(1, 12, Engine.get_physics_frames())
	_assert(not check.segment_matches(state, 12, Engine.get_physics_frames()), "unfinished proof cannot hand over")
	result = check.run(PlanClock.new(Time.get_ticks_usec() + 1000000, 1000000))
	_assert(result == ManeuverRollout.PASS and check.segment_matches(state, 12, Engine.get_physics_frames()), "safe segment and full stopping tail pass at matching checkpoint")
	_assert(not check.segment_matches(state, 13, Engine.get_physics_frames()), "new activated order invalidates old generation")
	_assert(not check.segment_matches(state, 12, Engine.get_physics_frames() + 1), "late checkpoint cannot hand over")
	state.planar_fraction_prev += 0.1
	_assert(not check.segment_matches(state, 12, Engine.get_physics_frames()), "changed previous planar demand invalidates proof")
	state.planar_fraction_prev -= 0.1
	state.speed_prev += 0.1
	_assert(not check.segment_matches(state, 12, Engine.get_physics_frames()), "changed previous speed invalidates proof")

func _assert(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		_failures += 1

func _finish() -> void:
	var gate_passed := _failures == 0
	for result in _results:
		gate_passed = gate_passed and result.first_current_handoffs == result.ships and result.shared_test_overruns == 0
		for ready_tick in result.ready_after_ticks:
			gate_passed = gate_passed and ready_tick == 0
	var output := "res://.godot/issue60/first_action_%d.json" % _hz
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify({functional_failures = _failures, response_gate_passed = gate_passed, groups = _results}, "\t"))
	print("FIRST_ACTION_GATE ", "PASS" if gate_passed else "STRICT STOP: response/budget gate not met", "; functional failures=", _failures)
	quit(0 if gate_passed else 1)
