class_name Navigator
extends RefCounted
## Static navigation for ShipMovement (Task #46): one planning job per activated move, then per-tick route guidance
## for the existing pilot. It never writes a transform or velocity; ShipMovement stays the single writer.
##
## A job checks navigation readiness, queries one Godot navigation path to the click, finds the hazard regions along
## it (where the hull might touch occupied space) and predicts candidate maneuvers with the real pilot (ShipPilot)
## and the real hull (HullProbe) through those regions. The first candidate that passes every hazard region is
## handed to the pilot once; no periodic re-planning. Jobs of all ships share one wall-clock allowance per physics
## tick (NavigationBudget) and are served oldest first; a job that runs out continues on the next tick.

const BUDGET: NavigationBudget = preload("res://Movement/Navigation/navigation_budget.tres")

enum Kind { DIRECT, ROUTE, DEPART }
enum Status { PENDING, DONE, DECLINED, CANCELLED }
enum Phase { SYNC, PREPARE, SEARCH, VALIDATE }
enum Run { RUNNING, PASS, FAIL }

## Physics frames that may pass with an unchanged map iteration while enabled regions report synced but no
## polygon is merged yet, before navigation counts as unavailable. Godot merges a region in the map sync after the
## one in which the region itself synced (observed: frame 3 region synced, frame 4 merge, path from frame 5).
const MERGE_WAIT_FRAMES := 2
## Hull-local departure translations tried, in order: astern, port, starboard, ahead (bow is local −Z). A moving ship
## first tries braking (no translation).
const DEPART_AXES: Array[Vector3] = [Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, -1)]
## A departure switches to route guidance after this many predicted ticks, tried in order (0.5 s steps to 4 s at
## 60 Hz); the rollout decides which switch point is safe.
const DEPART_SWITCH_STEP_TICKS := 30
const DEPART_SWITCH_COUNT := 8
## Prediction continues after arrival until the ship rests (below this speed) or this many ticks pass.
const REST_SPEED := 0.01
const REST_TICKS := 1200
## Past the last hazard region, a prediction checks the predicted ship's drift reach this often (ticks).
const DRIFT_CHECK_TICKS := 30
## Route points closer than this are duplicates.
const DUPLICATE_DISTANCE := 0.01
## A predicted ship counts as settled onto the route (so a long open stretch may be skipped) when its hull and
## velocity are within this angle of the route direction and it turns slower than SETTLE_TURN_RATE.
const SETTLE_ANGLE := deg_to_rad(2.0)
const SETTLE_TURN_RATE := deg_to_rad(0.5)

static var _jobs: Array[Job] = []
static var _frame := -1
static var _frame_used := 0


## A plan handed to the pilot: data only.
class Plan:
	var kind := Kind.DIRECT
	## Arrival point (the original click; Y at the ship).
	var destination := Vector3.ZERO
	## Route from the ship (index 0) to the destination, Y at the ship, and cumulative lengths.
	var route := PackedVector3Array()
	var lengths := PackedFloat32Array()
	var lookahead := 10.0
	## Per route point: the radius guidance traces through that corner (0 = no bend, the end points).
	var corner_radii := PackedFloat32Array()
	## Per interior route point: the sum of the incoming and outgoing unit directions (its bisector normal).
	var bisectors := PackedVector3Array()
	## Direct order course (radians).
	var has_course := false
	var course_yaw := 0.0
	## Departure: world direction, the yaw it starts at (kept: no commanded turning) and the tick at which route guidance
	## takes over.
	var depart_direction := Vector3.ZERO
	var hold_yaw := 0.0
	var switch_ticks := 0

	func total_length() -> float:
		return lengths[lengths.size() - 1]


## Per-ship progress along a plan; advanced by guide() each tick (real flight and prediction alike).
class Follow:
	var index := 1
	var frozen := false
	var frozen_course := 0.0
	var ticks := 0
	var switched := false
	## Arc length of the ship's projection on the route (m) and that projected point.
	var s := 0.0
	var point := Vector3.ZERO


## Starts the planning job for an activated move. The caller keeps the job and cancels it when a later command
## activates.
static func start_job(ship: ShipMovement, probe: HullProbe, click: Vector3) -> Job:
	var job := Job.new(ship, probe, click)
	_jobs.push_back(job)
	return job


## Advances queued jobs, oldest first, within this physics tick's shared allowance. Every ship calls it each tick;
## the allowance is reset on the first call of a new physics frame.
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
		job.advance(start + allowance)
		_frame_used += Time.get_ticks_usec() - start
		if job.status != Status.PENDING:
			_jobs.remove_at(i)
		else:
			i += 1


## Fills the pilot targets for this tick from a plan and the ship's planar position and yaw, advancing the follow
## state.
static func guide(plan: Plan, follow: Follow, position: Vector3, yaw: float, targets: ShipPilot.Targets) -> void:
	targets.destination = plan.destination
	targets.bend_lengths = plan.lengths
	targets.bend_radii = plan.corner_radii
	targets.bend_from = plan.route.size()
	_track(plan, follow, position)
	if plan.kind == Kind.DIRECT:
		targets.use_steer = false
		targets.has_course = plan.has_course
		targets.course_yaw = plan.course_yaw
		return
	var total := plan.total_length()
	var remaining := _planar(position - follow.point).length() + (total - follow.s)
	if plan.kind == Kind.DEPART and not follow.switched:
		if follow.ticks >= plan.switch_ticks:
			follow.switched = true
		else:
			# No commanded course: rotation stops at once without powered turning (Movement v3), so the hull keeps its
			# heading and the whole thruster capacity goes to braking or translating.
			targets.use_steer = true
			targets.steer_direction = plan.depart_direction
			targets.steer_distance = remaining
			targets.has_course = false
			targets.course_yaw = plan.hold_yaw
			return
	var aim_s := follow.s + plan.lookahead
	var aim := _point_from(plan, follow.index, minf(aim_s, total))
	var to_aim := _planar(aim - position)
	if aim_s >= total and not follow.frozen:
		# The final approach keeps the heading the hull has when it begins: no turning is left to share the thrusters
		# with the arrival braking, and arrival ends rotation anyway (no final alignment).
		follow.frozen = true
		follow.frozen_course = yaw
	if follow.frozen:
		# Final approach: the aim has reached the destination, so the pilot flies the ordinary direct arrival to it
		# (straight distance, sideways drift included) holding the heading it had when the approach began.
		targets.use_steer = false
		targets.has_course = true
		targets.course_yaw = follow.frozen_course
		return
	targets.use_steer = true
	targets.steer_direction = to_aim.normalized() if to_aim.length_squared() > 0.0 else Vector3.ZERO
	targets.steer_distance = remaining
	targets.has_course = to_aim.length_squared() > 0.0
	targets.course_yaw = atan2(-to_aim.x, -to_aim.z)
	# Upcoming interior route corners (the pilot caps the speed for each).
	targets.bend_from = follow.index
	targets.bend_s = follow.s


## Advances the corner index past every corner whose bisector the ship has crossed, then projects the ship on the
## current segment to update the arc length.
static func _track(plan: Plan, follow: Follow, position: Vector3) -> void:
	var route := plan.route
	var n := route.size()
	while follow.index < n - 1 and _planar(position - route[follow.index]).dot(plan.bisectors[follow.index]) >= 0.0:
		follow.index += 1
	var p0 := route[follow.index - 1]
	var segment := _planar(route[follow.index] - p0)
	var length := plan.lengths[follow.index] - plan.lengths[follow.index - 1]
	var t := 0.0
	if length > 0.0:
		t = clampf(_planar(position - p0).dot(segment) / (length * length), 0.0, 1.0)
	follow.s = plan.lengths[follow.index - 1] + t * length
	follow.point = p0 + segment * t


static func _point_at(plan: Plan, s: float) -> Vector3:
	return _point_from(plan, 1, s)


## The route point at arc length s, searching from route index first (s at or beyond that segment's start).
static func _point_from(plan: Plan, first: int, s: float) -> Vector3:
	var route := plan.route
	for j in range(first, route.size()):
		if s <= plan.lengths[j] or j == route.size() - 1:
			var length := plan.lengths[j] - plan.lengths[j - 1]
			var t := 0.0 if length <= 0.0 else clampf((s - plan.lengths[j - 1]) / length, 0.0, 1.0)
			return route[j - 1].lerp(route[j], t)
	return route[route.size() - 1]


## Whether a ship at position with the given speed, following the plan from arc length s on, cannot touch anything:
## the ship's position and every route sample ahead (every hull half-width) have an empty cylinder of radius hull
## reach + clearance buffer + v² / a_t, the distance the ship can drift sideways before the thrusters' planar share
## beside full turning (a_t / 2) has cancelled its speed. Conservative for geometry that is static while planning.
static func drift_clear(plan: Plan, probe: HullProbe, profile: MovementProfile, position: Vector3, speed: float, s: float) -> bool:
	var radius := probe.reach + profile.plan_clearance_buffer + speed * speed / (profile.thruster_strength / profile.mass)
	if not probe.cylinder_clear(position, radius):
		return false
	var total := plan.total_length()
	var spacing := maxf(probe.half_width, 0.5)
	var at := s
	while true:
		var point := _point_at(plan, minf(at, total))
		point.y = position.y
		if not probe.cylinder_clear(point, radius):
			return false
		if at >= total:
			return true
		at += spacing
	return true


## Stopping distance from max speed with the full directional-thruster braking (m).
static func stop_distance_of(profile: MovementProfile) -> float:
	return profile.max_speed * profile.max_speed / (2.0 * profile.thruster_strength / profile.mass)


static func _planar(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


## One predicted maneuver from the ship's actual state (see Job). Resumable: run() stops at the deadline.
##
## The prediction always starts at the actual state and is simulated tick by tick through every hazard region and
## through any open stretch where the predicted ship has not yet settled onto the route. Only an open stretch the
## predicted ship has entered settled (on the route, velocity and hull along it, no turn) and that is at least one
## stopping distance long is skipped: the next region then starts from the re-entry assumption (on the route, hull
## along it, the speed the speed law allows there). That assumption is not proof; the Task #44 stop remains the
## fallback there.
class Rollout:
	var plan: Plan
	var follow := Follow.new()
	var state: ShipPilot.State
	var targets := ShipPilot.Targets.new()
	var out := ShipPilot.Output.new()
	var profile: MovementProfile
	var probe: HullProbe
	var delta := 1.0 / 60.0
	var regions: Array[Vector2] = []
	var final_hazard := false
	var stop_distance := 0.0
	## Validation mode: only the stretch from the actual state to the end of the first hazard region (or to the point
	## the ship settles before it) is checked.
	var first_stretch_only := false
	var simulated_ticks := 0
	var skipped := 0
	var failure := ""
	## Whether the predicted ship had settled onto the route at some point (a later failure is then not a departure
	## problem).
	var settled_once := false
	var _region := 0
	var _arrived := false
	var _rest_ticks := 0
	var _start_check := true
	var _positions := PackedVector3Array()
	var _yaws := PackedFloat32Array()
	var _motions := PackedVector3Array()
	var _dyaws := PackedFloat32Array()
	var _sweeps := PackedFloat32Array()
	var _sweep := 0.0

	func _init(p_plan: Plan, start: ShipPilot.State, p_profile: MovementProfile, p_probe: HullProbe, p_regions: Array[Vector2], p_final: bool, p_delta: float) -> void:
		plan = p_plan
		state = start.copy()
		profile = p_profile
		probe = p_probe
		regions = p_regions
		final_hazard = p_final
		delta = p_delta
		stop_distance = Navigator.stop_distance_of(profile)
		targets.has_order = true
		Navigator._track(plan, follow, state.position)

	func run(deadline: int) -> int:
		while Time.get_ticks_usec() < deadline:
			var result := _tick()
			if result != Run.RUNNING:
				return result
		return Run.RUNNING

	## One predicted tick plus the region bookkeeping.
	func _tick() -> int:
		Navigator.guide(plan, follow, state.position, state.yaw, targets)
		targets.has_order = not _arrived
		var position := state.position
		var yaw := state.yaw
		ShipPilot.step(profile, state, targets, delta, out)
		if out.arrived:
			_arrived = true
		var motion := Vector3(state.velocity.x, 0.0, state.velocity.z) * delta
		state.position = position + motion
		state.bow = ShipPilot.bow_of(state.yaw)
		follow.ticks += 1
		simulated_ticks += 1
		_buffer(position, yaw, motion, state.yaw - yaw)
		if _sweep >= probe.half_width and not _flush():
			return Run.FAIL
		if _arrived:
			_rest_ticks += 1
			if state.velocity.length() <= Navigator.REST_SPEED or _rest_ticks >= Navigator.REST_TICKS:
				if not _flush():
					return Run.FAIL
				# The resting pose itself must be clear.
				if probe.overlaps(state.position, state.yaw, 0.0):
					failure = "resting pose overlaps"
					return Run.FAIL
				return Run.PASS
			return Run.RUNNING
		# Leave a region when the ship passes its end (the final hazard runs to rest).
		if _region < regions.size() and follow.s >= regions[_region].y and not (final_hazard and _region == regions.size() - 1):
			if not _flush():
				return Run.FAIL
			_region += 1
			if first_stretch_only:
				return Run.PASS
		# Past the last hazard region, the rest of the flight cannot touch anything once its drift corridor is empty (see
		# drift_clear()), checked every DRIFT_CHECK_TICKS.
		var in_region := _region < regions.size() and follow.s >= regions[_region].x
		if _region >= regions.size() and simulated_ticks % Navigator.DRIFT_CHECK_TICKS == 0:
			if Navigator.drift_clear(plan, probe, profile, state.position, state.velocity.length(), follow.s):
				return Run.PASS if _flush() else Run.FAIL
		# In an open stretch, skip ahead once the predicted ship has settled onto the route.
		if not in_region and _settled():
			settled_once = true
			if _region >= regions.size():
				return Run.PASS if _flush() else Run.FAIL
			if regions[_region].x - follow.s >= stop_distance:
				if not _flush():
					return Run.FAIL
				if first_stretch_only:
					return Run.PASS
				_reenter(regions[_region].x)
		return Run.RUNNING

	## Whether the predicted ship follows the route as the re-entry assumption describes: within the arrival tolerance
	## of it, velocity and hull along it, no turn.
	func _settled() -> bool:
		if plan.kind == Kind.DEPART and not follow.switched:
			return false
		var route := plan.route
		var direction := Navigator._planar(route[follow.index] - route[follow.index - 1]).normalized()
		var course := atan2(-direction.x, -direction.z)
		if absf(wrapf(state.yaw - course, -PI, PI)) > Navigator.SETTLE_ANGLE or absf(state.turn_rate) > Navigator.SETTLE_TURN_RATE:
			return false
		if Navigator._planar(state.position - follow.point).length() > profile.arrival_tolerance:
			return false
		var speed := state.velocity.length()
		return speed > 0.0 and state.velocity.dot(direction) >= speed * cos(Navigator.SETTLE_ANGLE)

	func _buffer(position: Vector3, yaw: float, motion: Vector3, dyaw: float) -> void:
		var bound := motion.length() + probe.reach * absf(dyaw)
		_positions.push_back(position)
		_yaws.push_back(yaw)
		_motions.push_back(motion)
		_dyaws.push_back(dyaw)
		_sweeps.push_back(bound)
		_sweep += bound

	## Checks the buffered ticks: one test of the hull grown by the segment's whole motion bound at its first pose
	## covers the segment; when that overlaps, the segment is halved until single ticks get the exact step test.
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
			var clear := probe.step_clear(_positions[first], _yaws[first], _motions[first], _dyaws[first], _start_check)
			_start_check = false
			if not clear:
				failure = "hull contact predicted at (%.1f, %.1f)" % [_positions[first].x, _positions[first].z]
			return clear
		if not _start_check and not probe.overlaps(_positions[first], _yaws[first], bound):
			return true
		var middle := (first + end) / 2
		var left := 0.0
		for k in range(first, middle):
			left += _sweeps[k]
		return _check(first, middle, left) and _check(middle, end, bound - left)

	## Skipped stretch: assume the ship is on the route at the region start, moving along it at the speed the speed
	## law allows there, hull on the route course, no turn (the stated re-entry assumption; not proof).
	func _reenter(s: float) -> void:
		skipped += 1
		var position := Navigator._point_at(plan, s)
		position.y = state.position.y
		var next := Navigator._point_at(plan, minf(s + 1.0, plan.total_length()))
		var direction := Navigator._planar(next - position).normalized()
		var a := profile.thruster_strength / profile.mass
		var lag := a * profile.pilot_response_time
		var speed := clampf(sqrt(2.0 * a * (plan.total_length() - s)) - lag, 0.0, profile.max_speed)
		var reentry := Follow.new()
		reentry.switched = true
		reentry.ticks = plan.switch_ticks
		Navigator._track(plan, reentry, position)
		var bend := minf(a, a / 2.0)
		for j in range(reentry.index, plan.route.size() - 1):
			var radius := plan.corner_radii[j]
			if radius > 0.0:
				speed = minf(speed, maxf(sqrt(bend * radius + 2.0 * bend * maxf(plan.lengths[j] - s, 0.0)) - bend * profile.pilot_response_time, 0.0))
		state.position = position
		state.velocity = direction * speed
		state.yaw = atan2(-direction.x, -direction.z)
		state.bow = ShipPilot.bow_of(state.yaw)
		state.turn_rate = 0.0
		state.planar_fraction_prev = 0.0
		follow = reentry
		_start_check = true


## One planning job for one activated move. Phases: SYNC (navigation readiness) → PREPARE (path, classification,
## hazard regions, candidates) → SEARCH (rollouts) → VALIDATE (only when the ship moved while the job ran).
class Job:
	var status := Status.PENDING
	## Result when DONE: a Plan (kind DIRECT for the unchanged direct order).
	var plan: Plan
	var reason := ""
	var used_usec := 0
	var ticks := 0
	var summary := ""
	var ship: ShipMovement
	var probe: HullProbe
	var profile: MovementProfile
	var click := Vector3.ZERO
	var _phase := Phase.SYNC
	var _last_frame := -1
	var _merge_iteration := -1
	var _merge_frame := -1
	var _map := RID()
	var _route_plan: Plan
	var _regions: Array[Vector2] = []
	var _final_hazard := false
	var _candidates: Array[Plan] = []
	var _candidate := 0
	var _rollout: Rollout
	var _snapshot: ShipPilot.State
	var _chosen: Plan
	var _hazard_text := ""
	var _rollouts := 0
	var _predicted_ticks := 0
	var _skipped := 0

	func _init(p_ship: ShipMovement, p_probe: HullProbe, p_click: Vector3) -> void:
		ship = p_ship
		probe = p_probe
		profile = p_ship.profile
		click = Vector3(p_click.x, p_ship.global_position.y, p_click.z)
		_map = p_ship.get_world_3d().navigation_map
		probe.queries = 0

	func cancel() -> void:
		if status == Status.PENDING:
			status = Status.CANCELLED

	func advance(deadline: int) -> void:
		if not is_instance_valid(ship):
			status = Status.CANCELLED
			return
		var start := Time.get_ticks_usec()
		var frame := Engine.get_physics_frames()
		if frame != _last_frame:
			_last_frame = frame
			ticks += 1
		var order_deadline := start + BUDGET.plan_time_per_order - used_usec
		var limit := mini(deadline, order_deadline)
		match _phase:
			Phase.SYNC:
				_sync()
			Phase.PREPARE:
				_prepare()
		if status == Status.PENDING and (_phase == Phase.SEARCH or _phase == Phase.VALIDATE):
			_search(limit)
		used_usec += Time.get_ticks_usec() - start
		if status == Status.PENDING and used_usec >= BUDGET.plan_time_per_order:
			_decline("planning time %d µs exceeded the per-order limit" % used_usec)

	func _sync() -> void:
		var iteration := NavigationServer3D.map_get_iteration_id(_map)
		if not NavigationServer3D.map_is_active(_map) or iteration == 0:
			return
		var enabled := _enabled_regions()
		if enabled.is_empty():
			_direct("navigation unavailable (no enabled navigation region)")
			return
		for region in enabled:
			if NavigationServer3D.region_get_iteration_id(region) == 0:
				return
		if NavigationServer3D.map_get_closest_point_owner(_map, click).is_valid():
			_phase = Phase.PREPARE
			_prepare()
			return
		# Regions synced but nothing merged yet: wait for the merge, but not for a map that no longer changes.
		var frame := Engine.get_physics_frames()
		if iteration != _merge_iteration:
			_merge_iteration = iteration
			_merge_frame = frame
		elif frame - _merge_frame >= Navigator.MERGE_WAIT_FRAMES:
			_direct("navigation unavailable (no navigation polygons)")

	func _enabled_regions() -> Array[RID]:
		var enabled: Array[RID] = []
		for region in NavigationServer3D.map_get_regions(_map):
			if NavigationServer3D.region_get_enabled(region):
				enabled.push_back(region)
		return enabled

	func _prepare() -> void:
		var position := ship.global_position
		var cell := NavigationServer3D.map_get_cell_size(_map)
		var inside := false
		for region in _enabled_regions():
			var bounds := NavigationServer3D.region_get_bounds(region)
			if click.x >= bounds.position.x and click.x <= bounds.end.x and click.z >= bounds.position.z and click.z <= bounds.end.z:
				inside = true
				break
		if not inside:
			_direct("destination outside the navigable area: direct (baseline)")
			return
		var closest := NavigationServer3D.map_get_closest_point(_map, click)
		if Navigator._planar(closest - click).length() > cell:
			_direct("unresolved destination %.2f m off the navigation mesh: direct (baseline until destination resolution)" % Navigator._planar(closest - click).length())
			return
		var path := NavigationServer3D.map_get_path(_map, position, click, true)
		if path.is_empty() or Navigator._planar(path[path.size() - 1] - click).length() > cell:
			_decline("destination unreachable on the navigation mesh")
			return
		# Route: the ship, the path's corners, the click; Y at the ship; duplicates dropped. The path starts at the
		# mesh point nearest the ship; within one cell that is the ship itself.
		var route := PackedVector3Array([position])
		for k in path.size():
			var point := Vector3(path[k].x, position.y, path[k].z)
			if k == path.size() - 1:
				point = click
			elif k == 0 and Navigator._planar(point - position).length() <= cell:
				continue
			if Navigator._planar(point - route[route.size() - 1]).length() > Navigator.DUPLICATE_DISTANCE:
				route.push_back(point)
		if route.size() == 1:
			route.push_back(click)
		route[route.size() - 1] = click
		# Drop corners that lie within one cell of the line between their neighbours (the path also keeps points where
		# it merely crosses a mesh polygon edge).
		var corner := 1
		while corner < route.size() - 1:
			var a := Navigator._planar(route[corner - 1])
			var b := Navigator._planar(route[corner + 1])
			var point := Navigator._planar(route[corner])
			var along := b - a
			var t := 0.0 if along.length_squared() == 0.0 else clampf((point - a).dot(along) / along.length_squared(), 0.0, 1.0)
			if (point - (a + along * t)).length() <= cell:
				route.remove_at(corner)
			else:
				corner += 1
		_route_plan = _make_plan(Kind.ROUTE, route)
		_find_hazards()
		if route.size() == 2:
			var direct := _make_plan(Kind.DIRECT, route)
			var course := Navigator._planar(click - position)
			direct.has_course = course != Vector3.ZERO
			if direct.has_course:
				direct.course_yaw = atan2(-course.x, -course.z)
			_candidates = [direct]
		else:
			_candidates = [_route_plan]
		var speed := Navigator._planar(ship.velocity).length()
		var moving := speed > profile.arrival_speed_tolerance
		if _regions.is_empty():
			# Nowhere along the route can the hull touch anything at any yaw. From rest the ship sets off along the route;
			# a moving ship needs its whole drift corridor empty as well (drift_clear()).
			if not moving or Navigator.drift_clear(_route_plan, probe, profile, position, speed, 0.0):
				_finish(_candidates[0], "no hazard regions")
				return
		# Departures: when the start is a hazard or the ship already moves (its momentum may carry it off the route).
		# Each holds the hull's heading, brakes or translates along a hull axis, then follows the route. A moving ship
		# tries braking first (shortest first), then the translations; translations are tried shortest first.
		if moving or (not _regions.is_empty() and _regions[0].x <= 0.0):
			if moving:
				for k in range(1, Navigator.DEPART_SWITCH_COUNT + 1):
					_candidates.push_back(_departure(route, Vector3.ZERO, k))
			for k in range(1, Navigator.DEPART_SWITCH_COUNT + 1):
				for axis in Navigator.DEPART_AXES:
					_candidates.push_back(_departure(route, axis, k))
		_phase = Phase.SEARCH
		_candidate = 0
		_snapshot = _live_state()

	func _departure(route: PackedVector3Array, axis: Vector3, k: int) -> Plan:
		var depart := _make_plan(Kind.DEPART, route)
		depart.hold_yaw = ship.rotation.y
		depart.depart_direction = Basis(Vector3.UP, ship.rotation.y) * axis
		depart.switch_ticks = k * Navigator.DEPART_SWITCH_STEP_TICKS
		return depart

	func _make_plan(kind: int, route: PackedVector3Array) -> Plan:
		var plan := Plan.new()
		plan.kind = kind
		plan.destination = click
		plan.route = route
		plan.lookahead = profile.detour_lookahead_distance
		plan.lengths.push_back(0.0)
		for k in range(1, route.size()):
			plan.lengths.push_back(plan.lengths[k - 1] + Navigator._planar(route[k] - route[k - 1]).length())
		# Corner radius: the tighter of an isolated corner rounded by the lookahead aim, lookahead / (2 sin(turn / 2)),
		# and the arc through the corner's neighbouring segments, (incoming + outgoing length) / (2 turn), which governs
		# a chain of small corners such as a navigation mesh's polygon around an obstacle.
		plan.corner_radii.resize(route.size())
		plan.corner_radii.fill(0.0)
		plan.bisectors.resize(route.size())
		plan.bisectors.fill(Vector3.ZERO)
		for j in range(1, route.size() - 1):
			var a := Navigator._planar(route[j] - route[j - 1])
			var b := Navigator._planar(route[j + 1] - route[j])
			plan.bisectors[j] = a.normalized() + b.normalized()
			var turn := acos(clampf(a.normalized().dot(b.normalized()), -1.0, 1.0))
			if turn >= 0.001:
				plan.corner_radii[j] = minf(plan.lookahead / (2.0 * sin(turn * 0.5)), (a.length() + b.length()) / (2.0 * turn))
		return plan

	## Hazard regions: route samples every hull half-width where a cylinder of radius hull reach + clearance buffer
	## is not empty (the hull could touch something there at some yaw). Each region gets a lead-in of the stopping
	## distance at max speed; regions closer than that are merged. The departure (start) and final approach (end)
	## samples are included.
	func _find_hazards() -> void:
		var total := _route_plan.total_length()
		var spacing := maxf(probe.half_width, 0.5)
		var radius := probe.reach + profile.plan_clearance_buffer
		var stop_distance := Navigator.stop_distance_of(profile)
		var samples := PackedFloat32Array()
		var s := 0.0
		while s < total:
			samples.push_back(s)
			s += spacing
		samples.push_back(total)
		_regions.clear()
		_final_hazard = false
		for k in samples.size():
			var point := Navigator._point_at(_route_plan, samples[k])
			if probe.cylinder_clear(point, radius):
				continue
			var start := maxf(samples[k] - stop_distance, 0.0)
			var end := minf(samples[k] + spacing, total)
			if k == samples.size() - 1:
				_final_hazard = true
				end = total
			if not _regions.is_empty() and start - _regions[_regions.size() - 1].y < stop_distance:
				_regions[_regions.size() - 1].y = maxf(_regions[_regions.size() - 1].y, end)
			else:
				_regions.push_back(Vector2(start, end))
		if _final_hazard and not _regions.is_empty():
			_regions[_regions.size() - 1].y = total
		var parts: Array[String] = []
		for region in _regions:
			parts.push_back("%.1f–%.1f" % [region.x, region.y])
		_hazard_text = "hazards [%s] of %.1f m%s" % [", ".join(parts), total, " (final approach)" if _final_hazard else ""]

	func _search(limit: int) -> void:
		while status == Status.PENDING:
			if _rollout == null:
				if _phase == Phase.VALIDATE:
					_rollout = _new_rollout(_chosen, true)
				else:
					if _candidate >= _candidates.size():
						_decline("no safe maneuver found (%d candidates; route: %s)" % [_candidates.size(), summary])
						return
					_rollout = _new_rollout(_candidates[_candidate], false)
				_rollouts += 1
			var result := _rollout.run(limit)
			if result == Run.RUNNING:
				return
			var finished := _rollout
			_rollout = null
			_predicted_ticks += finished.simulated_ticks
			_skipped += finished.skipped
			if _phase == Phase.VALIDATE:
				if result == Run.PASS:
					_complete(_chosen)
				else:
					# The ship moved while the job ran and the chosen departure no longer holds: search again from now.
					_phase = Phase.SEARCH
					_candidate = 0
					_snapshot = _live_state()
				continue
			if result == Run.PASS:
				_chosen = _candidates[_candidate]
				if _same_state(_snapshot, _live_state()):
					_complete(_chosen)
				else:
					_phase = Phase.VALIDATE
					_snapshot = _live_state()
				continue
			if _candidate == 0:
				summary = finished.failure
				# A first candidate that failed after the predicted ship had settled onto the route failed on the route
				# itself: no departure can change that.
				if finished.settled_once:
					_candidate = _candidates.size()
					continue
			_candidate += 1

	func _new_rollout(plan: Plan, first_stretch_only: bool) -> Rollout:
		var rollout := Rollout.new(plan, _snapshot, profile, probe, _regions, _final_hazard, ship.get_physics_process_delta_time())
		rollout.first_stretch_only = first_stretch_only
		return rollout

	func _complete(plan: Plan) -> void:
		var detail := ""
		if plan.kind == Kind.DEPART:
			detail = " departing %s for %.1f s" % [_axis_name(plan), plan.switch_ticks / 60.0]
		_finish(plan, "%s%s; %d rollouts, %d predicted ticks, %d skipped stretches, %d queries" % [_hazard_text, detail, _rollouts, _predicted_ticks, _skipped, probe.queries])

	func _axis_name(plan: Plan) -> String:
		var local := Basis(Vector3.UP, plan.hold_yaw).inverse() * plan.depart_direction
		if local == Vector3.ZERO:
			return "braking"
		if local.z > 0.5:
			return "astern"
		if local.z < -0.5:
			return "ahead"
		return "to port" if local.x < 0.0 else "to starboard"

	func _finish(p_plan: Plan, note: String) -> void:
		plan = p_plan
		status = Status.DONE
		summary = note

	func _direct(note: String) -> void:
		var direct := Plan.new()
		direct.kind = Kind.DIRECT
		direct.destination = click
		_finish(direct, note)

	func _decline(note: String) -> void:
		status = Status.DECLINED
		reason = note

	func _live_state() -> ShipPilot.State:
		return ship.get_pilot_state()

	func _same_state(a: ShipPilot.State, b: ShipPilot.State) -> bool:
		return a.position == b.position and a.velocity == b.velocity and a.yaw == b.yaw and a.turn_rate == b.turn_rate
