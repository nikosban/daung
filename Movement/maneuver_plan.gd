class_name ManeuverPlan
extends RefCounted
## Movement-internal maneuver plan of one route: a planned speed and turn-start trim for every route
## corner, and the incremental clearance gate that verifies them. Also holds Motion, the shared
## heading-and-throttle motion step used by both the ship and the gate's rollouts.

## Corner states in `speeds` (otherwise the verified corner speed, m/s).
const NO_TURN := INF ## Deflection within heading tolerance: passed without a planned turn.
const UNCHECKED := -1.0 ## Not verified yet: treated as stop-and-turn until it is.
const STOP := 0.0 ## Stop-and-turn: rest at the vertex, then start the next leg from rest.

## Fixed search bounds of the clearance gate (not gameplay tuning).
const SAMPLE_CORNER_MOTION := 0.25 ## m of hull-corner motion per sample through rotation; also the box margin.
const SAMPLE_TRAVEL := 1.0 ## m of travel per sample.
const SAMPLE_STEPS := 60 ## simulated steps per sample at most.
const MAX_SAMPLES := 200 ## per attempt; a turn not finished by then fails closed.
const ATTEMPTS := 4 ## planned corner speed, then halved three times.
const MAX_RESULTS := 32 ## overlap query result limit; a full result fails closed.


## Heading-and-throttle motion state of one ship, and its one-tick step.
class Motion:
	var position := Vector3.ZERO
	var yaw := 0.0 ## rad, Godot rotation.y; bow = (−sin, 0, −cos).
	var yaw_velocity := 0.0 ## rad/s, positive = left.
	var speed := 0.0 ## m/s along the bow, never negative.
	var slip := 0.0 ## m/s toward the hull's right; |slip| ≤ speed.
	var thrust_velocity := Vector3.ZERO ## m/s, world XZ, from the directional thrusters.

	func copy() -> Motion:
		var motion := Motion.new()
		motion.position = position
		motion.yaw = yaw
		motion.yaw_velocity = yaw_velocity
		motion.speed = speed
		motion.slip = slip
		motion.thrust_velocity = thrust_velocity
		return motion

	func bow() -> Vector3:
		return Vector3(-sin(yaw), 0.0, -cos(yaw))

	func right() -> Vector3:
		return Vector3(cos(yaw), 0.0, -sin(yaw))

	func velocity() -> Vector3:
		return bow() * speed + right() * slip + thrust_velocity

	func is_at_rest() -> bool:
		return speed == 0.0 and slip == 0.0 and thrust_velocity == Vector3.ZERO

	## One tick. heading: commanded yaw in rad, or NAN for none (yaw velocity eases to zero). The yaw
	## velocity approaches the fastest rate that can still stop at the heading, bounded by yaw_rate and
	## yaw_limit (rad/s), changing at most yaw_accel per second, so turns ease in and out. Slip gains
	## slip_gain of the old velocity's sideways part after the hull yaws, then decays. The main engine
	## moves speed toward speed_command at accel or decel; the thrusters move thrust_velocity toward
	## thrust_command at thruster_accel. Position is not integrated here.
	func step(profile: MovementProfile, delta: float, heading: float, speed_command: float, thrust_command: Vector3, yaw_limit: float) -> void:
		var max_rate := deg_to_rad(profile.yaw_rate)
		var yaw_accel := deg_to_rad(profile.yaw_accel)
		var error := 0.0
		var target := 0.0
		if not is_nan(heading):
			error = angle_difference(yaw, heading)
			# Fastest rate that still stops at the heading when slowed by yaw_accel·delta per tick.
			var step := yaw_accel * delta
			var stopping := step * (sqrt(0.25 + 2.0 * absf(error) / (step * delta)) - 0.5)
			target = signf(error) * minf(minf(max_rate, stopping), maxf(yaw_limit, 0.0))
		yaw_velocity = move_toward(yaw_velocity, target, yaw_accel * delta)
		var turn := yaw_velocity * delta
		if not is_nan(heading) and signf(turn) == signf(error) and absf(turn) > absf(error):
			turn = error
			yaw_velocity = error / delta
		yaw = wrapf(yaw + turn, -PI, PI)
		slip += profile.slip_gain * speed * sin(turn)
		slip = move_toward(slip, 0.0, profile.slip_decay * delta)
		var command := maxf(speed_command, 0.0)
		speed = move_toward(speed, command, (profile.accel if command > speed else profile.decel) * delta)
		slip = clampf(slip, -speed, speed)
		thrust_velocity = thrust_velocity.move_toward(thrust_command, profile.thruster_accel * delta)


## Route the plan belongs to (anchor first, final point last) and, per route index, the corner speed
## state and the turn-start distance before the vertex. Only interior indices are meaningful.
var route: PackedVector3Array
var speeds := PackedFloat64Array()
var trims := PackedFloat64Array()
## Planned (attempt 0) corner speed per route index.
var _base_speeds := PackedFloat64Array()
var _profile: MovementProfile

## Gate inputs, set by the owning ship.
var _hull_shape: BoxShape3D ## The hull box enlarged by SAMPLE_CORNER_MOTION on X and Z.
var _hull_local: Transform3D
var _hull_radius := 1.0
var _mask := 1
var _ship_rid: RID
var _height := 0.0

## Gate cursor: the next corner to check, and the rollout of the active attempt.
var _next := 1
var _active := false
var _corner := 0
var _attempt := 0
var _try_speed := 0.0
var _try_trim := 0.0
var _heading := 0.0
var _motion: Motion
var _sample_position := Vector3.ZERO
var _sample_yaw := 0.0
var _next_position := Vector3.ZERO
var _next_yaw := 0.0
var _steps := 0
var _samples := 0
var _stage := 0 ## 0 simulate; 1 overlap at sample; 2 candidates; 3 sweep; 4 final overlap.
var _turn_done := false
var _exclude: Array[RID] = []

## Measurement counters (read by tests): queries and simulated steps spent, and the last attempt index.
var queries_used := 0
var steps_used := 0
var attempts_used := PackedInt32Array()


func _init(route_points: PackedVector3Array, profile: MovementProfile, hull_shape: BoxShape3D, hull_local: Transform3D, hull_radius: float, mask: int, ship_rid: RID) -> void:
	_profile = profile
	_hull_shape = BoxShape3D.new()
	_hull_shape.size = hull_shape.size + Vector3(2.0 * SAMPLE_CORNER_MOTION, 0.0, 2.0 * SAMPLE_CORNER_MOTION)
	_hull_local = hull_local
	_hull_radius = maxf(hull_radius, 0.001)
	_mask = mask
	_ship_rid = ship_rid
	route = PackedVector3Array()
	for point in route_points:
		append(point)


## Adds a point to the end of the route; the previous final point becomes a corner to plan and check.
func append(point: Vector3) -> void:
	route.append(point)
	speeds.append(NO_TURN)
	trims.append(0.0)
	_base_speeds.append(NO_TURN)
	attempts_used.append(0)
	if route.size() >= 3:
		_plan_corner(route.size() - 2)


## Whether a corner still waits for the gate.
func is_unchecked(index: int) -> bool:
	return speeds[index] == UNCHECKED


## Marks a corner as stop-and-turn (e.g. reached before its check finished); the gate skips it.
func force_stop(index: int) -> void:
	speeds[index] = STOP
	trims[index] = 0.0
	if _active and _corner == index:
		_active = false


## Turn-start distance before a vertex for a corner speed: the turn radius v / yaw_rate times tan(φ / 2).
func trim_for(index: int, corner_speed: float) -> float:
	return corner_speed / deg_to_rad(_profile.yaw_rate) * tan(_deflection(index) / 2.0)


## Advances the clearance gate by at most clearance_check_budget queries and rollout_step_budget
## simulated steps; work stops for the tick as soon as either is used up and resumes from the same
## state. Returns the corners resolved this tick (passed at a speed, or STOP).
func advance(space: PhysicsDirectSpaceState3D, height: float) -> PackedInt32Array:
	_height = height
	var resolved := PackedInt32Array()
	var queries := _profile.clearance_check_budget
	var steps := _profile.rollout_step_budget
	while queries > 0 and steps > 0:
		if not _active:
			while _next <= route.size() - 2 and speeds[_next] != UNCHECKED:
				_next += 1
			if _next > route.size() - 2:
				break
			_corner = _next
			_attempt = 0
			_begin_attempt()
		if _stage != 0:
			queries -= 1
			queries_used += 1
			if not _run_stage(space):
				if _fail_attempt():
					resolved.append(_corner)
			elif _stage == 0 and _turn_done:
				speeds[_corner] = _try_speed
				trims[_corner] = _try_trim
				attempts_used[_corner] = _attempt + 1
				_active = false
				resolved.append(_corner)
			continue
		steps -= 1
		steps_used += 1
		_simulate()
	return resolved


func _deflection(index: int) -> float:
	var incoming := route[index] - route[index - 1]
	var outgoing := route[index + 1] - route[index]
	incoming.y = 0.0
	outgoing.y = 0.0
	if incoming.is_zero_approx() or outgoing.is_zero_approx():
		return 0.0
	return incoming.angle_to(outgoing)


## Corner speed for a vertex: min(turn_speed_factor · max_speed, the speed whose trim fits half of each
## adjacent leg). Deflections within heading_tolerance need no planned turn.
func _plan_corner(index: int) -> void:
	var deflection := _deflection(index)
	if deflection <= deg_to_rad(_profile.heading_tolerance):
		speeds[index] = NO_TURN
		_base_speeds[index] = NO_TURN
		return
	var half_leg := minf(route[index].distance_to(route[index - 1]), route[index].distance_to(route[index + 1])) / 2.0
	var fit := deg_to_rad(_profile.yaw_rate) * half_leg / tan(deflection / 2.0)
	_base_speeds[index] = minf(_profile.turn_speed_factor * _profile.max_speed, fit)
	speeds[index] = UNCHECKED
	trims[index] = 0.0
	if _active and _corner == index:
		_active = false


## Starts a rollout from the turn-start point at the attempt's speed, hull along the incoming leg.
func _begin_attempt() -> void:
	_active = true
	_try_speed = _base_speeds[_corner] / pow(2.0, _attempt)
	_try_trim = trim_for(_corner, _try_speed)
	var incoming := route[_corner] - route[_corner - 1]
	incoming.y = 0.0
	var outgoing := route[_corner + 1] - route[_corner]
	outgoing.y = 0.0
	_heading = atan2(-outgoing.x, -outgoing.z)
	_motion = Motion.new()
	_motion.position = route[_corner] - incoming.normalized() * _try_trim
	_motion.yaw = atan2(-incoming.x, -incoming.z)
	_motion.speed = _try_speed
	_sample_position = _motion.position
	_sample_yaw = _motion.yaw
	_steps = 0
	_samples = 0
	_turn_done = false
	_stage = 1 # The start pose is checked first.
	_next_position = _sample_position
	_next_yaw = _sample_yaw
	_exclude.clear()


## One simulated tick of the TURN the ship would fly through this corner (the shared motion step).
## Takes a sample after SAMPLE_CORNER_MOTION of hull-corner rotation, SAMPLE_TRAVEL of travel or
## SAMPLE_STEPS steps, and once the heading is within heading_tolerance of the outgoing leg.
func _simulate() -> void:
	var delta := 1.0 / Engine.physics_ticks_per_second
	_motion.step(_profile, delta, _heading, _try_speed, Vector3.ZERO, INF)
	_motion.position += _motion.velocity() * delta
	_steps += 1
	_turn_done = absf(angle_difference(_motion.yaw, _heading)) <= deg_to_rad(_profile.heading_tolerance)
	var rotated := absf(angle_difference(_sample_yaw, _motion.yaw)) * _hull_radius
	if _turn_done or rotated >= SAMPLE_CORNER_MOTION or _motion.position.distance_to(_sample_position) >= SAMPLE_TRAVEL or _steps >= SAMPLE_STEPS:
		_samples += 1
		_steps = 0
		_next_position = _motion.position
		_next_yaw = _motion.yaw
		_stage = 2
		if _samples > MAX_SAMPLES:
			_stage = -1 # Fails closed on the next query slot.


## Runs one query of the current sample interval. False when the attempt fails.
func _run_stage(space: PhysicsDirectSpaceState3D) -> bool:
	match _stage:
		-1:
			return false
		1:
			if _overlaps_static(space, _pose(_sample_position, _sample_yaw)):
				return false
			_stage = 0
			return true
		2:
			if not _collect_exclusions(space):
				return false
			_stage = 3
			return true
		3:
			var params := _shape_params(_pose(_sample_position, _sample_yaw))
			params.motion = Vector3(_next_position.x - _sample_position.x, 0.0, _next_position.z - _sample_position.z)
			params.exclude = _exclude
			var fractions := space.cast_motion(params)
			if fractions.is_empty() or fractions[0] < 1.0:
				return false
			_sample_position = _next_position
			_sample_yaw = _next_yaw
			_stage = 4 if _turn_done else 1
			return true
		4:
			if _overlaps_static(space, _pose(_sample_position, _sample_yaw)):
				return false
			_stage = 0
			return true
	return false


## Fails the active attempt: retries at half the speed, or resolves the corner as STOP after the last
## attempt. Returns true when the corner was resolved.
func _fail_attempt() -> bool:
	_attempt += 1
	if _attempt >= ATTEMPTS:
		speeds[_corner] = STOP
		trims[_corner] = 0.0
		attempts_used[_corner] = ATTEMPTS
		_active = false
		return true
	_begin_attempt()
	return false


func _pose(position: Vector3, yaw: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw), Vector3(position.x, _height, position.z)) * _hull_local


func _shape_params(pose: Transform3D) -> PhysicsShapeQueryParameters3D:
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = _hull_shape
	params.transform = pose
	params.collision_mask = _mask
	params.exclude = [_ship_rid]
	return params


## Static obstacle (a StaticBody3D that is not an AnimatableBody3D) overlapping the enlarged hull. A
## full result list or an unknown collider fails closed (counts as overlapping).
func _overlaps_static(space: PhysicsDirectSpaceState3D, pose: Transform3D) -> bool:
	var hits := space.intersect_shape(_shape_params(pose), MAX_RESULTS)
	if hits.size() >= MAX_RESULTS:
		return true
	for hit in hits:
		var collider: Object = hit.collider
		if collider == null or (collider is StaticBody3D and not collider is AnimatableBody3D):
			return true
	return false


## Bodies the sweep from the sample pose to the next one could touch: everything overlapping the
## axis-aligned box around the enlarged hull at both poses (a straight sweep stays inside it). Every
## one that is not a static obstacle is excluded from the sweep. False (fail closed) on a full result
## list or a collider that is not a CollisionObject3D.
func _collect_exclusions(space: PhysicsDirectSpaceState3D) -> bool:
	var extent := _hull_shape.size / 2.0
	var local := AABB(-extent, extent * 2.0)
	var bounds := (_pose(_sample_position, _sample_yaw) * local).merge(_pose(_next_position, _next_yaw) * local)
	var box := BoxShape3D.new()
	box.size = bounds.size
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = box
	params.transform = Transform3D(Basis.IDENTITY, bounds.get_center())
	params.collision_mask = _mask
	params.exclude = [_ship_rid]
	var hits := space.intersect_shape(params, MAX_RESULTS)
	if hits.size() >= MAX_RESULTS:
		return false
	_exclude = [_ship_rid]
	for hit in hits:
		var collider: Object = hit.collider
		if not collider is CollisionObject3D:
			return false
		if not (collider is StaticBody3D and not collider is AnimatableBody3D):
			_exclude.append(hit.rid)
	return true
