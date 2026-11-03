class_name ShipMovement
extends CharacterBody3D
## Authoritative planar movement for a ship. The only writer of its XZ position,
## planar velocity and yaw. Callers request movement through move_to(), append_waypoint() and stop().

@export var profile: MovementProfile

## The route: the anchor (ship position when the route was set), then the requested points; the last
## entry is the final destination. Never empty: while idle it holds only the last final point.
var _route := PackedVector3Array([Vector3.ZERO])
var _has_destination := false
## Multi-point routes only: monotonic arc length of the ship's progress and the segment it lies on.
var _route_progress := 0.0
var _route_segment := 0
## Point currently steered at, and its route segment. Equals the final destination unless the
## lookahead on a multi-point route is still ahead of it. Derived; refreshed every steering tick.
var _guidance_target := Vector3.ZERO
var _guidance_segment := 0
## Near-opposite order pending: brake to rest, then start the same order from rest.
var _awaiting_rest := false
## Signed degrees from travel direction to goal at order receipt, or to the next leg when guidance
## crosses a route vertex (positive = left turn); 0 unless a moving turn.
var _turn_deflection := 0.0


## Replaces any route with a single destination. Y is ignored; movement stays on the ship's plane.
## Classified once against the actual travel velocity: near-opposite orders brake to rest first.
## Orders inside arrival tolerance count as arrivals, never as reversals.
func move_to(world_position: Vector3) -> void:
	var destination := Vector3(world_position.x, global_position.y, world_position.z)
	_route = PackedVector3Array([global_position, destination])
	_route_progress = 0.0
	_route_segment = 0
	_guidance_target = destination
	_guidance_segment = 0
	_has_destination = true
	_awaiting_rest = false
	_turn_deflection = 0.0
	var planar_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var offset := destination - global_position
	offset.y = 0.0
	if not planar_velocity.is_zero_approx() and offset.length() > profile.arrival_tolerance:
		var angle := rad_to_deg(planar_velocity.angle_to(offset))
		_awaiting_rest = angle >= profile.near_opposite_angle or is_equal_approx(angle, profile.near_opposite_angle)
		if not _awaiting_rest:
			_turn_deflection = rad_to_deg(planar_velocity.signed_angle_to(offset, Vector3.UP))


## Appends a point to the end of the active route; the previous final point becomes intermediate.
## Never re-classifies, restarts or brakes the journey. Without an active order it acts as move_to().
func append_waypoint(world_position: Vector3) -> void:
	if not _has_destination:
		move_to(world_position)
		return
	var point := Vector3(world_position.x, global_position.y, world_position.z)
	if _route.size() == 2:
		# Re-anchor at the ship so the aim at the old final point stays continuous.
		_route = PackedVector3Array([global_position, _route[1], point])
		_route_progress = 0.0
		_route_segment = 0
		_guidance_segment = 0
	else:
		_route.append(point)


## Clears the route, including pending points. The ship brakes to rest and stops turning.
func stop() -> void:
	_end_route()


func has_destination() -> bool:
	return _has_destination


## The final requested point: the active route's end, or the last one once idle.
func get_destination() -> Vector3:
	return _route[-1]


## The point the ship currently steers at. Equals get_destination() for single destinations and while idle.
func get_guidance_target() -> Vector3:
	return _guidance_target


## Initial course change of the current order or route bend: signed degrees from the actual travel
## direction to the goal, or to the next leg when guidance crosses a route vertex (positive = left
## turn). 0 for orders from rest, near-opposite orders, orders inside arrival tolerance, and once the
## order ends (arrival or stop()).
func get_turn_deflection() -> float:
	return _turn_deflection


func _physics_process(delta: float) -> void:
	var planar_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var speed := planar_velocity.length()
	var direction := planar_velocity / speed if speed > 0.0 else Vector3.ZERO
	var remaining := 0.0
	if _has_destination and not _awaiting_rest and _route.size() > 2:
		remaining = _update_route_guidance(direction)
	var offset := _guidance_target - global_position
	offset.y = 0.0
	var distance := offset.length()
	var at_final := _guidance_target == get_destination()

	# Arrival: only the final destination completes the order, once guidance has reached it. The ship
	# then brakes to rest along its current travel and may coast slightly past, without turning back.
	if _has_destination and not _awaiting_rest and at_final and distance <= profile.arrival_tolerance:
		_end_route()

	var steering := _has_destination and not _awaiting_rest and distance > 0.0
	var desired_speed := 0.0
	if steering:
		var goal_direction := offset / distance
		if planar_velocity.is_zero_approx():
			direction = goal_direction
		else:
			var max_turn := deg_to_rad(profile.travel_turn_rate) * delta
			direction = direction.rotated(Vector3.UP, clampf(direction.signed_angle_to(goal_direction, Vector3.UP), -max_turn, max_turn))
		# Cap speed so the ship can still brake to rest at the final destination.
		desired_speed = minf(profile.max_speed, sqrt(2.0 * profile.braking * (distance + remaining)))
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
		if at_final and distance <= profile.arrival_tolerance:
			_end_route()

	if steering:
		var target_yaw := atan2(-offset.x, -offset.z)
		rotation.y = rotate_toward(rotation.y, target_yaw, deg_to_rad(profile.turn_rate) * delta)

	var commanded := velocity
	move_and_slide()

	# Blocked: moving into a static obstacle ends the whole order with a hard stop. A resting contact
	# does not block an order away from it. Other bodies, including moving AnimatableBody3D, keep the
	# engine's default sliding; their collision behavior is undecided.
	if _has_destination:
		for i in get_slide_collision_count():
			var collision := get_slide_collision(i)
			var collider := collision.get_collider()
			if collider is StaticBody3D and not collider is AnimatableBody3D and commanded.dot(collision.get_normal()) < 0.0:
				_end_route()
				velocity = Vector3.ZERO
				break


## Multi-point routes: advances progress and places the guidance point route_lookahead_distance
## further along the route, clamped to the final destination. Returns the route length left beyond
## the guidance point. Intermediate points are never arrival targets.
func _update_route_guidance(direction: Vector3) -> float:
	var lookahead := profile.route_lookahead_distance
	var segment_start := 0.0
	for i in _route_segment:
		segment_start += _route[i].distance_to(_route[i + 1])

	# Progress: the nearest point on the segments starting within lookahead of it; never backward.
	var best_distance := INF
	var best_progress := _route_progress
	var best_segment := _route_segment
	var arc := segment_start
	for i in range(_route_segment, _route.size() - 1):
		if arc > _route_progress + lookahead:
			break
		var closest := Geometry3D.get_closest_point_to_segment(global_position, _route[i], _route[i + 1])
		var closest_distance := global_position.distance_to(closest)
		if closest_distance < best_distance:
			best_distance = closest_distance
			best_segment = i
			best_progress = arc + _route[i].distance_to(closest)
		arc += _route[i].distance_to(_route[i + 1])
	if best_progress > _route_progress:
		for i in range(_route_segment, best_segment):
			segment_start += _route[i].distance_to(_route[i + 1])
		_route_progress = best_progress
		_route_segment = best_segment

	# Guidance point; zero-length segments are passed over.
	var target_arc := _route_progress + lookahead
	var guidance := _route[-1]
	var guidance_segment := _route.size() - 2
	var remaining := 0.0
	arc = segment_start
	for i in range(_route_segment, _route.size() - 1):
		var length := _route[i].distance_to(_route[i + 1])
		if arc + length > target_arc:
			guidance = _route[i].lerp(_route[i + 1], (target_arc - arc) / length)
			guidance_segment = i
			remaining = arc + length - target_arc
			for j in range(i + 1, _route.size() - 1):
				remaining += _route[j].distance_to(_route[j + 1])
			break
		arc += length

	# A bend: guidance crossed onto a later leg, so its deflection replaces the previous one.
	if guidance_segment > _guidance_segment:
		var leg := _route[guidance_segment + 1] - _route[guidance_segment]
		leg.y = 0.0
		if not leg.is_zero_approx() and not direction.is_zero_approx():
			_turn_deflection = rad_to_deg(direction.signed_angle_to(leg, Vector3.UP))
		_guidance_segment = guidance_segment
	_guidance_target = guidance
	return remaining


## Ends the order: keeps only the last final point, so the route and its getters stay defined.
func _end_route() -> void:
	_route = PackedVector3Array([_route[-1]])
	_route_progress = 0.0
	_route_segment = 0
	_guidance_target = _route[0]
	_guidance_segment = 0
	_has_destination = false
	_awaiting_rest = false
	_turn_deflection = 0.0
