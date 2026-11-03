class_name ShipMovement
extends CharacterBody3D
## Authoritative planar movement for a ship. The only writer of its XZ position,
## planar velocity and yaw. Callers request movement through move_to(), append_waypoint() and stop().

enum _Navigation { SYNCING, UNAVAILABLE, READY }

@export var profile: MovementProfile

## The route: the anchor (ship position when the route was set), then the route points (generated
## detour points and/or requested points); the last entry is the final destination. Never empty: while idle it holds only the last final point.
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
## Latest normal order received before navigation was ready; started once it is.
var _pending_order := Vector3.ZERO
var _has_pending_order := false
## Route index of a generated detour's final point (the requested destination); 0 for manual routes.
var _detour_end := 0


## Replaces any route with an order to the requested point. Y is ignored; movement stays on the
## ship's plane. Navigation plans a detour around static obstacles when one is needed; otherwise the
## order aims directly at the point. Before navigation is ready the latest order waits, replacing any
## earlier waiting order, and starts on the first tick it is. Classified once against the actual travel
## velocity: near-opposite orders brake to rest first. Orders inside arrival tolerance count as
## arrivals, never as reversals.
func move_to(world_position: Vector3) -> void:
	_pending_order = Vector3(world_position.x, global_position.y, world_position.z)
	_has_pending_order = true
	_start_pending_order()


## Appends a point to the end of the active route; the previous final point becomes intermediate.
## Never navigates, re-classifies, restarts or brakes the journey. Without an active order, or while
## a normal order waits for navigation, it replaces that with a direct order to the point.
func append_waypoint(world_position: Vector3) -> void:
	var point := Vector3(world_position.x, global_position.y, world_position.z)
	if not _has_destination or _has_pending_order:
		_has_pending_order = false
		_start_order(PackedVector3Array([global_position, point]), 0)
		return
	if _route.size() == 2:
		# Re-anchor at the ship so the aim at the old final point stays continuous.
		_route = PackedVector3Array([global_position, _route[1], point])
		_route_progress = 0.0
		_route_segment = 0
		_guidance_segment = 0
	else:
		_route.append(point)


## Clears the route, including pending points and any order waiting for navigation. The ship brakes
## to rest and stops turning.
func stop() -> void:
	_has_pending_order = false
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
	if _has_pending_order:
		_start_pending_order()
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
			# Bounded lateral acceleration a = v · ω: the travel direction turns at up to a / v.
			var max_turn := profile.lateral_acceleration / speed * delta
			direction = direction.rotated(Vector3.UP, clampf(direction.signed_angle_to(goal_direction, Vector3.UP), -max_turn, max_turn))
		# Cap speed so the ship can still brake to rest at the final destination.
		desired_speed = minf(profile.max_speed, sqrt(2.0 * profile.braking * (distance + remaining)))
		# Pure pursuit: keep the turn radius v² / a inside the circle through the goal
		# tangent to travel, R = d / (2 sin θ), so near goals are reached instead of orbited.
		var sin_theta := absf(sin(direction.angle_to(goal_direction)))
		if sin_theta > 0.001:
			desired_speed = minf(desired_speed, sqrt(profile.lateral_acceleration * distance / (2.0 * sin_theta)))

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


## Starts the waiting normal order once navigation is ready. A detour is used only when the path
## bends and ends at the requested point; otherwise, or without usable navigation data, the order
## aims directly at the point and the static-contact hard stop remains the fallback.
func _start_pending_order() -> void:
	var navigation := _navigation_state()
	if navigation == _Navigation.SYNCING:
		return
	_has_pending_order = false
	var destination := _pending_order
	var route := PackedVector3Array([global_position, destination])
	if navigation == _Navigation.READY:
		var query := NavigationPathQueryParameters3D.new()
		query.map = get_world_3d().navigation_map
		query.start_position = global_position
		query.target_position = destination
		query.simplify_path = true
		query.simplify_epsilon = profile.path_simplify_epsilon
		var result := NavigationPathQueryResult3D.new()
		NavigationServer3D.query_path(query, result)
		var path := result.path
		var end_offset := destination - (path[-1] if not path.is_empty() else global_position)
		end_offset.y = 0.0
		if path.size() > 2 and end_offset.length() <= profile.arrival_tolerance:
			# Interior points flattened onto the ship's plane; zero-length legs are dropped.
			route = PackedVector3Array([global_position])
			for i in range(1, path.size() - 1):
				var point := Vector3(path[i].x, global_position.y, path[i].z)
				if not point.is_equal_approx(route[-1]) and not point.is_equal_approx(destination):
					route.append(point)
			route.append(destination)
	_start_order(route, route.size() - 1 if route.size() > 2 else 0)


## Navigation readiness for this ship's map. Syncing until the map and every region on it have
## synchronized and a region with data has been merged into the map; unavailable once synchronized
## without any enabled region holding navigation data.
func _navigation_state() -> _Navigation:
	var map := get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return _Navigation.SYNCING
	var has_data := false
	for region in NavigationServer3D.map_get_regions(map):
		if NavigationServer3D.region_get_iteration_id(region) == 0:
			return _Navigation.SYNCING
		if NavigationServer3D.region_get_enabled(region) and NavigationServer3D.region_get_bounds(region).has_surface():
			has_data = true
	if not has_data:
		return _Navigation.UNAVAILABLE
	if not NavigationServer3D.map_get_closest_point_owner(map, global_position).is_valid():
		return _Navigation.SYNCING
	return _Navigation.READY


## Replaces any route with the given one (anchor first, destination last) and classifies the order
## once against the actual travel velocity, using the initial guidance point as the goal.
func _start_order(route: PackedVector3Array, detour_end: int) -> void:
	_route = route
	_route_progress = 0.0
	_route_segment = 0
	_guidance_target = route[-1]
	_guidance_segment = 0
	_detour_end = detour_end
	_has_destination = true
	_awaiting_rest = false
	_turn_deflection = 0.0
	if route.size() > 2:
		_update_route_guidance(Vector3.ZERO)
	var planar_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var to_destination := route[-1] - global_position
	to_destination.y = 0.0
	var offset := _guidance_target - global_position
	offset.y = 0.0
	if not planar_velocity.is_zero_approx() and to_destination.length() > profile.arrival_tolerance:
		var angle := rad_to_deg(planar_velocity.angle_to(offset))
		_awaiting_rest = angle >= profile.near_opposite_angle or is_equal_approx(angle, profile.near_opposite_angle)
		if not _awaiting_rest:
			_turn_deflection = rad_to_deg(planar_velocity.signed_angle_to(offset, Vector3.UP))


## Multi-point routes: advances progress and places the guidance point the lookahead distance
## further along the route, clamped to the final destination. Returns the route length left beyond
## the guidance point. Intermediate points are never arrival targets.
func _update_route_guidance(direction: Vector3) -> float:
	var lookahead := _lookahead(_route_progress)
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
	var target_arc := _limit_detour_chord(_route_progress + _lookahead(_route_progress), segment_start)
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


## Corner tracking on generated detours: pulls the guidance arc back so the straight chord from the
## ship to the guidance point passes within detour_corner_tolerance of every interior detour point it
## skips. Guidance always may reach the next route point. Advances point by point, stopping at the
## first point whose chord fails, then extends into the following segment by bisection; every accepted
## arc has been checked, so the result always meets the tolerance. Manual points are never checked.
func _limit_detour_chord(target_arc: float, segment_start: float) -> float:
	var next := _route_segment + 1
	var next_arc := segment_start + _route[_route_segment].distance_to(_route[next])
	if next >= _detour_end or next_arc >= target_arc or _chord_fits(_point_at_arc(target_arc, segment_start), next, _detour_end - 1, target_arc, next_arc):
		return target_arc
	var last := next
	var last_arc := next_arc
	while last + 1 < _route.size():
		var arc := last_arc + _route[last].distance_to(_route[last + 1])
		if arc >= target_arc or not _chord_fits(_route[last + 1], next, last, arc, next_arc):
			break
		last += 1
		last_arc = arc
	if last + 1 >= _route.size():
		return last_arc
	var low := last_arc
	var high := minf(target_arc, last_arc + _route[last].distance_to(_route[last + 1]))
	for i in 10: # Bisection steps: resolves the segment to 1/1024 of its length.
		var mid := (low + high) / 2.0
		if _chord_fits(_point_at_arc(mid, segment_start), next, last, mid, next_arc):
			low = mid
		else:
			high = mid
	return low


## Whether every interior detour point from index first to last that lies before chord_arc along the
## route is within detour_corner_tolerance of the chord from the ship to end.
func _chord_fits(end: Vector3, first: int, last: int, chord_arc: float, first_arc: float) -> bool:
	var arc := first_arc
	for i in range(first, mini(last, _detour_end - 1) + 1):
		if i > first:
			arc += _route[i - 1].distance_to(_route[i])
		if arc >= chord_arc:
			break
		if _route[i].distance_to(Geometry3D.get_closest_point_to_segment(_route[i], global_position, end)) > profile.detour_corner_tolerance:
			return false
	return true


## The route point at the given arc length, searching from the current segment (whose start is at
## segment_start); clamped to the final destination.
func _point_at_arc(target_arc: float, segment_start: float) -> Vector3:
	var arc := segment_start
	for i in range(_route_segment, _route.size() - 1):
		var length := _route[i].distance_to(_route[i + 1])
		if arc + length > target_arc:
			return _route[i].lerp(_route[i + 1], (target_arc - arc) / length)
		arc += length
	return _route[-1]


## Lookahead at the given route progress. Manual routes use route_lookahead_distance. A generated
## detour uses detour_lookahead_distance, blending linearly to route_lookahead_distance over the last
## detour_lookahead_distance of progress before its final point, so manually appended legs use the
## manual value without the guidance point jumping.
func _lookahead(progress: float) -> float:
	if _detour_end == 0:
		return profile.route_lookahead_distance
	var detour_length := 0.0
	for i in _detour_end:
		detour_length += _route[i].distance_to(_route[i + 1])
	var blend := clampf((progress - detour_length) / profile.detour_lookahead_distance + 1.0, 0.0, 1.0)
	return lerpf(profile.detour_lookahead_distance, profile.route_lookahead_distance, blend)


## Ends the order: keeps only the last final point, so the route and its getters stay defined.
func _end_route() -> void:
	_route = PackedVector3Array([_route[-1]])
	_route_progress = 0.0
	_route_segment = 0
	_guidance_target = _route[0]
	_guidance_segment = 0
	_detour_end = 0
	_has_destination = false
	_awaiting_rest = false
	_turn_deflection = 0.0
