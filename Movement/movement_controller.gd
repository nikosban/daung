class_name MovementController
extends CharacterBody3D

## Single movement authority for one ship (see ARCHITECTURE.md, Movement).
## Other systems call move_to() / stop() and read state through the getters;
## nothing else writes this body's transform or velocity.

## Emitted once when the active order arrives.
signal order_completed
## Emitted once when the active order's destination is unreachable for this
## ship's clearance on the static navigation map.
signal order_failed

enum State { IDLE, MOVING, BLOCKED, ARRIVED }

@export var profile: MovementProfile
## Clearance class for static routes.
@export var clearance: NavigationClearance
## The scene's static navigation. Required unless direct_route is set.
@export var navigation: StaticNavigation
## Only for scenes that intentionally have no navigation (the 1b/1c checks):
## route straight to the goal. Collision still applies.
@export var direct_route := false

var _state := State.IDLE
var _destination := Vector3.ZERO
var _route := PackedVector3Array()
var _waypoint := 0
var _route_pending := false
var _desired_direction := Vector3.ZERO


func _ready() -> void:
	assert(profile != null, "MovementController needs a MovementProfile.")
	if not direct_route and (navigation == null or clearance == null):
		push_error("%s needs a StaticNavigation and a NavigationClearance, or direct_route." % name)


## Replaces any active order with a new destination on the XZ plane. The old
## route and any pending route request are discarded.
func move_to(world_position: Vector3) -> void:
	_destination = Vector3(world_position.x, global_position.y, world_position.z)
	_route = PackedVector3Array()
	_waypoint = 0
	_route_pending = true
	_state = State.MOVING
	_request_route()


## Cancels the active order. The ship brakes to rest; no event is emitted.
func stop() -> void:
	_route = PackedVector3Array()
	_route_pending = false
	_desired_direction = Vector3.ZERO
	_state = State.IDLE


func get_state() -> State:
	return _state


func get_destination() -> Vector3:
	return _destination


func get_desired_direction() -> Vector3:
	return _desired_direction


func get_route() -> PackedVector3Array:
	return _route


func get_waypoint_index() -> int:
	return _waypoint


func _physics_process(delta: float) -> void:
	if _route_pending:
		_request_route()
	var has_order := _state == State.MOVING or _state == State.BLOCKED
	if not has_order and velocity.is_zero_approx():
		velocity = Vector3.ZERO
		return

	# No active order, or its route is still pending: zero request, so
	# locomotion brakes to rest.
	var following := has_order and not _route_pending
	var requested := Vector3.ZERO
	if following:
		requested = _limit_to_hull(_follow_route())
		_turn_toward(_desired_direction, delta)

	var rate := profile.acceleration if requested.length() > velocity.length() else profile.braking
	velocity = velocity.move_toward(requested, rate * delta)

	# Single translation commit: the engine moves the body as far as collision
	# allows. Nothing writes the position afterwards.
	var start := global_position
	var collision := move_and_collide(velocity * delta)

	# Reconcile from actual travel, never from the intended motion.
	var travel := global_position - start
	travel.y = 0.0
	velocity = travel / delta

	if not following:
		return
	# Collision takes precedence over arrival: a blocked tick never completes
	# the order. The next tick retries with the same order. A contact enters
	# Blocked; only real progress leaves it, because engine contact recovery
	# lets a pressed ship creep a margin without reporting a collision.
	var slow := velocity.length() < profile.blocked_speed_tolerance
	if slow and (collision != null or _state == State.BLOCKED):
		_state = State.BLOCKED
		return
	_state = State.MOVING
	_check_arrival()


## Requests the route for the active order once static navigation is ready.
## Until then the request stays pending; no pathfinding runs per tick after.
func _request_route() -> void:
	if direct_route:
		_route = PackedVector3Array([_destination])
		_route_pending = false
		return
	# Misconfigured ships (reported in _ready) never route around anything.
	if navigation == null or not navigation.is_ready(clearance):
		return
	_route_pending = false
	_route = navigation.find_route(clearance, global_position, _destination, profile.arrival_tolerance)
	if _route.is_empty():
		_desired_direction = Vector3.ZERO
		_state = State.IDLE
		order_failed.emit()


## Route follower: owns waypoint progress (planar, from actual position) and
## returns preferred world velocity toward the current waypoint, slowing only
## so the ship can brake to rest at the goal.
func _follow_route() -> Vector3:
	var here := _planar(global_position)
	var last := _route.size() - 1
	while _waypoint < last and here.distance_to(_planar(_route[_waypoint])) <= profile.waypoint_tolerance:
		_waypoint += 1
	var to_waypoint := _planar(_route[_waypoint]) - here
	if to_waypoint.is_zero_approx():
		return Vector3.ZERO
	var remaining := to_waypoint.length()
	for i in range(_waypoint, last):
		remaining += _planar(_route[i]).distance_to(_planar(_route[i + 1]))
	_desired_direction = to_waypoint.normalized()
	var speed := minf(profile.max_forward_speed, sqrt(2.0 * profile.braking * remaining))
	return _desired_direction * speed


func _planar(point: Vector3) -> Vector3:
	return Vector3(point.x, 0.0, point.z)


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


## Arrives only when the ship is within tolerance, nothing obstructs the rest
## of the way to the goal, and its predicted rest point under braking is also
## within tolerance.
func _check_arrival() -> void:
	var offset := _destination - global_position
	offset.y = 0.0
	var tolerance := profile.arrival_tolerance
	if offset.length() > tolerance:
		return
	# Query only (moves nothing): a contact short of the goal is Blocked, not
	# arrived, even on a tick where the commit reported no collision.
	if test_move(global_transform, offset):
		_state = State.BLOCKED
		return
	var stopping_travel := velocity * (velocity.length() / (2.0 * profile.braking))
	if (offset - stopping_travel).length() > tolerance:
		return
	_route = PackedVector3Array()
	_desired_direction = Vector3.ZERO
	_state = State.ARRIVED
	order_completed.emit()
