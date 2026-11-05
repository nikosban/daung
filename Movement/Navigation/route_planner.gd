class_name RoutePlanner
extends RefCounted
## The route half of one planning job (Task #46): navigation readiness, destination classification, one Godot
## navigation path, route cleanup, hazard regions and, for a moving ship without hazards, the drift corridor.
## Resumable: run() does one small item at a time while its PlanClock allows and continues on a later call.
##
## Readiness: map inactive or iteration 0, or an enabled region with region iteration 0: wait (no path query). No
## enabled region once the map has synced: navigation unavailable. Regions synced but no polygon merged yet: wait
## while the map iteration still changes; after MERGE_WAIT_FRAMES frames without change, unavailable.
##
## Hazard regions: route samples every hull half-width where a cylinder of radius hull reach + clearance buffer is not
## empty (the hull could touch something there at some yaw), each with a lead-in of the stopping distance at max
## speed; regions closer than that merge. The start (departure) and end (final approach) samples are included.

enum { RUNNING, BASELINE, UNREACHABLE, ROUTE }
enum Step { SYNC, CLASSIFY, PATH, HAZARDS, DRIFT }

## Physics frames that may pass with an unchanged map iteration while enabled regions report synced but no polygon
## is merged yet, before navigation counts as unavailable. Godot merges a region in the map sync after the one in
## which the region itself synced (observed: frame 3 region synced, frame 4 merge, path from frame 5).
const MERGE_WAIT_FRAMES := 2
## Route points closer than this are duplicates (m).
const DUPLICATE_DISTANCE := 0.01

## Outcome once run() stops returning RUNNING; note explains BASELINE and UNREACHABLE.
var result := RUNNING
var note := ""
## For ROUTE: the route plan, the direct-or-route plan the pilot flies when nothing needs predicting, the hazard
## regions (arc-length intervals, m), whether the last one is the final approach, and whether prediction is needed.
var route_plan: RouteGuidance.Plan
var primary_plan: RouteGuidance.Plan
var regions: Array[Vector2] = []
var final_hazard := false
var needs_prediction := true
var hazard_text := ""
## Whether run() is only waiting for navigation to sync (no work done; the job may yield to others).
var waiting := false

var _map: RID
var _probe: HullProbe
var _profile: MovementProfile
var _click := Vector3.ZERO
var _live_state: Callable
var _step := Step.SYNC
var _cell := 0.25
var _merge_iteration := -1
var _merge_frame := -1
var _samples := PackedFloat32Array()
var _sample := 0
var _corridor: CorridorScan


func _init(map: RID, probe: HullProbe, profile: MovementProfile, click: Vector3, live_state: Callable) -> void:
	_map = map
	_probe = probe
	_profile = profile
	_click = click
	_live_state = live_state


func run(clock: PlanClock) -> int:
	waiting = false
	while result == RUNNING:
		if _step == Step.SYNC:
			if not _sync():
				waiting = result == RUNNING
				return result
			continue
		if not clock.has_time():
			return RUNNING
		match _step:
			Step.CLASSIFY:
				_classify()
			Step.PATH:
				_path()
			Step.HAZARDS:
				_hazard_sample()
			Step.DRIFT:
				_drift_sample()
		clock.item_done()
	return result


## Readiness; true once ready (step moves on) or decided unavailable (result set).
func _sync() -> bool:
	var iteration := NavigationServer3D.map_get_iteration_id(_map)
	if not NavigationServer3D.map_is_active(_map) or iteration == 0:
		return false
	var enabled := _enabled_regions()
	if enabled.is_empty():
		_baseline("navigation unavailable (no enabled navigation region)")
		return true
	for region in enabled:
		if NavigationServer3D.region_get_iteration_id(region) == 0:
			return false
	if NavigationServer3D.map_get_closest_point_owner(_map, _click).is_valid():
		_cell = NavigationServer3D.map_get_cell_size(_map)
		_step = Step.CLASSIFY
		return true
	# Regions synced but nothing merged yet: wait for the merge, but not for a map that no longer changes.
	var frame := Engine.get_physics_frames()
	if iteration != _merge_iteration:
		_merge_iteration = iteration
		_merge_frame = frame
	elif frame - _merge_frame >= MERGE_WAIT_FRAMES:
		_baseline("navigation unavailable (no navigation polygons)")
		return true
	return false


func _enabled_regions() -> Array[RID]:
	var enabled: Array[RID] = []
	for region in NavigationServer3D.map_get_regions(_map):
		if NavigationServer3D.region_get_enabled(region):
			enabled.push_back(region)
	return enabled


## Clicks outside every enabled region's bounds, or more than one cell off the mesh, keep the direct order (baseline
## until destination resolution).
func _classify() -> void:
	var inside := false
	for region in _enabled_regions():
		var bounds := NavigationServer3D.region_get_bounds(region)
		if _click.x >= bounds.position.x and _click.x <= bounds.end.x and _click.z >= bounds.position.z and _click.z <= bounds.end.z:
			inside = true
			break
	if not inside:
		_baseline("destination outside the navigable area: direct (baseline)")
		return
	var off_mesh := RouteGuidance.planar(NavigationServer3D.map_get_closest_point(_map, _click) - _click).length()
	if off_mesh > _cell:
		_baseline("unresolved destination %.2f m off the navigation mesh: direct (baseline until destination resolution)" % off_mesh)
		return
	_step = Step.PATH


## One path query, then the route: the ship, the path's corners, the click; Y at the ship. The path must reach the
## click, or end where a straight on-mesh leg reaches it (_leg_on_mesh()); otherwise the click is unreachable. The path starts at the
## mesh point nearest the ship (within one cell that is the ship itself); duplicates and corners within one cell of
## the line between their neighbours (polygon-edge crossings) are dropped.
func _path() -> void:
	var position: Vector3 = (_live_state.call() as ShipPilot.State).position
	var path := NavigationServer3D.map_get_path(_map, position, _click, true)
	if path.is_empty() or not _leg_on_mesh(path[path.size() - 1], _click):
		result = UNREACHABLE
		note = "destination unreachable on the navigation mesh"
		return
	var route := PackedVector3Array([position])
	for k in path.size():
		var point := Vector3(path[k].x, position.y, path[k].z)
		if k == path.size() - 1:
			point = _click
		elif k == 0 and RouteGuidance.planar(point - position).length() <= _cell:
			continue
		if RouteGuidance.planar(point - route[route.size() - 1]).length() > DUPLICATE_DISTANCE:
			route.push_back(point)
	if route.size() == 1:
		route.push_back(_click)
	route[route.size() - 1] = _click
	var corner := 1
	while corner < route.size() - 1:
		var a := RouteGuidance.planar(route[corner - 1])
		var b := RouteGuidance.planar(route[corner + 1])
		var point := RouteGuidance.planar(route[corner])
		var along := b - a
		var t := 0.0 if along.length_squared() == 0.0 else clampf((point - a).dot(along) / along.length_squared(), 0.0, 1.0)
		if (point - (a + along * t)).length() <= _cell:
			route.remove_at(corner)
		else:
			corner += 1
	route_plan = RouteGuidance.make_plan(RouteGuidance.Kind.ROUTE, route, _click, _profile.detour_lookahead_distance)
	primary_plan = route_plan
	if route.size() == 2:
		primary_plan = RouteGuidance.make_plan(RouteGuidance.Kind.DIRECT, route, _click, _profile.detour_lookahead_distance)
		var course := RouteGuidance.planar(_click - position)
		primary_plan.has_course = course != Vector3.ZERO
		if primary_plan.has_course:
			primary_plan.course_yaw = atan2(-course.x, -course.z)
	var total := route_plan.total_length()
	var spacing := maxf(_probe.half_width, 0.5)
	var s := 0.0
	while s < total:
		_samples.push_back(s)
		s += spacing
	_samples.push_back(total)
	_step = Step.HAZARDS


## Whether the straight leg from the path's end to the click stays on the mesh (every point within one cell of it,
## sampled every cell). The click is already known to be on the mesh; Godot can end a path short of an on-mesh
## target (observed: (97.43, −12.02) for a click on (98, −12)), and the route then ends with this leg to the click.
func _leg_on_mesh(from: Vector3, to: Vector3) -> bool:
	var leg := RouteGuidance.planar(to - from)
	var samples := int(ceil(leg.length() / _cell))
	for i in range(1, samples + 1):
		var point := from + leg * (float(i) / samples)
		if RouteGuidance.planar(NavigationServer3D.map_get_closest_point(_map, point) - point).length() > _cell:
			return false
	return true


func _hazard_sample() -> void:
	var total := route_plan.total_length()
	var spacing := maxf(_probe.half_width, 0.5)
	var stop_distance := stop_distance_of(_profile)
	var k := _sample
	_sample += 1
	var point := RouteGuidance.point_at(route_plan, _samples[k])
	if not _probe.cylinder_clear(point, _probe.reach + _profile.plan_clearance_buffer):
		var start := maxf(_samples[k] - stop_distance, 0.0)
		var end := minf(_samples[k] + spacing, total)
		if k == _samples.size() - 1:
			final_hazard = true
			end = total
		if not regions.is_empty() and start - regions[regions.size() - 1].y < stop_distance:
			regions[regions.size() - 1].y = maxf(regions[regions.size() - 1].y, end)
		else:
			regions.push_back(Vector2(start, end))
	if _sample < _samples.size():
		return
	if final_hazard and not regions.is_empty():
		regions[regions.size() - 1].y = total
	var parts: Array[String] = []
	for region in regions:
		parts.push_back("%.1f–%.1f" % [region.x, region.y])
	hazard_text = "hazards [%s] of %.1f m%s" % [", ".join(parts), total, " (final approach)" if final_hazard else ""]
	if not regions.is_empty():
		result = ROUTE
		return
	# Nowhere along the route can the hull touch anything at any yaw. From rest the ship sets off along the route; a
	# moving ship needs its drift corridor empty as well.
	var state: ShipPilot.State = _live_state.call()
	var speed := RouteGuidance.planar(state.velocity).length()
	if speed <= _profile.arrival_speed_tolerance:
		needs_prediction = false
		result = ROUTE
		return
	_corridor = CorridorScan.new(route_plan, _probe, _profile, state.position, speed, 0.0)
	_step = Step.DRIFT


func _drift_sample() -> void:
	match _corridor.step():
		CorridorScan.CLEAR:
			needs_prediction = false
			result = ROUTE
		CorridorScan.BLOCKED:
			result = ROUTE


func _baseline(reason: String) -> void:
	result = BASELINE
	note = reason


## Stopping distance from max speed with the full directional-thruster braking (m).
static func stop_distance_of(profile: MovementProfile) -> float:
	return profile.max_speed * profile.max_speed / (2.0 * profile.thruster_strength / profile.mass)
