class_name PassageGraph
extends RefCounted
## Distinct passages on demand (Task #56). Godot's NavigationServer3D answers path queries only (the shortest path);
## when a ship's path cannot be negotiated, this finds other passages to the same destination over the same baked
## navigation mesh. It is never used up front: only Navigator's checked flight starts a Query, after its checks have
## rejected the current path.
##
## Geometry: the polygons of the map's single enabled navigation region, read through engine APIs only
## (map_get_regions -> region_get_owner_id -> the NavigationRegion3D's navigation_mesh, region_get_transform). Two
## polygons are adjacent when they share an edge (a vertex pair); that edge is their portal. The cache is read-only,
## shared by every ship, built one work item at a time and rebuilt when the map iteration changes. A map with more
## than one enabled region (portals between regions are not represented) has no alternatives: queries end at once.
##
## Query: A* over polygons from the ship's position to the destination (cost: distance between portal midpoints, times
## the portal's penalty; heuristic: straight distance), then a funnel turns the portal sequence into corners. After
## each search, the portals it used cost PORTAL_PENALTY times more, so the next search prefers another passage. A
## found route in the same passage as a rejected or earlier found one (every point of it within the distinct distance
## of that route) is skipped. Routes come in generation order; there is no ranking. At most max_searches searches.

enum { RUNNING, FOUND, DONE, UNAVAILABLE }

## Cost factor on the portals of each found corridor for the next search (search shape, not tuning).
const PORTAL_PENALTY := 4.0
## Polygons handled per work item while building the cache or locating a point.
const POLYGONS_PER_ITEM := 16
## A corner is rounded only where the route turns by more than this (radians; about 1°, search shape).
const MIN_CORNER_TURN := 0.02
## A corner offset smaller than this (m) is not applied.
const MIN_CORNER_OFFSET := 0.1

static var _map := RID()
static var _iteration := -1
static var _state := RUNNING
static var _mesh: NavigationMesh
static var _transform := Transform3D.IDENTITY
static var _verts := PackedVector3Array()
static var _polys: Array[PackedInt32Array] = []
static var _centres := PackedVector3Array()
## Per polygon: Vector3i(neighbour, vertex a, vertex b) for each shared edge.
static var _adj: Array[Array] = []
static var _edges := {}
static var _built := 0


## Advances the shared cache by one work item for the map's current iteration: RUNNING, DONE (ready) or UNAVAILABLE.
static func build_item(map: RID) -> int:
	var iteration := NavigationServer3D.map_get_iteration_id(map)
	if map != _map or iteration != _iteration:
		_map = map
		_iteration = iteration
		_reset()
		var regions: Array[RID] = []
		for region in NavigationServer3D.map_get_regions(map):
			if NavigationServer3D.region_get_enabled(region):
				regions.push_back(region)
		if regions.size() != 1:
			_state = UNAVAILABLE
			return _state
		var owner := instance_from_id(NavigationServer3D.region_get_owner_id(regions[0]))
		if not owner is NavigationRegion3D or (owner as NavigationRegion3D).navigation_mesh == null:
			_state = UNAVAILABLE
			return _state
		_mesh = (owner as NavigationRegion3D).navigation_mesh
		_transform = NavigationServer3D.region_get_transform(regions[0])
		_verts = _mesh.get_vertices()
		for i in _verts.size():
			_verts[i] = _transform * _verts[i]
		_state = RUNNING
		return _state
	if _state != RUNNING:
		return _state
	var count := _mesh.get_polygon_count()
	var end := mini(_built + POLYGONS_PER_ITEM, count)
	for p in range(_built, end):
		var poly := _mesh.get_polygon(p)
		_polys.push_back(poly)
		_adj.push_back([])
		var centre := Vector3.ZERO
		for v in poly:
			centre += _verts[v]
		_centres.push_back(centre / maxi(poly.size(), 1))
		for k in poly.size():
			var a := poly[k]
			var b := poly[(k + 1) % poly.size()]
			var key := Vector2i(mini(a, b), maxi(a, b))
			if _edges.has(key):
				var other: int = _edges[key]
				_adj[p].push_back(Vector3i(other, a, b))
				_adj[other].push_back(Vector3i(p, a, b))
			else:
				_edges[key] = p
	_built = end
	if _built >= count:
		_edges = {}
		_state = DONE
	return _state


static func _reset() -> void:
	_state = RUNNING
	_mesh = null
	_verts = PackedVector3Array()
	_polys = []
	_centres = PackedVector3Array()
	_adj = []
	_edges = {}
	_built = 0


## Whether every point of route lies within distance of one of the other routes (the same passage).
static func same_passage(route: PackedVector3Array, others: Array[PackedVector3Array], distance: float) -> bool:
	for other in others:
		var all_near := true
		for point in route:
			if _distance_to(other, point) > distance:
				all_near = false
				break
		if all_near:
			return true
	return false


static func _distance_to(route: PackedVector3Array, point: Vector3) -> float:
	var best := INF
	var p := Vector2(point.x, point.z)
	for k in range(1, route.size()):
		var a := Vector2(route[k - 1].x, route[k - 1].z)
		var b := Vector2(route[k].x, route[k].z)
		var ab := b - a
		var t := 0.0 if ab.length_squared() == 0.0 else clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		best = minf(best, (a + ab * t - p).length())
	return best


## Clearance-aware corners (Task #56), resumable one work item (one on-mesh sample) at a time. Route corners from a
## string-pulled path lie on the mesh edge, which the lookahead aim cuts. Each interior corner where the route turns by
## more than MIN_CORNER_TURN is moved outward along its bisector, away from the obstacle the route bends around, by
## clearance. Both legs into and out of the moved corner (from the previous, already shaped point to the next original
## one) must stay on the navigation mesh, sampled every SAMPLE_SPACING within one cell; otherwise the offset is halved,
## and below MIN_CORNER_OFFSET the corner is kept as it is. A moved corner therefore never pushes a leg out of a narrow
## passage further along it.
class CornerShaper:
	const SAMPLE_SPACING := 0.5

	var route := PackedVector3Array()
	var rounded := 0
	var reduced := 0
	var samples_tested := 0
	var done := false
	var _map: RID
	var _raw := PackedVector3Array()
	var _clearance := 0.0
	var _cell := 0.25
	var _corner := 1
	var _offset := 0.0
	var _moved := Vector3.ZERO
	var _outward := Vector3.ZERO
	var _samples := PackedVector3Array()
	var _sample := 0

	func _init(map: RID, raw: PackedVector3Array, clearance: float) -> void:
		_map = map
		_raw = raw
		_clearance = clearance
		_cell = NavigationServer3D.map_get_cell_size(map)
		route.push_back(raw[0])
		_next_corner()

	## One work item; true when the route is complete.
	func step() -> bool:
		if done:
			return true
		if _sample < _samples.size():
			var point := _samples[_sample]
			_sample += 1
			samples_tested += 1
			if RouteGuidance.planar(NavigationServer3D.map_get_closest_point(_map, point) - point).length() > _cell:
				_offset *= 0.5
				_try_offset()
			elif _sample >= _samples.size():
				route.push_back(_moved)
				rounded += 1
				if _offset < _clearance - 1e-4:
					reduced += 1
				_corner += 1
				_next_corner()
		return done

	## Sets up the next corner that needs moving, copying straight corners through.
	func _next_corner() -> void:
		while _corner < _raw.size() - 1:
			var corner := _raw[_corner]
			var incoming := RouteGuidance.planar(corner - route[route.size() - 1])
			var outgoing := RouteGuidance.planar(_raw[_corner + 1] - corner)
			var bend := outgoing.normalized() - incoming.normalized()
			if bend.length() > PassageGraph.MIN_CORNER_TURN and _clearance >= PassageGraph.MIN_CORNER_OFFSET:
				_outward = -bend.normalized()
				_offset = _clearance
				_try_offset()
				return
			route.push_back(corner)
			_corner += 1
		route.push_back(_raw[_raw.size() - 1])
		done = true

	## Samples both legs through the corner moved by the current offset, or keeps the corner unmoved.
	func _try_offset() -> void:
		_samples = PackedVector3Array()
		_sample = 0
		if _offset < PassageGraph.MIN_CORNER_OFFSET:
			route.push_back(_raw[_corner])
			_corner += 1
			_next_corner()
			return
		_moved = _raw[_corner] + _outward * _offset
		for leg in [[route[route.size() - 1], _moved], [_moved, _raw[_corner + 1]]]:
			var a: Vector3 = leg[0]
			var b: Vector3 = leg[1]
			var count := maxi(1, ceili(RouteGuidance.planar(b - a).length() / SAMPLE_SPACING))
			for i in range(1, count):
				_samples.push_back(a.lerp(b, float(i) / count))
		_samples.push_back(_moved)


## One on-demand search for distinct passages from a position to a destination. step() does one work item and returns
## RUNNING, FOUND (route holds a new distinct route), DONE (no further route) or UNAVAILABLE.
class Query:
	var route := PackedVector3Array()
	var searches := 0
	var expansions := 0
	var _map: RID
	var _from := Vector3.ZERO
	var _goal := Vector3.ZERO
	var _known: Array[PackedVector3Array] = []
	var _max_searches := 1
	var _distance := 10.0
	var _phase := 0
	var _locate_at := 0
	var _start_poly := -1
	var _goal_poly := -1
	var _start_best := INF
	var _goal_best := INF
	var _penalty := {}
	var _cost := PackedFloat32Array()
	var _came := PackedInt32Array()
	var _came_a := PackedInt32Array()
	var _came_b := PackedInt32Array()
	var _entry := PackedVector3Array()
	var _closed := PackedByteArray()
	var _heap_cost := PackedFloat32Array()
	var _heap_poly := PackedInt32Array()

	func _init(map: RID, from: Vector3, goal: Vector3, rejected: Array[PackedVector3Array], max_searches: int, distinct_distance: float) -> void:
		_map = map
		_from = from
		_goal = goal
		_known = rejected.duplicate()
		_max_searches = max_searches
		_distance = distinct_distance

	func step() -> int:
		match _phase:
			0:
				var built := PassageGraph.build_item(_map)
				if built == PassageGraph.UNAVAILABLE:
					return UNAVAILABLE
				if built == PassageGraph.DONE:
					_phase = 1
				return RUNNING
			1:
				_locate_item()
				return RUNNING
			2:
				if searches >= _max_searches:
					return DONE
				_start_search()
				return RUNNING
			3:
				return _expand()
		return DONE

	## Finds the polygons holding the start and the goal (or, failing that, the nearest polygon centres), a batch of
	## polygons per item.
	func _locate_item() -> void:
		var polys := PassageGraph._polys
		var end := mini(_locate_at + PassageGraph.POLYGONS_PER_ITEM, polys.size())
		for p in range(_locate_at, end):
			var start_score := _score(p, _from)
			if start_score < _start_best:
				_start_best = start_score
				_start_poly = p
			var goal_score := _score(p, _goal)
			if goal_score < _goal_best:
				_goal_best = goal_score
				_goal_poly = p
		_locate_at = end
		if _locate_at >= polys.size():
			_phase = 2

	## -1 when the point lies inside the polygon (in plan view), otherwise the distance to its centre.
	func _score(p: int, point: Vector3) -> float:
		var poly: PackedInt32Array = PassageGraph._polys[p]
		var verts := PassageGraph._verts
		var positive := 0
		var negative := 0
		for k in poly.size():
			var a := verts[poly[k]]
			var b := verts[poly[(k + 1) % poly.size()]]
			var cross := (b.x - a.x) * (point.z - a.z) - (b.z - a.z) * (point.x - a.x)
			if cross > 0.01:
				positive += 1
			elif cross < -0.01:
				negative += 1
		if positive == 0 or negative == 0:
			return -1.0
		var centre := PassageGraph._centres[p]
		return Vector2(centre.x - point.x, centre.z - point.z).length()

	func _start_search() -> void:
		var n := PassageGraph._polys.size()
		_cost.resize(n)
		_cost.fill(INF)
		_came.resize(n)
		_came.fill(-1)
		_came_a.resize(n)
		_came_b.resize(n)
		_entry.resize(n)
		_closed.resize(n)
		_closed.fill(0)
		_heap_cost = PackedFloat32Array()
		_heap_poly = PackedInt32Array()
		_cost[_start_poly] = 0.0
		_entry[_start_poly] = _from
		_push(RouteGuidance.planar(_goal - _from).length(), _start_poly)
		searches += 1
		_phase = 3

	## One A* expansion; at the goal, the funnel, the portal penalty and the distinct-passage test.
	func _expand() -> int:
		while not _heap_poly.is_empty():
			var current := _pop()
			if _closed[current] == 1:
				continue
			_closed[current] = 1
			expansions += 1
			if current == _goal_poly:
				return _finish_search()
			var verts := PassageGraph._verts
			for edge in PassageGraph._adj[current]:
				var next: int = edge.x
				if _closed[next] == 1:
					continue
				var middle := (verts[edge.y] + verts[edge.z]) * 0.5
				var key := Vector2i(mini(edge.y, edge.z), maxi(edge.y, edge.z))
				var cost := _cost[current] + RouteGuidance.planar(middle - _entry[current]).length() * float(_penalty.get(key, 1.0))
				if cost < _cost[next]:
					_cost[next] = cost
					_came[next] = current
					_came_a[next] = edge.y
					_came_b[next] = edge.z
					_entry[next] = middle
					_push(cost + RouteGuidance.planar(_goal - middle).length(), next)
			return RUNNING
		return DONE

	func _finish_search() -> int:
		var portals: Array[Vector2i] = []
		var current := _goal_poly
		while current != _start_poly:
			portals.push_front(Vector2i(_came_a[current], _came_b[current]))
			current = _came[current]
		for portal in portals:
			var key := Vector2i(mini(portal.x, portal.y), maxi(portal.x, portal.y))
			_penalty[key] = float(_penalty.get(key, 1.0)) * PassageGraph.PORTAL_PENALTY
		_phase = 2
		var found := _funnel(portals)
		if PassageGraph.same_passage(found, _known, _distance):
			return RUNNING
		_known.push_back(found)
		route = found
		return FOUND

	## Simple stupid funnel over the portal sequence: the shortest polyline through the portals.
	func _funnel(portals: Array[Vector2i]) -> PackedVector3Array:
		var verts := PassageGraph._verts
		var lefts: Array[Vector3] = [_from]
		var rights: Array[Vector3] = [_from]
		var previous := _from
		for portal in portals:
			var a := verts[portal.x]
			var b := verts[portal.y]
			if _area(previous, a, b) > 0.0:
				lefts.push_back(a)
				rights.push_back(b)
			else:
				lefts.push_back(b)
				rights.push_back(a)
			previous = (a + b) * 0.5
		lefts.push_back(_goal)
		rights.push_back(_goal)
		var path := PackedVector3Array([_from])
		var apex := _from
		var left := _from
		var right := _from
		var left_index := 0
		var right_index := 0
		var i := 1
		while i < lefts.size():
			var next_left := lefts[i]
			var next_right := rights[i]
			if _area(apex, right, next_right) <= 0.0:
				if apex.is_equal_approx(right) or _area(apex, left, next_right) > 0.0:
					right = next_right
					right_index = i
				else:
					path.push_back(left)
					apex = left
					right_index = left_index
					right = apex
					i = left_index + 1
					continue
			if _area(apex, left, next_left) >= 0.0:
				if apex.is_equal_approx(left) or _area(apex, right, next_left) < 0.0:
					left = next_left
					left_index = i
				else:
					path.push_back(right)
					apex = right
					left_index = right_index
					left = apex
					i = right_index + 1
					continue
			i += 1
		if not path[path.size() - 1].is_equal_approx(_goal):
			path.push_back(_goal)
		for k in path.size():
			path[k].y = _from.y
		return path

	static func _area(a: Vector3, b: Vector3, c: Vector3) -> float:
		return (c.x - a.x) * (b.z - a.z) - (b.x - a.x) * (c.z - a.z)

	func _push(cost: float, poly: int) -> void:
		_heap_cost.push_back(cost)
		_heap_poly.push_back(poly)
		var i := _heap_cost.size() - 1
		while i > 0:
			var parent := (i - 1) / 2
			if _heap_cost[parent] <= _heap_cost[i]:
				break
			_swap(i, parent)
			i = parent

	func _pop() -> int:
		var top := _heap_poly[0]
		var last := _heap_cost.size() - 1
		_swap(0, last)
		_heap_cost.resize(last)
		_heap_poly.resize(last)
		var i := 0
		while true:
			var smallest := i
			var l := 2 * i + 1
			var r := l + 1
			if l < last and _heap_cost[l] < _heap_cost[smallest]:
				smallest = l
			if r < last and _heap_cost[r] < _heap_cost[smallest]:
				smallest = r
			if smallest == i:
				break
			_swap(i, smallest)
			i = smallest
		return top

	func _swap(i: int, j: int) -> void:
		var cost := _heap_cost[i]
		_heap_cost[i] = _heap_cost[j]
		_heap_cost[j] = cost
		var poly := _heap_poly[i]
		_heap_poly[i] = _heap_poly[j]
		_heap_poly[j] = poly
