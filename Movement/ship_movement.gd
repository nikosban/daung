class_name ShipMovement
extends CharacterBody3D
## Authoritative planar movement for a ship (Movement v3): the only writer of its XZ position, its one
## world-space planar velocity (the built-in velocity) and its yaw. Callers request movement through
## move_to() and stop().
##
## Each physics tick the pilot computes a desired velocity toward the destination that falls with the
## remaining distance (arrival steering) and requests the acceleration that closes the gap to the actual
## velocity within pilot_response_time. The main engine supplies the useful part along the bow; the
## directional thrusters supply the rest. Turning demand is computed first, so the approach speed is planned
## with the braking that sharing will leave. The pilot also steers the hull toward the order's course heading
## (set once by move_to(), toward the destination) with bounded angular acceleration whose authority grows
## with actual speed (zero at rest), and a turn-rate limit that also follows speed (zero at rest). Planar
## and turning demand share the directional thrusters' capacity proportionally. Only applied acceleration
## is integrated; yaw never rotates the velocity, and rotation does not persist without powered turning.
##
## Retro rule (profile.retro_thrusters false): the directional thrusters' acceleration toward the stern (the
## component along -bow) never exceeds no_retro_braking_effectiveness x thruster_strength / mass. It is applied
## after proportional sharing by removing only the excess sternward part (lateral and bow-forward parts are
## untouched, nothing is scaled up). The pilot plans its approach braking with the same limit, projected onto
## the direction of the velocity it must slow (the direction to the destination only at a standstill).

@export var profile: MovementProfile

var _destination := Vector3.ZERO
var _has_order := false
## Course heading of the current order (yaw in radians), set by move_to(); no course for a zero-length order.
var _course_yaw := 0.0
var _has_course := false
## Turn rate in rad/s (per ship); zero whenever powered turning is not requested.
var _turn_rate := 0.0
## Previous tick's planar demand fraction on the directional thrusters (0–1). It measures last tick's actual
## thruster demand, so it carries over order replacement and stop(); it starts at 0 (no demand before the
## first tick). Used only to plan the yaw braking authority.
var _planar_fraction_prev := 0.0
## Last tick's values (read-only debug getters).
var _main_command := 0.0
var _thruster_command := Vector3.ZERO
var _target_yaw := 0.0
var _turn_acceleration := 0.0
var _rudder_multiplier := 0.0
var _turn_rate_limit := 0.0
var _shared_scale := 1.0
var _desired_speed := 0.0
var _planned_braking := 0.0


func _ready() -> void:
	if not _profile_valid():
		push_error("ShipMovement needs a MovementProfile with every value above 0 and a rudder curve above 0 at full speed; the ship will not move.")
		set_physics_process(false)


## Orders the ship to the point, replacing any earlier order. Y is ignored. The current velocity carries over.
func move_to(world_position: Vector3) -> void:
	_destination = Vector3(world_position.x, global_position.y, world_position.z)
	_has_order = true
	var course := _destination - global_position
	course.y = 0.0
	_has_course = course != Vector3.ZERO
	if _has_course:
		_course_yaw = atan2(-course.x, -course.z)


## Ends the order. The ship brakes toward zero velocity with its thrusters; it does not hold position.
func stop() -> void:
	_has_order = false


func has_order() -> bool:
	return _has_order


func get_destination() -> Vector3:
	return _destination


## Heading in degrees of yaw (0 = bow toward −Z, positive = counter-clockwise seen from above).
func get_heading() -> float:
	return rad_to_deg(rotation.y)


## Course heading of the current order in degrees (same convention as get_heading()).
func get_target_heading() -> float:
	return rad_to_deg(_target_yaw)


## Current turn rate in °/s (positive = counter-clockwise).
func get_turn_rate() -> float:
	return rad_to_deg(_turn_rate)


## Last turn-rate limit at the actual speed, in °/s.
func get_turn_rate_limit() -> float:
	return rad_to_deg(_turn_rate_limit)


## Last applied angular acceleration in °/s², after shared-capacity scaling.
func get_turn_acceleration() -> float:
	return rad_to_deg(_turn_acceleration)


## Last rudder multiplier sampled from the rudder curve at the actual speed.
func get_rudder_multiplier() -> float:
	return _rudder_multiplier


## Last shared-capacity scale applied to both thruster and turning demand (1 = not saturated).
func get_shared_scale() -> float:
	return _shared_scale


## Last desired approach speed in m/s.
func get_desired_speed() -> float:
	return _desired_speed


## Last planar braking acceleration the pilot planned its approach with, in m/s²: a_t / (1 + turn fraction),
## further limited by the retro rule when the hull has no retro thrusters.
func get_planned_braking() -> float:
	return _planned_braking


## Last main-engine acceleration along the bow, 0 to main_acceleration, in m/s².
func get_main_command() -> float:
	return _main_command


## Last directional thruster acceleration (world XZ), magnitude up to thruster_strength / mass, in m/s².
func get_thruster_command() -> Vector3:
	return _thruster_command


func _physics_process(delta: float) -> void:
	var planar_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var speed := planar_velocity.length()
	var to_destination := _destination - global_position
	to_destination.y = 0.0
	var distance := to_destination.length()
	var thruster_limit := profile.thruster_strength / profile.mass
	var sternward_limit := _sternward_limit(thruster_limit)
	var bow := -global_basis.z
	bow.y = 0.0
	bow = bow.normalized()

	if _has_order and distance <= profile.arrival_tolerance and speed <= profile.arrival_speed_tolerance:
		_has_order = false

	# Turning demand: bounded angular acceleration toward the order's course heading, as a fraction of the
	# rated authority at the actual speed. The turn-rate limit follows the same rudder curve, normalized
	# to its full-speed value, so it is zero at rest.
	_rudder_multiplier = profile.rudder_curve.sample(clampf(speed / profile.max_speed, 0.0, 1.0))
	var turn_limit := deg_to_rad(profile.turn_authority / profile.mass) * _rudder_multiplier
	_turn_rate_limit = deg_to_rad(profile.max_turn_rate_at_max_speed) * _rudder_multiplier / profile.rudder_curve.sample(1.0)
	_target_yaw = _course_yaw
	var turn_request := 0.0
	var turn_fraction := 0.0
	if _has_order and _has_course and turn_limit > 0.0:
		var error := wrapf(_target_yaw - rotation.y, -PI, PI)
		# Braking-distance rule: the fastest rate that can still stop at the target, within the turn-rate
		# limit. It plans with the share the turn would get if planar demand stays at last tick's level
		# (proportional sharing). The |error| / delta term only keeps the wanted rate from stepping past
		# the target in one tick.
		var planned_turn_limit := turn_limit / (1.0 + _planar_fraction_prev)
		var wanted_rate := signf(error) * minf(minf(sqrt(2.0 * planned_turn_limit * absf(error)), absf(error) / delta), _turn_rate_limit)
		turn_request = (wanted_rate - _turn_rate) / delta
		turn_fraction = minf(absf(turn_request) / turn_limit, 1.0)
	else:
		_turn_rate = 0.0

	# Desired velocity: toward the destination at the speed the thrusters can still stop from, capped. The
	# braking it plans with is what proportional sharing leaves a saturated planar demand beside this
	# tick's turning demand: a_t / (1 + turn fraction).
	# Without retro thrusters, stopping the velocity takes acceleration along its reverse, whose sternward share
	# is (travel direction · bow); the retro rule then allows at most sternward_limit / share. At a standstill
	# the travel direction is the direction to the destination.
	_planned_braking = thruster_limit / (1.0 + turn_fraction)
	var travel := Vector3.ZERO
	if speed > 0.0:
		travel = planar_velocity / speed
	elif distance > 0.0:
		travel = to_destination / distance
	var sternward_share := travel.dot(bow)
	if sternward_share > 0.0:
		_planned_braking = minf(_planned_braking, sternward_limit / sternward_share)
	var desired := Vector3.ZERO
	if _has_order and distance > 0.0:
		desired = to_destination / distance * minf(profile.max_speed, sqrt(2.0 * _planned_braking * distance))
	_desired_speed = desired.length()

	var requested := (desired - planar_velocity) / profile.pilot_response_time
	# The main engine pushes along the bow only, and only when that cannot reduce the current speed
	# (no stern-first component), so it never brakes. It is outside the shared thruster capacity.
	_main_command = 0.0
	if planar_velocity.dot(bow) >= 0.0:
		_main_command = clampf(requested.dot(bow), 0.0, profile.main_acceleration)

	# Planar demand on the directional thrusters, as a fraction of their rating.
	var thruster_request := requested - bow * _main_command
	var planar_fraction := minf(thruster_request.length() / thruster_limit, 1.0)

	# One shared capacity: when the two fractions exceed it, both are scaled down proportionally.
	_shared_scale = 1.0
	if planar_fraction + turn_fraction > 1.0:
		_shared_scale = 1.0 / (planar_fraction + turn_fraction)
	_thruster_command = thruster_request.normalized() * planar_fraction * _shared_scale * thruster_limit
	_turn_acceleration = signf(turn_request) * turn_fraction * _shared_scale * turn_limit
	# Retro rule on the applied thrust: remove only the sternward excess; the removed capacity is not reallocated.
	var sternward := -_thruster_command.dot(bow)
	if sternward > sternward_limit:
		_thruster_command += bow * (sternward - sternward_limit)

	# The limit can contract faster than the authority can slow the turn; the rate is then clamped to it.
	_turn_rate = clampf(_turn_rate + _turn_acceleration * delta, -_turn_rate_limit, _turn_rate_limit)
	_planar_fraction_prev = planar_fraction
	planar_velocity += (bow * _main_command + _thruster_command) * delta
	velocity = planar_velocity.limit_length(profile.max_speed)
	rotation.y += _turn_rate * delta
	move_and_slide()


func _profile_valid() -> bool:
	return profile != null and profile.mass > 0.0 and profile.main_acceleration > 0.0 \
		and profile.thruster_strength > 0.0 and profile.max_speed > 0.0 and profile.pilot_response_time > 0.0 \
		and profile.arrival_tolerance > 0.0 and profile.arrival_speed_tolerance > 0.0 \
		and profile.turn_authority > 0.0 and profile.max_turn_rate_at_max_speed > 0.0 \
		and profile.no_retro_braking_effectiveness > 0.0 and profile.rudder_curve != null and profile.rudder_curve.sample(1.0) > 0.0


## Largest sternward directional-thruster acceleration (m/s²): unlimited with retro thrusters.
func _sternward_limit(thruster_limit: float) -> float:
	if profile.retro_thrusters:
		return INF
	return profile.no_retro_braking_effectiveness * thruster_limit
