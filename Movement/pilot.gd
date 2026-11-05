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

	func copy() -> State:
		var other := State.new()
		other.position = position
		other.velocity = velocity
		other.yaw = yaw
		other.bow = bow
		other.turn_rate = turn_rate
		other.planar_fraction_prev = planar_fraction_prev
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
	var rudder_multiplier := 0.0
	var turn_rate_limit := 0.0
	var shared_scale := 1.0
	var desired_speed := 0.0
	var planned_braking := 0.0


## One pilot tick. Sets out.arrived when the active order completes this tick; the caller then ends its order.
static func step(profile: MovementProfile, state: State, targets: Targets, delta: float, out: Output) -> void:
	var planar_velocity := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var speed := planar_velocity.length()
	var to_destination := targets.destination - state.position
	to_destination.y = 0.0
	var distance := to_destination.length()
	var thruster_limit := profile.thruster_strength / profile.mass
	var sternward_limit := sternward_limit_of(profile, thruster_limit)
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

	# Turning demand: bounded angular acceleration toward the order's course heading, as a fraction of the
	# rated authority at the actual speed. The turn-rate limit follows the same rudder curve, normalized
	# to its full-speed value, so it is zero at rest.
	var _rudder_multiplier := profile.rudder_curve.sample(clampf(speed / profile.max_speed, 0.0, 1.0))
	var turn_limit := deg_to_rad(profile.turn_authority / profile.mass) * _rudder_multiplier
	var _turn_rate_limit := deg_to_rad(profile.max_turn_rate_at_max_speed) * _rudder_multiplier / profile.rudder_curve.sample(1.0)
	var _target_yaw := targets.course_yaw
	var turn_request := 0.0
	var turn_fraction := 0.0
	if has_order and targets.has_course and turn_limit > 0.0:
		var error := wrapf(_target_yaw - state.yaw, -PI, PI)
		# Braking-distance rule: the fastest rate that can still stop at the target, within the turn-rate
		# limit. It plans with the share the turn would get if planar demand stays at last tick's level
		# (proportional sharing). The |error| / delta term only keeps the wanted rate from stepping past
		# the target in one tick.
		var planned_turn_limit := turn_limit / (1.0 + state.planar_fraction_prev)
		var wanted_rate := signf(error) * minf(minf(sqrt(2.0 * planned_turn_limit * absf(error)), absf(error) / delta), _turn_rate_limit)
		turn_request = (wanted_rate - state.turn_rate) / delta
		turn_fraction = minf(absf(turn_request) / turn_limit, 1.0)
	else:
		state.turn_rate = 0.0

	# Desired velocity: along the steering direction at the speed the thrusters can still stop from, capped. The
	# braking it plans with is what proportional sharing leaves a saturated planar demand beside this
	# tick's turning demand: a_t / (1 + turn fraction).
	# Without retro thrusters, stopping the velocity takes acceleration along its reverse, whose sternward share
	# is (travel direction · bow); the retro rule then allows at most sternward_limit / share. At a standstill
	# the travel direction is the steering direction.
	# The pilot closes the gap to the desired speed through pilot_response_time, so it would trail the ideal
	# braking curve sqrt(2 a d) by a·response time. Subtracting that lag makes the request exactly the planned
	# braking while the ship is on the curve, so braking starts in time to stop at the destination (clamped at
	# zero within a·response time² / 2 of it).
	var _planned_braking := thruster_limit / (1.0 + turn_fraction)
	var travel := Vector3.ZERO
	if speed > 0.0:
		travel = planar_velocity / speed
	elif steer_distance > 0.0:
		travel = steer_direction
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
			var bend_braking := minf(braking, thruster_limit / 2.0)
			var bend_lag := bend_braking * profile.pilot_response_time
			for j in range(targets.bend_from, last_bend):
				var radius := targets.bend_radii[j]
				if radius > 0.0:
					var to_bend := maxf(targets.bend_lengths[j] - targets.bend_s, 0.0)
					var bend_speed := sqrt(bend_braking * radius + 2.0 * bend_braking * to_bend) - bend_lag
					desired_speed = minf(desired_speed, maxf(bend_speed, 0.0))
		desired = steer_direction * desired_speed
	var _desired_speed := desired.length()

	var requested := (desired - planar_velocity) / profile.pilot_response_time
	# The main engine pushes along the bow only, and only when that cannot reduce the current speed
	# (no stern-first component), so it never brakes. It is outside the shared thruster capacity.
	var _main_command := 0.0
	if planar_velocity.dot(bow) >= 0.0:
		_main_command = clampf(requested.dot(bow), 0.0, profile.main_acceleration)

	# Planar demand on the directional thrusters, as a fraction of their rating.
	var thruster_request := requested - bow * _main_command
	var planar_fraction := minf(thruster_request.length() / thruster_limit, 1.0)

	# One shared capacity: when the two fractions exceed it, both are scaled down proportionally.
	var _shared_scale := 1.0
	if planar_fraction + turn_fraction > 1.0:
		_shared_scale = 1.0 / (planar_fraction + turn_fraction)
	var _thruster_command := thruster_request.normalized() * planar_fraction * _shared_scale * thruster_limit
	var _turn_acceleration := signf(turn_request) * turn_fraction * _shared_scale * turn_limit
	# Retro rule on the applied thrust: remove only the sternward excess; the removed capacity is not reallocated.
	var sternward := -_thruster_command.dot(bow)
	if sternward > sternward_limit:
		_thruster_command += bow * (sternward - sternward_limit)

	# The limit can contract faster than the authority can slow the turn; the rate is then clamped to it.
	state.turn_rate = clampf(state.turn_rate + _turn_acceleration * delta, -_turn_rate_limit, _turn_rate_limit)
	state.planar_fraction_prev = planar_fraction
	planar_velocity += (bow * _main_command + _thruster_command) * delta
	state.velocity = planar_velocity.limit_length(profile.max_speed)
	state.yaw += state.turn_rate * delta

	out.arrived = arrived
	out.main_command = _main_command
	out.thruster_command = _thruster_command
	out.target_yaw = _target_yaw
	out.turn_acceleration = _turn_acceleration
	out.rudder_multiplier = _rudder_multiplier
	out.turn_rate_limit = _turn_rate_limit
	out.shared_scale = _shared_scale
	out.desired_speed = _desired_speed
	out.planned_braking = _planned_braking


## Unit planar bow for a yaw (0 = −Z, positive = counter-clockwise seen from above).
static func bow_of(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


## Largest sternward directional-thruster acceleration (m/s²): unlimited with retro thrusters.
static func sternward_limit_of(profile: MovementProfile, thruster_limit: float) -> float:
	if profile.retro_thrusters:
		return INF
	return profile.no_retro_braking_effectiveness * thruster_limit
