class_name RoutePlanner
extends RefCounted
## The route half of one planning job (Task #46): navigation readiness, destination classification, one Godot
## navigation path and route cleanup. Physical feasibility is checked locally from actual movement (#60).
## Resumable: run() does one small item at a time while its PlanClock allows and continues on a later call.
##
## Readiness: map inactive or iteration 0, or an enabled region with region iteration 0: wait (no path query). No
## enabled region once the map has synced: navigation unavailable. Regions synced but no polygon merged yet: wait
## while the map iteration still changes; after MERGE_WAIT_FRAMES frames without change, unavailable.
##
## Destination resolution (Task #54): a click inside the bounds that is off the mesh (a no-go zone) or that the path
## cannot reach is replaced by the nearest candidate found by a bounded local search; a valid click skips it entirely.
## Candidates are kept in one queue sorted by planar distance from the click: the nearest navigable point to the click,
## the end of every failed candidate path (Godot's nearest reachable point to that candidate), and probe points on
## rings of RING_DIRECTIONS around the click (radius step x 2^(k - 1), step = hull reach + clearance buffer; alternate
## rings turned by half a direction), each projected onto the mesh. A ring point is generated, one per work item, only
## while the queue is empty or its nearest candidate is not nearer than that ring's radius (less one cell); rings stop
## after the first one whose radius covers the enabled regions' bounds. A point that projected more than one cell is
## moved onto the mesh by the arrival allowance A along the projection; points within one cell of an earlier one are
## dropped. Each candidate is tested nearest first: the arrival allowance (the point and RING_DIRECTIONS points at A
## around it within no_go_tolerance of the mesh, and a cylinder of hull reach + clearance buffer + A free), then, as its
## own item, one path query from the ship (counted against NavigationBudget.destination_candidates_per_order). The
## first candidate the path reaches becomes the destination. A = arrival_tolerance + arrival_speed_tolerance^2 /
## (2 a_min) bounds where a resolved order comes to rest; a_min is the weakest planned braking (a_t / 2, or the
## no-retro cap). The search never claims a destination is unreachable: it ends "search exhausted" (path tests used
## up) or "no destination found in bounded search" (queue empty at the horizon).
##
## Destination limit and reservations (Task 37, #78): with NavigationBudget.max_destination_displacement above 0, the
## horizon and every ring radius are capped at the limit (the last ring lies on it) and candidates farther than the
## limit from the click are rejected. A click inside another ship's area (EndpointReservations) starts resolution; a
## path test only succeeds, and an arrival check only passes, where this ship's area overlaps no other ship's.

enum { RUNNING, BASELINE, DECLINED, ROUTE }
enum Step { SYNC, CLASSIFY, PATH, RESOLVE }

## Physics frames that may pass with an unchanged map iteration while enabled regions report synced but no polygon
## is merged yet, before navigation counts as unavailable. Godot merges a region in the map sync after the one in
## which the region itself synced (observed: frame 3 region synced, frame 4 merge, path from frame 5).
const MERGE_WAIT_FRAMES := 2
## Route points closer than this are duplicates (m).
const DUPLICATE_DISTANCE := 0.01
## Probe directions per resolution ring and points on the arrival-allowance circle (search shape, not tuning).
const RING_DIRECTIONS := 8

## Outcome once run() stops returning RUNNING; note explains BASELINE and DECLINED.
var result := RUNNING
var note := ""
## The destination the route leads to: the click, or the resolved candidate (Task #54).
var destination := Vector3.ZERO
## Destination resolution (Task #54): whether the click was replaced, a short summary, every tested candidate with its
## outcome, and the query counts (closest-point queries include the route's on-mesh leg checks).
var resolved := false
var resolution := ""
var resolution_log := PackedStringArray()
var closest_queries := 0
var path_queries := 0
## Usable route guidance; never a full-flight approval.
var route_plan: RouteGuidance.Plan
var primary_plan: RouteGuidance.Plan
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
var _path_limit := 1
var _candidates: Array[Dictionary] = []
var _seen := PackedVector3Array()
var _awaiting: Dictionary = {}
var _ring := 1
var _ring_point := 0
var _ring_step := 0.0
var _horizon := 0.0
var _allowance := 0.0
var _tested := 0
var _path_tests := 0
var _keep_destination := false
var _ship: ShipMovement
## Destination limit (m); 0 = none.
var _limit := 0.0


func _init(ship: ShipMovement, map: RID, probe: HullProbe, profile: MovementProfile, click: Vector3, live_state: Callable, path_limit: int, limit: float, keep_destination := false) -> void:
	_ship = ship
	_limit = limit
	_map = map
	_probe = probe
	_profile = profile
	_click = click
	destination = click
	_live_state = live_state
	_path_limit = path_limit
	_keep_destination = keep_destination


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
			Step.RESOLVE:
				_resolve_item()
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


## Clicks outside every enabled region's bounds keep the direct order (baseline). A click inside them but more than
## one cell off the mesh lies in a static no-go zone (an obstacle's baked exclusion) and is resolved (Task #54),
## starting from the nearest navigable point.
func _classify() -> void:
	if _keep_destination:
		# One current-state path refresh, never a new destination search for the existing order.
		_step = Step.PATH
		return
	var inside := false
	for region in _enabled_regions():
		var bounds := NavigationServer3D.region_get_bounds(region)
		if _click.x >= bounds.position.x and _click.x <= bounds.end.x and _click.z >= bounds.position.z and _click.z <= bounds.end.z:
			inside = true
			break
	if not inside:
		_baseline("destination outside the navigable area: direct (baseline)")
		return
	var nearest := _closest(_click)
	var off_mesh := RouteGuidance.planar(nearest - _click).length()
	if off_mesh > _cell:
		_start_resolution("inside a no-go zone, %.2f m off the navigation mesh" % off_mesh)
		_add_candidate(_click, nearest, "nearest navigable point")
		return
	var conflict := EndpointReservations.conflict(_ship, _click, true)
	if conflict != "":
		_start_resolution(conflict)
		return
	_step = Step.PATH


## One path query to the click. The path must reach the click, or end where a straight on-mesh leg reaches it
## (_leg_on_mesh()); otherwise the click is resolved (Task #54), starting from the path's end.
func _path() -> void:
	var position: Vector3 = (_live_state.call() as ShipPilot.State).position
	var path := _query_path(position, _click)
	if not path.is_empty() and _leg_on_mesh(path[path.size() - 1], _click):
		var conflict := "" if _keep_destination else EndpointReservations.conflict(_ship, _click, false)
		if conflict == "":
			_build_route(path, position)
		else:
			_start_resolution(conflict)
		return
	if _keep_destination:
		_decline_search("ordinary path refresh does not reach the retained destination")
		return
	if path.is_empty():
		_start_resolution("no path from the ship")
		return
	var end := path[path.size() - 1]
	_start_resolution("unreachable from the ship (path ends at (%.2f, %.2f))" % [end.x, end.z])
	_add_candidate(_click, end, "path end")


## The route: the ship, the path's corners, the destination; Y at the ship. The path starts at the mesh point nearest
## the ship (within one cell that is the ship itself); duplicates and corners within one cell of the line between
## their neighbours (polygon-edge crossings) are dropped.
func _build_route(path: PackedVector3Array, position: Vector3) -> void:
	var target := destination
	var route := PackedVector3Array([position])
	for k in path.size():
		var point := Vector3(path[k].x, position.y, path[k].z)
		if k == path.size() - 1:
			point = target
		elif k == 0 and RouteGuidance.planar(point - position).length() <= _cell:
			continue
		if RouteGuidance.planar(point - route[route.size() - 1]).length() > DUPLICATE_DISTANCE:
			route.push_back(point)
	if route.size() == 1:
		route.push_back(target)
	route[route.size() - 1] = target
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
	route_plan = RouteGuidance.make_plan(RouteGuidance.Kind.ROUTE, route, target, _profile.detour_lookahead_distance)
	primary_plan = route_plan
	if route.size() == 2:
		primary_plan = RouteGuidance.make_plan(RouteGuidance.Kind.DIRECT, route, target, _profile.detour_lookahead_distance)
		var course := RouteGuidance.planar(target - position)
		primary_plan.has_course = course != Vector3.ZERO
		if primary_plan.has_course:
			primary_plan.course_yaw = atan2(-course.x, -course.z)
	# The path is guidance, not a full-flight feasibility result. Local clearance uses the actual ship each tick.
	result = ROUTE


## Whether the straight leg from the path's end to the target stays on the mesh (every point within one cell of it,
## sampled every cell). The target is on the mesh; Godot can end a path short of an on-mesh target (observed:
## (97.43, −12.02) for a click on (98, −12)), and the route then ends with this leg to the target.
func _leg_on_mesh(from: Vector3, to: Vector3) -> bool:
	var leg := RouteGuidance.planar(to - from)
	var samples := int(ceil(leg.length() / _cell))
	for i in range(1, samples + 1):
		var point := from + leg * (float(i) / samples)
		if RouteGuidance.planar(_closest(point) - point).length() > _cell:
			return false
	return true


## Starts destination resolution (Task #54): the arrival allowance, the ring step and the search horizon (the farthest
## corner of the enabled regions' bounds from the click).
func _start_resolution(reason: String) -> void:
	resolution_log.push_back("click (%.2f, %.2f): %s" % [_click.x, _click.z, reason])
	_allowance = arrival_allowance_of(_profile)
	_ring_step = _probe.reach + _profile.plan_clearance_buffer
	var click := Vector2(_click.x, _click.z)
	for region in _enabled_regions():
		var bounds := NavigationServer3D.region_get_bounds(region)
		for corner in [Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.end.x, bounds.position.z), Vector2(bounds.position.x, bounds.end.z), Vector2(bounds.end.x, bounds.end.z)]:
			_horizon = maxf(_horizon, (corner - click).length())
	if _limit > 0.0:
		_horizon = minf(_horizon, _limit)
	_seen.push_back(_click)
	_step = Step.RESOLVE


## One resolution work item: the path test of the candidate that passed its arrival check, one ring point, or the
## arrival check of the nearest candidate.
func _resolve_item() -> void:
	if not _awaiting.is_empty():
		var awaiting := _awaiting
		_awaiting = {}
		_path_test(awaiting)
		return
	var radius := _ring_radius(_ring)
	var previous := _ring_radius(_ring - 1)
	var can_generate := _ring == 1 or (previous <= _horizon and not (_limit > 0.0 and previous >= _limit))
	# Finish the ring before testing anything at its radius or beyond (an unmoved ring point lies exactly on it, within
	# float noise; one cell absorbs that).
	if can_generate and (_candidates.is_empty() or _candidates[0].distance >= radius - _cell):
		var angle := TAU * _ring_point / RING_DIRECTIONS + (PI / RING_DIRECTIONS if _ring % 2 == 0 else 0.0)
		var probe := _click + Vector3(sin(angle), 0.0, -cos(angle)) * radius
		_add_candidate(probe, _closest(probe), "ring %d" % _ring)
		_ring_point += 1
		if _ring_point == RING_DIRECTIONS:
			_ring_point = 0
			_ring += 1
		return
	if _candidates.is_empty():
		if _limit > 0.0 and _horizon >= _limit:
			_decline_search("no destination found within the %.0f m destination limit (%d candidates rejected)" % [_limit, _tested])
		else:
			_decline_search("no destination found in bounded search (horizon %.0f m reached, %d candidates rejected)" % [_horizon, _tested])
		return
	var candidate: Dictionary = _candidates.pop_front()
	_tested += 1
	if _limit > 0.0 and candidate.distance > _limit + DUPLICATE_DISTANCE:
		_reject(candidate, "beyond the destination limit (%.0f m)" % _limit)
		return
	var reason := _arrival_check(candidate.position)
	if reason != "":
		_reject(candidate, reason)
		return
	if _path_tests >= _path_limit:
		_decline_search("destination search exhausted (%d path tests used, %d candidates untested)" % [_path_tests, _candidates.size() + 1])
		return
	_awaiting = candidate


## Arrival allowance and hull fit at a candidate: "" when it passes, otherwise the reason.
func _arrival_check(point: Vector3) -> String:
	for i in RING_DIRECTIONS + 1:
		var sample := point
		if i > 0:
			var angle := TAU * (i - 1) / RING_DIRECTIONS
			sample = point + Vector3(sin(angle), 0.0, -cos(angle)) * _allowance
		var beyond := RouteGuidance.planar(_closest(sample) - sample).length()
		if beyond > _profile.no_go_tolerance:
			return "no arrival allowance (%.2f m beyond the mesh at (%.2f, %.2f))" % [beyond, sample.x, sample.z]
	if not _probe.cylinder_clear(point, _probe.reach + _profile.plan_clearance_buffer + _allowance):
		return "hull does not fit"
	return EndpointReservations.conflict(_ship, point, false)


## One path query from the ship to the candidate: the route when the path reaches it; otherwise the path's end becomes
## another candidate.
func _path_test(candidate: Dictionary) -> void:
	_path_tests += 1
	var position: Vector3 = (_live_state.call() as ShipPilot.State).position
	var point: Vector3 = candidate.position
	var path := _query_path(position, point)
	if path.is_empty():
		_reject(candidate, "no path from the ship")
		return
	var end := path[path.size() - 1]
	if not _leg_on_mesh(end, point):
		_reject(candidate, "unreachable from the ship (path ends at (%.2f, %.2f))" % [end.x, end.z])
		_add_candidate(point, end, "path end")
		return
	# Re-checked here: another job may have reserved an overlapping endpoint since the arrival check.
	var conflict := EndpointReservations.conflict(_ship, point, false)
	if conflict != "":
		_reject(candidate, conflict)
		return
	resolved = true
	destination = point
	resolution = "resolved to (%.2f, %.2f), %.2f m from the click (%s; %d candidates tested, %d path tests)" % [point.x, point.z, candidate.distance, candidate.source, _tested, _path_tests]
	resolution_log.push_back("accepted (%.2f, %.2f) %.2f m, %s" % [point.x, point.z, candidate.distance, candidate.source])
	_build_route(path, position)


## Adds a candidate from a projection: moved onto the mesh by the arrival allowance when the projection moved more
## than one cell, dropped within one cell of an earlier candidate, inserted by planar distance from the click.
func _add_candidate(source: Vector3, projected: Vector3, label: String) -> void:
	var point := Vector3(projected.x, _click.y, projected.z)
	var offset := RouteGuidance.planar(point - source)
	if offset.length() > _cell:
		point += offset.normalized() * _allowance
	for seen in _seen:
		if RouteGuidance.planar(seen - point).length() <= _cell:
			return
	_seen.push_back(point)
	var distance := RouteGuidance.planar(point - _click).length()
	var index := _candidates.size()
	for i in _candidates.size():
		if _candidates[i].distance > distance:
			index = i
			break
	_candidates.insert(index, {position = point, distance = distance, source = label})


## Ring k's radius: step x 2^(k - 1), capped at the destination limit when one is set.
func _ring_radius(ring: int) -> float:
	var radius := _ring_step * pow(2.0, ring - 1)
	return minf(radius, _limit) if _limit > 0.0 else radius


func _reject(candidate: Dictionary, reason: String) -> void:
	resolution_log.push_back("(%.2f, %.2f) %.2f m, %s: %s" % [candidate.position.x, candidate.position.z, candidate.distance, candidate.source, reason])


func _decline_search(reason: String) -> void:
	result = DECLINED
	note = "%s; %d closest-point, %d path, %d physics queries" % [reason, closest_queries, path_queries, _probe.queries]


func _closest(point: Vector3) -> Vector3:
	closest_queries += 1
	return NavigationServer3D.map_get_closest_point(_map, point)


func _query_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	path_queries += 1
	return NavigationServer3D.map_get_path(_map, from, to, true)


func _baseline(reason: String) -> void:
	result = BASELINE
	note = reason


## Arrival allowance (Task #54, m): an order completes within arrival_tolerance at most arrival_speed_tolerance and
## then only brakes, at least at the weakest planned braking (half the thruster rating at full turning share, or the
## no-retro sternward cap when that is lower), so it comes to rest within this distance of its destination.
static func arrival_allowance_of(profile: MovementProfile) -> float:
	var thrusters := profile.thruster_strength / profile.mass
	var braking := thrusters * 0.5
	if not profile.retro_thrusters:
		braking = minf(braking, profile.no_retro_braking_effectiveness * thrusters)
	return profile.arrival_tolerance + profile.arrival_speed_tolerance * profile.arrival_speed_tolerance / (2.0 * braking)
