class_name ShipMovement
extends CharacterBody3D
## Authoritative planar movement for a ship. The only writer of its XZ position,
## planar velocity and yaw. Callers request movement through move_to() and stop().

@export var profile: MovementProfile

var _destination := Vector3.ZERO
var _has_destination := false
## Brake to rest, then re-evaluate the same order: set by near-opposite orders and on entering arrival tolerance.
var _awaiting_rest := false


## Sets or replaces the destination. Y is ignored; movement stays on the ship's plane.
## Classified once against the actual travel velocity: near-opposite orders brake to rest first.
func move_to(world_position: Vector3) -> void:
	_destination = Vector3(world_position.x, global_position.y, world_position.z)
	_has_destination = true
	_awaiting_rest = false
	var planar_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var offset := _destination - global_position
	offset.y = 0.0
	if not planar_velocity.is_zero_approx() and not offset.is_zero_approx():
		var angle := rad_to_deg(planar_velocity.angle_to(offset))
		_awaiting_rest = angle >= profile.near_opposite_angle or is_equal_approx(angle, profile.near_opposite_angle)


## Clears the destination. The ship brakes to rest and stops turning.
func stop() -> void:
	_has_destination = false
	_awaiting_rest = false


func has_destination() -> bool:
	return _has_destination


func get_destination() -> Vector3:
	return _destination


func _physics_process(delta: float) -> void:
	var planar_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var speed := planar_velocity.length()
	var direction := planar_velocity / speed if speed > 0.0 else Vector3.ZERO
	var offset := _destination - global_position
	offset.y = 0.0
	var distance := offset.length()

	# An order completes only at rest inside tolerance, so brake first and re-evaluate at rest.
	if _has_destination and not _awaiting_rest and distance <= profile.arrival_tolerance:
		_awaiting_rest = true

	var steering := _has_destination and not _awaiting_rest
	var desired_speed := 0.0
	if steering:
		var goal_direction := offset / distance
		if planar_velocity.is_zero_approx():
			direction = goal_direction
		else:
			var max_turn := deg_to_rad(profile.travel_turn_rate) * delta
			direction = direction.rotated(Vector3.UP, clampf(direction.signed_angle_to(goal_direction, Vector3.UP), -max_turn, max_turn))
		# Cap speed so the ship can still brake to rest at the destination.
		desired_speed = minf(profile.max_speed, sqrt(2.0 * profile.braking * distance))
		# Pure pursuit: keep the turn radius v / ω inside the circle through the goal
		# tangent to travel, R = d / (2 sin θ), so near goals are reached instead of orbited.
		var sin_theta := absf(sin(direction.angle_to(goal_direction)))
		if sin_theta > 0.001:
			desired_speed = minf(desired_speed, deg_to_rad(profile.travel_turn_rate) * distance / (2.0 * sin_theta))

	var rate := profile.acceleration if desired_speed > speed else profile.braking
	speed = move_toward(speed, desired_speed, rate * delta)
	velocity = direction * speed

	if _awaiting_rest and speed == 0.0:
		_awaiting_rest = false
		if distance <= profile.arrival_tolerance:
			_has_destination = false

	if steering:
		var target_yaw := atan2(-offset.x, -offset.z)
		rotation.y = rotate_toward(rotation.y, target_yaw, deg_to_rad(profile.turn_rate) * delta)

	move_and_slide()
