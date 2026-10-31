class_name MovementController
extends CharacterBody3D

## Single movement authority for one ship (see ARCHITECTURE.md, Movement).
## Other systems call move_to() / stop() and read state through the getters;
## nothing else writes this body's transform or velocity.

## Emitted once when the active order arrives.
signal order_completed
## Emitted once when the active order's route is unreachable (static
## navigation, Task 1d). The direct route used before 1d always succeeds.
signal order_failed

enum State { IDLE, MOVING, BLOCKED, ARRIVED }

@export var profile: MovementProfile

var _state := State.IDLE
var _destination := Vector3.ZERO
var _route := PackedVector3Array()
var _desired_direction := Vector3.ZERO


func _ready() -> void:
	assert(profile != null, "MovementController needs a MovementProfile.")


## Replaces any active order with a new destination on the XZ plane.
func move_to(world_position: Vector3) -> void:
	_destination = Vector3(world_position.x, global_position.y, world_position.z)
	_route = _request_route(_destination)
	_state = State.MOVING


## Cancels the active order. The ship brakes to rest; no event is emitted.
func stop() -> void:
	_route = PackedVector3Array()
	_desired_direction = Vector3.ZERO
	_state = State.IDLE


func get_state() -> State:
	return _state


func get_destination() -> Vector3:
	return _destination


func get_desired_direction() -> Vector3:
	return _desired_direction


func _physics_process(delta: float) -> void:
	var has_order := _state == State.MOVING
	if not has_order and velocity.is_zero_approx():
		velocity = Vector3.ZERO
		return

	# No active order: zero request, so locomotion brakes to rest.
	var requested := Vector3.ZERO
	if has_order:
		requested = _limit_to_hull(_follow_route())
		_turn_toward(_desired_direction, delta)

	var rate := profile.acceleration if requested.length() > velocity.length() else profile.braking
	velocity = velocity.move_toward(requested, rate * delta)

	# Single translation commit. Task 1c replaces this with move_and_collide().
	global_position += velocity * delta

	if has_order:
		_check_arrival()


## Route provider seam. Direct route until Task 1d adds static navigation.
func _request_route(goal: Vector3) -> PackedVector3Array:
	return PackedVector3Array([goal])


## Route follower: preferred world velocity toward the route's end, slowing
## so the ship can brake to rest at the goal.
func _follow_route() -> Vector3:
	var to_goal := _route[_route.size() - 1] - global_position
	to_goal.y = 0.0
	var distance := to_goal.length()
	if is_zero_approx(distance):
		return Vector3.ZERO
	_desired_direction = to_goal / distance
	var speed := minf(profile.max_forward_speed, sqrt(2.0 * profile.braking * distance))
	return _desired_direction * speed


## Limits the requested velocity to the hull's current local axes. Actual
## velocity is never clamped, so a yaw change cannot snap speed.
func _limit_to_hull(requested: Vector3) -> Vector3:
	var forward := -global_basis.z
	var right := global_basis.x
	# No commanded reverse: a target behind is reached by turning and sliding.
	var forward_speed := clampf(requested.dot(forward), 0.0, profile.max_forward_speed)
	var lateral_speed := clampf(requested.dot(right), -profile.max_lateral_speed, profile.max_lateral_speed)
	return forward * forward_speed + right * lateral_speed


func _turn_toward(direction: Vector3, delta: float) -> void:
	if direction.is_zero_approx():
		return
	var target_yaw := atan2(-direction.x, -direction.z)
	rotation.y = rotate_toward(rotation.y, target_yaw, deg_to_rad(profile.yaw_rate) * delta)


## Arrives only when the ship is within tolerance and its predicted rest
## point under braking is also within tolerance.
func _check_arrival() -> void:
	var offset := _destination - global_position
	offset.y = 0.0
	var tolerance := profile.arrival_tolerance
	if offset.length() > tolerance:
		return
	var stopping_travel := velocity * (velocity.length() / (2.0 * profile.braking))
	if (offset - stopping_travel).length() > tolerance:
		return
	_route = PackedVector3Array()
	_desired_direction = Vector3.ZERO
	_state = State.ARRIVED
	order_completed.emit()
