class_name RouteGuidance
extends RefCounted
## Navigation plans as data, and the per-tick guidance that turns a plan into pilot targets (Task #46). Used the same
## way by the real physics tick (ShipMovement) and by prediction (ManeuverCheck), so both fly identical guidance.

enum Kind { DIRECT, ROUTE }


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

	func total_length() -> float:
		return lengths[lengths.size() - 1]


## Progress along a plan; advanced by guide() each tick (real flight and prediction alike).
class Follow:
	var index := 1
	var frozen := false
	var frozen_course := 0.0
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


## Fills the pilot targets for this tick from a plan and the ship's planar position and yaw, advancing the follow
## state.
static func guide(plan: Plan, follow: Follow, position: Vector3, yaw: float, targets: ShipPilot.Targets) -> void:
	targets.destination = plan.destination
	targets.bend_lengths = plan.lengths
	targets.bend_radii = plan.corner_radii
	targets.bend_from = plan.route.size()
	track(plan, follow, position)
	if plan.kind == Kind.DIRECT:
		targets.use_steer = false
		targets.has_course = plan.has_course
		targets.course_yaw = plan.course_yaw
		return
	var total := plan.total_length()
	var remaining := planar(position - follow.point).length() + (total - follow.s)
	var aim_s := follow.s + plan.lookahead
	var aim := point_from(plan, follow.index, minf(aim_s, total))
	var to_aim := planar(aim - position)
	if aim_s >= total and not follow.frozen:
		# The final approach keeps the heading the hull has when it begins: no turning is left to share the thrusters
		# with the arrival braking, and arrival ends rotation anyway (no final alignment).
		follow.frozen = true
		follow.frozen_course = yaw
	if follow.frozen:
		# Final approach: the aim has reached the destination, so the pilot flies the ordinary direct arrival to it
		# (straight distance, sideways drift included) holding the heading it had when the approach began.
		targets.use_steer = false
		targets.has_course = true
		targets.course_yaw = follow.frozen_course
		return
	targets.use_steer = true
	targets.steer_direction = to_aim.normalized() if to_aim.length_squared() > 0.0 else Vector3.ZERO
	targets.steer_distance = remaining
	targets.has_course = to_aim.length_squared() > 0.0
	targets.course_yaw = atan2(-to_aim.x, -to_aim.z)
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
