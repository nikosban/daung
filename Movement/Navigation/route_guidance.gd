class_name RouteGuidance
extends RefCounted
## Navigation plans as data, and the per-tick guidance that turns a plan into pilot targets (Task #46). Used the same
## way by the real physics tick (ShipMovement) and by prediction (ManeuverRollout), so both fly identical guidance.

enum Kind { DIRECT, ROUTE, DEPART }

## Two times closer than this count as equal (float summation of physics deltas).
const TIME_EPSILON := 1e-6


## A plan handed to the pilot: data only.
class Plan:
	var kind := Kind.DIRECT
	## Arrival point (the original click; Y at the ship).
	var destination := Vector3.ZERO
	## Route from the ship (index 0) to the destination, Y at the ship, and cumulative lengths.
	var route := PackedVector3Array()
	var lengths := PackedFloat32Array()
	var lookahead := 10.0
	## Per route point: the radius guidance traces through that corner (0 = no bend, the end points).
	var corner_radii := PackedFloat32Array()
	## Per interior route point: the sum of the incoming and outgoing unit directions (its bisector normal).
	var bisectors := PackedVector3Array()
	## Direct order course (radians).
	var has_course := false
	var course_yaw := 0.0
	## Departure: world direction (zero = braking), the yaw it starts at (kept: no commanded turning) and the time
	## after handoff at which route guidance takes over (s).
	var depart_direction := Vector3.ZERO
	var hold_yaw := 0.0
	var switch_time := 0.0

	func total_length() -> float:
		return lengths[lengths.size() - 1]


## Progress along a plan; advanced by guide() each tick (real flight and prediction alike). The caller adds each
## tick's delta to time after the pilot step.
class Follow:
	var index := 1
	## Task 28 scratch (#59): where the ship was when it began following the plan; a direct plan's path runs from here
	## to the destination.
	var start := Vector3.ZERO
	## Time since handoff (s).
	var time := 0.0
	var switched := false
	## Arc length of the ship's projection on the route (m) and that projected point.
	var s := 0.0
	var point := Vector3.ZERO


## A plan of the given kind over a route (lengths, corner radii and bisectors precomputed).
static func make_plan(kind: int, route: PackedVector3Array, destination: Vector3, lookahead: float) -> Plan:
	var plan := Plan.new()
	plan.kind = kind
	plan.destination = destination
	plan.route = route
	plan.lookahead = lookahead
	plan.lengths.push_back(0.0)
	for k in range(1, route.size()):
		plan.lengths.push_back(plan.lengths[k - 1] + planar(route[k] - route[k - 1]).length())
	# Corner radius: the tighter of an isolated corner rounded by the lookahead aim, lookahead / (2 sin(turn / 2)),
	# and the arc through the corner's neighbouring segments, (incoming + outgoing length) / (2 turn), which governs a
	# chain of small corners such as a navigation mesh's polygon around an obstacle.
	plan.corner_radii.resize(route.size())
	plan.corner_radii.fill(0.0)
	plan.bisectors.resize(route.size())
	plan.bisectors.fill(Vector3.ZERO)
	for j in range(1, route.size() - 1):
		var a := planar(route[j] - route[j - 1])
		var b := planar(route[j + 1] - route[j])
		plan.bisectors[j] = a.normalized() + b.normalized()
		var turn := acos(clampf(a.normalized().dot(b.normalized()), -1.0, 1.0))
		if turn >= 0.001:
			plan.corner_radii[j] = minf(plan.lookahead / (2.0 * sin(turn * 0.5)), (a.length() + b.length()) / (2.0 * turn))
	return plan


## Task 28 scratch (#59): fresh progress for a plan the ship begins to follow at this position (real flight and
## prediction alike).
static func start_follow(plan: Plan, position: Vector3) -> Follow:
	var follow := Follow.new()
	follow.start = planar(position)
	track(plan, follow, position)
	return follow


## Task 28 scratch (#59): the pursuit lookahead (m) at a planar speed: pursuit_lookahead_hull_lengths hull lengths plus
## the straight-line stopping distance with the profile's actual sternward braking (the retro cap without retro
## thrusters).
static func pursuit_lookahead(profile: MovementProfile, hull_length: float, speed: float) -> float:
	var thruster_limit := profile.thruster_strength / profile.mass
	var stopping := minf(thruster_limit, ShipPilot.sternward_limit_of(profile, thruster_limit))
	return profile.pursuit_lookahead_hull_lengths * hull_length + speed * speed / (2.0 * stopping)


## Task 28 scratch (#59): the pure-pursuit bearing (unit planar direction, zero if none). The ship's projection on the
## path (a direct plan: from follow.start to the destination; otherwise the route) is advanced by the lookahead and the
## bow aims at that point; once it reaches the path's end, the bow takes the final segment's direction, so the bearing
## never flips back toward the destination point.
static func pursuit_bearing(plan: Plan, follow: Follow, position: Vector3, lookahead: float) -> Vector3:
	if plan.kind == Kind.DIRECT:
		var segment := planar(plan.destination - follow.start)
		var length := segment.length()
		if length <= 0.0:
			return Vector3.ZERO
		var along := segment / length
		var s := clampf(planar(position - follow.start).dot(along), 0.0, length)
		if s + lookahead >= length:
			return along
		var to_point := planar(follow.start + along * (s + lookahead) - position)
		return to_point.normalized() if to_point.length_squared() > 0.0 else along
	var total := plan.total_length()
	var n := plan.route.size()
	var last := planar(plan.route[n - 1] - plan.route[n - 2]).normalized()
	if follow.s + lookahead >= total:
		return last
	var to_aim := planar(point_from(plan, follow.index, follow.s + lookahead) - position)
	return to_aim.normalized() if to_aim.length_squared() > 0.0 else last


## Fills the pilot targets for this tick from a plan and the ship's planar position and yaw, advancing the follow
## state. Task 28 scratch (#59): the course is the pure-pursuit bearing for a lookahead of pursuit metres.
static func guide(plan: Plan, follow: Follow, position: Vector3, _yaw: float, pursuit: float, targets: ShipPilot.Targets) -> void:
	targets.destination = plan.destination
	targets.bend_lengths = plan.lengths
	targets.bend_radii = plan.corner_radii
	targets.bend_from = plan.route.size()
	track(plan, follow, position)
	if plan.kind == Kind.DIRECT:
		var bearing := pursuit_bearing(plan, follow, position, pursuit)
		targets.use_steer = false
		targets.has_course = bearing != Vector3.ZERO
		targets.course_yaw = atan2(-bearing.x, -bearing.z)
		return
	var total := plan.total_length()
	var remaining := planar(position - follow.point).length() + (total - follow.s)
	if plan.kind == Kind.DEPART and not follow.switched:
		if follow.time >= plan.switch_time - TIME_EPSILON:
			follow.switched = true
		else:
			# No commanded course: rotation stops at once without powered turning (Movement v3), so the hull keeps its
			# heading and the whole thruster capacity goes to braking or translating.
			targets.use_steer = true
			targets.steer_direction = plan.depart_direction
			targets.steer_distance = remaining
			targets.has_course = false
			targets.course_yaw = plan.hold_yaw
			return
	# Task 28 scratch (#59): the bow follows the pure-pursuit bearing; the desired velocity still steers at the plan's
	# own (navigation) lookahead point and, once that reaches the destination, flies the ordinary direct arrival.
	var bearing := pursuit_bearing(plan, follow, position, pursuit)
	targets.has_course = bearing != Vector3.ZERO
	targets.course_yaw = atan2(-bearing.x, -bearing.z)
	var aim_s := follow.s + plan.lookahead
	var aim := point_from(plan, follow.index, minf(aim_s, total))
	var to_aim := planar(aim - position)
	if aim_s >= total:
		targets.use_steer = false
		return
	targets.use_steer = true
	targets.steer_direction = to_aim.normalized() if to_aim.length_squared() > 0.0 else Vector3.ZERO
	targets.steer_distance = remaining
	# Upcoming interior route corners (the pilot caps the speed for each).
	targets.bend_from = follow.index
	targets.bend_s = follow.s


## Advances the corner index past every corner whose bisector the ship has crossed, then projects the ship on the
## current segment to update the arc length.
static func track(plan: Plan, follow: Follow, position: Vector3) -> void:
	var route := plan.route
	var n := route.size()
	while follow.index < n - 1 and planar(position - route[follow.index]).dot(plan.bisectors[follow.index]) >= 0.0:
		follow.index += 1
	var p0 := route[follow.index - 1]
	var segment := planar(route[follow.index] - p0)
	var length := plan.lengths[follow.index] - plan.lengths[follow.index - 1]
	var t := 0.0
	if length > 0.0:
		t = clampf(planar(position - p0).dot(segment) / (length * length), 0.0, 1.0)
	follow.s = plan.lengths[follow.index - 1] + t * length
	follow.point = p0 + segment * t


## The route point at arc length s.
static func point_at(plan: Plan, s: float) -> Vector3:
	return point_from(plan, 1, s)


## The route point at arc length s, searching from route index first (s at or beyond that segment's start).
static func point_from(plan: Plan, first: int, s: float) -> Vector3:
	var route := plan.route
	for j in range(first, route.size()):
		if s <= plan.lengths[j] or j == route.size() - 1:
			var length := plan.lengths[j] - plan.lengths[j - 1]
			var t := 0.0 if length <= 0.0 else clampf((s - plan.lengths[j - 1]) / length, 0.0, 1.0)
			return route[j - 1].lerp(route[j], t)
	return route[route.size() - 1]


static func planar(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)
