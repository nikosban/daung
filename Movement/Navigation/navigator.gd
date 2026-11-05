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

const BUDGET: NavigationBudget = preload("res://Movement/Navigation/navigation_budget.tres")

enum Status { PENDING, DONE, DECLINED, CANCELLED }

static var _jobs: Array[Job] = []
static var _frame := -1
static var _frame_used := 0


## Starts the planning job for an activated move. The caller keeps the job and cancels it when a later command
## activates.
static func start_job(ship: ShipMovement, probe: HullProbe, click: Vector3) -> Job:
	var job := Job.new(ship, probe, click)
	_jobs.push_back(job)
	return job


## Advances queued jobs, oldest first, within this physics tick's shared allowance. Every ship calls it each tick; the
## allowance is reset on the first call of a new physics frame. A job only waiting for navigation to sync does not
## hold up the jobs behind it.
static func service() -> void:
	var frame := Engine.get_physics_frames()
	if frame != _frame:
		_frame = frame
		_frame_used = 0
	var i := 0
	while i < _jobs.size():
		var job := _jobs[i]
		if job.status != Status.PENDING:
			_jobs.remove_at(i)
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
	var click := Vector3.ZERO
	var _ship: ShipMovement
	var _probe: HullProbe
	var _profile: MovementProfile
	var _route: RoutePlanner
	var _maneuver: ManeuverPlanner
	var _last_frame := -1

	func _init(ship: ShipMovement, probe: HullProbe, p_click: Vector3) -> void:
		_ship = ship
		_probe = probe
		_profile = ship.profile
		click = Vector3(p_click.x, ship.global_position.y, p_click.z)
		probe.queries = 0
		_route = RoutePlanner.new(ship.get_world_3d().navigation_map, probe, _profile, click, ship.get_pilot_state)

	func cancel() -> void:
		if status == Status.PENDING:
			status = Status.CANCELLED

	## Whether the job is only waiting for navigation to sync (it used no planning time).
	func is_waiting() -> bool:
		return _maneuver == null and _route.waiting

	func advance(clock: PlanClock) -> void:
		if not is_instance_valid(_ship):
			status = Status.CANCELLED
			return
		var start := Time.get_ticks_usec()
		var frame := Engine.get_physics_frames()
		if frame != _last_frame:
			_last_frame = frame
			ticks += 1
		if _maneuver == null:
			match _route.run(clock):
				RoutePlanner.BASELINE:
					var direct := RouteGuidance.Plan.new()
					direct.destination = click
					_finish(direct, _route.note)
				RoutePlanner.UNREACHABLE:
					_decline(_route.note)
				RoutePlanner.ROUTE:
					if _route.needs_prediction:
						_maneuver = ManeuverPlanner.new(_route.route_plan, _route.primary_plan, _route.regions, _route.final_hazard, _profile, _probe, _ship.get_pilot_state, _ship.get_physics_process_delta_time(), Navigator.BUDGET.plan_prediction_per_order)
					else:
						_finish(_route.primary_plan, "no hazard regions")
		if status == Status.PENDING and _maneuver != null:
			match _maneuver.run(clock):
				ManeuverPlanner.PASS:
					_finish(_maneuver.chosen, "%s%s; %d rollouts, %d predicted ticks, %d skipped stretches, %d queries" % [_route.hazard_text, _maneuver.departure_text(), _maneuver.rollouts, _maneuver.predicted_ticks, _maneuver.skipped, _probe.queries])
				ManeuverPlanner.FAIL:
					if _maneuver.exhausted:
						_decline("no safe maneuver found within %.0f s of predicted flight (route: %s)" % [Navigator.BUDGET.plan_prediction_per_order, _maneuver.failure])
					else:
						_decline("no safe maneuver found (route: %s)" % _maneuver.failure)
		used_usec += Time.get_ticks_usec() - start

	func _finish(p_plan: RouteGuidance.Plan, note: String) -> void:
		plan = p_plan
		status = Status.DONE
		summary = note

	func _decline(note: String) -> void:
		status = Status.DECLINED
		reason = note
