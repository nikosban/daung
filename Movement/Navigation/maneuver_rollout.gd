class_name ManeuverRollout
extends RefCounted
## One predicted maneuver from the ship's actual state (Task #46), with the real pilot (ShipPilot), the same per-tick
## guidance as real flight (RouteGuidance) and the real hull (HullProbe). Resumable: run() predicts one tick at a time
## while its PlanClock allows.
##
## The prediction runs tick by tick through every hazard region and through any open stretch where the predicted ship
## has not yet settled onto the route. Only an open stretch the predicted ship has entered settled (on the route,
## velocity and hull along it, no turn) and that is at least one stopping distance long is skipped: the next region
## then starts from the re-entry assumption (on the route, hull along it, the speed the speed law allows there). That
## assumption is not proof; the Task #44 stop remains the fallback there. Past the last region the prediction passes
## once the predicted ship's drift corridor (CorridorScan) is empty; the corridor is only checked while the predicted
## ship is within arrival_tolerance of the route, since it bounds drift off the route, not the way back to it (Task #50).
##
## Wait (Task #50): a rollout may first predict wait_ticks ticks of the braking the ship does while its job runs (no
## order), then the plan from that state (handoff_state), which is where the real ship starts it. A direct plan's
## course is taken from the position where the plan starts, as ShipMovement does at handoff.
##
## Reversal (brake_first): the order was classified a reversal when it activated, so the plan starts with the same
## braking commitment as real flight (ShipPilot.Targets.brake_first, carried between ticks). Until it completes, the
## prediction never skips a stretch or passes on the drift corridor: the braking runs off the route.
##
## No-go zone (Task #48): once the predicted centre has been on the navigation mesh (within one map cell), a tick
## that takes it more than MovementProfile.no_go_tolerance beyond the mesh edge fails the maneuver ("centre enters
## the no-go zone"). A ship starting inside a zone may leave it. The rotating hull may cross the edge (only the centre
## is tested), the braking wait and clearance mode are not tested, and nothing is enforced in real flight.
##
## Clearance mode (find_clear): a departure is predicted only until the hull has room to turn, a cylinder of hull reach
## + clearance buffer around the root being empty (rotation is then safe at any yaw). It passes with clear_time, the
## predicted time since handoff when that happens, and fails on hull contact or after clear_limit seconds.

enum { RUNNING, PASS, FAIL }

## Prediction continues after arrival until the ship rests (below REST_SPEED, m/s) or REST_TIME (s) passes.
const REST_SPEED := 0.01
const REST_TIME := 20.0
## Past the last hazard region, the drift corridor is checked this often (s of predicted flight).
const DRIFT_CHECK_INTERVAL := 0.5
## Corridor samples checked per predicted tick while a corridor scan runs.
const CORRIDOR_SAMPLES_PER_TICK := 8
## A segment of buffered ticks is checked once its motion bound reaches the hull half-width or it holds this many
## ticks, which bounds one predicted tick's work.
const SEGMENT_MAX_TICKS := 16
## The predicted ship counts as settled onto the route within this angle (hull and velocity) and below this turn rate.
const SETTLE_ANGLE := deg_to_rad(2.0)
const SETTLE_TURN_RATE := deg_to_rad(0.5)

var plan: RouteGuidance.Plan
var follow := RouteGuidance.Follow.new()
var state: ShipPilot.State
## Braking ticks predicted before the plan starts (see Wait above), and the predicted state when it starts.
var wait_ticks := 0
var handoff_state: ShipPilot.State
var simulated_ticks := 0
var skipped := 0
var failure := ""
## Whether the predicted ship had settled onto the route at some point (a later failure is then not a departure
## problem).
var settled_once := false
## The most ticks this prediction may simulate (the job's remaining prediction allowance); reaching it fails with
## exhausted set.
var tick_limit := 1 << 30
var exhausted := false
## Clearance mode (see above).
var find_clear := false
var clear_limit := 0.0
var clear_time := 0.0

var _targets := ShipPilot.Targets.new()
var _out := ShipPilot.Output.new()
var _profile: MovementProfile
var _probe: HullProbe
var _delta := 1.0 / 60.0
var _regions: Array[Vector2] = []
var _final_hazard := false
var _stop_distance := 0.0
var _region := 0
var _arrived := false
var _rest_time := 0.0
var _drift_time := 0.0
var _corridor: CorridorScan
var _start_check := true
var _positions := PackedVector3Array()
var _yaws := PackedFloat32Array()
var _motions := PackedVector3Array()
var _dyaws := PackedFloat32Array()
var _sweeps := PackedFloat32Array()
var _sweep := 0.0
var _direct_has_course := false
var _direct_course := 0.0
var _direct_course_follows := false
## Reversal braking: the order's classification, and whether the predicted braking is still to complete.
var _reversal := false
var _brake_first := false
## No-go check (Task #48): the navigation map, its cell size and whether the predicted centre has been on the mesh.
var _map: RID
var _cell := 0.25
var _on_mesh := false

## Stage 1 (#60) gate: the same pilot/hull prediction can verify a finite segment followed by physical braking.
## This mode is not connected to live navigation until the response/budget gate passes. No full-flight shortcut
## or legacy 20-second rest timeout can approve a segment. A clear prefix alone never returns PASS.
var segment_ticks := -1
var segment_clear := false
var segment_verified := false
var segment_state: ShipPilot.State
var segment_follow: RouteGuidance.Follow
var segment_brake_first := false
var segment_on_mesh := false
var segment_course := 0.0
var segment_course_follows := false
var order_generation := 0
var anchor_frame := -1
var _segment_start: ShipPilot.State
var _segment_map_iteration := 0
var _segment_seed_checked := false
var _segment_tail := false


## Select finite-segment verification before run(). The snapshot and guidance progress belong to this order;
## on_mesh carries the existing no-go history, rather than renewing the starting-inside exemption.
func verify_segment(ticks: int, generation: int, frame: int, progress: RouteGuidance.Follow = null, on_mesh := false) -> void:
	segment_ticks = maxi(ticks, 1)
	order_generation = generation
	anchor_frame = frame
	_segment_start = state.copy()
	_segment_map_iteration = NavigationServer3D.map_get_iteration_id(_map)
	_on_mesh = on_mesh
	if progress != null:
		follow = _copy_follow(progress)


## Initial-state handoff gate. The caller additionally owns candidate/course identity and cancellation. Compare
## every pilot field: previous demand/speed influence future yaw even when position and velocity match.
func segment_matches(actual: ShipPilot.State, generation: int, frame: int) -> bool:
	if not segment_verified or generation != order_generation or frame != anchor_frame:
		return false
	if NavigationServer3D.map_get_iteration_id(_map) != _segment_map_iteration:
		return false
	var expected := _segment_start
	var difference := actual.position.distance_to(expected.position) + actual.velocity.distance_to(expected.velocity) \
		+ absf(wrapf(actual.yaw - expected.yaw, -PI, PI)) + actual.bow.distance_to(expected.bow) \
		+ absf(actual.turn_rate - expected.turn_rate) + absf(actual.speed_prev - expected.speed_prev) \
		+ absf(actual.planar_fraction_prev - expected.planar_fraction_prev)
	return difference <= Navigator.HANDOFF_TOLERANCE and failure == ""


static func _copy_follow(source: RouteGuidance.Follow) -> RouteGuidance.Follow:
	var copy := RouteGuidance.Follow.new()
	copy.index = source.index
	copy.frozen = source.frozen
	copy.frozen_course = source.frozen_course
	copy.time = source.time
	copy.switched = source.switched
	copy.s = source.s
	copy.point = source.point
	return copy


func _init(p_plan: RouteGuidance.Plan, start: ShipPilot.State, profile: MovementProfile, probe: HullProbe, regions: Array[Vector2], final_hazard: bool, delta: float, map: RID, reversal := false) -> void:
	_reversal = reversal
	plan = p_plan
	state = start.copy()
	_profile = profile
	_probe = probe
	_regions = regions
	_final_hazard = final_hazard
	_delta = delta
	_stop_distance = RoutePlanner.stop_distance_of(profile)
	_map = map
	_cell = NavigationServer3D.map_get_cell_size(map)
	_targets.has_order = true
	_start_plan()


func run(clock: PlanClock) -> int:
	while clock.has_time():
		var result := _tick()
		clock.item_done()
		if result != RUNNING:
			return result
	return RUNNING


## One predicted tick plus the region bookkeeping.
func _tick() -> int:
	if simulated_ticks >= tick_limit:
		exhausted = true
		failure = "prediction limit reached"
		return FAIL
	if wait_ticks > 0:
		return _wait_tick()
	if segment_ticks >= 0:
		if not _segment_seed_checked:
			_segment_seed_checked = true
			if not _centre_allowed():
				failure = "segment starts outside the permitted no-go boundary"
				return FAIL
		if not _segment_tail and simulated_ticks >= segment_ticks:
			if not _flush():
				return FAIL
			segment_clear = true
			segment_state = state.copy()
			segment_follow = _copy_follow(follow)
			segment_brake_first = _brake_first
			segment_on_mesh = _on_mesh
			segment_course = _direct_course
			segment_course_follows = _direct_course_follows
			_segment_tail = true
	if not _segment_tail:
		RouteGuidance.guide(plan, follow, state.position, state.yaw, _targets)
	if plan.kind == RouteGuidance.Kind.DIRECT:
		_targets.has_course = _direct_has_course
		_targets.course_yaw = _direct_course
		_targets.course_follows = _direct_course_follows
	_targets.has_order = not _arrived and not _segment_tail
	if _segment_tail:
		_targets.has_course = false
	_targets.brake_first = _brake_first
	var position := state.position
	var yaw := state.yaw
	ShipPilot.step(_profile, state, _targets, _delta, _out)
	_brake_first = _targets.brake_first
	if plan.kind == RouteGuidance.Kind.DIRECT:
		_direct_course = _targets.course_yaw
		_direct_course_follows = _targets.course_follows
	if _out.arrived:
		_arrived = true
	var motion := Vector3(state.velocity.x, 0.0, state.velocity.z) * _delta
	state.position = position + motion
	state.bow = ShipPilot.bow_of(state.yaw)
	follow.time += _delta
	simulated_ticks += 1
	_buffer(position, yaw, motion, state.yaw - yaw)
	if (_sweep >= _probe.half_width or _positions.size() >= SEGMENT_MAX_TICKS) and not _flush():
		return FAIL
	if not find_clear and not _centre_allowed():
		failure = "centre enters the no-go zone at (%.1f, %.1f)" % [state.position.x, state.position.z]
		return FAIL
	if segment_ticks >= 0:
		if _segment_tail and state.velocity.length() <= REST_SPEED:
			if not _flush():
				return FAIL
			return _segment_rest()
		return RUNNING
	if find_clear:
		if _probe.cylinder_clear(state.position, _probe.reach + _profile.plan_clearance_buffer):
			if not _flush():
				return FAIL
			clear_time = follow.time
			return PASS
		if follow.time >= clear_limit - RouteGuidance.TIME_EPSILON:
			failure = "no room to turn within the longest departure"
			return FAIL
		return RUNNING
	if _arrived:
		_rest_time += _delta
		if state.velocity.length() <= REST_SPEED or _rest_time >= REST_TIME:
			if not _flush():
				return FAIL
			# The resting pose itself must be clear.
			if _probe.overlaps(state.position, state.yaw, 0.0):
				failure = "resting pose overlaps"
				return FAIL
			return PASS
		return RUNNING
	# Leave a region when the ship passes its end (the final hazard runs to rest).
	if _region < _regions.size() and follow.s >= _regions[_region].y and not (_final_hazard and _region == _regions.size() - 1):
		if not _flush():
			return FAIL
		_region += 1
	# Past the last hazard region, the rest of the flight cannot touch anything once its drift corridor is empty.
	var in_region := _region < _regions.size() and follow.s >= _regions[_region].x
	if _region >= _regions.size():
		_drift_time += _delta
		var off_route := RouteGuidance.planar(state.position - follow.point).length()
		# The corridor bounds drift for a ship travelling along its route; a ship crossing it at an angle sweeps round
		# at its speed (momentum-preserving course changes) instead of braking, so it is predicted tick by tick until its
		# velocity runs along the route.
		if _corridor == null and (off_route > _profile.arrival_tolerance or not _moving_along_route() or _brake_first):
			_drift_time = 0.0
		if _corridor == null and _drift_time >= DRIFT_CHECK_INTERVAL - RouteGuidance.TIME_EPSILON:
			_drift_time = 0.0
			_corridor = CorridorScan.new(plan, _probe, _profile, state.position, state.velocity.length(), follow.s, off_route)
		if _corridor != null:
			for i in CORRIDOR_SAMPLES_PER_TICK:
				var corridor := _corridor.step()
				if corridor == CorridorScan.RUNNING:
					continue
				_corridor = null
				if corridor == CorridorScan.CLEAR:
					return PASS if _flush() else FAIL
				break
	# In an open stretch, skip ahead once the predicted ship has settled onto the route.
	if not in_region and _settled():
		settled_once = true
		if _region >= _regions.size():
			return PASS if _flush() else FAIL
		if _regions[_region].x - follow.s >= _stop_distance:
			if not _flush():
				return FAIL
			_reenter(_regions[_region].x)
	return RUNNING


## Cover the infinite proportional-braking remainder, rather than treating REST_SPEED as an instantaneous stop.
## With a linear, positive directional curve and delta <= response time, sufficiently slow no-order motion is
## unsaturated on every hull axis and decays geometrically. Nonlinear/zero curves get no shortcut (unproven).
func _segment_rest() -> int:
	if _delta > _profile.pilot_response_time:
		failure = "stopping remainder unproven at this physics delta"
		return FAIL
	var curve := _profile.directional_thrust_curve
	var minimum := 1.0
	for i in curve.point_count:
		minimum = minf(minimum, clampf(curve.get_point_position(i).y, 0.0, 1.0))
		if i + 1 < curve.point_count and (curve.get_point_right_mode(i) != Curve.TANGENT_LINEAR or curve.get_point_left_mode(i + 1) != Curve.TANGENT_LINEAR):
			failure = "stopping remainder unproven for nonlinear directional curve"
			return FAIL
	var rating := _profile.thruster_strength / _profile.mass
	var weakest := minf(rating * minimum, ShipPilot.sternward_limit_of(_profile, rating))
	var speed := state.velocity.length()
	if weakest <= 0.0 or speed / _profile.pilot_response_time > weakest:
		failure = "stopping remainder still thrust-limited"
		return FAIL
	# Ideal remaining length <= speed * response_time. Twice that bounds float-rounded position increments
	# (a nonzero increment rounds by at most its own size); the hull is fixed during no-order braking.
	var remainder := 2.0 * speed * _profile.pilot_response_time
	if _probe.overlaps(state.position, state.yaw, remainder):
		failure = "stopping remainder overlaps"
		return FAIL
	var closest := NavigationServer3D.map_get_closest_point(_map, state.position)
	# Distance to this fixed on-mesh point bounds distance to the mesh for every point in the remainder ball.
	if RouteGuidance.planar(closest - state.position).length() + remainder > _profile.no_go_tolerance:
		failure = "stopping remainder no-go clearance unproven"
		return FAIL
	segment_verified = true
	return PASS


## One predicted tick of the braking before the plan starts (no order: the pilot brakes, rotation stops), hull-checked
## like any other tick. When the wait ends, the plan starts from the state reached.
func _wait_tick() -> int:
	var braking := ShipPilot.Targets.new()
	var position := state.position
	var yaw := state.yaw
	ShipPilot.step(_profile, state, braking, _delta, _out)
	var motion := Vector3(state.velocity.x, 0.0, state.velocity.z) * _delta
	state.position = position + motion
	state.bow = ShipPilot.bow_of(state.yaw)
	simulated_ticks += 1
	_buffer(position, yaw, motion, state.yaw - yaw)
	if (_sweep >= _probe.half_width or _positions.size() >= SEGMENT_MAX_TICKS) and not _flush():
		return FAIL
	wait_ticks -= 1
	if wait_ticks == 0:
		handoff_state = state.copy()
		_start_plan()
	return RUNNING


## Whether the predicted centre may be here: on the navigation mesh, still before it first reached the mesh (a ship
## leaving a zone), or within no_go_tolerance beyond its edge.
func _centre_allowed() -> bool:
	var closest := NavigationServer3D.map_get_closest_point(_map, state.position)
	var off_mesh := RouteGuidance.planar(closest - state.position).length()
	if off_mesh <= _cell:
		_on_mesh = true
		return true
	return not _on_mesh or off_mesh <= _profile.no_go_tolerance


## Starts following the plan from the current predicted state, as ShipMovement does at handoff: fresh route
## progress, and a direct plan's course from here to the destination.
func _start_plan() -> void:
	follow = RouteGuidance.Follow.new()
	RouteGuidance.track(plan, follow, state.position)
	var course := RouteGuidance.planar(plan.destination - state.position)
	_direct_has_course = course != Vector3.ZERO
	_direct_course = atan2(-course.x, -course.z) if _direct_has_course else 0.0
	_direct_course_follows = _direct_has_course
	_brake_first = _reversal


## Whether the predicted ship follows the route as the re-entry assumption describes: within the arrival tolerance
## of it, velocity and hull along it, no turn.
func _settled() -> bool:
	if _brake_first:
		return false
	if plan.kind == RouteGuidance.Kind.DEPART and not follow.switched:
		return false
	var route := plan.route
	var direction := RouteGuidance.planar(route[follow.index] - route[follow.index - 1]).normalized()
	var course := atan2(-direction.x, -direction.z)
	if absf(wrapf(state.yaw - course, -PI, PI)) > SETTLE_ANGLE or absf(state.turn_rate) > SETTLE_TURN_RATE:
		return false
	if RouteGuidance.planar(state.position - follow.point).length() > _profile.arrival_tolerance:
		return false
	return state.velocity.length() > 0.0 and _moving_along_route()


## Whether the predicted velocity runs along the current route segment (within SETTLE_ANGLE); true at rest (no drift).
func _moving_along_route() -> bool:
	var route := plan.route
	var direction := RouteGuidance.planar(route[follow.index] - route[follow.index - 1]).normalized()
	var speed := state.velocity.length()
	return state.velocity.dot(direction) >= speed * cos(SETTLE_ANGLE)


func _buffer(position: Vector3, yaw: float, motion: Vector3, dyaw: float) -> void:
	var bound := motion.length() + _probe.reach * absf(dyaw)
	_positions.push_back(position)
	_yaws.push_back(yaw)
	_motions.push_back(motion)
	_dyaws.push_back(dyaw)
	_sweeps.push_back(bound)
	_sweep += bound


## Checks the buffered ticks: one test of the hull grown by the segment's whole motion bound at its first pose covers
## the segment; when that overlaps, the segment is halved until single ticks get the exact step test.
func _flush() -> bool:
	if _positions.is_empty():
		return true
	var clear := _check(0, _positions.size(), _sweep)
	_positions.resize(0)
	_yaws.resize(0)
	_motions.resize(0)
	_dyaws.resize(0)
	_sweeps.resize(0)
	_sweep = 0.0
	return clear


func _check(first: int, end: int, bound: float) -> bool:
	if end - first == 1:
		var clear := _probe.step_clear(_positions[first], _yaws[first], _motions[first], _dyaws[first], _start_check)
		_start_check = false
		if not clear:
			failure = "hull contact predicted at (%.1f, %.1f)" % [_positions[first].x, _positions[first].z]
		return clear
	if not _start_check and not _probe.overlaps(_positions[first], _yaws[first], bound):
		return true
	var middle := (first + end) / 2
	var left := 0.0
	for k in range(first, middle):
		left += _sweeps[k]
	return _check(first, middle, left) and _check(middle, end, bound - left)


## Skipped stretch: assume the ship is on the route at the region start, moving along it at the speed the speed law
## allows there, hull on the route course, no turn (the stated re-entry assumption; not proof).
func _reenter(s: float) -> void:
	skipped += 1
	var position := RouteGuidance.point_at(plan, s)
	position.y = state.position.y
	var next := RouteGuidance.point_at(plan, minf(s + 1.0, plan.total_length()))
	var direction := RouteGuidance.planar(next - position).normalized()
	var a := _profile.thruster_strength / _profile.mass
	var lag := a * _profile.pilot_response_time
	var speed := clampf(sqrt(2.0 * a * (plan.total_length() - s)) - lag, 0.0, _profile.max_speed)
	var reentry := RouteGuidance.Follow.new()
	reentry.switched = true
	reentry.time = plan.switch_time
	RouteGuidance.track(plan, reentry, position)
	var bend := a / 2.0
	for j in range(reentry.index, plan.route.size() - 1):
		var radius := plan.corner_radii[j]
		if radius > 0.0:
			speed = minf(speed, maxf(sqrt(bend * radius + 2.0 * bend * maxf(plan.lengths[j] - s, 0.0)) - bend * _profile.pilot_response_time, 0.0))
	state.position = position
	state.velocity = direction * speed
	state.yaw = atan2(-direction.x, -direction.z)
	state.bow = ShipPilot.bow_of(state.yaw)
	state.turn_rate = 0.0
	state.planar_fraction_prev = 0.0
	follow = reentry
	_start_check = true
