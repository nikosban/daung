class_name ShipPilot
extends RefCounted
## The Movement v3 pilot and propulsion (steps 1–8 in ARCHITECTURE.md) as one pure function. ShipMovement calls it
## for the real physics tick; the navigator calls it on copies of the state to predict motion (Task #46). There is
## no other steering code, so prediction and flight cannot drift apart.
##
## step() reads the state and targets, and writes the new planar velocity, yaw and turn rate back into the state.
## It never moves the position: the real tick does that with move_and_slide(), a prediction with velocity x delta.


## Planar ship state. The real tick fills it from the body; a prediction keeps its own copy.
class State:
	var position := Vector3.ZERO
	## Planar velocity (Y is ignored on input and 0 on output).
	var velocity := Vector3.ZERO
	## Yaw in radians.
	var yaw := 0.0
	## Unit planar bow. The real tick takes it from the body's basis; a prediction derives it from the yaw.
	var bow := Vector3.FORWARD
	## Turn rate in rad/s.
	var turn_rate := 0.0
	## Last tick's planar demand fraction on the directional thrusters (0–1).
	var planar_fraction_prev := 0.0
	## Last tick's start-of-tick planar speed (m/s); with this tick's it gives the current deceleration.
	var speed_prev := 0.0

	func copy() -> State:
		var other := State.new()
		other.position = position
		other.velocity = velocity
		other.yaw = yaw
		other.bow = bow
		other.turn_rate = turn_rate
		other.planar_fraction_prev = planar_fraction_prev
		other.speed_prev = speed_prev
		return other


## What the pilot steers toward this tick.
class Targets:
	var has_order := false
	## Arrival point: the order completes within arrival_tolerance of it at or below arrival_speed_tolerance.
	var destination := Vector3.ZERO
	## false: steer straight at the destination (the direct order). true: steer along steer_direction with the
	## arrival speed law applied to steer_distance (route guidance, Task #46).
	var use_steer := false
	var steer_direction := Vector3.ZERO
	var steer_distance := 0.0
	var has_course := false
	## Course heading in radians.
	var course_yaw := 0.0
	## Route bends: per route point, its arc length along the route (m) and the radius guidance traces through it
	## (m, 0 = no bend). Points from bend_from on are ahead of the ship, which is at arc length bend_s. Empty arrays
	## (the direct order) mean no bends.
	var bend_lengths := PackedFloat32Array()
	var bend_radii := PackedFloat32Array()
	var bend_from := 0
	var bend_s := 0.0


## Last tick's values, for the read-only debug getters.
class Output:
	var arrived := false
	var main_command := 0.0
	var thruster_command := Vector3.ZERO
	var target_yaw := 0.0
	var turn_acceleration := 0.0
	## Available angular acceleration at the actual speed (rad/s², before sharing) and the turn-rate limit (rad/s).
	var turn_authority := 0.0
	var turn_rate_limit := 0.0
	var shared_scale := 1.0
	var desired_speed := 0.0
	var planned_braking := 0.0
	var directional_effectiveness := 1.0
	## The directional thrusters' request before allocation (world XZ, m/s²) and the planar share of their limits it was
	## allocated within (0–1).
	var thruster_request := Vector3.ZERO
	var planar_share := 0.0
	## Bow alignment: the order's course yaw, the largest commanded bow-to-travel angle at the actual speed (radians,
	## PI = unrestricted) and the actual angle between bow and travel direction (radians, 0–PI; 0 at rest).
	var course_yaw := 0.0
	var max_bow_angle := PI
	var bow_travel_angle := 0.0


## One pilot tick. Sets out.arrived when the active order completes this tick; the caller then ends its order.
static func step(profile: MovementProfile, state: State, targets: Targets, delta: float, out: Output) -> void:
	var planar_velocity := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var speed := planar_velocity.length()
	var to_destination := targets.destination - state.position
	to_destination.y = 0.0
	var distance := to_destination.length()
	var thruster_limit := profile.thruster_strength / profile.mass
	var sternward_limit := sternward_limit_of(profile, thruster_limit)
	# Speed-dependent directional thrust at the actual planar speed. The thrusters' physical envelope: sideways and
	# bow-forward thruster_limit x effectiveness, sternward the full thruster_limit (then the retro rule). Bow-forward
	# thrust that does not brake (forward propulsion assistance) is further limited to forward_directional_acceleration x
	# effectiveness, so the main engine stays the primary forward propulsion; braking keeps the physical envelope.
	var _effectiveness := effectiveness_of(profile, speed)
	var sideways_limit := thruster_limit * _effectiveness
	var forward_limit := profile.forward_directional_acceleration * _effectiveness
	var bow := state.bow
	var has_order := targets.has_order

	var arrived := false
	if has_order and distance <= profile.arrival_tolerance and speed <= profile.arrival_speed_tolerance:
		has_order = false
		arrived = true

	# Steering direction and distance for the speed law: straight at the destination for a direct order, or the
	# supplied route guidance.
	var steer_direction := Vector3.ZERO
	var steer_distance := distance
	if targets.use_steer:
		steer_direction = targets.steer_direction
		steer_distance = targets.steer_distance
	elif distance > 0.0:
		steer_direction = to_destination / distance

	# Turning demand: bounded angular acceleration toward the steering target, as a fraction of the available
	# authority. Authority and turn-rate limit come from their own curves of the actual speed.
	var turn_limit := deg_to_rad(maxf(profile.turn_acceleration_curve.sample(speed), 0.0))
	var _turn_rate_limit := deg_to_rad(maxf(profile.turn_rate_curve.sample(speed), 0.0))
	# Bow alignment: while the ship moves bow-first, the steering target is the course heading limited to
	# bow_alignment_curve(actual speed) either side of the actual travel direction, recalculated every tick, so the hull
	# leads a turn by at most that angle and the turn finishes as the trajectory follows. Stern-first motion and a
	# standstill are not limited. Only the target is limited: the hull and the velocity are never moved into line.
	var _max_bow_angle := alignment_limit_of(profile, speed)
	var _target_yaw := aligned_target(targets.course_yaw, planar_velocity, bow, _max_bow_angle)
	var turn_request := 0.0
	var turn_fraction := 0.0
	if has_order and targets.has_course and turn_limit > 0.0:
		var error := wrapf(_target_yaw - state.yaw, -PI, PI)
		# Braking-distance rule: the fastest rate that can still stop at the target, within the turn-rate
		# limit. It plans with the share the turn would get if planar demand stays at last tick's level
		# (proportional sharing). The |error| / delta term only keeps the wanted rate from stepping past
		# the target in one tick. Authority and rate limit fall as the ship slows below their peak, so the plan uses
		# the least of each between the actual speed and the speed left after the time the turn needs to stop at
		# last tick's deceleration: the turn can still be stopped, and the rate stays within the limit it will meet.
		var deceleration := maxf((state.speed_prev - speed) / delta, 0.0)
		var plan_authority := turn_limit
		var plan_rate_limit := _turn_rate_limit
		for _i in 2:
			var stop_time := absf(state.turn_rate) * (1.0 + state.planar_fraction_prev) / maxf(plan_authority, 1e-6)
			var lowest := maxf(speed - deceleration * stop_time, 0.0)
			plan_authority = deg_to_rad(maxf(curve_minimum(profile.turn_acceleration_curve, lowest, speed), 0.0))
			plan_rate_limit = deg_to_rad(maxf(curve_minimum(profile.turn_rate_curve, lowest, speed), 0.0))
		var planned_turn_limit := plan_authority / (1.0 + state.planar_fraction_prev)
		var wanted_rate := signf(error) * minf(minf(sqrt(2.0 * planned_turn_limit * absf(error)), absf(error) / delta), plan_rate_limit)
		turn_request = (wanted_rate - state.turn_rate) / delta
		turn_fraction = minf(absf(turn_request) / turn_limit, 1.0)
	else:
		state.turn_rate = 0.0

	# Desired velocity: along the steering direction at the speed the thrusters can still stop from, capped. The
	# braking it plans with is the physical envelope's reach against the travel direction at the actual speed (full
	# thruster_limit when that is sternward, thruster_limit x effectiveness sideways or bow-forward: braking is not
	# forward assistance, so the forward-assistance limit does not apply), times the share
	# proportional sharing leaves a saturated planar demand beside this tick's turning demand: 1 / (1 + turn fraction).
	# Without retro thrusters, stopping the velocity takes acceleration along its reverse, whose sternward share
	# is (travel direction · bow); the retro rule then allows at most sternward_limit / share. At a standstill
	# the travel direction is the steering direction.
	# The pilot closes the gap to the desired speed through pilot_response_time, so it would trail the ideal
	# braking curve sqrt(2 a d) by a·response time. Subtracting that lag makes the request exactly the planned
	# braking while the ship is on the curve, so braking starts in time to stop at the destination (clamped at
	# zero within a·response time² / 2 of it).
	var travel := Vector3.ZERO
	if speed > 0.0:
		travel = planar_velocity / speed
	elif steer_distance > 0.0:
		travel = steer_direction
	var _planned_braking := thruster_limit / (1.0 + turn_fraction)
	if travel != Vector3.ZERO:
		_planned_braking = reach_of(-travel, bow, thruster_limit, sideways_limit, sideways_limit) / (1.0 + turn_fraction)
	var sternward_share := travel.dot(bow)
	if sternward_share > 0.0:
		_planned_braking = minf(_planned_braking, sternward_limit / sternward_share)
	var desired := Vector3.ZERO
	if has_order and steer_distance > 0.0:
		var braking := _planned_braking
		var lag := braking * profile.pilot_response_time
		var desired_speed := clampf(sqrt(2.0 * braking * steer_distance) - lag, 0.0, profile.max_speed)
		# Route bends (Task #46): slow early enough to reach each bend at the speed its curve can be held at,
		# v² = a · radius, with the same lag compensation. A bend needs turning, so it plans with the planar share
		# proportional sharing leaves beside full turning demand, a_t / (1 + 1), not this tick's (possibly straight-
		# line) share, which would only shrink once the turn has begun.
		var last_bend := targets.bend_radii.size() - 1
		if targets.bend_from < last_bend:
			# The curve itself is held sideways, so its speed is also limited by half the sideways limit at that
			# speed (v² = a_t · effectiveness(v) / 2 · radius).
			var bend_braking := minf(braking, thruster_limit / 2.0)
			var bend_lag := bend_braking * profile.pilot_response_time
			for j in range(targets.bend_from, last_bend):
				var radius := targets.bend_radii[j]
				if radius > 0.0:
					var to_bend := maxf(targets.bend_lengths[j] - targets.bend_s, 0.0)
					var hold := minf(bend_braking * radius, bend_hold_speed_squared(profile, thruster_limit / 2.0, radius))
					var bend_speed := sqrt(hold + 2.0 * bend_braking * to_bend) - bend_lag
					desired_speed = minf(desired_speed, maxf(bend_speed, 0.0))
		desired = steer_direction * desired_speed
	var _desired_speed := desired.length()

	var requested := (desired - planar_velocity) / profile.pilot_response_time
	# The main engine pushes along the bow only, and only when that cannot reduce the current speed
	# (no stern-first component), so it never brakes. It is outside the shared thruster capacity.
	var _main_command := 0.0
	if planar_velocity.dot(bow) >= 0.0:
		_main_command = clampf(requested.dot(bow), 0.0, profile.main_acceleration)

	# Planar demand on the directional thrusters, as a fraction of their speed-dependent limits (1 = at a limit): the
	# physical envelope, and the forward-assistance limit for the request's non-braking bow-forward part.
	var thruster_request := requested - bow * _main_command
	var response_time := profile.pilot_response_time
	var planar_fraction := minf(demand_of(thruster_request, planar_velocity, bow, response_time, thruster_limit, sideways_limit, forward_limit), 1.0)

	# One shared capacity: when the two fractions exceed it, both are scaled down proportionally. The planar share is
	# then filled braking first, sideways maneuvering second and forward assistance last (see allocate()).
	var _shared_scale := 1.0
	if planar_fraction + turn_fraction > 1.0:
		_shared_scale = 1.0 / (planar_fraction + turn_fraction)
	var _planar_share := planar_fraction * _shared_scale
	var _thruster_command := allocate(thruster_request, planar_velocity, _planar_share, bow, response_time, thruster_limit, sideways_limit, forward_limit)
	var _turn_acceleration := signf(turn_request) * turn_fraction * _shared_scale * turn_limit
	# Retro rule on the applied thrust: remove only the sternward excess; the removed capacity is not reallocated.
	var sternward := -_thruster_command.dot(bow)
	if sternward > sternward_limit:
		_thruster_command += bow * (sternward - sternward_limit)

	# The limit can contract faster than the authority can slow the turn; the rate is then clamped to it.
	state.turn_rate = clampf(state.turn_rate + _turn_acceleration * delta, -_turn_rate_limit, _turn_rate_limit)
	state.planar_fraction_prev = planar_fraction
	state.speed_prev = speed
	planar_velocity += (bow * _main_command + _thruster_command) * delta
	state.velocity = planar_velocity.limit_length(profile.max_speed)
	state.yaw += state.turn_rate * delta

	out.arrived = arrived
	out.main_command = _main_command
	out.thruster_command = _thruster_command
	out.target_yaw = _target_yaw
	out.turn_acceleration = _turn_acceleration
	out.turn_authority = turn_limit
	out.turn_rate_limit = _turn_rate_limit
	out.shared_scale = _shared_scale
	out.desired_speed = _desired_speed
	out.planned_braking = _planned_braking
	out.directional_effectiveness = _effectiveness
	out.thruster_request = thruster_request
	out.course_yaw = targets.course_yaw
	out.max_bow_angle = _max_bow_angle
	out.bow_travel_angle = acos(clampf(bow.dot(planar_velocity / speed), -1.0, 1.0)) if speed > 0.0 else 0.0
	out.planar_share = _planar_share


## Unit planar bow for a yaw (0 = −Z, positive = counter-clockwise seen from above).
static func bow_of(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


## The lowest value of a curve over the input range low–high (its value at both ends and at every point between).
static func curve_minimum(curve: Curve, low: float, high: float) -> float:
	var lowest := minf(curve.sample(low), curve.sample(high))
	for i in curve.point_count:
		var x := curve.get_point_position(i).x
		if x > low and x < high:
			lowest = minf(lowest, curve.get_point_position(i).y)
	return lowest


## Largest commanded angle (radians, 0–PI) between bow and travel direction at an actual planar speed in m/s.
static func alignment_limit_of(profile: MovementProfile, speed: float) -> float:
	return deg_to_rad(clampf(profile.bow_alignment_curve.sample(speed), 0.0, 180.0))


## Steering target (yaw in radians): the course yaw limited to max_angle either side of the travel direction while the
## velocity has a bow-first component; otherwise (stern-first, sideways or at rest) the course yaw itself.
static func aligned_target(course_yaw: float, velocity: Vector3, bow: Vector3, max_angle: float) -> float:
	if velocity.dot(bow) <= 0.0 or max_angle >= PI:
		return course_yaw
	var travel_yaw := atan2(-velocity.x, -velocity.z)
	return travel_yaw + clampf(wrapf(course_yaw - travel_yaw, -PI, PI), -max_angle, max_angle)


## Directional-thruster effectiveness (0–1) at an actual planar speed in m/s, from the profile's curve.
static func effectiveness_of(profile: MovementProfile, speed: float) -> float:
	return clampf(profile.directional_thrust_curve.sample(speed), 0.0, 1.0)


## A planar thruster acceleration's size relative to an envelope (1 = on its edge). In the bow frame the envelope is two
## half-ellipses sharing the sideways semi-axis sideways_limit: toward the stern with semi-axis thruster_limit, toward the
## bow with semi-axis forward_limit. Convex. The thrusters' physical envelope uses forward_limit = sideways_limit.
static func envelope_norm(thrust: Vector3, bow: Vector3, thruster_limit: float, sideways_limit: float, forward_limit: float) -> float:
	var axial := thrust.dot(bow)
	var lateral := thrust.dot(Vector3(-bow.z, 0.0, bow.x))
	var axial_limit := forward_limit if axial > 0.0 else thruster_limit
	if (lateral != 0.0 and sideways_limit <= 0.0) or (axial > 0.0 and axial_limit <= 0.0):
		return INF
	var axial_part := axial / axial_limit if axial != 0.0 else 0.0
	var lateral_part := lateral / sideways_limit if lateral != 0.0 else 0.0
	return sqrt(axial_part * axial_part + lateral_part * lateral_part)


## The largest thruster acceleration (m/s²) along a unit planar direction inside the envelope.
static func reach_of(direction: Vector3, bow: Vector3, thruster_limit: float, sideways_limit: float, forward_limit: float) -> float:
	return 1.0 / envelope_norm(direction, bow, thruster_limit, sideways_limit, forward_limit)


## Splits a planar thrust into [braking, maneuvering, forward assistance], which sum to it. Per hull axis (along the bow
## and sideways), braking is the thrust that opposes the velocity on that axis, up to the rate that removes that velocity
## within response_time (what the pilot requests to stop it); more than that pushes the other way and is not braking.
## Forward assistance is the remaining bow-forward thrust, which pushes the ship forward. Maneuvering is everything else
## (sideways thrust that does not brake, and sternward thrust that does not brake).
static func split(thrust: Vector3, velocity: Vector3, bow: Vector3, response_time: float) -> Array[Vector3]:
	var right := Vector3(-bow.z, 0.0, bow.x)
	var axial := thrust.dot(bow)
	var lateral := thrust.dot(right)
	var braking_axial := _braking_on_axis(axial, velocity.dot(bow), response_time)
	var braking_lateral := _braking_on_axis(lateral, velocity.dot(right), response_time)
	var braking := bow * braking_axial + right * braking_lateral
	var forward := bow * maxf(axial - braking_axial, 0.0)
	return [braking, thrust - braking - forward, forward]


## The part of a thrust component that opposes the velocity component on the same axis, up to |velocity| / response_time.
static func _braking_on_axis(thrust: float, velocity: float, response_time: float) -> float:
	if thrust * velocity >= 0.0:
		return 0.0
	return signf(thrust) * minf(absf(thrust), absf(velocity) / response_time)


## A planar thrust's demand as a fraction of the limits (1 = at a limit): the physical envelope, or the forward-assistance
## limit for its forward-assistance part, whichever is larger.
static func demand_of(thrust: Vector3, velocity: Vector3, bow: Vector3, response_time: float, thruster_limit: float, sideways_limit: float, forward_limit: float) -> float:
	var demand := envelope_norm(thrust, bow, thruster_limit, sideways_limit, sideways_limit)
	var forward := split(thrust, velocity, bow, response_time)[2].length()
	if forward > 0.0:
		demand = maxf(demand, forward / forward_limit if forward_limit > 0.0 else INF)
	return demand


## Thruster command for a request within a share (capacity, 0–1) of the limits, in priority order: braking, then
## maneuvering (sideways and non-braking sternward), then forward assistance (see split()). Each part gets the largest scale
## (0–1) that keeps the physical envelope within the share after the parts before it, which it never reduces; forward
## assistance is also kept within capacity x forward_limit. Nothing is scaled up, so the command never exceeds the request
## or the share.
static func allocate(request: Vector3, velocity: Vector3, capacity: float, bow: Vector3, response_time: float, thruster_limit: float, sideways_limit: float, forward_limit: float) -> Vector3:
	var scales := allocation_scales(request, velocity, capacity, bow, response_time, thruster_limit, sideways_limit, forward_limit)
	if scales == Vector3.ONE:
		return request
	var parts := split(request, velocity, bow, response_time)
	return parts[0] * scales.x + parts[1] * scales.y + parts[2] * scales.z


## The scales allocate() gives the request's [braking, maneuvering, forward assistance] parts (x, y, z; each 0–1).
static func allocation_scales(request: Vector3, velocity: Vector3, capacity: float, bow: Vector3, response_time: float, thruster_limit: float, sideways_limit: float, forward_limit: float) -> Vector3:
	var parts := split(request, velocity, bow, response_time)
	var forward_cap := forward_scale_cap(parts[2], capacity, forward_limit)
	if forward_cap >= 1.0 and envelope_norm(request, bow, thruster_limit, sideways_limit, sideways_limit) <= capacity:
		return Vector3.ONE
	var command := Vector3.ZERO
	var k_braking := largest_fit(command, parts[0], 1.0, capacity, bow, thruster_limit, sideways_limit)
	command += parts[0] * k_braking
	var k_maneuver := largest_fit(command, parts[1], 1.0, capacity, bow, thruster_limit, sideways_limit)
	command += parts[1] * k_maneuver
	var k_forward := largest_fit(command, parts[2], forward_cap, capacity, bow, thruster_limit, sideways_limit)
	return Vector3(k_braking, k_maneuver, k_forward)


## The largest scale (0–1) forward assistance may get from its own limit: capacity x forward_limit / its size.
static func forward_scale_cap(forward: Vector3, capacity: float, forward_limit: float) -> float:
	var size := forward.length()
	if size <= 0.0:
		return 1.0
	return minf(1.0, capacity * forward_limit / size) if forward_limit > 0.0 else 0.0


## The largest k in 0–k_max with base + addition x k inside the physical envelope's share (base already inside it):
## exact when base is zero (the envelope norm is positively homogeneous), otherwise by bisection (it is convex along the
## line).
static func largest_fit(base: Vector3, addition: Vector3, k_max: float, capacity: float, bow: Vector3, thruster_limit: float, sideways_limit: float) -> float:
	if addition == Vector3.ZERO or k_max <= 0.0:
		return 0.0
	if base == Vector3.ZERO:
		return minf(k_max, capacity / envelope_norm(addition, bow, thruster_limit, sideways_limit, sideways_limit))
	if envelope_norm(base + addition * k_max, bow, thruster_limit, sideways_limit, sideways_limit) <= capacity:
		return k_max
	var low := 0.0
	var high := k_max
	for _i in 20:
		var k := (low + high) * 0.5
		if envelope_norm(base + addition * k, bow, thruster_limit, sideways_limit, sideways_limit) <= capacity:
			low = k
		else:
			high = k
	return low


## Squared speed (m²/s²) at which a bend of this radius can be held with hold_limit x effectiveness at that speed as the
## sideways acceleration: v² = hold_limit · effectiveness(v) · radius, by bisection over 0–max_speed.
static func bend_hold_speed_squared(profile: MovementProfile, hold_limit: float, radius: float) -> float:
	var low := 0.0
	var high := profile.max_speed
	if high * high <= hold_limit * effectiveness_of(profile, high) * radius:
		return high * high
	for _i in 16:
		var v := (low + high) * 0.5
		if v * v <= hold_limit * effectiveness_of(profile, v) * radius:
			low = v
		else:
			high = v
	return low * low


## Largest sternward directional-thruster acceleration (m/s²): unlimited with retro thrusters.
static func sternward_limit_of(profile: MovementProfile, thruster_limit: float) -> float:
	if profile.retro_thrusters:
		return INF
	return profile.no_retro_braking_effectiveness * thruster_limit
