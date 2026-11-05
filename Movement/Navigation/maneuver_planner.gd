class_name ManeuverPlanner
extends RefCounted
## The maneuver half of one planning job (Task #46): predicts candidate maneuvers over a planned route (one
## ManeuverRollout each) and picks the first that passes. Resumable: run() continues where its PlanClock stopped.
##
## Candidates, in order:
## 1. the direct order (2-point route) or route guidance;
## 2. only when the start is a hazard or the ship already moves, departures that keep the hull's heading (no commanded
##    course) and then follow the route. First, for each direction (braking for a moving ship, then astern, port,
##    starboard, ahead), a clearance-mode prediction finds when the hull has room to turn (at most departure_max_time)
##    or when that direction runs into something; a direction with room is tried at once with the departure that
##    switches to the route exactly then. Then fixed departures of one to several departure_step_time steps (shorter
##    first): in a direction with room, only those longer than its time to room (a slow-turning hull may need more
##    distance before it can line up with the route); in a direction that runs into something, only those that end
##    before the contact.
## A first candidate that fails after its prediction had settled onto the route failed on the route itself, which no
## departure can change, so the search ends there.
##
## All predictions of one order together may simulate at most NavigationBudget.plan_prediction_per_order seconds of
## flight; reaching it declines the order. That limit counts predicted time, so the outcome does not depend on how
## fast the machine runs the search.
##
## The search predicts from a snapshot of the ship. If the ship has moved by the time a candidate passes (it brakes
## while the job waits), the candidate's first stretch is predicted again from the actual state (validation); a
## failure restarts the search from that state.

enum { RUNNING, PASS, FAIL }
enum Task { PRIMARY, CLEARANCE, DEPARTURE }

## Hull-local departure translations, in order: astern, port, starboard, ahead (bow is local −Z).
const DEPART_AXES: Array[Vector3] = [Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)]
## A departure that never switches to the route (clearance mode ends it).
const NEVER := 1.0e9

## The chosen plan once run() returned PASS; why the first candidate failed once it returned FAIL.
var chosen: RouteGuidance.Plan
var failure := ""
## Whether the search stopped at the prediction limit.
var exhausted := false
var rollouts := 0
var predicted_ticks := 0
var skipped := 0

var _route_plan: RouteGuidance.Plan
var _primary: RouteGuidance.Plan
var _regions: Array[Vector2] = []
var _final_hazard := false
var _profile: MovementProfile
var _probe: HullProbe
var _live_state: Callable
var _delta := 1.0 / 60.0
var _ticks_left := 0
var _snapshot: ShipPilot.State
## Pending work, in order: [Task, direction (hull-local), switch time (s)].
var _tasks: Array = []
var _task: Array = []
## Clearance results per direction: [direction, has room, time (s): room found, or contact].
var _clearance: Array = []
var _fixed_added := false
var _validating := false
var _rollout: ManeuverRollout


func _init(route_plan: RouteGuidance.Plan, primary: RouteGuidance.Plan, regions: Array[Vector2], final_hazard: bool, profile: MovementProfile, probe: HullProbe, live_state: Callable, delta: float, prediction_limit: float) -> void:
	_route_plan = route_plan
	_primary = primary
	_regions = regions
	_final_hazard = final_hazard
	_profile = profile
	_probe = probe
	_live_state = live_state
	_delta = delta
	_ticks_left = int(ceil(prediction_limit / delta))
	_start_search()


func run(clock: PlanClock) -> int:
	while true:
		if _rollout == null:
			if _validating:
				_rollout = _new_rollout(chosen)
				_rollout.first_stretch_only = true
			else:
				if _tasks.is_empty() and not _fixed_added:
					_add_fixed_departures()
				if _tasks.is_empty():
					return FAIL
				_task = _tasks.pop_front()
				_rollout = _task_rollout(_task)
			_rollout.tick_limit = _ticks_left
			rollouts += 1
		var result := _rollout.run(clock)
		if result == ManeuverRollout.RUNNING:
			return RUNNING
		var finished := _rollout
		_rollout = null
		predicted_ticks += finished.simulated_ticks
		skipped += finished.skipped
		_ticks_left -= finished.simulated_ticks
		if finished.exhausted:
			exhausted = true
			return FAIL
		if _validating:
			if result == ManeuverRollout.PASS:
				return PASS
			# The ship moved while the job ran and the chosen maneuver no longer holds: search again from now.
			_start_search()
			continue
		if _task[0] == Task.CLEARANCE:
			# The hull has room to turn after clear_time: try the departure that switches to the route exactly then.
			if result == ManeuverRollout.PASS:
				_clearance.push_back([_task[1], true, finished.clear_time])
				_tasks.push_front([Task.DEPARTURE, _task[1], finished.clear_time])
			else:
				_clearance.push_back([_task[1], false, finished.follow.time])
			continue
		if result == ManeuverRollout.PASS:
			chosen = finished.plan
			var now: ShipPilot.State = _live_state.call()
			if _same_state(_snapshot, now):
				return PASS
			_validating = true
			_snapshot = now
			continue
		if _task[0] == Task.PRIMARY:
			failure = finished.failure
			if finished.settled_once:
				return FAIL
	return FAIL


## Text for the plan log: the departure chosen, if any.
func departure_text() -> String:
	if chosen == null or chosen.kind != RouteGuidance.Kind.DEPART:
		return ""
	var local := Basis(Vector3.UP, chosen.hold_yaw).inverse() * chosen.depart_direction
	var name := "braking"
	if local.z > 0.5:
		name = "astern"
	elif local.z < -0.5:
		name = "ahead"
	elif local != Vector3.ZERO:
		name = "to port" if local.x < 0.0 else "to starboard"
	return " departing %s for %.2f s" % [name, chosen.switch_time]


func _start_search() -> void:
	_snapshot = _live_state.call()
	_validating = false
	_tasks = [[Task.PRIMARY, Vector3.ZERO, 0.0]]
	var moving := RouteGuidance.planar(_snapshot.velocity).length() > _profile.arrival_speed_tolerance
	if not moving and (_regions.is_empty() or _regions[0].x > 0.0):
		return
	_clearance.clear()
	_fixed_added = false
	var directions: Array[Vector3] = []
	if moving:
		directions.push_back(Vector3.ZERO)
	directions.append_array(DEPART_AXES)
	for direction in directions:
		_tasks.push_back([Task.CLEARANCE, direction, 0.0])


## Fixed departures, once every clearance result is known (see the class description).
func _add_fixed_departures() -> void:
	_fixed_added = true
	var steps := maxi(1, roundi(_profile.departure_max_time / _profile.departure_step_time))
	for step in range(1, steps + 1):
		var time := step * _profile.departure_step_time
		for result in _clearance:
			if (result[1] and time > result[2] + RouteGuidance.TIME_EPSILON) or (not result[1] and time < result[2] - RouteGuidance.TIME_EPSILON):
				_tasks.push_back([Task.DEPARTURE, result[0], time])


func _task_rollout(task: Array) -> ManeuverRollout:
	if task[0] == Task.PRIMARY:
		return _new_rollout(_primary)
	if task[0] == Task.CLEARANCE:
		var rollout := _new_rollout(_departure(task[1], NEVER))
		rollout.find_clear = true
		rollout.clear_limit = _profile.departure_max_time
		return rollout
	return _new_rollout(_departure(task[1], task[2]))


func _departure(local_direction: Vector3, switch_time: float) -> RouteGuidance.Plan:
	var depart := RouteGuidance.make_plan(RouteGuidance.Kind.DEPART, _route_plan.route, _route_plan.destination, _route_plan.lookahead)
	depart.hold_yaw = _snapshot.yaw
	depart.depart_direction = Basis(Vector3.UP, _snapshot.yaw) * local_direction
	depart.switch_time = switch_time
	return depart


func _new_rollout(plan: RouteGuidance.Plan) -> ManeuverRollout:
	return ManeuverRollout.new(plan, _snapshot, _profile, _probe, _regions, _final_hazard, _delta)


func _same_state(a: ShipPilot.State, b: ShipPilot.State) -> bool:
	return a.position == b.position and a.velocity == b.velocity and a.yaw == b.yaw and a.turn_rate == b.turn_rate
