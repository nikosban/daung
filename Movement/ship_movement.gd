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
## Latest normal order (the requested point), waiting for its physics tick, for navigation to be
## ready, or for its destination search; the previous order continues meanwhile.
var _pending_order := Vector3.ZERO
var _has_pending_order := false
## Points appended while a normal order waits outside navigation syncing; appended once it starts.
var _pending_waypoints := PackedVector3Array()
## Destination search of the pending order: ring 0 is the nearest reachable navigation point; samples
## start at its direction from the requested point. The search ends past the farthest region corner.
var _searching := false
var _search_origin := Vector3.ZERO
var _search_angle := 0.0
var _search_limit := 0.0
var _search_ring := 0
var _search_sample := 0
## Vertical cylinder bounding the hull's collision box at any yaw, and its height offset; derived.
var _hull_bound: CylinderShape3D
var _hull_bound_offset := 0.0
## Route index of a generated detour's final point (the requested destination); 0 for manual routes.
var _detour_end := 0


func _ready() -> void:
	for child in get_children():
		var hull := child as CollisionShape3D
		if hull != null and hull.shape is BoxShape3D:
			var half := (hull.shape as BoxShape3D).size / 2.0
			_hull_bound = CylinderShape3D.new()
			_hull_bound.radius = Vector2(half.x + absf(hull.position.x), half.z + absf(hull.position.z)).length()
			_hull_bound.height = half.y * 2.0
			_hull_bound_offset = hull.position.y
			return
	push_error("ShipMovement needs a CollisionShape3D child with a BoxShape3D.")


## Replaces any route with an order to the requested point. Y is ignored; movement stays on the
## ship's plane. The order starts in the next physics tick, once navigation is ready; until then the
## previous order continues and the latest request replaces any earlier waiting one. A point on the
## navigation surface that the ship can reach and fits at is kept exactly, with a detour around static
## obstacles when needed. Otherwise a destination search picks an approximately nearest such point,
## possibly over several ticks; if none is found the ship brakes to rest. Without navigation data a free
## point is aimed at directly. Classified once against the actual travel velocity: near-opposite orders
## brake to rest first. Orders inside arrival tolerance count as arrivals, never as reversals.
func move_to(world_position: Vector3) -> void:
	_pending_order = Vector3(world_position.x, global_position.y, world_position.z)
	_has_pending_order = true
	_searching = false
	_pending_waypoints.clear()


## Appends a point to the end of the active route; the previous final point becomes intermediate.
## Never navigates, re-classifies, restarts or brakes the journey. While a normal order waits for its
## tick or search, the point is appended once that order starts. Without an active order, or while a
## normal order waits for navigation to sync, it replaces that with a direct order to the point.
func append_waypoint(world_position: Vector3) -> void:
	var point := Vector3(world_position.x, global_position.y, world_position.z)
	if _has_pending_order and _navigation_state() != _Navigation.SYNCING:
		_pending_waypoints.append(point)
		return
	if not _has_destination or _has_pending_order:
		_has_pending_order = false
		_searching = false
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


## Clears the route, including pending points and any waiting order or destination search. The ship
## brakes to rest and stops turning.
func stop() -> void:
	_has_pending_order = false
	_searching = false
	_pending_waypoints.clear()
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
	var bend_limit := INF
	if _has_destination and not _awaiting_rest and _route.size() > 2:
		remaining = _update_route_guidance(direction)
		bend_limit = _bend_speed_limit()
	var offset := _guidance_target - global_position
	offset.y = 0.0
	var distance := offset.length()
	var at_final := _guidance_target == get_destination()

	# Arrival: only the final destination completes the order, once guidance has reached it. The ship
	# then brakes to rest along its current travel and may coast slightly past, without turning back.
	if _has_destination and not _awaiting_rest and at_final and distance <= profile.arrival_tolerance:
		_end_route()

	# Desired velocity: toward the guidance point at the capped speed while steering; otherwise rest
	# (arrival, idle, stop() and near-opposite braking).
	var steering := _has_destination and not _awaiting_rest and distance > 0.0
	var desired_velocity := Vector3.ZERO
	if steering:
		var goal_direction := offset / distance
		# Cap speed so the ship can still brake to rest at the final destination.
		var desired_speed := minf(minf(profile.max_speed, bend_limit), sqrt(2.0 * profile.braking * (distance + remaining)))
		# Pure pursuit: keep the turn radius v² / a inside the circle through the goal tangent to the
		# actual travel, R = d / (2 sin θ), so near goals are reached instead of orbited.
		var sin_theta := absf(sin(direction.angle_to(goal_direction)))
		if sin_theta > 0.001:
			desired_speed = minf(desired_speed, sqrt(profile.lateral_acceleration * distance / (2.0 * sin_theta)))
		desired_velocity = goal_direction * desired_speed

	# One bounded velocity change toward the desired velocity. It is resolved along and across the
	# actual travel (from rest, along the change itself) and limited by one combined budget, an
	# ellipse of acceleration or braking along travel and directional thrust across it: the requested
	# change is scaled onto the ellipse, keeping its direction. Below precision_fade_speed the
	# directional thrust rises smoothly toward precision_lateral_acceleration.
	var change := desired_velocity - planar_velocity
	var change_size := change.length()
	if change_size > 0.0:
		var axis := direction if speed > 0.0 else change / change_size
		var along := change.dot(axis)
		var across := (change - axis * along).length()
		var longitudinal := (profile.acceleration if along > 0.0 else profile.braking) * delta
		var cruise := profile.lateral_acceleration
		var lateral := lerpf(maxf(profile.precision_lateral_acceleration, cruise), cruise, smoothstep(0.0, profile.precision_fade_speed, speed)) * delta
		var demand := sqrt(pow(along / longitudinal, 2.0) + pow(across / lateral, 2.0))
		planar_velocity += change / maxf(demand, 1.0)
	velocity = planar_velocity
	speed = planar_velocity.length()

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


## Resolves and starts the waiting normal order once navigation is not syncing; runs in the physics
## tick, since hull checks query the physics space. A requested point on the navigation surface that
## the ship can reach and fits at is kept; otherwise the destination search continues. Without
## navigation data a free point becomes a direct order and an occupied one is declined.
func _start_pending_order() -> void:
	var navigation := _navigation_state()
	if navigation == _Navigation.SYNCING:
		return
	var requested := _pending_order
	if navigation == _Navigation.UNAVAILABLE:
		_finish_pending_order(PackedVector3Array([global_position, requested]) if _hull_fits(requested) else PackedVector3Array())
		return
	if not _searching:
		var path := _query_path(requested)
		if _on_navigation_surface(requested) and _path_reaches(path, requested) and _hull_fits(requested):
			_finish_pending_order(_route_from_path(path, requested))
			return
		_begin_destination_search(requested, path)
	_search_destination(requested)


## Starts the order on the given route, or declines it when the route is empty (the ship brakes to
## rest, replacing the previous order). Points appended while it waited are then appended.
func _finish_pending_order(route: PackedVector3Array) -> void:
	_has_pending_order = false
	_searching = false
	if route.is_empty():
		_end_route()
	else:
		_start_order(route, route.size() - 1 if route.size() > 2 else 0)
	var waypoints := _pending_waypoints
	_pending_waypoints = PackedVector3Array()
	for point in waypoints:
		append_waypoint(point)


## Sets up the destination search around the requested point. Ring 0 is the path's end (the nearest
## reachable navigation point), or the nearest navigation point when there is no path. The search
## limit is the farthest corner of the enabled navigation regions, beyond which no surface exists.
func _begin_destination_search(requested: Vector3, path: PackedVector3Array) -> void:
	var map := get_world_3d().navigation_map
	var origin: Vector3 = path[-1] if not path.is_empty() else NavigationServer3D.map_get_closest_point(map, requested)
	_search_origin = Vector3(origin.x, global_position.y, origin.z)
	var direction := Vector2(origin.x - requested.x, origin.z - requested.z)
	if direction.is_zero_approx():
		direction = Vector2(global_position.x - requested.x, global_position.z - requested.z)
	_search_angle = direction.angle()
	_search_limit = 0.0
	for region in NavigationServer3D.map_get_regions(map):
		if NavigationServer3D.region_get_enabled(region):
			var bounds := NavigationServer3D.region_get_bounds(region)
			for x in [bounds.position.x, bounds.end.x]:
				for z in [bounds.position.z, bounds.end.z]:
					_search_limit = maxf(_search_limit, Vector2(x - requested.x, z - requested.z).length())
	_search_ring = 0
	_search_sample = 0
	_searching = true


## Advances the destination search by at most destination_search_budget samples. Rings around the
## requested point start at ring 0's distance and grow by destination_search_spacing; samples about
## one spacing apart start at ring 0's direction and alternate sides, each snapped onto the navigation
## surface. The first sample within its ring where the hull fits and the ship's current position can
## reach becomes the destination, and its path from the ship is the route. Once the rings pass the
## search limit the order is declined. Approximately nearest: pockets narrower than the spacing can be
## missed, so a declined order does not prove that no free space exists.
func _search_destination(requested: Vector3) -> void:
	var map := get_world_3d().navigation_map
	var spacing := profile.destination_search_spacing
	var start_radius := Vector2(_search_origin.x - requested.x, _search_origin.z - requested.z).length()
	var budget := profile.destination_search_budget
	while budget > 0:
		var radius := start_radius + spacing * _search_ring
		if _search_ring > 0 and radius > _search_limit:
			_finish_pending_order(PackedVector3Array())
			return
		var samples := 1 if _search_ring == 0 else ceili(TAU * radius / spacing)
		if _search_sample == samples:
			_search_ring += 1
			_search_sample = 0
			continue
		var angle := _search_angle + TAU * ceili(_search_sample / 2.0) / samples * (1.0 if _search_sample % 2 == 1 else -1.0)
		_search_sample += 1
		budget -= 1
		var candidate := _search_origin
		if _search_ring > 0:
			candidate = NavigationServer3D.map_get_closest_point(map, requested + Vector3(cos(angle), 0.0, sin(angle)) * radius)
			candidate.y = global_position.y
		# A sample snapped beyond its ring belongs to a later ring, keeping the search nearest-first.
		var distance := Vector2(candidate.x - requested.x, candidate.z - requested.z).length()
		if (distance <= radius or is_equal_approx(distance, radius)) and _hull_fits(candidate):
			var path := _query_path(candidate)
			if _path_reaches(path, candidate):
				_finish_pending_order(_route_from_path(path, candidate))
				return


## Navigation path from the ship to the target on the ship's map.
func _query_path(target: Vector3) -> PackedVector3Array:
	var query := NavigationPathQueryParameters3D.new()
	query.map = get_world_3d().navigation_map
	query.start_position = global_position
	query.target_position = target
	query.simplify_path = true
	query.simplify_epsilon = profile.path_simplify_epsilon
	var result := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(query, result)
	return result.path


## Whether the point lies on the navigation surface: its nearest navigation point is directly above or below it.
func _on_navigation_surface(point: Vector3) -> bool:
	var closest := NavigationServer3D.map_get_closest_point(get_world_3d().navigation_map, point)
	return is_equal_approx(closest.x, point.x) and is_equal_approx(closest.z, point.z)


## Whether the path ends at the point, within the path's own simplification tolerance (XZ).
func _path_reaches(path: PackedVector3Array, point: Vector3) -> bool:
	return not path.is_empty() and Vector2(path[-1].x - point.x, path[-1].z - point.z).length() <= profile.path_simplify_epsilon


## Whether the hull, at any yaw, fits at the point without overlapping a static obstacle (the same
## bodies the hard stop reacts to).
func _hull_fits(point: Vector3) -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _hull_bound
	query.transform = Transform3D(Basis.IDENTITY, Vector3(point.x, global_position.y + _hull_bound_offset, point.z))
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	for hit in get_world_3d().direct_space_state.intersect_shape(query):
		if hit.collider is StaticBody3D and not hit.collider is AnimatableBody3D:
			return false
	return true


## Route from the ship along the path to the destination. A path that bends becomes a detour: its
## interior points flattened onto the ship's plane, zero-length legs dropped; otherwise a direct route.
func _route_from_path(path: PackedVector3Array, destination: Vector3) -> PackedVector3Array:
	var route := PackedVector3Array([global_position])
	for i in range(1, path.size() - 1):
		var point := Vector3(path[i].x, global_position.y, path[i].z)
		if not point.is_equal_approx(route[-1]) and not point.is_equal_approx(destination):
			route.append(point)
	route.append(destination)
	return route


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


## Multi-point routes: the highest speed at which lateral_acceleration can hold the route's bends
## ahead. The stretch steered through is the lookahead window ahead of progress; its radius is the
## lookahead over the summed absolute deflections inside it, and its limit sqrt(a · R). The window
## ending at each bend ahead applies from the progress where that bend enters guidance, reached with
## the existing braking beforehand. Zero-length legs are skipped. Finite and positive, or INF without bends.
func _bend_speed_limit() -> float:
	var lookahead := _lookahead(_route_progress)
	var reach := _route_progress + lookahead + profile.max_speed * profile.max_speed / (2.0 * profile.braking)
	# Bends ahead of progress: arc position and absolute deflection between legs with length.
	var bend_arcs := PackedFloat64Array()
	var bend_angles := PackedFloat64Array()
	var arc := 0.0
	var previous := Vector3.ZERO
	for i in _route.size() - 1:
		if arc > reach:
			break
		var leg := _route[i + 1] - _route[i]
		if not leg.is_zero_approx():
			if not previous.is_zero_approx() and arc > _route_progress:
				bend_arcs.append(arc)
				bend_angles.append(previous.angle_to(leg))
			previous = leg
		arc += leg.length()

	var limit := INF
	for k in bend_arcs.size():
		var turn := 0.0
		for j in range(k, -1, -1):
			if bend_arcs[j] <= bend_arcs[k] - lookahead:
				break
			turn += bend_angles[j]
		if turn > 0.0:
			var bend_speed := sqrt(profile.lateral_acceleration * lookahead / turn)
			var run_up := maxf(bend_arcs[k] - lookahead - _route_progress, 0.0)
			limit = minf(limit, sqrt(bend_speed * bend_speed + 2.0 * profile.braking * run_up))
	return limit


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
