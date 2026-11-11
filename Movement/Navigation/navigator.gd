class_name Navigator
extends RefCounted
## #60: ordinary Godot route acquisition and local physical clearance, sharing one navigation allowance.
## Pending route work never implies braking. ShipMovement owns the order and all physical movement.

const BUDGET: NavigationBudget = preload("res://Movement/Navigation/navigation_budget.tres")
enum Status { PENDING, DONE, DECLINED, CANCELLED }

static var _jobs: Array[Job] = []
static var _ships: Array[ShipMovement] = []
static var _frame := -1
static var _frame_used := 0
static var _serviced_frame := -1


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


## Telemetry only (Task #84): navigation time measured this frame. Nothing may branch on a time value.
static func measure() -> int:
	_begin_frame()
	return Time.get_ticks_usec()


static func account(start: int) -> void:
	_frame_used += Time.get_ticks_usec() - start


static func start_job(ship: ShipMovement, probe: HullProbe, click: Vector3, refresh := false) -> Job:
	var start := measure()
	var job := Job.new(ship, probe, click, refresh)
	_jobs.push_back(job)
	account(start)
	return job


## Runs once per physics frame, on the first call; later calls in the same frame return at once (Task #84).
## Cache preparation and route work are each bounded by a count of work items, never by measured time, so an
## unfinished cache or job simply continues next frame. Live guidance is never limited by this budget.
static func service() -> void:
	var start := measure()
	if _serviced_frame == _frame:
		account(start)
		return
	_serviced_frame = _frame
	var preparation := PlanClock.new(BUDGET.preparation_items_per_tick)
	var maps: Array[RID] = []
	for ship in _ships:
		var map := ship.get_world_3d().navigation_map
		if not maps.has(map):
			maps.push_back(map)
			if preparation.has_time():
				HullProbe.prepare_space(map, ship.get_tree().root, preparation)
	var clock := PlanClock.new(BUDGET.plan_items_per_tick)
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
			ship.get_propulsion_state, Navigator.BUDGET.destination_candidates_per_order,
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
