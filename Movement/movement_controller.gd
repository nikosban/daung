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
# Facing reference for the hull, separate from the translation direction.
var _heading := Vector3.ZERO
# Per-order yaw lead; translation and collision keep running while it expires.
var _rotation_lead_remaining := 0.0
# Route speed plan, built once per route: arc length at each route point, and
# arc ranges [start, end] where speed is held at or below a planned speed.
var _arc := PackedFloat32Array()
var _slow_start := PackedFloat32Array()
var _slow_end := PackedFloat32Array()
var _slow_speed := PackedFloat32Array()


func _ready() -> void:
	assert(profile != null, "MovementController needs a MovementProfile.")
	if not direct_route and (navigation == null or clearance == null):
		push_error("%s needs a StaticNavigation and a NavigationClearance, or direct_route." % name)
	if profile.max_reverse_speed >= profile.max_forward_speed:
		push_error("%s: max_reverse_speed must stay below max_forward_speed." % name)


## Replaces any active order with a new destination on the XZ plane. The old
## route and any pending route request are discarded. Actual planar speed at
## receipt selects the profile's from-rest or already-moving yaw lead.
func move_to(world_position: Vector3) -> void:
	var speed := _planar(velocity).length()
	_rotation_lead_remaining = profile.rotation_lead_from_rest if speed <= profile.blocked_speed_tolerance else profile.rotation_lead_while_moving
	_destination = Vector3(world_position.x, global_position.y, world_position.z)
	_set_route(PackedVector3Array())
	_route_pending = true
	_state = State.MOVING
	_request_route()


## Cancels the active order. The ship brakes to rest; no event is emitted.
func stop() -> void:
	_rotation_lead_remaining = 0.0
	_set_route(PackedVector3Array())
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
		# Only following ticks consume the lead, even with no physical progress.
		# No catch-up turn on expiry, and no restart at route corners.
		if _rotation_lead_remaining > 0.0:
			_rotation_lead_remaining = maxf(0.0, _rotation_lead_remaining - delta)
		else:
			_turn_toward(_heading, delta)

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
		_set_route(PackedVector3Array([_destination]))
		_route_pending = false
		return
	# Misconfigured ships (reported in _ready) never route around anything.
	if navigation == null or not navigation.is_ready(clearance):
		return
	_route_pending = false
	_set_route(navigation.find_route(clearance, global_position, _destination))
	if _route.is_empty():
		_rotation_lead_remaining = 0.0
		_desired_direction = Vector3.ZERO
		_state = State.IDLE
		order_failed.emit()


## Replaces the route and rebuilds its speed plan; an empty route clears both.
func _set_route(route: PackedVector3Array) -> void:
	_route = route
	_waypoint = 0
	_arc.resize(route.size())
	for i in route.size():
		_arc[i] = 0.0 if i == 0 else _arc[i - 1] + _planar(route[i - 1]).distance_to(_planar(route[i]))
	_plan_speed()


## Route follower (pure pursuit): owns segment progress along the route
## (planar, from actual position) and returns preferred world velocity.
## _waypoint is the end of the current segment; it advances only once the ship
## has passed that corner and never goes back. The ship translates toward the
## point a look-ahead distance further along the route from its projection on
## the current segment, which also corrects cross-track drift. The hull faces
## the route's direction across that same look-ahead instead, so correcting a
## small drift slides the ship rather than turning it.
func _follow_route() -> Vector3:
	var here := _planar(global_position)
	var last := _route.size() - 1
	# route[0] is the path's start point; the first segment ends at route[1].
	_waypoint = maxi(_waypoint, mini(1, last))
	while _waypoint < last:
		var segment_start := _planar(_route[_waypoint - 1])
		var segment_end := _planar(_route[_waypoint])
		var along := (here - segment_start).dot((segment_end - segment_start).normalized())
		if along < segment_start.distance_to(segment_end):
			break
		_waypoint += 1
	var aim := _planar(_route[_waypoint])
	var progress := _arc[_waypoint] - here.distance_to(aim)
	var heading := Vector3.ZERO
	if _waypoint > 0:
		var start := _planar(_route[_waypoint - 1])
		var along := (here - start).dot((aim - start).normalized())
		progress = _arc[_waypoint - 1] + along
		var projected := clampf(along, 0.0, start.distance_to(aim))
		aim = _point_along_route(projected + _lookahead())
		# Chord across the look-ahead window: the route's average direction
		# there. It turns continuously as the window slides over a corner.
		heading = aim - _point_along_route(projected)
	var to_aim := aim - here
	if to_aim.is_zero_approx():
		return Vector3.ZERO
	_desired_direction = to_aim.normalized()
	_heading = heading.normalized() if not heading.is_zero_approx() else _desired_direction
	# Braking to the goal uses the route distance left, but never less than the
	# actual distance to the goal: a ship carried past the route's end, or off
	# to its side, still has a distance to cover and is never asked to stop
	# short of it.
	var goal_distance := maxf(_arc[last] - progress, here.distance_to(_planar(_route[last])))
	var speed := _route_speed(progress, goal_distance)
	# Routes that bend: never ask for more than the hull, as currently turned,
	# can thrust along the desired direction. Direct and single-segment orders
	# move exactly as in open space.
	if _route.size() > 2:
		speed = minf(speed, _hull_speed())
	return _desired_direction * speed


## Look-ahead distance along the route. A longer, speed-scaled look-ahead
## (the turning radius) was measured to cut obstacle corners to contact, so it
## stays at waypoint_tolerance.
func _lookahead() -> float:
	return profile.waypoint_tolerance


## The route point the given distance past the start of the current segment,
## continuing across later segments; the goal if the route ends first.
func _point_along_route(distance: float) -> Vector3:
	for i in range(_waypoint, _route.size()):
		var start := _planar(_route[i - 1])
		var end := _planar(_route[i])
		var length := start.distance_to(end)
		if distance <= length:
			return start + (end - start).normalized() * distance
		distance -= length
	return _planar(_route[_route.size() - 1])


## Highest speed at which the hull, as currently turned, can thrust along the
## desired direction without its sideways share exceeding max_lateral_speed.
## Behind the hull, its backward share must also fit max_reverse_speed, but the
## cap never drops below max_lateral_speed: _limit_to_hull then trims any excess
## backward share and keeps the sideways share, so a ship that cannot reverse
## still slides sideways while it turns.
func _hull_speed() -> float:
	var heading := _planar(-global_basis.z).normalized()
	var sin_angle := absf(heading.cross(_desired_direction).y)
	var cos_angle := heading.dot(_desired_direction)
	var speed := profile.max_forward_speed
	if not is_zero_approx(sin_angle):
		speed = minf(speed, profile.max_lateral_speed / sin_angle)
	if cos_angle < 0.0:
		speed = minf(speed, maxf(profile.max_lateral_speed, profile.max_reverse_speed / -cos_angle))
	return speed


## Planned speed at the given arc-length progress: the lowest of the top speed,
## braking to rest over the given distance to the goal, and, for each slow
## section, braking into it, holding its speed inside it and accelerating out
## of it. This is the forward-backward pass over the plan, evaluated where the
## ship is.
func _route_speed(progress: float, goal_distance: float) -> float:
	var speed := minf(profile.max_forward_speed, sqrt(2.0 * profile.braking * goal_distance))
	for k in _slow_speed.size():
		var held := _slow_speed[k]
		if progress < _slow_start[k]:
			speed = minf(speed, sqrt(held * held + 2.0 * profile.braking * (_slow_start[k] - progress)))
		elif progress <= _slow_end[k]:
			speed = minf(speed, held)
		else:
			speed = minf(speed, sqrt(held * held + 2.0 * profile.acceleration * (progress - _slow_end[k])))
	return speed


## Builds the route's slow sections. Each bend becomes one turn; bends whose
## turns overlap are one physical turn and merge, so passing an intermediate
## route point never releases its speed. Between turns (and before the goal),
## a stretch too short for a speed-up that reaches top speed (see
## _peak_speed) holds a steady speed instead of speeding up only to brake
## again.
func _plan_speed() -> void:
	_slow_start.clear()
	_slow_end.clear()
	_slow_speed.clear()
	if _route.is_empty():
		return
	# Each turn: [first bend arc, last bend arc, total heading change].
	var turns: Array[Vector3] = []
	for i in range(1, _route.size() - 1):
		var incoming := _planar(_route[i]) - _planar(_route[i - 1])
		var outgoing := _planar(_route[i + 1]) - _planar(_route[i])
		var angle := incoming.angle_to(outgoing)
		if not is_zero_approx(angle):
			turns.append(Vector3(_arc[i], _arc[i], angle))
	var i := 0
	while i < turns.size() - 1:
		if _turn_section(turns[i]).y >= _turn_section(turns[i + 1]).x:
			turns[i] = Vector3(turns[i].x, turns[i + 1].y, turns[i].z + turns[i + 1].z)
			turns.remove_at(i + 1)
			i = maxi(i - 1, 0)
		else:
			i += 1
	var goal := _arc[_arc.size() - 1]
	for k in turns.size():
		var section := _turn_section(turns[k])
		_add_slow_section(section)
		var next := _turn_section(turns[k + 1]) if k + 1 < turns.size() else Vector3(goal, goal, 0.0)
		var gap := next.x - section.y
		if gap > 0.0 and _peak_speed(section.z, next.z, gap) < profile.max_forward_speed:
			_add_slow_section(Vector3(section.y, next.x, maxf(section.z, next.z)))


func _add_slow_section(section: Vector3) -> void:
	_slow_start.append(section.x)
	_slow_end.append(section.y)
	_slow_speed.append(section.z)


## Slow section [start, end, speed] for a turn [first bend, last bend, angle].
## The hull's facing reference starts turning one look-ahead before the first
## bend; the section lasts until the hull, at yaw_rate, has turned through the
## whole angle, and at least past the last bend.
func _turn_section(turn: Vector3) -> Vector3:
	var speed := _corner_speed(turn.z, turn.y - turn.x)
	var start := turn.x - _lookahead()
	var end := maxf(turn.y, start + speed * turn.z / deg_to_rad(profile.yaw_rate))
	return Vector3(start, end, speed)


## Speed for a turn through the given angle whose bends span the given arc
## length. Two limits:
## - outward swing: the velocity change across the turn, absorbed at the
##   acceleration and braking rates, stays within corner_drift_limit;
## - hull: the facing reference turns through the angle over the look-ahead
##   plus the span; the hull lags it at yaw_rate, and the sideways thrust must
##   cover that lag (v·sin(lag) within max_lateral_speed).
func _corner_speed(angle: float, span: float) -> float:
	var rate := minf(profile.acceleration, profile.braking)
	var change := 2.0 * sin(minf(angle, PI) / 2.0)
	var speed := minf(profile.max_forward_speed, sqrt(2.0 * rate * profile.corner_drift_limit) / change)
	var yaw := deg_to_rad(profile.yaw_rate)
	var lagged := func(v: float) -> float:
		return v * sin(clampf(angle - yaw * (_lookahead() + span) / v, 0.0, PI / 2.0))
	if lagged.call(speed) <= profile.max_lateral_speed:
		return speed
	# Sideways need grows with speed, so bisect for the highest speed that fits.
	var low := 0.0
	var high := speed
	for step in 24:
		var mid := (low + high) / 2.0
		if lagged.call(mid) <= profile.max_lateral_speed:
			low = mid
		else:
			high = mid
	return low


## Peak speed reachable over a gap that starts at one speed and must end at
## another, speeding up and slowing down again at the gentler of the
## acceleration and braking rates. Planning the slow-down at that rate means a
## speed-up is kept only when the ship can stay at top speed for a while
## before braking, not peak and brake at once.
func _peak_speed(from_speed: float, to_speed: float, gap: float) -> float:
	var rate := minf(profile.acceleration, profile.braking)
	return sqrt(rate * gap + (from_speed * from_speed + to_speed * to_speed) / 2.0)


func _planar(point: Vector3) -> Vector3:
	return Vector3(point.x, 0.0, point.z)


## Limits the requested velocity to the hull's current local axes. Actual
## velocity is never clamped, so a yaw change cannot snap speed.
func _limit_to_hull(requested: Vector3) -> Vector3:
	var forward := -global_basis.z
	var right := global_basis.x
	# Bounded reverse: a target behind is reached by backing, sliding and
	# turning after the order's yaw lead; the mix changes as yaw aligns.
	var forward_speed := clampf(requested.dot(forward), -profile.max_reverse_speed, profile.max_forward_speed)
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
	_rotation_lead_remaining = 0.0
	_set_route(PackedVector3Array())
	_desired_direction = Vector3.ZERO
	_state = State.ARRIVED
	order_completed.emit()
