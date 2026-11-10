extends SceneTree
## Headless open-space check of bow alignment (no scene, no navigation queries): drives ShipPilot.step() at 60 Hz, as
## ShipMovement and the navigator's predictions do, and compares it with the pilot at BASELINE (the orientation branch
## before bow alignment), read from Git at run time. Route following uses RouteGuidance on a hand-made polyline.
## Run from the project folder:
##   godot --headless --path . --script res://Tests/bow_alignment_test.gd
## Prints measurements and PASS/FAIL lines; exits with code 1 when any check fails.

const BASELINE := "a9af6cc"
const DELTA := 1.0 / 60.0
const PROFILE_PATH := "res://Movement/Profiles/frigate_movement_profile.tres"
const Baseline := preload("res://Tests/baseline_pilot.gd")

var _failures := 0
var _old: GDScript
var _profile: MovementProfile
## BASELINE's own frigate profile.
var _old_profile: Resource
## Test copy of the frigate profile with bow alignment unrestricted at every speed (180°); the shared profile is untouched.
var _unaligned: MovementProfile


func _init() -> void:
	_profile = load(PROFILE_PATH)
	var before := _snapshot(_profile)
	_unaligned = _profile.duplicate()
	var open := Curve.new()
	open.max_domain = 15.0
	open.max_value = 180.0
	open.add_point(Vector2(0.0, 180.0))
	_unaligned.bow_alignment_curve = open
	_old = Baseline.load_pilot(BASELINE)
	_old_profile = Baseline.load_profile(BASELINE)
	if _old == null or _old_profile == null:
		_fail("pilot or profile at %s could not be loaded" % BASELINE)
		quit(1)
		return

	_test_curve()
	_test_stationary()
	_test_straight()
	_test_cruise_turn(45.0)
	_test_cruise_turn(90.0)
	_test_cruise_turn(135.0)
	_test_stern_first()
	_test_braking_and_arrival()
	_test_turn_then_arrive()
	_test_route()

	print("\n11. Profile unchanged at run time")
	_check(_snapshot(_profile) == before, "frigate profile (every property and curve point) identical after all runs")
	print("\n%s (%d failed)" % ["ALL PASSED" if _failures == 0 else "FAILURES", _failures])
	quit(1 if _failures > 0 else 0)


# 1. The curve.
func _test_curve() -> void:
	print("\n1. Bow alignment curve (largest commanded bow-to-travel angle)")
	var expected := {0.0: 180.0, 2.5: 135.0, 5.0: 90.0, 7.5: 67.5, 10.0: 45.0, 12.5: 37.5, 15.0: 30.0, 20.0: 30.0}
	var ok := true
	var row: Array[String] = []
	for v in expected:
		var got := rad_to_deg(ShipPilot.alignment_limit_of(_profile, v))
		row.push_back("%.1f m/s %.2f°" % [v, got])
		ok = ok and absf(got - expected[v]) < 1e-3
	print("   %s" % ", ".join(row))
	_check(ok, "curve 180 / 90 / 45 / 30° at 0 / 5 / 10 / 15 m/s, linear between, clamped past the end")


# 2. Stationary sideways translation while rotating.
func _test_stationary() -> void:
	print("\n2. From rest: order 40 m abeam (translate while rotating) and 60 m at 60° off the bow")
	for destination in [Vector3(40, 0, 0), Vector3(60 * sin(deg_to_rad(60.0)), 0, -60 * cos(deg_to_rad(60.0)))]:
		var rows := {}
		for pilot in ["baseline", "unaligned", "now"]:
			rows[pilot] = _run(pilot, Vector3.ZERO, destination, 40.0)
			_print_run(pilot, rows[pilot])
		_check(rows["now"].arrived and rows["now"].both_ticks > 60, "translates and rotates at once and arrives (%s)" % destination)
		# Was: within 0.5 s of BASELINE (obsolete after the #86 propulsion retune). Bow alignment must not slow the order.
		_check(rows["unaligned"].arrived and absf(rows["now"].arrive_time - rows["unaligned"].arrive_time) < 0.5, "arrival within 0.5 s of the same order with bow alignment unrestricted (%.2f vs %.2f s)" % [rows["now"].arrive_time, rows["unaligned"].arrive_time])
		_check(rows["now"].limit_breaches == 0, "commanded target never beyond the limit (%s)" % destination)


# 3. Straight forward acceleration (no course change): unchanged.
func _test_straight() -> void:
	print("\n3. Straight acceleration from rest to cruise (order 1000 m ahead)")
	var rows := {}
	for pilot in ["baseline", "now"]:
		rows[pilot] = _run(pilot, Vector3.ZERO, Vector3(0, 0, -1000), 30.0)
		_print_run(pilot, rows[pilot])
	# Was: identical to BASELINE on every tick (obsolete after the #86 propulsion retune).
	_check(rows["now"].heading_travel == 0.0 and rows["now"].limit_breaches == 0 and rows["now"].final_position.z < -100.0, "no hull rotation (%.4f°), accelerates along the bow (%.1f m in 30 s)" % [rows["now"].heading_travel, -rows["now"].final_position.z])


# 4–6 and 10. A course change at cruise: the commanded target stays within the curve, the trajectory makes progress,
# bow and travel converge afterwards, no oscillation or circling.
func _test_cruise_turn(angle: float) -> void:
	print("\n4. Cruise 15 m/s along −Z, order 1500 m away at %.0f° to the right (120 s)" % angle)
	var a := deg_to_rad(angle)
	var destination := Vector3(1500 * sin(a), 0, -1500 * cos(a))
	var rows := {}
	for pilot in ["baseline", "now"]:
		rows[pilot] = _run(pilot, Vector3.FORWARD * 15.0, destination, 120.0)
		_print_run(pilot, rows[pilot])
	var r: Dictionary = rows["now"]
	_check(r.limit_breaches == 0, "commanded bow-to-travel angle never beyond the curve (%.0f° turn)" % angle)
	_check(r.course_reached > 0.0, "travel direction reaches the ordered course within 5° (%.0f° turn: %.1f s)" % [angle, r.course_reached])
	# Sustained travel: the remaining bow-to-travel angle is the fixed order course against the bearing to the destination
	# after the moving turn (the same in the baseline); it must not exceed the baseline and stay far inside the curve.
	var b: Dictionary = rows["baseline"]
	_check(r.course_reached > 0.0 and r.after_max_angle <= b.after_max_angle + 0.05 and r.after_max_angle < 5.0, "bow and travel stay aligned in sustained travel (largest angle in the last 60 s %.2f°, baseline %.2f°; final %.2f°)" % [r.after_max_angle, b.after_max_angle, r.final_angle])
	_check(r.heading_travel <= angle + 30.0, "no oscillation or circling (total heading change %.1f° for a %.0f° turn; turn-rate reversals %d, baseline %d)" % [r.heading_travel, angle, r.reversals, b.reversals])
	if angle <= 90.0:
		_check(r.max_angle_fast <= rows["baseline"].max_angle_fast, "bow leads the trajectory by less than the baseline above 5 m/s (%.1f° vs %.1f°)" % [r.max_angle_fast, rows["baseline"].max_angle_fast])


# 6. Stern-first movement and braking.
func _test_stern_first() -> void:
	print("\n6. Stern-first")
	var rows := {}
	for pilot in ["baseline", "now"]:
		rows[pilot] = _run(pilot, Vector3.BACK * 5.0, Vector3.ZERO, 20.0, false)
		_print_run(pilot, rows[pilot])
	# Was: identical to BASELINE on every tick (obsolete after the #86 propulsion retune).
	_check(rows["now"].heading_travel == 0.0 and rows["now"].min_speed < 0.01, "stern-first stop from 5 m/s (no order): no hull rotation (%.4f°), comes to rest" % rows["now"].heading_travel)
	rows = {}
	for pilot in ["baseline", "now"]:
		rows[pilot] = _run(pilot, Vector3.BACK * 5.0, Vector3(40, 0, -100), 60.0)
		_print_run(pilot, rows[pilot])
	_check(rows["now"].arrived and rows["now"].limit_breaches == 0, "5 m/s stern-first with an order ahead-right and turning: arrives (%.2f s, baseline %.2f s)" % [rows["now"].arrive_time, rows["baseline"].arrive_time])
	rows = {}
	for pilot in ["baseline", "now"]:
		rows[pilot] = _run(pilot, Vector3.ZERO, Vector3(0, 0, 40), 60.0)
		_print_run(pilot, rows[pilot])
	_check(rows["now"].arrived, "from rest, order 40 m astern: arrives (%.2f s, baseline %.2f s)" % [rows["now"].arrive_time, rows["baseline"].arrive_time])


# 7. Straight braking and arrival: unchanged.
func _test_braking_and_arrival() -> void:
	print("\n7. Straight braking and arrival from 15 m/s")
	for destination in [Vector3.ZERO, Vector3(0, 0, -80)]:
		var rows := {}
		for pilot in ["baseline", "now"]:
			rows[pilot] = _run(pilot, Vector3.FORWARD * 15.0, destination, 40.0, destination != Vector3.ZERO)
			_print_run(pilot, rows[pilot])
		# Was: identical to BASELINE on every tick (obsolete after the #86 propulsion retune).
		var done: bool = rows["now"].min_speed < 0.01 if destination == Vector3.ZERO else rows["now"].arrived
		_check(rows["now"].heading_travel == 0.0 and done, "%s: no hull rotation (%.4f°), %s" % ["stop" if destination == Vector3.ZERO else "arrival 80 m ahead", rows["now"].heading_travel, "comes to rest" if destination == Vector3.ZERO else "arrives (%.2f s)" % rows["now"].arrive_time])


# 8. A moving turn that ends in an arrival.
func _test_turn_then_arrive() -> void:
	print("\n8. Cruise 15 m/s, order 150 m abeam (90°): turn, brake and arrive")
	var rows := {}
	for pilot in ["baseline", "now"]:
		rows[pilot] = _run(pilot, Vector3.FORWARD * 15.0, Vector3(150, 0, 0), 120.0, true, PackedVector3Array(), true)
		_print_run(pilot, rows[pilot])
	var r: Dictionary = rows["now"]
	_check(r.arrived and r.limit_breaches == 0, "arrives without breaching the commanded limit (%.2f s, baseline %.2f s)" % [r.arrive_time, rows["baseline"].arrive_time])
	# The course follows the useful direction of travel (it is no longer fixed at the order's start), so the hull turns
	# as far as the trajectory does; circling is a trajectory that loops or a hull that swings beyond it.
	_check(r.travel_turn < 360.0 and r.heading_travel <= r.travel_turn + 30.0 and r.reversals <= 2, "no persistent corrective circling (trajectory turns %.1f°, hull %.1f° for a 90° order, baseline %.1f°; turn-rate reversals %d, baseline %d)" % [r.travel_turn, r.heading_travel, rows["baseline"].heading_travel, r.reversals, rows["baseline"].reversals])


# 9. Route following and final approach (RouteGuidance on an open-space polyline with two 45° bends).
func _test_route() -> void:
	print("\n9. Route following: (0,0) → (0,−120) → (85,−205) → (85,−400), from rest and from 15 m/s")
	var route := PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -120), Vector3(85, 0, -205), Vector3(85, 0, -400)])
	for v0 in [0.0, 15.0]:
		var rows := {}
		for pilot in ["baseline", "now"]:
			rows[pilot] = _run(pilot, Vector3.FORWARD * v0, route[route.size() - 1], 120.0, true, route)
			_print_run(pilot, rows[pilot])
		var r: Dictionary = rows["now"]
		_check(r.arrived and r.limit_breaches == 0, "route from %.0f m/s: arrives with the commanded limit kept (%.2f s, baseline %.2f s; largest distance off the route %.2f m, baseline %.2f m)" % [v0, r.arrive_time, rows["baseline"].arrive_time, r.off_route, rows["baseline"].off_route])
		_check(r.heading_travel <= rows["baseline"].heading_travel + 30.0, "route from %.0f m/s: no oscillation (total heading change %.1f°, baseline %.1f°; turn-rate reversals %d, baseline %d)" % [v0, r.heading_travel, rows["baseline"].heading_travel, r.reversals, rows["baseline"].reversals])


## Runs one pilot from the origin with bow −Z at `velocity` toward `destination` (an order when `order`, course toward it)
## or along `route` with RouteGuidance, and measures it.
func _run(pilot: String, velocity: Vector3, destination: Vector3, seconds: float, order := true, route := PackedVector3Array(), dense := false) -> Dictionary:
	var script: Variant = _old if pilot == "baseline" else ShipPilot
	var state: Variant = script.State.new()
	state.velocity = velocity
	var targets: Variant = script.Targets.new()
	targets.has_order = order
	targets.destination = destination
	targets.has_course = order and destination != Vector3.ZERO
	targets.course_yaw = atan2(-destination.x, -destination.z)
	# As ShipMovement: a direct order's course follows the bearing until arrival braking (pilots before that rule ignore it).
	targets.set("course_follows", targets.has_course and route.is_empty())
	var plan: RouteGuidance.Plan = null
	var follow: RouteGuidance.Follow = null
	var guided := ShipPilot.Targets.new()
	if not route.is_empty():
		plan = RouteGuidance.make_plan(RouteGuidance.Kind.ROUTE, route, destination, _profile.detour_lookahead_distance)
		follow = RouteGuidance.Follow.new()
	var out: Variant = script.Output.new()
	var course := targets.course_yaw as float
	var r := {trace = PackedVector3Array(), arrived = false, arrive_time = -1.0, limit_breaches = 0, both_ticks = 0,
		max_angle_fast = 0.0, over_curve = 0.0, over_time = 0.0, course_reached = -1.0, after_max_angle = 0.0, final_angle = 0.0,
		reversals = 0, heading_travel = 0.0, travel_turn = 0.0, min_speed = INF, off_route = 0.0, samples = []}
	var last_sign := 0
	var times := [1.0, 2.0, 5.0, 10.0, 20.0, 40.0] if not dense else [2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0, 24.0, 26.0]
	var ticks := roundi(seconds / DELTA)
	for i in ticks:
		var t := (i + 1) * DELTA
		state.bow = ShipPilot.bow_of(state.yaw)
		var v: Vector3 = state.velocity
		var speed := v.length()
		var yaw_before: float = state.yaw
		if plan != null and targets.has_order:
			RouteGuidance.guide(plan, follow, state.position, state.yaw, guided)
			for field in ["destination", "use_steer", "steer_direction", "steer_distance", "has_course", "course_yaw", "course_follows", "bend_lengths", "bend_radii", "bend_from", "bend_s"]:
				targets.set(field, guided.get(field))
			course = targets.course_yaw
		script.step(_profile if pilot == "now" else (_unaligned if pilot == "unaligned" else _old_profile), state, targets, DELTA, out)
		state.position += state.velocity * DELTA
		if follow != null:
			follow.time += DELTA
		r.trace.push_back(state.position)
		r.trace.push_back(state.velocity)
		var limit := ShipPilot.alignment_limit_of(_profile, speed)
		var angle := 0.0
		if speed > 0.05:
			angle = rad_to_deg(acos(clampf(state.bow.dot(v / speed), -1.0, 1.0)))
			# Commanded target against travel, while bow-first with an order and a course.
			if pilot == "now" and targets.has_order and targets.has_course and v.dot(state.bow) > 0.0:
				var travel_yaw := atan2(-v.x, -v.z)
				if absf(wrapf(out.target_yaw - travel_yaw, -PI, PI)) > limit + 1e-6:
					r.limit_breaches += 1
			if speed > 5.0 and v.dot(state.bow) > 0.0:
				r.max_angle_fast = maxf(r.max_angle_fast, angle)
				if angle > rad_to_deg(limit):
					r.over_curve = maxf(r.over_curve, angle - rad_to_deg(limit))
					r.over_time += DELTA
		if absf(state.turn_rate) > 1e-4 and out.thruster_command.length() > 0.1:
			r.both_ticks += 1
		r.heading_travel += rad_to_deg(absf(state.yaw - yaw_before))
		var v_after: Vector3 = state.velocity
		if speed > 1.0 and v_after.length() > 1.0:
			r.travel_turn += rad_to_deg(absf(wrapf(atan2(-v_after.x, -v_after.z) - atan2(-v.x, -v.z), -PI, PI)))
		var rate_sign := 0
		if absf(state.turn_rate) > deg_to_rad(0.5):
			rate_sign = 1 if state.turn_rate > 0.0 else -1
		if rate_sign != 0:
			if last_sign != 0 and rate_sign != last_sign and t > 1.0:
				r.reversals += 1
			last_sign = rate_sign
		if order and plan == null:
			var travel_error := 180.0
			var now_speed: float = state.velocity.length()
			if now_speed > 0.5:
				travel_error = rad_to_deg(absf(wrapf(atan2(-state.velocity.x, -state.velocity.z) - course, -PI, PI)))
			if r.course_reached < 0.0 and travel_error < 5.0 and t > 0.5:
				r.course_reached = t
			# Sustained travel: the second half of the run, well after the course change.
			if t > seconds * 0.5 and speed > 0.5:
				r.after_max_angle = maxf(r.after_max_angle, angle)
		if plan != null:
			r.off_route = maxf(r.off_route, _distance_to_route(route, state.position))
		r.min_speed = minf(r.min_speed, state.velocity.length())
		if out.arrived and not r.arrived:
			r.arrived = true
			r.arrive_time = t
			targets.has_order = false
		for mark in times:
			if absf(t - mark) < DELTA * 0.5:
				r.samples.push_back("%.0f s: pos (%.1f, %.1f) speed %.2f, bow–travel %.1f°, heading %.1f°, travel %.1f°, rate %.2f°/s" % [t, state.position.x, state.position.z, state.velocity.length(), angle, -rad_to_deg(state.yaw), -rad_to_deg(atan2(-state.velocity.x, -state.velocity.z)) if state.velocity.length() > 0.05 else 0.0, -rad_to_deg(state.turn_rate)])
	r.final_angle = 0.0
	var vf: Vector3 = state.velocity
	if vf.length() > 0.5:
		r.final_angle = rad_to_deg(acos(clampf(ShipPilot.bow_of(state.yaw).dot(vf.normalized()), -1.0, 1.0)))
	r.final_position = state.position
	return r


func _print_run(pilot: String, r: Dictionary) -> void:
	print("   %-8s arrived %s at %.2f s; bow–travel above 5 m/s: max %.1f° (beyond the curve by up to %.1f° for %.2f s); course within 5° at %.1f s, largest angle afterwards %.2f°, final %.2f°; commanded-limit breaches %d; turn reversals %d; heading travel %.1f°; min speed %.2f m/s; end (%.1f, %.1f)%s" % [pilot, r.arrived, r.arrive_time, r.max_angle_fast, r.over_curve, r.over_time, r.course_reached, r.after_max_angle, r.final_angle, r.limit_breaches, r.reversals, r.heading_travel, r.min_speed, r.final_position.x, r.final_position.z, ("; off route max %.2f m" % r.off_route) if r.off_route > 0.0 else ""])
	print("            %s" % "; ".join(r.samples))


func _distance_to_route(route: PackedVector3Array, p: Vector3) -> float:
	var best := INF
	for k in range(1, route.size()):
		var a := route[k - 1]
		var b := route[k]
		var ab := b - a
		var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		best = minf(best, (a + ab * t - p).length())
	return best


func _snapshot(profile: MovementProfile) -> String:
	var parts: Array[String] = []
	for property in profile.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var value: Variant = profile.get(property.name)
			if value is Curve:
				var curve: Curve = value
				var points: Array[String] = []
				for i in curve.point_count:
					points.push_back("%s/%s/%s" % [curve.get_point_position(i), curve.get_point_left_tangent(i), curve.get_point_right_tangent(i)])
				parts.push_back("%s=[%s]" % [property.name, ",".join(points)])
			else:
				parts.push_back("%s=%s" % [property.name, value])
	return ";".join(parts)


func _check(condition: bool, text: String) -> void:
	print("   %s %s" % ["PASS" if condition else "FAIL", text])
	if not condition:
		_failures += 1


func _fail(text: String) -> void:
	print("FAIL %s" % text)
	_failures += 1
