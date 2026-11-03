class_name ShipMovement
extends CharacterBody3D
## Authoritative planar movement for a ship. The only writer of its XZ position,
## planar velocity and yaw. Callers request movement through move_to(), append_waypoint() and stop().
## Locomotion is heading-and-throttle: the hull turns toward a commanded heading with bounded yaw rate
## and yaw acceleration, the main engine changes speed along the bow, a small sideways slip fades, and
## directional thrusters reposition the ship (TRANSLATE) or start it moving from rest.

enum _Navigation { SYNCING, UNAVAILABLE, READY }
enum Phase { IDLE, TURN, CRUISE, BRAKE, TRANSLATE }

@export var profile: MovementProfile

## The route: the anchor (ship position when the route was set), then the route points (generated
## detour points and/or requested points); the last entry is the final destination. Never empty: while
## idle it holds only the last final point.
var _route := PackedVector3Array([Vector3.ZERO])
var _has_destination := false
## Current leg, from _route[_leg] to _route[_leg + 1] (the aim point).
var _leg := 0
## Maneuver plan of the active route: corner speeds, turn-start trims and the clearance gate.
var _plan: ManeuverPlan
var _motion := ManeuverPlan.Motion.new()
var _phase := Phase.IDLE
## TURN: the latched commanded speed; the fixed commanded heading at a planned corner (NAN: aim at the
## aim point); whether thrusters also push toward the aim point (a start from rest).
var _turn_speed := 0.0
var _turn_heading := NAN
var _departure := false
## Near-opposite order pending: brake to rest, then start the same order from rest.
var _awaiting_rest := false
## Signed degrees from travel direction to goal at order receipt, or to the next leg at a planned
## corner's turn start (positive = left turn); 0 unless a moving turn.
var _turn_deflection := 0.0
## Last tick's commands (read-only debug getters).
var _commanded_heading := NAN
var _commanded_speed := 0.0
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
## The hull's collision box and its local transform, for the corner clearance gate.
var _hull_box: BoxShape3D
var _hull_local := Transform3D.IDENTITY


func _ready() -> void:
	_motion.position = global_position
	_motion.yaw = rotation.y
	for child in get_children():
		var hull := child as CollisionShape3D
		if hull != null and hull.shape is BoxShape3D:
			_hull_box = hull.shape as BoxShape3D
			_hull_local = hull.transform
			var half := _hull_box.size / 2.0
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


## Appends a point to the end of the active route; the previous final point becomes a corner, planned
## and checked like the others. Never navigates, re-classifies or restarts the journey by itself. While
## a normal order waits for its tick or search, the point is appended once that order starts. Without
## an active order, or while a normal order waits for navigation to sync, it replaces that with a
## direct order to the point.
func append_waypoint(world_position: Vector3) -> void:
	var point := Vector3(world_position.x, global_position.y, world_position.z)
	if _has_pending_order and _navigation_state() != _Navigation.SYNCING:
		_pending_waypoints.append(point)
		return
	if not _has_destination or _has_pending_order:
		_has_pending_order = false
		_searching = false
		_start_order(PackedVector3Array([global_position, point]))
		return
	if _route.size() == 2:
		# Re-anchor at the ship so the aim at the old final point stays continuous.
		_route = PackedVector3Array([global_position, _route[1], point])
		_leg = 0
		_plan = _new_plan(_route)
	else:
		_route.append(point)
		_plan.append(point)


## Clears the route, including pending points and any waiting order or destination search. The ship
## brakes to rest and stops turning on the same tick.
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


## The point the ship currently steers at: the end of its current leg, or the final point while idle.
func get_guidance_target() -> Vector3:
	return _route[_leg + 1] if _has_destination else _route[-1]


## Initial course change of the current order or planned corner: signed degrees from the actual travel
## direction to the goal, or to the next leg at a corner's turn start (positive = left turn). 0 for
## orders from rest, near-opposite orders, and once the order ends (arrival or stop()).
func get_turn_deflection() -> float:
	return _turn_deflection


## Read-only debug state (F3 readout). Headings are degrees of yaw (0 = −Z, positive = left); the
## commanded heading is NAN when none is commanded.
func get_phase_name() -> String:
	return Phase.keys()[_phase]


func get_commanded_heading() -> float:
	return rad_to_deg(_commanded_heading)


func get_heading() -> float:
	return rad_to_deg(rotation.y)


## Commanded main-engine speed, or the thruster speed target in TRANSLATE and departure TURNs (m/s).
func get_commanded_speed() -> float:
	return _commanded_speed


## Actual planar speed (m/s).
func get_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


## Sideways slip toward the hull's right (m/s).
func get_slip() -> float:
	return _motion.slip


func _physics_process(delta: float) -> void:
	if _has_pending_order:
		_start_pending_order()
	if _plan != null:
		for index in _plan.advance(get_world_3d().direct_space_state, global_position.y):
			_apply_corner_result(index)
	_motion.position = global_position
	var heading := NAN
	var speed_command := 0.0
	var thrust_command := Vector3.ZERO
	var yaw_limit := INF
	var resting_at_vertex := false
	if _has_destination:
		_update_leg()
		var offset := _route[_leg + 1] - global_position
		offset.y = 0.0
		var distance := offset.length()
		var final_leg := _leg == _route.size() - 2
		if final_leg and not _awaiting_rest and distance <= profile.arrival_tolerance:
			# Arrival ends the order and its rotation; the ship then brakes to rest along its travel.
			_end_route()
		elif _awaiting_rest:
			_phase = Phase.BRAKE
		elif not final_leg and _plan.speeds[_leg + 1] <= 0.0 and distance <= profile.arrival_tolerance:
			# A stop-and-turn corner, or one whose clearance check has not finished: rest here first.
			_phase = Phase.BRAKE
			resting_at_vertex = true
		else:
			var direction := offset / distance if distance > 0.0 else _motion.bow()
			var bearing := atan2(-direction.x, -direction.z)
			yaw_limit = deg_to_rad(profile.yaw_accel) * _time_to_arrival(distance)
			if _phase == Phase.TRANSLATE:
				heading = bearing
				thrust_command = direction * minf(profile.max_speed, sqrt(2.0 * profile.thruster_accel * distance))
			else:
				var tolerance := deg_to_rad(profile.heading_tolerance)
				if _phase == Phase.TURN and absf(angle_difference(rotation.y, bearing if is_nan(_turn_heading) else _turn_heading)) <= tolerance:
					_enter_cruise()
				if _phase != Phase.TURN and absf(angle_difference(rotation.y, bearing)) > 2.0 * tolerance:
					_enter_turn(minf(profile.turn_speed_factor * _motion.speed, _fit_speed(direction, distance)), NAN, _motion.speed == 0.0)
				if _phase == Phase.TURN:
					heading = bearing if is_nan(_turn_heading) else _turn_heading
					speed_command = _turn_speed
					if _departure:
						thrust_command = direction * minf(profile.turn_speed_factor * profile.max_speed, sqrt(2.0 * profile.thruster_accel * distance))
				else:
					heading = bearing
					var cap := _route_speed_cap(distance)
					speed_command = cap.x
					var braking := cap.y > 0.0 and speed_command < profile.max_speed and _motion.speed > 0.0 and speed_command <= _motion.speed + profile.accel * delta
					_phase = Phase.BRAKE if braking else Phase.CRUISE

	_motion.step(profile, delta, heading, speed_command, thrust_command, yaw_limit)
	_commanded_heading = heading
	_commanded_speed = thrust_command.length() if _phase == Phase.TRANSLATE or (_phase == Phase.TURN and _departure) else speed_command
	rotation.y = _motion.yaw
	velocity = _motion.velocity()
	var commanded := velocity
	move_and_slide()
	_motion.position = global_position

	if _has_destination and _motion.is_at_rest():
		if _awaiting_rest:
			_awaiting_rest = false
			_start_from_rest()
		elif resting_at_vertex:
			if _plan.is_unchecked(_leg + 1):
				_plan.force_stop(_leg + 1)
			_leg += 1
			_start_from_rest()

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
				_motion.speed = 0.0
				_motion.slip = 0.0
				_motion.thrust_velocity = Vector3.ZERO
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
		_start_order(route)
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



## Replaces any route with the given one (anchor first, destination last), plans it, and classifies
## the order once against the actual travel velocity, using the first aim point as the goal: at rest,
## a start from rest; at or beyond near_opposite_angle, brake to rest first; otherwise a continuous
## TURN (heading error beyond heading_tolerance) or CRUISE.
func _start_order(route: PackedVector3Array) -> void:
	_route = route
	_leg = 0
	_plan = _new_plan(route)
	_has_destination = true
	_awaiting_rest = false
	_turn_deflection = 0.0
	_departure = false
	_turn_heading = NAN
	if _motion.is_at_rest():
		_start_from_rest()
		return
	var travel := _motion.velocity()
	travel.y = 0.0
	var to_destination := route[-1] - global_position
	to_destination.y = 0.0
	var offset := route[1] - global_position
	offset.y = 0.0
	_phase = Phase.CRUISE
	if to_destination.length() <= profile.arrival_tolerance or offset.is_zero_approx():
		return
	var angle := rad_to_deg(travel.angle_to(offset))
	_awaiting_rest = angle >= profile.near_opposite_angle or is_equal_approx(angle, profile.near_opposite_angle)
	if _awaiting_rest:
		_phase = Phase.BRAKE
		return
	_turn_deflection = rad_to_deg(travel.signed_angle_to(offset, Vector3.UP))
	var distance := offset.length()
	var bearing := atan2(-offset.x, -offset.z)
	if absf(angle_difference(rotation.y, bearing)) > deg_to_rad(profile.heading_tolerance):
		_enter_turn(minf(profile.turn_speed_factor * _motion.speed, _fit_speed(offset / distance, distance)), NAN, _motion.speed == 0.0)


## Starts the current leg from rest. A single-leg route within thruster_range uses TRANSLATE when its
## estimated time is at most translate_preference times turn-and-burn's. Otherwise a heading error
## beyond heading_tolerance is a departure TURN: the hull yaws and the thrusters push toward the aim
## point from the same tick. Otherwise CRUISE.
func _start_from_rest() -> void:
	_departure = false
	_turn_heading = NAN
	_turn_speed = 0.0
	_phase = Phase.CRUISE
	var offset := _route[_leg + 1] - global_position
	offset.y = 0.0
	var distance := offset.length()
	if distance == 0.0:
		return
	var error := absf(angle_difference(rotation.y, atan2(-offset.x, -offset.z)))
	if _route.size() == 2 and distance <= profile.thruster_range and 2.0 * sqrt(distance / profile.thruster_accel) <= profile.translate_preference * _turn_and_burn_time(error, distance):
		_phase = Phase.TRANSLATE
	elif error > deg_to_rad(profile.heading_tolerance):
		_enter_turn(0.0, NAN, true)


func _enter_turn(speed: float, heading: float, departure: bool) -> void:
	_phase = Phase.TURN
	_turn_speed = speed
	_turn_heading = heading
	_departure = departure


## TURN → CRUISE. After a departure the thrusters' forward part along the bow becomes main-engine
## speed (world velocity unchanged); any sideways or sternward part stays and fades at thruster_accel.
func _enter_cruise() -> void:
	if _departure:
		var forward := maxf(_motion.thrust_velocity.dot(_motion.bow()), 0.0)
		_motion.speed += forward
		_motion.thrust_velocity -= _motion.bow() * forward
	_departure = false
	_turn_heading = NAN
	_phase = Phase.CRUISE


## Estimated time to turn by error (rad) with the yaw profile, then cover distance from rest with accel,
## max_speed and decel.
func _turn_and_burn_time(error: float, distance: float) -> float:
	var rate := deg_to_rad(profile.yaw_rate)
	var yaw_accel := deg_to_rad(profile.yaw_accel)
	var turn := error / rate + rate / yaw_accel if error >= rate * rate / yaw_accel else 2.0 * sqrt(error / yaw_accel)
	var a := profile.accel
	var b := profile.decel
	var peak := sqrt(2.0 * distance * a * b / (a + b))
	if peak <= profile.max_speed:
		return turn + peak / a + peak / b
	var v := profile.max_speed
	return turn + v / a + v / b + (distance - v * v / (2.0 * a) - v * v / (2.0 * b)) / v


## Speed whose turn radius (v / yaw_rate) fits the circle through the aim point tangent to the bow.
func _fit_speed(direction: Vector3, distance: float) -> float:
	var sine := absf(sin(_motion.bow().angle_to(direction)))
	if sine < 0.001:
		return INF
	return deg_to_rad(profile.yaw_rate) * distance / (2.0 * sine)


## CRUISE speed: max_speed, limited so the ship can brake with decel to each planned corner's speed at
## its turn start, and to rest at the final point or the next stop-and-turn (or unchecked) corner.
## Returns (speed, 1 when the limit is a rest point, else 0).
func _route_speed_cap(distance: float) -> Vector2:
	var cap := profile.max_speed
	var rest := 0.0
	var along := distance
	for index in range(_leg + 1, _route.size()):
		var limit := INF
		var stops := index == _route.size() - 1 or _plan.speeds[index] <= 0.0
		if stops:
			limit = sqrt(2.0 * profile.decel * along)
		elif _plan.speeds[index] != ManeuverPlan.NO_TURN:
			var corner := _plan.speeds[index]
			limit = sqrt(corner * corner + 2.0 * profile.decel * maxf(along - _plan.trims[index], 0.0))
		if limit < cap:
			cap = limit
			rest = 1.0 if stops else 0.0
		if stops:
			break
		along += _route[index].distance_to(_route[index + 1])
	return Vector2(cap, rest)


## Shortest time to the arrival trigger along the rest of the route (braking-limited profile with the
## stronger of decel and thruster_accel), so the yaw velocity can be wound down before arrival.
func _time_to_arrival(distance: float) -> float:
	var along := distance
	for index in range(_leg + 1, _route.size() - 1):
		along += _route[index].distance_to(_route[index + 1])
	var a := maxf(profile.decel, profile.thruster_accel)
	return maxf(sqrt(2.0 * a * along) - sqrt(2.0 * a * profile.arrival_tolerance), 0.0) / a


## Advances the current leg: past a no-turn vertex once it is within arrival_tolerance (or passed),
## and into a corner's TURN at its turn-start point once the corner has passed the clearance gate.
## Stop-and-turn and unchecked corners advance only after resting at the vertex.
func _update_leg() -> void:
	while _leg < _route.size() - 2 and _phase != Phase.TRANSLATE and not _awaiting_rest:
		var index := _leg + 1
		var corner := _plan.speeds[index]
		var remaining := _remaining_on_leg()
		if corner == ManeuverPlan.NO_TURN:
			if remaining > profile.arrival_tolerance:
				return
			_leg += 1
		elif corner > 0.0:
			if remaining > _plan.trims[index]:
				return
			_leg += 1
			var next := _route[_leg + 1] - _route[_leg]
			next.y = 0.0
			var travel := _motion.velocity()
			if not travel.is_zero_approx() and not next.is_zero_approx():
				_turn_deflection = rad_to_deg(travel.signed_angle_to(next, Vector3.UP))
			_enter_turn(corner, atan2(-next.x, -next.z), false)
		else:
			return


## Distance left along the current leg to its end, measured on the leg's line.
func _remaining_on_leg() -> float:
	var leg := _route[_leg + 1] - _route[_leg]
	leg.y = 0.0
	var length := leg.length()
	if length == 0.0:
		return 0.0
	var along := (global_position - _route[_leg]).dot(leg / length)
	return length - along


## A corner just resolved by the clearance gate. If the ship is already past its turn-start point on
## the leg leading to it, the checked turn no longer applies, so that corner stays stop-and-turn.
func _apply_corner_result(index: int) -> void:
	if not _has_destination or index != _leg + 1:
		return
	var corner := _plan.speeds[index]
	if corner > 0.0 and corner != ManeuverPlan.NO_TURN and _remaining_on_leg() < _plan.trims[index]:
		_plan.force_stop(index)


func _new_plan(route: PackedVector3Array) -> ManeuverPlan:
	return ManeuverPlan.new(route, profile, _hull_box, _hull_local, _hull_bound.radius, collision_mask, get_rid())


## Ends the order: keeps only the last final point, so the route and its getters stay defined. The
## heading freezes on this tick (arrival and stop() end commanded rotation); the ship brakes to rest.
func _end_route() -> void:
	_route = PackedVector3Array([_route[-1]])
	_leg = 0
	_plan = null
	_has_destination = false
	_awaiting_rest = false
	_turn_deflection = 0.0
	_departure = false
	_turn_heading = NAN
	_phase = Phase.IDLE
	_motion.yaw_velocity = 0.0
