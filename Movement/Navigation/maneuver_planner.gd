class_name ManeuverPlanner
extends RefCounted
## The maneuver half of one planning job (Task #46): predicts candidate maneuvers over a planned route (one
## ManeuverRollout each) and picks the first that passes. Resumable: run() continues where its PlanClock stopped.
##
## Candidates, in order: the direct order (2-point route) or route guidance; departures, only when the start is a
## hazard or the ship already moves: a moving ship first brakes for one to several departure steps, then any ship
## translates astern, to port, to starboard or ahead for one to several steps (shorter first). Each departure keeps
## the hull's heading (no commanded course) and then follows the route. A first candidate that fails after its
## prediction had settled onto the route failed on the route itself, which no departure can change, so the search
## ends there.
##
## The search predicts from a snapshot of the ship. If the ship has moved by the time a candidate passes (it brakes
## while the job waits), the candidate's first stretch is predicted again from the actual state (validation); a
## failure restarts the search from that state.

enum { RUNNING, PASS, FAIL }

## Hull-local departure translations, in order: astern, port, starboard, ahead (bow is local −Z).
const DEPART_AXES: Array[Vector3] = [Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)]

## The chosen plan once run() returned PASS; why the first candidate failed once it returned FAIL.
var chosen: RouteGuidance.Plan
var failure := ""
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
var _snapshot: ShipPilot.State
var _moving := false
var _departures := false
var _steps := 1
var _candidate := 0
var _validating := false
var _rollout: ManeuverRollout


func _init(route_plan: RouteGuidance.Plan, primary: RouteGuidance.Plan, regions: Array[Vector2], final_hazard: bool, profile: MovementProfile, probe: HullProbe, live_state: Callable, delta: float) -> void:
	_route_plan = route_plan
	_primary = primary
	_regions = regions
	_final_hazard = final_hazard
	_profile = profile
	_probe = probe
	_live_state = live_state
	_delta = delta
	_steps = maxi(1, roundi(profile.departure_max_time / profile.departure_step_time))
	_start_search()


func run(clock: PlanClock) -> int:
	while true:
		if _rollout == null:
			if _validating:
				_rollout = _new_rollout(chosen, true)
			else:
				if _candidate >= _candidate_count():
					return FAIL
				_rollout = _new_rollout(_candidate_plan(_candidate), false)
			rollouts += 1
		var result := _rollout.run(clock)
		if result == ManeuverRollout.RUNNING:
			return RUNNING
		var finished := _rollout
		_rollout = null
		predicted_ticks += finished.simulated_ticks
		skipped += finished.skipped
		if _validating:
			if result == ManeuverRollout.PASS:
				return PASS
			# The ship moved while the job ran and the chosen maneuver no longer holds: search again from now.
			_start_search()
			continue
		if result == ManeuverRollout.PASS:
			chosen = finished.plan
			var now: ShipPilot.State = _live_state.call()
			if _same_state(_snapshot, now):
				return PASS
			_validating = true
			_snapshot = now
			continue
		if _candidate == 0:
			failure = finished.failure
			if finished.settled_once:
				return FAIL
		_candidate += 1
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
	_moving = RouteGuidance.planar(_snapshot.velocity).length() > _profile.arrival_speed_tolerance
	_departures = _moving or (not _regions.is_empty() and _regions[0].x <= 0.0)
	_candidate = 0
	_validating = false


func _candidate_count() -> int:
	if not _departures:
		return 1
	return 1 + (_steps if _moving else 0) + _steps * DEPART_AXES.size()


## Candidate plans are made when they are reached: 0 is the primary plan, then braking (moving ships), then the
## translations by duration and axis.
func _candidate_plan(index: int) -> RouteGuidance.Plan:
	if index == 0:
		return _primary
	var k := index - 1
	var axis := Vector3.ZERO
	var step := 0
	if _moving and k < _steps:
		step = k + 1
	else:
		if _moving:
			k -= _steps
		step = k / DEPART_AXES.size() + 1
		axis = DEPART_AXES[k % DEPART_AXES.size()]
	var depart := RouteGuidance.make_plan(RouteGuidance.Kind.DEPART, _route_plan.route, _route_plan.destination, _route_plan.lookahead)
	depart.hold_yaw = _snapshot.yaw
	depart.depart_direction = Basis(Vector3.UP, _snapshot.yaw) * axis
	depart.switch_time = step * _profile.departure_step_time
	return depart


func _new_rollout(plan: RouteGuidance.Plan, first_stretch_only: bool) -> ManeuverRollout:
	var rollout := ManeuverRollout.new(plan, _snapshot, _profile, _probe, _regions, _final_hazard, _delta)
	rollout.first_stretch_only = first_stretch_only
	return rollout


func _same_state(a: ShipPilot.State, b: ShipPilot.State) -> bool:
	return a.position == b.position and a.velocity == b.velocity and a.yaw == b.yaw and a.turn_rate == b.turn_rate
