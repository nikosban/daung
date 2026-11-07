class_name HullProbe
extends RefCounted
## Occupancy tests with a ship's own collision hull at predicted planar poses (Task #46). It reads the ship's
## CollisionShape3D once (the single authoritative hull source) and only queries the physics space: overlap
## (intersect_shape) and straight sweeps (cast_motion). It never moves anything.
##
## The hull rotates about the ship root's vertical axis. reach is the farthest hull point from that axis, so a yaw
## change of dpsi moves every hull point by at most reach x |dpsi|; a translation dp moves it by |dp|. A hull grown
## by that bound in X and Z therefore contains every intermediate pose (conservative, for geometry that is static
## while the plan is made; not a proof for moving bodies).
##
## Only BoxShape3D hulls are supported (the only hull today); others log an error and fail every test.

var reach := 0.0
## Smallest planar half extent of the hull (m): route sampling and coarse-segment spacing.
var half_width := 0.0
## Shape queries made since the counter was last reset (evidence and cost reports).
var queries := 0

var _valid := false
var _size := Vector3.ZERO
var _offset := Transform3D.IDENTITY
var _height := 0.0
var _exclude: Array[RID] = []
var _mask := 1
var _space: PhysicsDirectSpaceState3D
var _box := BoxShape3D.new()
var _cylinder := CylinderShape3D.new()
var _query := PhysicsShapeQueryParameters3D.new()

## Read-only boundary edges of the existing baked mesh, shared by ships in the same map. This is a clearance
## query cache, not a route graph. Internal polygon edges cancel; region seams can conservatively reject a check.
static var _spaces: Dictionary = {}


static func forget_space(map: RID) -> void:
	_spaces.erase(map)


static func prepare_space(map: RID, root: Node, clock: PlanClock) -> bool:
	var iteration := NavigationServer3D.map_get_iteration_id(map)
	if iteration == 0:
		return false
	if not _spaces.has(map) or _spaces[map].iteration != iteration:
		_spaces[map] = {iteration = iteration, regions = [], region = 0, polygon = 0,
			edges = {}, edge_keys = [], boundary = PackedVector3Array(), bounds = [], ready = false, vertices = PackedVector3Array()}
		for node in root.find_children("*", "NavigationRegion3D", true, false):
			if node.enabled and node.navigation_mesh != null and node.get_navigation_map() == map:
				_spaces[map].regions.push_back(node)
	var space: Dictionary = _spaces[map]
	if space.ready:
		return true
	while not space.ready and clock.has_time():
		if space.region >= space.regions.size():
			space.ready = true
		elif space.polygon == -1:
			# Consume one edge at a time, including finalization, under the same clock.
			if space.edge_keys.is_empty():
				space.region += 1
				space.polygon = 0
				space.vertices = PackedVector3Array()
				space.edges.clear()
			else:
				var key: Vector2i = space.edge_keys.pop_back()
				if space.edges[key] == 1:
					var region: NavigationRegion3D = space.regions[space.region]
					var a: Vector3 = region.global_transform * space.vertices[key.x]
					var b: Vector3 = region.global_transform * space.vertices[key.y]
					space.boundary.push_back(Vector3(a.x, 0, a.z))
					space.boundary.push_back(Vector3(b.x, 0, b.z))
					space.bounds.push_back(Vector4(minf(a.x, b.x), minf(a.z, b.z), maxf(a.x, b.x), maxf(a.z, b.z)))
				space.edges.erase(key)
		else:
			var region: NavigationRegion3D = space.regions[space.region]
			var mesh := region.navigation_mesh
			if space.vertices.is_empty():
				space.vertices = mesh.get_vertices()
			if space.polygon >= mesh.get_polygon_count():
				space.polygon = -1
				space.edge_keys = space.edges.keys()
			else:
				var polygon := mesh.get_polygon(space.polygon)
				for i in polygon.size():
					var a := polygon[i]
					var b := polygon[(i + 1) % polygon.size()]
					var key := Vector2i(mini(a, b), maxi(a, b))
					space.edges[key] = space.edges.get(key, 0) + 1
				space.polygon += 1
		clock.item_done()
	return space.ready


## A disk lies entirely on the mesh if its centre is on it and no boundary enters the disk. Unlike ring samples,
## this catches a hole wholly inside the disk. A cache miss is inconclusive and invokes the local hull check.
static func disk_on_mesh(map: RID, centre: Vector3, radius: float) -> bool:
	return capsule_on_mesh(map, centre, centre, radius)


static func capsule_on_mesh(map: RID, start: Vector3, end: Vector3, radius: float) -> bool:
	if not _spaces.has(map) or not _spaces[map].ready or _spaces[map].iteration != NavigationServer3D.map_get_iteration_id(map):
		return false
	var nearest := NavigationServer3D.map_get_closest_point(map, start)
	if RouteGuidance.planar(nearest - start).length() > 1e-4:
		return false
	var edges: PackedVector3Array = _spaces[map].boundary
	if edges.is_empty():
		return false
	var low := Vector2(minf(start.x, end.x) - radius, minf(start.z, end.z) - radius)
	var high := Vector2(maxf(start.x, end.x) + radius, maxf(start.z, end.z) + radius)
	var bounds: Array = _spaces[map].bounds
	var flat_start := RouteGuidance.planar(start)
	var flat_end := RouteGuidance.planar(end)
	for i in range(0, edges.size(), 2):
		var box: Vector4 = bounds[i / 2]
		if high.x < box.x or low.x > box.z or high.y < box.y or low.y > box.w:
			continue
		var closest := Geometry3D.get_closest_points_between_segments(flat_start, flat_end, edges[i], edges[i + 1])
		# At a crossing, float closest points can differ by a few micrometres; radius zero must not require exact
		# equality. Segment intersection also catches the crossing directly, independent of that rounding.
		if radius == 0.0 and Geometry2D.segment_intersects_segment(Vector2(start.x, start.z), Vector2(end.x, end.z),
			Vector2(edges[i].x, edges[i].z), Vector2(edges[i + 1].x, edges[i + 1].z)) != null:
			return false
		if closest[0].distance_squared_to(closest[1]) <= maxf(radius, 1e-4) * maxf(radius, 1e-4):
			return false
	return true


## Lower bound across the actual directional curve. Nonlinear curves need the detailed check rather than an
## endpoint-minimum assumption. This does not change or rescale the profile.
static func minimum_braking(profile: MovementProfile) -> float:
	var curve := profile.directional_thrust_curve
	var effectiveness := 1.0
	for i in curve.point_count:
		effectiveness = minf(effectiveness, clampf(curve.get_point_position(i).y, 0.0, 1.0))
		if i + 1 < curve.point_count and (curve.get_point_right_mode(i) != Curve.TANGENT_LINEAR or curve.get_point_left_mode(i + 1) != Curve.TANGENT_LINEAR):
			return 0.0
	var rating := profile.thruster_strength / profile.mass
	return minf(rating * effectiveness, ShipPilot.sternward_limit_of(profile, rating))


## Direction toward more centre clearance for a low-speed reposition, using the same baked boundaries.
static func escape_direction(map: RID, position: Vector3) -> Vector3:
	var nearest := NavigationServer3D.map_get_closest_point(map, position)
	var onto_mesh := RouteGuidance.planar(nearest - position)
	if onto_mesh.length() > 1e-4:
		return onto_mesh.normalized()
	if not _spaces.has(map) or not _spaces[map].ready:
		return Vector3.ZERO
	var edges: PackedVector3Array = _spaces[map].boundary
	var bounds: Array = _spaces[map].bounds
	var point := Vector2(position.x, position.z)
	var away := Vector2.ZERO
	var best := INF
	for i in range(0, edges.size(), 2):
		var box: Vector4 = bounds[i / 2]
		var dx := maxf(box.x - point.x, maxf(point.x - box.z, 0.0))
		var dz := maxf(box.y - point.y, maxf(point.y - box.w, 0.0))
		if dx * dx + dz * dz >= best:
			continue
		var closest := Geometry2D.get_closest_point_to_segment(point, Vector2(edges[i].x, edges[i].z), Vector2(edges[i + 1].x, edges[i + 1].z))
		var offset := point - closest
		if offset.length_squared() < best:
			best = offset.length_squared()
			away = offset
	return Vector3(away.x, 0, away.y).normalized()


## Cheap clear-space proof: all response-window accelerations, then ordinary braking, fit this enclosing disk.
## For retro-equipped ships no-order braking is parallel to velocity, with fixed hull heading. The lateral radius
## bounds response-window velocity changes through the longest possible stop. Without retro, use a full ball
## because the sternward component cap can curve the stopping motion. No stopping ticks are simulated here.
func open_stopping_room(profile: MovementProfile, state: ShipPilot.State, delta: float, map: RID) -> bool:
	var braking := minimum_braking(profile)
	if braking <= 0.0 or delta > profile.pilot_response_time:
		return false
	var window := profile.pilot_response_time
	var speed := state.velocity.length()
	var acceleration := profile.main_acceleration + profile.thruster_strength / profile.mass
	var change := acceleration * (window + delta)
	var top := minf(profile.max_speed, speed + change)
	var stopping := top * top / (2.0 * braking) + top * (window + delta)
	var distance := speed * window + acceleration * window * (window + delta) + stopping
	var side := minf(distance, change * (window + delta + top / braking + profile.pilot_response_time))
	var centre := state.position
	var radius := distance
	if profile.retro_thrusters and speed > change:
		centre += state.velocity.normalized() * distance * 0.5
		radius = distance * 0.5 + side
	if profile.retro_thrusters and speed > change:
		var end := state.position + state.velocity.normalized() * distance
		if not capsule_on_mesh(map, state.position, end, side):
			return false
		return cylinder_sweep_clear(state.position, end, side + reach + profile.plan_clearance_buffer)
	elif not disk_on_mesh(map, centre, radius):
		return false
	return cylinder_clear(centre, radius + reach + profile.plan_clearance_buffer)


## Sweep the same all-yaw occupancy cylinder down the stopping corridor, instead of replacing a long narrow
## corridor with a large ball that includes unrelated obstacles to either side. cast_motion ignores start overlaps.
func cylinder_sweep_clear(start: Vector3, end: Vector3, radius: float) -> bool:
	if not cylinder_clear(start, radius):
		return false
	_query.motion = RouteGuidance.planar(end - start)
	queries += 1
	var fractions := _space.cast_motion(_query)
	_query.motion = Vector3.ZERO
	return fractions[0] >= 1.0


func _init(body: CollisionObject3D, collision_shape: CollisionShape3D) -> void:
	if collision_shape == null or not collision_shape.shape is BoxShape3D:
		push_error("HullProbe needs a CollisionShape3D with a BoxShape3D; navigation will decline every plan.")
		return
	_size = (collision_shape.shape as BoxShape3D).size
	_offset = collision_shape.transform
	_height = _size.y
	var half := _size * 0.5
	var corner_x := absf(_offset.origin.x) + half.x
	var corner_z := absf(_offset.origin.z) + half.z
	reach = Vector2(corner_x, corner_z).length()
	half_width = minf(half.x, half.z)
	_exclude = [body.get_rid()]
	_mask = body.collision_mask
	_space = body.get_world_3d().direct_space_state
	_query.collision_mask = _mask
	_query.exclude = _exclude
	_query.margin = 0.0
	_valid = true


func is_valid() -> bool:
	return _valid


## Whether the hull at the planar pose, grown by grow metres in X and Z, overlaps occupied space.
func overlaps(position: Vector3, yaw: float, grow: float) -> bool:
	if not _valid:
		return true
	_box.size = Vector3(_size.x + 2.0 * grow, _size.y, _size.z + 2.0 * grow)
	_query.shape = _box
	_query.transform = _pose(position, yaw)
	_query.motion = Vector3.ZERO
	queries += 1
	return not _space.intersect_shape(_query, 1).is_empty()


## Whether a vertical cylinder of the given radius (hull height) around the root is free: the hull is then clear at
## any yaw. A cheap positive shortcut only; an occupied cylinder proves nothing.
func cylinder_clear(position: Vector3, radius: float) -> bool:
	if not _valid:
		return false
	_cylinder.radius = radius
	_cylinder.height = _height
	_query.shape = _cylinder
	_query.transform = Transform3D(Basis.IDENTITY, Vector3(position.x, position.y + _offset.origin.y, position.z))
	_query.motion = Vector3.ZERO
	queries += 1
	return _space.intersect_shape(_query, 1).is_empty()


## One predicted tick from (position, yaw) by motion and dyaw is safe when:
## 1. the exact hull at the start pose does not overlap (cast_motion ignores an initial overlap). Only needed for
##    the first pose of a prediction (check_start): every later pose lies inside the previous tick's checked sweep;
## 2. for a yaw change, the hull grown by reach x |dyaw| at the start pose does not overlap (no corner can enter);
## 3. that hull swept along the translation is free over the whole motion (cast_motion safe fraction 1).
## A touching ship may therefore translate away from the contact, but cannot rotate until it has clearance.
func step_clear(position: Vector3, yaw: float, motion: Vector3, dyaw: float, check_start: bool) -> bool:
	if check_start and overlaps(position, yaw, 0.0):
		return false
	var grow := reach * absf(dyaw)
	if grow > 0.0 and overlaps(position, yaw, grow):
		return false
	if motion.length_squared() == 0.0:
		return true
	_box.size = Vector3(_size.x + 2.0 * grow, _size.y, _size.z + 2.0 * grow)
	_query.shape = _box
	_query.transform = _pose(position, yaw)
	_query.motion = Vector3(motion.x, 0.0, motion.z)
	queries += 1
	var fractions := _space.cast_motion(_query)
	_query.motion = Vector3.ZERO
	return fractions[0] >= 1.0


func _pose(position: Vector3, yaw: float) -> Transform3D:
	var root := Transform3D(Basis(Vector3.UP, yaw), position)
	return root * _offset
