class_name ManeuverCheck
extends RefCounted
## One bounded near-term prediction from a ship state (Task #56), with the real pilot (ShipPilot), the same per-tick
## guidance as real flight (RouteGuidance) and the real hull (HullProbe). Resumable: run() predicts one tick per work
## item while its PlanClock allows. It replaces Task #46's whole-flight rollout: nothing is predicted beyond the
## segments below and, for a safety check, the braking to rest after them.
##
## A check is a list of segments, each one control (coast, brake or follow the plan) for a number of ticks, then
## optionally the tail:
## - REST: the ship brakes (the pilot without an order) until it rests; the resting pose must be clear. A passing
##   check proves that every control in the segments can be followed by a stop without contact or a no-go breach.
## - NONE: no tail (the progress window and boundary predictions).
## A follow segment whose plan arrives continues as braking (the order has ended), and a NONE check then passes.
##
## Hull: every predicted tick is swept (HullProbe.step_clear on the tick's motion and turn); ticks are buffered and a
## whole segment is first tested once with the hull grown by its summed motion bound, then halved where that overlaps.
## The first tick also checks the start pose.
##
## No-go zone (Task #48): a tick that takes the centre more than MovementProfile.no_go_tolerance beyond the navigation
## mesh edge fails, once the centre has been within that tolerance (a ship starting deeper inside a zone may leave it
## until it reaches the mesh). The hull may cross the edge; only the centre is tested.

enum { RUNNING, PASS, FAIL }
enum Mode { COAST, BRAKE, FOLLOW }
enum Tail { NONE, REST }

## The braking tail ends below this speed (m/s); it fails if the ship has not come to rest after REST_LIMIT (s).
const REST_SPEED := 0.01
const REST_LIMIT := 30.0
## A buffered segment of ticks is checked once its motion bound reaches the hull half-width or it holds this many ticks.
const SEGMENT_MAX_TICKS := 16

## Predicted state and follow progress; after a pass or fail they hold where the prediction stopped.
var state: ShipPilot.State
var follow: RouteGuidance.Follow
## The predicted state and follow progress at the end of each segment (filled as segments complete).
var segment_states: Array[ShipPilot.State] = []
var segment_follows: Array[RouteGuidance.Follow] = []
var failure := ""
## Index of the segment that failed (segments.size() = in the braking tail; -1 = none).
var failed_segment := -1
var predicted_ticks := 0

var _plan: RouteGuidance.Plan
var _segments: Array[Vector2i] = []
var _tail := Tail.NONE
var _segment := 0
var _segment_tick := 0
var _in_tail := false
var _tail_time := 0.0
var _arrived := false
var _targets := ShipPilot.Targets.new()
var _out := ShipPilot.Output.new()
var _profile: MovementProfile
var _probe: HullProbe
var _delta := 1.0 / 60.0
var _map: RID
var _cell := 0.25
var _on_mesh := false
var _start_check := true
var _positions := PackedVector3Array()
var _yaws := PackedFloat32Array()
var _motions := PackedVector3Array()
var _dyaws := PackedFloat32Array()
var _sweeps := PackedFloat32Array()
var _sweep := 0.0


## segments: Vector2i(Mode, ticks) each. plan may be null when no segment follows it. p_follow is copied.
func _init(start: ShipPilot.State, p_follow: RouteGuidance.Follow, plan: RouteGuidance.Plan, segments: Array[Vector2i], tail: int, profile: MovementProfile, probe: HullProbe, delta: float, map: RID) -> void:
	state = start.copy()
	follow = copy_follow(p_follow)
	_plan = plan
	_segments = segments
	_tail = tail
	_profile = profile
	_probe = probe
	_delta = delta
	_map = map
	_cell = NavigationServer3D.map_get_cell_size(map)
	_on_mesh = _off_mesh(state.position) <= profile.no_go_tolerance
	_skip_empty_segments()


func run(clock: PlanClock) -> int:
	while clock.has_time():
		var result := _step()
		clock.item_done()
		if result != RUNNING:
			return result
	return RUNNING


## Runs to the end without a clock (debug and tests).
func run_all() -> int:
	var result := RUNNING
	while result == RUNNING:
		result = _step()
	return result


func _step() -> int:
	if not _in_tail and _segment >= _segments.size():
		if _tail == Tail.NONE:
			return PASS if _flush() else _fail_here()
		_in_tail = true
	var mode := Mode.BRAKE if _in_tail or _arrived else _segments[_segment].x
	var position := state.position
	var yaw := state.yaw
	_targets.coast = mode == Mode.COAST
	_targets.has_order = mode == Mode.FOLLOW
	_targets.use_steer = false
	_targets.has_course = false
	_targets.bend_from = 0
	_targets.bend_radii = PackedFloat32Array()
	_targets.destination = state.position
	if mode == Mode.FOLLOW:
		RouteGuidance.guide(_plan, follow, state.position, state.yaw, _targets)
	ShipPilot.step(_profile, state, _targets, _delta, _out)
	if mode == Mode.FOLLOW and _out.arrived:
		_arrived = true
	var motion := Vector3(state.velocity.x, 0.0, state.velocity.z) * _delta
	state.position = position + motion
	state.bow = ShipPilot.bow_of(state.yaw)
	predicted_ticks += 1
	_buffer(position, yaw, motion, state.yaw - yaw)
	if (_sweep >= _probe.half_width or _positions.size() >= SEGMENT_MAX_TICKS) and not _flush():
		return _fail_here()
	if not _centre_allowed():
		failure = "centre enters the no-go zone at (%.1f, %.1f)" % [state.position.x, state.position.z]
		return _fail_here()
	if _in_tail:
		_tail_time += _delta
		if RouteGuidance.planar(state.velocity).length() <= REST_SPEED:
			if not _flush():
				return _fail_here()
			if _probe.overlaps(state.position, state.yaw, 0.0):
				failure = "resting pose overlaps at (%.1f, %.1f)" % [state.position.x, state.position.z]
				return _fail_here()
			return PASS
		if _tail_time >= REST_LIMIT:
			failure = "no rest within %.0f s of braking" % REST_LIMIT
			return _fail_here()
		return RUNNING
	_segment_tick += 1
	if _segment_tick >= _segments[_segment].y:
		segment_states.push_back(state.copy())
		segment_follows.push_back(copy_follow(follow))
		_segment += 1
		_segment_tick = 0
		_skip_empty_segments()
	elif _arrived and _tail == Tail.NONE:
		# The plan arrived: nothing is left to steer, and a progress prediction has reached its end.
		return PASS if _flush() else _fail_here()
	return RUNNING


func _skip_empty_segments() -> void:
	while _segment < _segments.size() and _segments[_segment].y <= 0:
		segment_states.push_back(state.copy())
		segment_follows.push_back(copy_follow(follow))
		_segment += 1


func _fail_here() -> int:
	failed_segment = _segments.size() if _in_tail else _segment
	return FAIL


func _off_mesh(position: Vector3) -> float:
	return RouteGuidance.planar(NavigationServer3D.map_get_closest_point(_map, position) - position).length()


## Whether the predicted centre may be here (see the class description).
func _centre_allowed() -> bool:
	var off_mesh := _off_mesh(state.position)
	if off_mesh <= _cell:
		_on_mesh = true
		return true
	return not _on_mesh or off_mesh <= _profile.no_go_tolerance


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


static func copy_follow(source: RouteGuidance.Follow) -> RouteGuidance.Follow:
	var other := RouteGuidance.Follow.new()
	if source == null:
		return other
	other.index = source.index
	other.frozen = source.frozen
	other.frozen_course = source.frozen_course
	other.s = source.s
	other.point = source.point
	return other
