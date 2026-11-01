class_name StaticNavigation
extends Node

## Scene-owned static navigation: one navigation map per NavigationClearance,
## shared by every ship in this scene with that clearance. A map is created
## and activated when its first ClearanceRegion child registers, and freed
## when this node leaves the tree (after its child regions have detached).

## Floating-point noise allowed when comparing planar positions on the mesh.
## Not a tuning value.
const PLANAR_EPSILON := 0.001

var _maps := {}  # NavigationClearance -> RID
var _regions := {}  # NavigationClearance -> Array[ClearanceRegion]


func _exit_tree() -> void:
	for map: RID in _maps.values():
		NavigationServer3D.free_rid(map)
	_maps.clear()
	_regions.clear()


func register_region(region: ClearanceRegion) -> void:
	var map: RID = _maps.get(region.clearance, RID())
	if not map.is_valid():
		map = NavigationServer3D.map_create()
		NavigationServer3D.map_set_cell_size(map, region.navigation_mesh.cell_size)
		NavigationServer3D.map_set_cell_height(map, region.navigation_mesh.cell_height)
		NavigationServer3D.map_set_active(map, true)
		_maps[region.clearance] = map
		_regions[region.clearance] = []
	region.set_navigation_map(map)
	_regions[region.clearance].append(region)


## True once the map has synchronized with every region's polygons. Regions
## build asynchronously, so a synchronized map can still lack them; each
## region is checked by asking the map who owns the centre of one of its own
## polygons (an interior point, so a neighbouring region sharing an edge or
## vertex cannot answer instead). Only polled while a route request is pending.
func is_ready(clearance: NavigationClearance) -> bool:
	var map: RID = _maps.get(clearance, RID())
	if not map.is_valid() or NavigationServer3D.map_get_iteration_id(map) == 0:
		return false
	for region: ClearanceRegion in _regions[clearance]:
		var navigation_mesh := region.navigation_mesh
		if navigation_mesh.get_polygon_count() == 0:
			return false
		var vertices := navigation_mesh.get_vertices()
		var centre := Vector3.ZERO
		var polygon := navigation_mesh.get_polygon(0)
		for index in polygon:
			centre += vertices[index]
		centre /= polygon.size()
		var probe := region.global_transform * centre
		if NavigationServer3D.map_get_closest_point_owner(map, probe) != region.get_rid():
			return false
	return true


## Returns a route ending exactly at goal, or an empty array if the goal is
## unreachable for this clearance. All checks are planar (XZ).
func find_route(clearance: NavigationClearance, from: Vector3, goal: Vector3) -> PackedVector3Array:
	var map: RID = _maps[clearance]
	# The exact goal must lie on this clearance's navmesh (its closest mesh
	# point is directly below it); otherwise it is inside the berth around an
	# obstacle, however close to the edge.
	var closest := NavigationServer3D.map_get_closest_point(map, goal)
	if _planar_distance(closest, goal) > PLANAR_EPSILON:
		return PackedVector3Array()
	# The path must end at the goal itself. Godot may end it at the nearest
	# reachable point instead (another island); that is a failure, never a
	# substitute destination.
	var path := NavigationServer3D.map_get_path(map, from, goal, true)
	if path.is_empty() or _planar_distance(path[path.size() - 1], goal) > PLANAR_EPSILON:
		return PackedVector3Array()
	# Same planar point; only the height changes from the mesh to the ship plane.
	path[path.size() - 1] = goal
	return path


func _planar_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
