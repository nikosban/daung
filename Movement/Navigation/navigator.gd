class_name Navigator
extends RefCounted
## #60: ordinary Godot route acquisition and local physical clearance, sharing one navigation allowance.
## Pending route work never implies braking. ShipMovement owns the order and all physical movement.

const BUDGET: NavigationBudget = preload("res://Movement/Navigation/navigation_budget.tres")
enum Status { PENDING, DONE, DECLINED, CANCELLED }
enum Clearance { OPEN, LOCAL, SLOW }

static var _jobs: Array[Job] = []
static var _ships: Array[ShipMovement] = []
static var _frame := -1
static var _frame_used := 0
static var _guided := 0
static var _runtime_peak := 0
static var _prepared_frame := -1


static func register_ship(ship: ShipMovement) -> void:
	if not _ships.has(ship):
		_ships.push_back(ship)


static func unregister_ship(ship: ShipMovement) -> void:
	_ships.erase(ship)
	for job in _jobs:
		if job._ship == ship:
			job.cancel()
	var map := ship.get_world_3d().navigation_map
	for remaining in _ships:
		if remaining.get_world_3d().navigation_map == map:
			return
	HullProbe.forget_space(map)


static func _begin_frame() -> void:
	if _frame != Engine.get_physics_frames():
		_frame = Engine.get_physics_frames()
		_frame_used = 0
		_guided = 0


static func measure() -> int:
	_begin_frame()
	return Time.get_ticks_usec()


static func account(start: int, runtime := false) -> void:
	var used := Time.get_ticks_usec() - start
	_frame_used += used
	if runtime:
		_runtime_peak = maxi(_runtime_peak, used)
		_guided += 1


static func start_job(ship: ShipMovement, probe: HullProbe, click: Vector3, _brake_first := false, refresh := false) -> Job:
	var start := measure()
	var job := Job.new(ship, probe, click, refresh)
	_jobs.push_back(job)
	account(start)
	return job


## Cache preparation, path queries and resolver work all run under the existing clock. Reserve the measured cost
## of live guidance for ships still to move this frame. Geometry checks are charged by the caller as well.
static func service() -> void:
	var start := measure()
	if _jobs.is_empty() and _prepared_frame == _frame:
		account(start)
		return # No route work; this frame's cache preparation has already had its slice.
	# Do not cap this at half the allowance: several ships beside hazards can need more than half
	# for live checks alone. Only route/preparation work yields; physical guidance still runs this tick.
	var reserve := _runtime_peak * maxi(_ships.size() - _guided, 0)
	var allowance := BUDGET.plan_time_per_tick - _frame_used - reserve
	if allowance > 0:
		var clock := PlanClock.new(start + allowance, BUDGET.plan_time_per_tick)
		if _prepared_frame != _frame:
			_prepared_frame = _frame
			# Static boundary preparation is background work. Leave half this slice for live guidance/dispatch,
			# as PlanClock already does for its largest atomic item; an unfinished cache never freezes movement.
			var preparation := PlanClock.new(start + allowance / 2, BUDGET.plan_time_per_tick)
			var maps: Array[RID] = []
			for ship in _ships:
				var map := ship.get_world_3d().navigation_map
				if not maps.has(map):
					maps.push_back(map)
					if preparation.has_time():
						HullProbe.prepare_space(map, ship.get_tree().root, preparation)
		var i := 0
		while i < _jobs.size() and clock.has_time():
			var job := _jobs[i]
			if job.status == Status.PENDING:
				job.advance(clock)
			if job.status != Status.PENDING:
				_jobs.remove_at(i)
			elif job.waiting:
				i += 1
			else:
				break
	account(start)


static func get_frame_used() -> int:
	return _frame_used


## Called from the actual start-of-tick state. Quick rejection means local examination, never unreachable.
## No async trajectory or checkpoint is handed back to the ship.
static func clearance(profile: MovementProfile, probe: HullProbe, actual: ShipPilot.State,
		targets: ShipPilot.Targets, delta: float, map: RID, on_mesh := true) -> int:
	if probe.open_stopping_room(profile, actual, delta, map):
		return Clearance.OPEN
	if ManeuverRollout.local_clear(profile, probe, actual, targets, delta, map, on_mesh):
		return Clearance.LOCAL
	return Clearance.SLOW


## A bounded correction toward the next ordinary route guide. Test a temporary target with the same pilot,
## including translation and turning; the caller applies it only when its hull and stopping room are clear.
static func reposition(profile: MovementProfile, probe: HullProbe, actual: ShipPilot.State,
		targets: ShipPilot.Targets, delta: float, map: RID, guide: Vector3, on_mesh := true) -> ShipPilot.Targets:
	var toward := RouteGuidance.planar(guide - actual.position)
	if toward == Vector3.ZERO:
		return null
	var candidate := ManeuverRollout._copy_targets(targets)
	candidate.use_steer = true
	candidate.steer_direction = toward.normalized()
	candidate.steer_distance = profile.detour_lookahead_distance
	# Keep the ordinary guide's course while crabbing/backing toward it; translation direction is not a new
	# heading request. This preserves the pilot's simultaneous translate-and-turn capability.
	candidate.course_follows = false
	candidate.bend_radii = PackedFloat32Array()
	if ManeuverRollout.local_clear(profile, probe, actual, candidate, delta, map, on_mesh):
		return candidate
	return null


class Job:
	var status := Status.PENDING
	var plan: RouteGuidance.Plan
	var baseline := false
	var waiting := false
	var reason := ""
	var summary := ""
	var used_usec := 0
	var ticks := 0
	var click := Vector3.ZERO
	var destination := Vector3.ZERO
	var resolution := ""
	var resolution_log := PackedStringArray()
	var worst_tick_usec := 0
	var _ship: ShipMovement
	var _probe: HullProbe
	var _route: RoutePlanner
	var _last_frame := -1
	var _tick_usec := 0
	var refresh := false

	func _init(ship: ShipMovement, probe: HullProbe, p_click: Vector3, p_refresh: bool) -> void:
		_ship = ship
		_probe = probe
		click = Vector3(p_click.x, ship.global_position.y, p_click.z)
		refresh = p_refresh
		destination = click
		probe.queries = 0
		_route = RoutePlanner.new(ship, ship.get_world_3d().navigation_map, probe, ship.profile, click,
			ship.get_pilot_state, Navigator.BUDGET.destination_candidates_per_order,
			Navigator.BUDGET.max_destination_displacement, refresh)

	func cancel() -> void:
		status = Status.CANCELLED

	func advance(clock: PlanClock) -> void:
		if status != Status.PENDING:
			return
		if not is_instance_valid(_ship):
			status = Status.CANCELLED
			return
		var start := Time.get_ticks_usec()
		if _last_frame != Engine.get_physics_frames():
			_last_frame = Engine.get_physics_frames()
			ticks += 1
			_tick_usec = 0
		var result := _route.run(clock)
		waiting = _route.waiting
		match result:
			RoutePlanner.BASELINE:
				plan = RouteGuidance.Plan.new()
				plan.destination = click
				baseline = true
				status = Status.DONE
				summary = _route.note
				# Task 37 (#78): reserved here, so jobs finishing later in this service call see it.
				EndpointReservations.reserve(_ship, click)
			RoutePlanner.DECLINED:
				status = Status.DECLINED
				reason = _route.note
			RoutePlanner.ROUTE:
				plan = _route.primary_plan
				destination = plan.destination
				status = Status.DONE
				EndpointReservations.reserve(_ship, destination)
				summary = "path guidance; clearance checked from actual motion"
		resolution = _route.resolution
		resolution_log = _route.resolution_log
		var used := Time.get_ticks_usec() - start
		used_usec += used
		_tick_usec += used
		worst_tick_usec = maxi(worst_tick_usec, _tick_usec)

	func query_text() -> String:
		return "%d closest-point, %d path, %d physics queries" % [_route.closest_queries, _route.path_queries, _probe.queries]
