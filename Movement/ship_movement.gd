class_name ShipMovement
extends CharacterBody3D
## Authoritative planar movement for a ship (Movement v3): the only writer of its XZ position, its one
## world-space planar velocity (the built-in velocity) and its yaw. Callers request movement through
## move_to() and stop().
##
## Each physics tick the pilot computes a desired velocity toward the destination that falls with the
## remaining distance (arrival steering) and requests the acceleration that closes the gap to the actual
## velocity within pilot_response_time. The main engine supplies the useful part along the bow; the
## directional thrusters supply the rest from one vector budget. Only applied acceleration is integrated.
## The heading is held fixed in this slice (yaw is never written).

@export var profile: MovementProfile

var _destination := Vector3.ZERO
var _has_order := false
## Last tick's commands, in m/s² (read-only debug getters).
var _main_command := 0.0
var _thruster_command := Vector3.ZERO


func _ready() -> void:
	if not _profile_valid():
		push_error("ShipMovement needs a MovementProfile with every value above 0; the ship will not move.")
		set_physics_process(false)


## Orders the ship to the point, replacing any earlier order. Y is ignored. The current velocity carries over.
func move_to(world_position: Vector3) -> void:
	_destination = Vector3(world_position.x, global_position.y, world_position.z)
	_has_order = true


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


## Last main-engine acceleration along the bow, 0 to main_acceleration, in m/s².
func get_main_command() -> float:
	return _main_command


## Last directional thruster acceleration (world XZ), magnitude up to thruster_strength / mass, in m/s².
func get_thruster_command() -> Vector3:
	return _thruster_command


func _physics_process(delta: float) -> void:
	var planar_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var to_destination := _destination - global_position
	to_destination.y = 0.0
	var distance := to_destination.length()
	var thruster_limit := profile.thruster_strength / profile.mass

	if _has_order and distance <= profile.arrival_tolerance and planar_velocity.length() <= profile.arrival_speed_tolerance:
		_has_order = false

	# Desired velocity: toward the destination at the speed the thrusters can still stop from, capped.
	var desired := Vector3.ZERO
	if _has_order and distance > 0.0:
		desired = to_destination / distance * minf(profile.max_speed, sqrt(2.0 * thruster_limit * distance))

	var requested := (desired - planar_velocity) / profile.pilot_response_time
	var bow := -global_basis.z
	bow.y = 0.0
	bow = bow.normalized()
	# The main engine pushes along the bow only, and only when that cannot reduce the current speed
	# (no stern-first component), so it never brakes.
	_main_command = 0.0
	if planar_velocity.dot(bow) >= 0.0:
		_main_command = clampf(requested.dot(bow), 0.0, profile.main_acceleration)
	_thruster_command = (requested - bow * _main_command).limit_length(thruster_limit)

	planar_velocity += (bow * _main_command + _thruster_command) * delta
	velocity = planar_velocity.limit_length(profile.max_speed)
	move_and_slide()


func _profile_valid() -> bool:
	return profile != null and profile.mass > 0.0 and profile.main_acceleration > 0.0 \
		and profile.thruster_strength > 0.0 and profile.max_speed > 0.0 and profile.pilot_response_time > 0.0 \
		and profile.arrival_tolerance > 0.0 and profile.arrival_speed_tolerance > 0.0
