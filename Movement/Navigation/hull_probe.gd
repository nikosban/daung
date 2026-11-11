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

## Physics layer 1 (static obstacles) as a bitmask. Static navigation queries only this layer, so ships
## (layer 3) never appear in another ship's static clearance checks.
const STATIC_OBSTACLE_MASK := 1 << (1 - 1)
## Physics layer 3 (ships) as a bitmask: only ship traffic checks query it (ship_step_clear()).
const SHIP_MASK := 1 << (3 - 1)

var _valid := false
var _size := Vector3.ZERO
var _offset := Transform3D.IDENTITY
var _height := 0.0
var _exclude: Array[RID] = []
var _mask := STATIC_OBSTACLE_MASK
var _space: PhysicsDirectSpaceState3D
var _box := BoxShape3D.new()
var _cylinder := CylinderShape3D.new()
var _query := PhysicsShapeQueryParameters3D.new()

## Read-only boundary edges of the existing baked mesh, shared by ships in the same map. This is a clearance
## query cache, not a route graph. Internal polygon edges cancel; region seams can conservatively reject a check.
static var _spaces: Dictionary = {}
const BOUNDARY_BLOCK_SIZE := 16 # Geometry broad-phase batch size, not movement tuning.


static func forget_space(map: RID) -> void:
	_spaces.erase(map)


static func prepare_space(map: RID, root: Node, clock: PlanClock) -> bool:
	var iteration := NavigationServer3D.map_get_iteration_id(map)
	if iteration == 0:
		return false
	if not _spaces.has(map) or _spaces[map].iteration != iteration:
		_spaces[map] = {iteration = iteration, regions = [], region = 0, polygon = 0,
			edges = {}, edge_keys = [], boundary = PackedVector3Array(), bounds = [], order = [], blocks = [], ready = false,
			vertices = PackedVector3Array(), flat = true, height = INF, sample_frame = -1, samples = {}, closest = {}, last_hit = -1}
		for node in root.find_children("*", "NavigationRegion3D", true, false):
			if node.enabled and node.navigation_mesh != null and node.get_navigation_map() == map:
				_spaces[map].regions.push_back(node)
	var space: Dictionary = _spaces[map]
	if space.ready:
		return true
	while not space.ready and clock.has_time():
		if space.region >= space.regions.size():
			var offset: int = space.blocks.size() * BOUNDARY_BLOCK_SIZE
			if offset >= space.order.size():
				space.ready = true
			else:
				var box: Vector4 = space.bounds[space.order[offset]]
				for i in range(offset + 1, mini(offset + BOUNDARY_BLOCK_SIZE, space.order.size())):
					var next: Vector4 = space.bounds[space.order[i]]
					box = Vector4(minf(box.x, next.x), minf(box.y, next.y), maxf(box.z, next.z), maxf(box.w, next.w))
				space.blocks.push_back(box)
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
					var box := Vector4(minf(a.x, b.x), minf(a.z, b.z), maxf(a.x, b.x), maxf(a.z, b.z))
					# Keep edge centres sorted along X, one insertion per clock item. Adjacent batches then
					# have useful spatial bounds without an unbudgeted whole-cache sort.
					var low := 0
					var high: int = space.order.size()
					while low < high:
						var middle := (low + high) / 2
						var other: Vector4 = space.bounds[space.order[middle]]
						if other.x + other.z < box.x + box.z:
							low = middle + 1
						else:
							high = middle
					space.order.insert(low, space.bounds.size())
					space.bounds.push_back(box)
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
					var height: float = (region.global_transform * space.vertices[a]).y
					if space.height == INF:
						space.height = height
					elif height != space.height:
						space.flat = false
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
	var edges: PackedVector3Array = _spaces[map].boundary
	if edges.is_empty():
		return false
	var low := Vector2(minf(start.x, end.x) - radius, minf(start.z, end.z) - radius)
	var high := Vector2(maxf(start.x, end.x) + radius, maxf(start.z, end.z) + radius)
	var bounds: Array = _spaces[map].bounds
	var flat_start := RouteGuidance.planar(start)
	var flat_end := RouteGuidance.planar(end)
	# Nearby ships and successive local checks usually meet the same boundary. Re-test that exact edge first;
	# a remembered obstruction never counts as a current result without the same geometric intersection test.
	var last_hit: int = _spaces[map].last_hit
	if last_hit >= 0 and _edge_intersects(flat_start, flat_end, radius, edges[last_hit], edges[last_hit + 1]):
		return false
	# Coarse blocks reject unrelated edge batches before the per-edge test. They only group existing geometry;
	# no navigation adjacency, route graph or alternate search is added.
	var blocks: Array = _spaces[map].blocks
	var order: Array = _spaces[map].order
	var i := 0
	while i < order.size():
		if i % BOUNDARY_BLOCK_SIZE == 0:
			var group: Vector4 = blocks[i / BOUNDARY_BLOCK_SIZE]
			if high.x < group.x or low.x > group.z or high.y < group.y or low.y > group.w:
				i += BOUNDARY_BLOCK_SIZE
				continue
		var edge: int = order[i]
		var box: Vector4 = bounds[edge]
		if high.x < box.x or low.x > box.z or high.y < box.y or low.y > box.w:
			i += 1
			continue
		if _edge_intersects(flat_start, flat_end, radius, edges[edge * 2], edges[edge * 2 + 1]):
			_spaces[map].last_hit = edge * 2
			return false
		i += 1
	# An intersected boundary already disproves containment; only surviving capsules need a start-point query.
	return RouteGuidance.planar(closest_point(map, start) - start).length() <= 1e-4


static func _edge_intersects(start: Vector3, end: Vector3, radius: float, a: Vector3, b: Vector3) -> bool:
	var points := Geometry3D.get_closest_points_between_segments(start, end, a, b)
	# A crossing's float closest points need not be exactly equal, even for a zero-width line.
	if radius == 0.0 and Geometry2D.segment_intersects_segment(Vector2(start.x, start.z), Vector2(end.x, end.z), Vector2(a.x, a.z), Vector2(b.x, b.z)) != null:
		return true
	return points[0].distance_squared_to(points[1]) <= maxf(radius, 1e-4) * maxf(radius, 1e-4)


## Exact native query memoization for repeated points in one immutable map iteration/physics frame.
static func closest_point(map: RID, point: Vector3) -> Vector3:
	if not _spaces.has(map) or _spaces[map].iteration != NavigationServer3D.map_get_iteration_id(map):
		return NavigationServer3D.map_get_closest_point(map, point)
	var space: Dictionary = _spaces[map]
	_sample_frame(space)
	if not space.closest.has(point):
		space.closest[point] = NavigationServer3D.map_get_closest_point(map, point)
	return space.closest[point]


static func _sample_frame(space: Dictionary) -> void:
	var frame := Engine.get_physics_frames()
	if space.sample_frame != frame:
		space.sample_frame = frame
		space.closest.clear()


## Same clearance decision as the exact closest-point test. On a flat map, planar distance to the mesh is
## 1-Lipschitz: a cached cell-centre distance +/- the offset bounds this sample. Only decisive bounds are reused;
## near a threshold, on nonflat maps, or without a current cache, query the exact point. Cell distances belong
## to the immutable map iteration; no physical state or earlier-order guidance is retained.
static func centre_within(map: RID, point: Vector3, limit: float) -> bool:
	if _spaces.has(map) and _spaces[map].ready and _spaces[map].flat and _spaces[map].iteration == NavigationServer3D.map_get_iteration_id(map):
		var space: Dictionary = _spaces[map]
		_sample_frame(space)
		var cell := NavigationServer3D.map_get_cell_size(map)
		var centre := Vector3((floorf(point.x / cell) + 0.5) * cell, point.y, (floorf(point.z / cell) + 0.5) * cell)
		if not space.samples.has(centre):
			space.samples[centre] = RouteGuidance.planar(NavigationServer3D.map_get_closest_point(map, centre) - centre).length()
		var distance: float = space.samples[centre]
		var offset := RouteGuidance.planar(point - centre).length()
		if distance + offset + 1e-4 <= limit:
			return true
		if distance - offset - 1e-4 > limit:
			return false
	return RouteGuidance.planar(closest_point(map, point) - point).length() <= limit


## Provisional compatibility braking (#102, m/s²): the weaker of the main engines and the retro thrusters, as if the
## hull were turned to burn against the velocity (the turn itself is not included). Main and retro act only along the
## hull axis; this is not sideways braking. Stopping estimates (Fleet, traffic, reservations) use it; it is not the
## V4 stopping model.
static func minimum_braking(profile: MovementProfile) -> float:
	return minf(profile.main_acceleration, profile.retro_acceleration)


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
	_mask = STATIC_OBSTACLE_MASK
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


## Ship traffic (Task 38, #79): the same one-tick test as step_clear(), against other ships (layer 3) instead of
## static obstacles. The start pose is not tested on its own (a touching ship may still move away).
func ship_step_clear(position: Vector3, yaw: float, motion: Vector3, dyaw: float) -> bool:
	_query.collision_mask = SHIP_MASK
	var clear := step_clear(position, yaw, motion, dyaw, false)
	_query.collision_mask = _mask
	return clear


func _pose(position: Vector3, yaw: float) -> Transform3D:
	var root := Transform3D(Basis(Vector3.UP, yaw), position)
	return root * _offset
