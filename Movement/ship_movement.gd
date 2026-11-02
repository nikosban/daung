class_name ShipMovement
extends CharacterBody3D
## Authoritative planar movement for a ship. The only writer of its XZ position,
## planar velocity and yaw. Callers request movement through move_to() and stop().

@export var profile: MovementProfile

var _destination := Vector3.ZERO
var _has_destination := false


## Sets or replaces the destination. Y is ignored; movement stays on the ship's plane.
func move_to(world_position: Vector3) -> void:
	var target := Vector3(world_position.x, global_position.y, world_position.z)
	if global_position.distance_to(target) <= profile.arrival_tolerance:
		return
	_destination = target
	_has_destination = true


## Clears the destination. The ship brakes to rest and stops turning.
func stop() -> void:
	_has_destination = false


func has_destination() -> bool:
	return _has_destination


func get_destination() -> Vector3:
	return _destination


func _physics_process(delta: float) -> void:
	var desired_velocity := Vector3.ZERO
	if _has_destination:
		var offset := _destination - global_position
		offset.y = 0.0
		var distance := offset.length()
		if distance <= profile.arrival_tolerance:
			_has_destination = false
		else:
			# Cap speed so the ship can still brake to rest at the destination.
			var desired_speed := minf(profile.max_speed, sqrt(2.0 * profile.braking * distance))
			desired_velocity = offset / distance * desired_speed

	var planar_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var rate := profile.acceleration if desired_velocity.length() > planar_velocity.length() else profile.braking
	velocity = planar_velocity.move_toward(desired_velocity, rate * delta)

	if _has_destination:
		var to_destination := _destination - global_position
		var target_yaw := atan2(-to_destination.x, -to_destination.z)
		rotation.y = rotate_toward(rotation.y, target_yaw, deg_to_rad(profile.turn_rate) * delta)

	move_and_slide()
