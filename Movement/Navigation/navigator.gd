class_name Navigator
extends RefCounted
## Orchestrates navigation planning for ShipMovement (Task #46): one planning Job per activated move, served from one
## queue shared by all ships within a wall-clock allowance per physics tick (NavigationBudget). A Job runs its
## RoutePlanner (readiness, path, hazard regions), then, when anything needs predicting, its ManeuverPlanner
## (candidate predictions), and ends with one plan for the pilot (RouteGuidance.Plan), a decline, or a cancellation.
## The outcome depends only on the ship's state and the world, never on wall-clock time: the per-tick allowance only
## spreads the work over ticks, and the per-order limit counts predicted flight time.
## Nothing here writes a transform or velocity; ShipMovement stays the single writer and follows the plan with
## RouteGuidance.guide() every tick. No job ever runs again for the same order.
##
## Handoff (Task #50): a plan validated with a predicted braking wait is held until its handoff frame and handed over
## only if the ship's state then equals the predicted one (within HANDOFF_TOLERANCE); otherwise the search restarts
## from the actual state. A holding job is checked every physics frame, outside the per-tick allowance, and does not
## hold up the jobs behind it.

const BUDGET: NavigationBudget = preload("res://Movement/Navigation/navigation_budget.tres")

enum Status { PENDING, DONE, DECLINED, CANCELLED }

## Largest summed difference (position m + velocity m/s + yaw rad + turn rate rad/s) between the ship's state and
## the predicted handoff state for which a held plan is handed over. The no-order braking is predicted exactly (0 to
## about 1e-7 measured); this only absorbs float noise.
const HANDOFF_TOLERANCE := 1.0e-4

static var _jobs: Array[Job] = []
static var _frame := -1
static var _frame_used := 0


## Starts the planning job for an activated move. The caller keeps the job and cancels it when a later command
## activates. brake_first: the order was classified a reversal (ShipMovement), so every prediction of it brakes to near
## rest first, and a route with no hazard regions is still predicted (the braking runs off the route).
static func start_job(ship: ShipMovement, probe: HullProbe, click: Vector3, brake_first := false) -> Job:
	var job := Job.new(ship, probe, click, brake_first)
	_jobs.push_back(job)
	return job


## Advances queued jobs, oldest first, within this physics tick's shared allowance. Every ship calls it each tick; the
## allowance is reset on the first call of a new physics frame. A job only waiting for navigation to sync, or holding a
## plan, does not hold up the jobs behind it. Held plans are handed over in the first call of a frame, before any ship
## has moved in it (every ship calls this before its own move), so each ship is in its start-of-tick state.
static func service() -> void:
	var frame := Engine.get_physics_frames()
	if frame != _frame:
		_frame = frame
		_frame_used = 0
		for job in _jobs:
			if job.status == Status.PENDING and job.is_holding():
				job.advance(null)
	var i := 0
	while i < _jobs.size():
		var job := _jobs[i]
		if job.status != Status.PENDING:
			_jobs.remove_at(i)
			continue
		if job.is_holding():
			i += 1
			continue
		var allowance := BUDGET.plan_time_per_tick - _frame_used
		if allowance <= 0:
			return
		var start := Time.get_ticks_usec()
		job.advance(PlanClock.new(start + allowance, BUDGET.plan_time_per_tick))
		_frame_used += Time.get_ticks_usec() - start
		if job.status != Status.PENDING:
			_jobs.remove_at(i)
		elif job.is_waiting():
			i += 1
		else:
			return


## Used time this physics frame by all planning jobs (µs; debug and traces).
static func get_frame_used() -> int:
	return _frame_used


## One planning job for one activated move.
class Job:
	var status := Status.PENDING
	## Result when DONE: the plan the pilot follows (kind DIRECT for the unchanged direct order).
	var plan: RouteGuidance.Plan
	var reason := ""
	var summary := ""
	var used_usec := 0
	var ticks := 0
	## The requested click (Y at the ship) and, once DONE, the destination the plan leads to (the click, or the
	## resolved candidate, Task #54).
	var click := Vector3.ZERO
	var destination := Vector3.ZERO
	## Destination resolution (Task #54): a short summary when the click was replaced, and every tested candidate.
	var resolution := ""
	var resolution_log := PackedStringArray()
	## Largest wall-clock time this job used in one physics tick (µs; evidence for the shared allowance).
	var worst_tick_usec := 0
	var _ship: ShipMovement
	var _probe: HullProbe
	var _profile: MovementProfile
	var _route: RoutePlanner
	var _maneuver: ManeuverPlanner
	var _last_frame := -1
	var _holding := false
	var _held_frames := 0
	var _tick_usec := 0
	var _brake_first := false

	func _init(ship: ShipMovement, probe: HullProbe, p_click: Vector3, brake_first: bool) -> void:
		_brake_first = brake_first
		_ship = ship
		_probe = probe
		_profile = ship.profile
		click = Vector3(p_click.x, ship.global_position.y, p_click.z)
		destination = click
		probe.queries = 0
		_route = RoutePlanner.new(ship.get_world_3d().navigation_map, probe, _profile, click, ship.get_pilot_state, Navigator.BUDGET.destination_candidates_per_order)

	func cancel() -> void:
		if status == Status.PENDING:
			status = Status.CANCELLED

	## Whether the job is only waiting: for navigation to sync, or for a held plan's handoff frame (no planning work).
	func is_waiting() -> bool:
		return (_maneuver == null and _route.waiting) or _holding

	## Whether the job holds a validated plan until its handoff frame.
	func is_holding() -> bool:
		return _holding

	func advance(clock: PlanClock) -> void:
		if not is_instance_valid(_ship):
			status = Status.CANCELLED
			return
		var start := Time.get_ticks_usec()
		var frame := Engine.get_physics_frames()
		if frame != _last_frame:
			_last_frame = frame
			ticks += 1
			_tick_usec = 0
		if _maneuver == null:
			match _route.run(clock):
				RoutePlanner.BASELINE:
					var direct := RouteGuidance.Plan.new()
					direct.destination = click
					_finish(direct, _route.note)
				RoutePlanner.DECLINED:
					_decline(_route.note)
				RoutePlanner.ROUTE:
					if _route.needs_prediction or _brake_first:
						_maneuver = ManeuverPlanner.new(_route.route_plan, _route.primary_plan, _route.regions, _route.final_hazard, _profile, _probe, _ship.get_pilot_state, _ship.get_physics_process_delta_time(), Navigator.BUDGET.plan_prediction_per_order, _ship.get_world_3d().navigation_map, _brake_first)
					else:
						_finish(_route.primary_plan, "no hazard regions")
		if _holding:
			_hand_over()
			_add_time(start)
			return
		if status == Status.PENDING and _maneuver != null:
			match _maneuver.run(clock):
				ManeuverPlanner.PASS when _maneuver.hold_frame >= 0:
					_holding = true
					_held_frames = _maneuver.hold_frame - frame
					_hand_over()
				ManeuverPlanner.PASS:
					_finish_maneuver()
				ManeuverPlanner.FAIL:
					if _maneuver.exhausted:
						_decline("maneuver planning failed: no safe maneuver found within %.0f s of predicted flight (route: %s)" % [Navigator.BUDGET.plan_prediction_per_order, _maneuver.failure])
					else:
						_decline("maneuver planning failed: no safe maneuver found (route: %s)" % _maneuver.failure)
		_add_time(start)

	func _add_time(start: int) -> void:
		var used := Time.get_ticks_usec() - start
		used_usec += used
		_tick_usec += used
		worst_tick_usec = maxi(worst_tick_usec, _tick_usec)

	## A held plan: wait for its handoff frame, then hand it over if the ship is in the predicted state, or search
	## again from the actual state.
	func _hand_over() -> void:
		if Engine.get_physics_frames() < _maneuver.hold_frame:
			return
		_holding = false
		var now := _ship.get_pilot_state()
		var expected := _maneuver.handoff_state
		var difference := (now.position - expected.position).length() + (now.velocity - expected.velocity).length() + absf(wrapf(now.yaw - expected.yaw, -PI, PI)) + absf(now.turn_rate - expected.turn_rate)
		if Engine.get_physics_frames() == _maneuver.hold_frame and difference <= HANDOFF_TOLERANCE:
			_finish_maneuver()
		else:
			_held_frames = 0
			_maneuver.restart()

	func _finish_maneuver() -> void:
		var held := "" if _held_frames == 0 else ", held %d ticks" % _held_frames
		_finish(_maneuver.chosen, "%s%s; %d rollouts, %d predicted ticks, %d skipped stretches, %d queries%s" % [_route.hazard_text, _maneuver.departure_text(), _maneuver.rollouts, _maneuver.predicted_ticks, _maneuver.skipped, _probe.queries, held])

	func _finish(p_plan: RouteGuidance.Plan, note: String) -> void:
		plan = p_plan
		status = Status.DONE
		summary = note
		destination = p_plan.destination
		resolution = _route.resolution
		resolution_log = _route.resolution_log

	func _decline(note: String) -> void:
		status = Status.DECLINED
		reason = note
		resolution = _route.resolution
		resolution_log = _route.resolution_log

	## Destination-resolution query counts (Task #54): closest-point, path and physics (hull) queries of this job.
	func query_text() -> String:
		return "%d closest-point, %d path, %d physics queries" % [_route.closest_queries, _route.path_queries, _probe.queries]
