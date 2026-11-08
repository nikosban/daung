extends SceneTree
## Headless open-space check of speed-dependent turning (no scene, no navigation queries): drives ShipPilot.step() at
## 60 Hz, as ShipMovement and the navigator's predictions do, and compares it with the pilot and frigate profile at
## BASELINE (the orientation branch before this change), read from Git at run time. Run from the project folder:
##   godot --headless --path . --script res://Tests/speed_turning_test.gd
## Prints measurements and PASS/FAIL lines; exits with code 1 when any check fails.

const BASELINE := "a8a5b69"
const DELTA := 1.0 / 60.0
const PROFILE_PATH := "res://Movement/Profiles/frigate_movement_profile.tres"
const Baseline := preload("res://Tests/baseline_pilot.gd")

var _failures := 0
var _old: GDScript
var _old_profile: Resource
var _profile: MovementProfile


func _init() -> void:
	_profile = load(PROFILE_PATH)
	var before := _snapshot(_profile)
	_old = Baseline.load_pilot(BASELINE)
	_old_profile = Baseline.load_profile(BASELINE)
	if _old == null or _old_profile == null:
		_fail("pilot or profile at %s could not be loaded" % BASELINE)
		quit(1)
		return

	_test_curves()
	_test_course_changes()
	_test_low_speed()
	_test_unchanged()
	_test_arrivals()
	_test_route()

	print("\n8. Profile unchanged at run time")
	_check(_snapshot(_profile) == before, "frigate profile (every property and curve point) identical after all runs")
	print("\n%s (%d failed)" % ["ALL PASSED" if _failures == 0 else "FAILURES", _failures])
	quit(1 if _failures > 0 else 0)


# 1. The curves against the approved values, and the baseline's for comparison.
func _test_curves() -> void:
	print("\n1. Turning authority and turn-rate limit against actual speed")
	var expected := {0.0: [0.5, 1.8], 5.0: [10.0, 35.0], 10.0: [7.0, 30.0], 15.0: [3.5, 20.0]}
	var ok := true
	for v in [0.0, 2.5, 5.0, 7.5, 10.0, 12.5, 15.0, 20.0]:
		var accel := _profile.turn_acceleration_curve.sample(v)
		var rate := _profile.turn_rate_curve.sample(v)
		var rudder: float = _old_profile.rudder_curve.sample(clampf(v / _old_profile.max_speed, 0.0, 1.0))
		var old_accel: float = _old_profile.turn_authority / _old_profile.mass * rudder
		var old_rate: float = _old_profile.max_turn_rate_at_max_speed * rudder / _old_profile.rudder_curve.sample(1.0)
		print("   %4.1f m/s: now %5.2f °/s², %5.2f °/s; %s %5.2f °/s², %5.2f °/s" % [v, accel, rate, BASELINE, old_accel, old_rate])
		if expected.has(v):
			ok = ok and absf(accel - expected[v][0]) < 1e-4 and absf(rate - expected[v][1]) < 1e-4
	ok = ok and absf(_profile.turn_acceleration_curve.sample(20.0) - 3.5) < 1e-4 and absf(_profile.turn_rate_curve.sample(20.0) - 20.0) < 1e-4
	_check(ok, "approved values 0.5 / 10 / 7 / 3.5 °/s² and 1.8 / 35 / 30 / 20 °/s at 0 / 5 / 10 / 15 m/s, linear between, clamped past the end")


# 2. Course changes of 45 / 90 / 135° from 5 / 10 / 15 m/s (order 1500 m away along the new course).
func _test_course_changes() -> void:
	print("\n2. Course changes from 5 / 10 / 15 m/s (bow −Z, order 1500 m away at the given angle to the right)")
	for angle in [45.0, 90.0, 135.0]:
		var rows := {}
		for v in [5.0, 10.0, 15.0]:
			var a := deg_to_rad(angle)
			var destination := Vector3(1500 * sin(a), 0, -1500 * cos(a))
			for pilot in ["baseline", "now"]:
				var r := _run(pilot, Vector3.FORWARD * v, destination, 90.0)
				rows["%s|%s" % [pilot, v]] = r
				print("   %3.0f° from %4.1f m/s %-8s at the order authority %5.2f °/s², permitted %5.2f °/s; first 3 s mean %5.2f °/s², %5.2f °/s; peak turn rate %5.2f °/s (permitted then %5.2f), peak applied %5.2f °/s²; bow–travel max %5.1f°; course within 5° after %5.1f s, advance %6.1f m, transfer %6.1f m; min speed %5.2f m/s; heading overshoot %5.1f°, heading change %6.1f°, reversals %d" % [angle, v, pilot, r.authority_start, r.permitted_start, r.authority_3s, r.permitted_3s, r.peak_rate, r.permitted_at_peak, r.peak_applied, r.max_bow_travel, r.course_time, r.advance, r.transfer, r.min_speed, r.overshoot, r.heading_travel, r.reversals])
		var n5: Dictionary = rows["now|5.0"]
		var n10: Dictionary = rows["now|10.0"]
		var n15: Dictionary = rows["now|15.0"]
		_check(n5.course_time > 0.0 and n10.course_time > 0.0 and n15.course_time > 0.0, "%.0f°: the new course is established from every speed (%.1f / %.1f / %.1f s)" % [angle, n5.course_time, n10.course_time, n15.course_time])
		# At the speed the order is given (the 3 s means also include the speed the turn itself loses or gains).
		_check(n5.authority_start > n10.authority_start and n10.authority_start > n15.authority_start and n5.permitted_start > n10.permitted_start and n10.permitted_start > n15.permitted_start, "%.0f°: turning authority and permitted rate at the order's speed fall with speed (%.2f / %.2f / %.2f °/s², %.2f / %.2f / %.2f °/s)" % [angle, n5.authority_start, n10.authority_start, n15.authority_start, n5.permitted_start, n10.permitted_start, n15.permitted_start])
		_check(n5.advance < n10.advance and n10.advance < n15.advance, "%.0f°: the faster ship needs more distance to change its trajectory (advance %.1f / %.1f / %.1f m)" % [angle, n5.advance, n10.advance, n15.advance])
		_check(n15.authority_3s < rows["baseline|15.0"].authority_3s and n15.permitted_3s < rows["baseline|15.0"].permitted_3s, "%.0f° from 15 m/s: less authority and a lower permitted rate than %s (%.2f vs %.2f °/s², %.2f vs %.2f °/s)" % [angle, BASELINE, n15.authority_3s, rows["baseline|15.0"].authority_3s, n15.permitted_3s, rows["baseline|15.0"].permitted_3s])
		for v in [5.0, 10.0, 15.0]:
			var r: Dictionary = rows["now|%s" % v]
			_check(r.heading_travel <= angle + 30.0 and r.rate_jumps == 0, "%.0f° from %.0f m/s: no oscillation, circling or abrupt rate change (heading change %.1f°, overshoot %.1f°, reversals %d; rate clamped by a contracting limit on %d ticks, largest step %.3f °/s)" % [angle, v, r.heading_travel, r.overshoot, r.reversals, r.rate_jumps, r.largest_jump])


# 3. Stationary and low-speed turning.
func _test_low_speed() -> void:
	print("\n3. Stationary and low-speed turning")
	var cases := [
		["from rest, order 40 m abeam", Vector3.ZERO, Vector3(40, 0, 0)],
		["from rest, order 60 m at 60°", Vector3.ZERO, Vector3(60 * sin(deg_to_rad(60.0)), 0, -60 * cos(deg_to_rad(60.0)))],
		["from rest, order 60 m at 135°", Vector3.ZERO, Vector3(60 * sin(deg_to_rad(135.0)), 0, -60 * cos(deg_to_rad(135.0)))],
		["2 m/s, order 80 m at 90°", Vector3.FORWARD * 2.0, Vector3(80, 0, 0)],
	]
	for case in cases:
		var rows := {}
		for pilot in ["baseline", "now"]:
			rows[pilot] = _run(pilot, case[1], case[2], 60.0)
			var r: Dictionary = rows[pilot]
			print("   %-30s %-8s heading after 1 / 2 / 5 s %5.2f / %5.2f / %6.2f°; turning and translating together %d ticks; peak rate %5.2f °/s at %4.2f m/s; arrived %s at %.2f s; heading overshoot %.1f°, reversals %d; rotation after arrival %.4f°; rate clamped on %d ticks (largest step %.4f °/s); turn rate stopped at arrival %.2f °/s" % [case[0], pilot, r.heading_1s, r.heading_2s, r.heading_5s, r.both_ticks, r.peak_rate, r.speed_at_peak, r.arrived, r.arrive_time, r.overshoot, r.reversals, r.rotation_after, r.rate_jumps, r.largest_jump, r.arrival_rate_stop])
		var n: Dictionary = rows["now"]
		_check(n.arrived and n.rotation_after == 0.0 and n.rate_jumps == 0, "%s: arrives, no rotation after arrival, no abrupt rate change (%d clamp ticks)" % [case[0], n.rate_jumps])
	var rest := _run("now", Vector3.ZERO, Vector3(40, 0, 0), 1.0)
	_check(rest.peak_rate <= 1.8 + 1e-3 and rest.both_ticks > 30, "at rest the hull turns at most 1.8 °/s while translating at once (peak %.3f °/s in the first second)" % rest.peak_rate)


# 4. Scenarios that do not turn: identical to the baseline.
func _test_unchanged() -> void:
	print("\n4. No turning involved: identical to %s" % BASELINE)
	var cases := [
		["straight acceleration from rest (1000 m ahead)", Vector3.ZERO, Vector3(0, 0, -1000), true],
		["straight stop from 15 m/s", Vector3.FORWARD * 15.0, Vector3.ZERO, false],
		["straight arrival 80 m ahead from 15 m/s", Vector3.FORWARD * 15.0, Vector3(0, 0, -80), true],
		["stern-first stop from 5 m/s", Vector3.BACK * 5.0, Vector3.ZERO, false],
	]
	for case in cases:
		var old_r := _run("baseline", case[1], case[2], 40.0, case[3])
		var new_r := _run("now", case[1], case[2], 40.0, case[3])
		_check(old_r.trace == new_r.trace, "%s identical on every tick" % case[0])
	var side_old := _run("baseline", Vector3.FORWARD * 15.0, Vector3(40, 0, -300), 40.0, true, PackedVector3Array(), false)
	var side_new := _run("now", Vector3.FORWARD * 15.0, Vector3(40, 0, -300), 40.0, true, PackedVector3Array(), false)
	# A moving redirect: the guidance now turns the velocity progressively (momentum-preserving course changes), so it is
	# no longer identical tick by tick; it must still reach the offset and arrive no later.
	_check(side_new.arrived and side_new.arrive_time <= side_old.arrive_time + 0.05, "sideways repositioning at cruise without a course turn arrives no later (%.2f vs %.2f s)" % [side_new.arrive_time, side_old.arrive_time])
	var rest_old := _run("baseline", Vector3.ZERO, Vector3(40, 0, 0), 20.0, true, PackedVector3Array(), false)
	var rest_new := _run("now", Vector3.ZERO, Vector3(40, 0, 0), 20.0, true, PackedVector3Array(), false)
	_check(rest_old.trace == rest_new.trace, "sideways repositioning from rest without a course turn identical on every tick")


# 5. Moving turns followed by arrival, stern-first with turning.
func _test_arrivals() -> void:
	print("\n5. Moving turns that end in an arrival")
	var cases := [
		["15 m/s, order 150 m abeam", Vector3.FORWARD * 15.0, Vector3(150, 0, 0)],
		["10 m/s, order 100 m abeam", Vector3.FORWARD * 10.0, Vector3(100, 0, 0)],
		["5 m/s, order 60 m abeam", Vector3.FORWARD * 5.0, Vector3(60, 0, 0)],
		["15 m/s, order 200 m at 135°", Vector3.FORWARD * 15.0, Vector3(200 * sin(deg_to_rad(135.0)), 0, -200 * cos(deg_to_rad(135.0)))],
		["5 m/s stern-first, order (40, −100)", Vector3.BACK * 5.0, Vector3(40, 0, -100)],
	]
	for case in cases:
		var rows := {}
		for pilot in ["baseline", "now"]:
			rows[pilot] = _run(pilot, case[1], case[2], 120.0)
			var r: Dictionary = rows[pilot]
			print("   %-36s %-8s arrived %s at %6.2f s; bow–travel max above 5 m/s %5.1f°; heading change %6.1f°, overshoot %5.1f°, reversals %d; rotation after arrival %.4f°; rate clamped on %d ticks; turn rate stopped at arrival %.2f °/s" % [case[0], pilot, r.arrived, r.arrive_time, r.max_bow_travel, r.heading_travel, r.overshoot, r.reversals, r.rotation_after, r.rate_jumps, r.arrival_rate_stop])
		var n: Dictionary = rows["now"]
		_check(n.arrived and n.rotation_after == 0.0 and n.rate_jumps == 0, "%s: arrives (%.2f s, %s %.2f s), no rotation after arrival, no abrupt rate change" % [case[0], n.arrive_time, BASELINE, rows["baseline"].arrive_time])


# 6. Route following and final approach (open-space polyline with two 45° bends).
func _test_route() -> void:
	print("\n6. Route following: (0,0) → (0,−120) → (85,−205) → (85,−400)")
	var route := PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -120), Vector3(85, 0, -205), Vector3(85, 0, -400)])
	for v0 in [0.0, 15.0]:
		var rows := {}
		for pilot in ["baseline", "now"]:
			rows[pilot] = _run(pilot, Vector3.FORWARD * v0, route[route.size() - 1], 120.0, true, route)
			var r: Dictionary = rows[pilot]
			print("   from %4.1f m/s %-8s arrived %s at %6.2f s; largest distance off the route %5.2f m; bow–travel max above 5 m/s %5.1f°; heading change %6.1f°, reversals %d; rotation after arrival %.4f°" % [v0, pilot, r.arrived, r.arrive_time, r.off_route, r.max_bow_travel, r.heading_travel, r.reversals, r.rotation_after])
		var n: Dictionary = rows["now"]
		_check(n.arrived and n.rotation_after == 0.0 and n.rate_jumps == 0 and n.heading_travel <= rows["baseline"].heading_travel + 30.0, "route from %.0f m/s: arrives (%.2f s, %s %.2f s), off route at most %.2f m (%.2f m), no oscillation" % [v0, n.arrive_time, BASELINE, rows["baseline"].arrive_time, n.off_route, rows["baseline"].off_route])


## Runs one pilot from the origin with bow −Z at `velocity` toward `destination` (an order when `order`; with the course
## toward it when `course`) or along `route` with RouteGuidance, and measures it.
func _run(pilot: String, velocity: Vector3, destination: Vector3, seconds: float, order := true, route := PackedVector3Array(), course := true) -> Dictionary:
	var now := pilot == "now"
	var script: Variant = ShipPilot if now else _old
	var profile: Resource = _profile if now else _old_profile
	var state: Variant = script.State.new()
	state.velocity = velocity
	var targets: Variant = script.Targets.new()
	targets.has_order = order
	targets.destination = destination
	targets.has_course = order and course and destination != Vector3.ZERO
	targets.course_yaw = atan2(-destination.x, -destination.z)
	# As ShipMovement: a direct order's course follows the bearing until arrival braking (pilots before that rule ignore it).
	targets.set("course_follows", targets.has_course and route.is_empty())
	var course_yaw: float = targets.course_yaw
	var plan: RouteGuidance.Plan = null
	var follow: RouteGuidance.Follow = null
	var guided := ShipPilot.Targets.new()
	if not route.is_empty():
		plan = RouteGuidance.make_plan(RouteGuidance.Kind.ROUTE, route, destination, _profile.detour_lookahead_distance)
		follow = RouteGuidance.Follow.new()
	var out: Variant = script.Output.new()
	var r := {trace = PackedVector3Array(), arrived = false, arrive_time = -1.0, authority_3s = 0.0, permitted_3s = 0.0, authority_start = 0.0, permitted_start = 0.0,
		peak_rate = 0.0, permitted_at_peak = 0.0, speed_at_peak = 0.0, peak_applied = 0.0, max_bow_travel = 0.0, course_time = -1.0,
		advance = 0.0, transfer = 0.0, min_speed = INF, overshoot = 0.0, heading_travel = 0.0, reversals = 0, rate_jumps = 0,
		largest_jump = 0.0, jump_time = -1.0, arrival_rate_stop = 0.0, both_ticks = 0, heading_1s = 0.0, heading_2s = 0.0, heading_5s = 0.0, rotation_after = 0.0,
		off_route = 0.0, final_position = Vector3.ZERO}
	var start_dir := velocity.normalized() if velocity != Vector3.ZERO else Vector3.FORWARD
	var right := Vector3(-start_dir.z, 0, start_dir.x)
	var crossed := false
	var last_sign := 0
	var ticks := roundi(seconds / DELTA)
	var samples_3s := 0
	for i in ticks:
		var t := (i + 1) * DELTA
		state.bow = ShipPilot.bow_of(state.yaw)
		var v: Vector3 = state.velocity
		var speed := v.length()
		var yaw_before: float = state.yaw
		var rate_before: float = state.turn_rate
		if plan != null and targets.has_order:
			RouteGuidance.guide(plan, follow, state.position, state.yaw, guided)
			for field in ["destination", "use_steer", "steer_direction", "steer_distance", "has_course", "course_yaw", "course_follows", "bend_lengths", "bend_radii", "bend_from", "bend_s"]:
				targets.set(field, guided.get(field))
		var had_order: bool = targets.has_order
		script.step(profile, state, targets, DELTA, out)
		state.position += state.velocity * DELTA
		if follow != null:
			follow.time += DELTA
		r.trace.push_back(state.position)
		r.trace.push_back(state.velocity)
		# Authority and permitted rate at this tick's actual speed, from the pilot's own outputs.
		var authority := rad_to_deg(out.turn_authority) if now else rad_to_deg(deg_to_rad(profile.turn_authority / profile.mass) * out.rudder_multiplier)
		var permitted := rad_to_deg(out.turn_rate_limit)
		if i == 0:
			r.authority_start = authority
			r.permitted_start = permitted
		if t <= 3.0:
			r.authority_3s += authority
			r.permitted_3s += permitted
			samples_3s += 1
		var rate := absf(rad_to_deg(state.turn_rate))
		if rate > r.peak_rate:
			r.peak_rate = rate
			r.permitted_at_peak = permitted
			r.speed_at_peak = speed
		r.peak_applied = maxf(r.peak_applied, absf(rad_to_deg(out.turn_acceleration)))
		# Rate changed by more than the applied acceleration: clamped by a contracting limit.
		var jump := absf(state.turn_rate - (rate_before + out.turn_acceleration * DELTA))
		# The arrival tick ends powered turning (rotation never persists without an order): reported separately.
		if had_order and out.arrived:
			r.arrival_rate_stop = rad_to_deg(absf(rate_before))
		elif had_order and jump > 1e-6:
			r.rate_jumps += 1
			if rad_to_deg(jump) > r.largest_jump:
				r.largest_jump = rad_to_deg(jump)
				r.jump_time = t
		if speed > 5.0 and v.dot(state.bow) > 0.0:
			r.max_bow_travel = maxf(r.max_bow_travel, rad_to_deg(acos(clampf(state.bow.dot(v / speed), -1.0, 1.0))))
		if absf(state.turn_rate) > 1e-4 and out.thruster_command.length() > 0.1:
			r.both_ticks += 1
		r.heading_travel += rad_to_deg(absf(state.yaw - yaw_before))
		var sign := 0
		if absf(state.turn_rate) > deg_to_rad(0.5):
			sign = 1 if state.turn_rate > 0.0 else -1
		if sign != 0:
			if last_sign != 0 and sign != last_sign:
				r.reversals += 1
			last_sign = sign
		if targets.has_course and plan == null:
			var heading_error := wrapf(state.yaw - course_yaw, -PI, PI)
			if not crossed and absf(heading_error) < deg_to_rad(0.5):
				crossed = true
			if crossed:
				r.overshoot = maxf(r.overshoot, rad_to_deg(absf(heading_error)))
		var now_v: Vector3 = state.velocity
		if r.course_time < 0.0 and order and plan == null and now_v.length() > 0.5 and absf(wrapf(atan2(-now_v.x, -now_v.z) - course_yaw, -PI, PI)) < deg_to_rad(5.0) and t > 0.5:
			r.course_time = t
			r.advance = state.position.dot(start_dir)
			r.transfer = state.position.dot(right)
		r.min_speed = minf(r.min_speed, now_v.length())
		if plan != null:
			r.off_route = maxf(r.off_route, _distance_to_route(route, state.position))
		if absf(t - 1.0) < DELTA * 0.5:
			r.heading_1s = -rad_to_deg(state.yaw)
		if absf(t - 2.0) < DELTA * 0.5:
			r.heading_2s = -rad_to_deg(state.yaw)
		if absf(t - 5.0) < DELTA * 0.5:
			r.heading_5s = -rad_to_deg(state.yaw)
		if r.arrived:
			r.rotation_after += rad_to_deg(absf(state.yaw - yaw_before))
		if out.arrived and not r.arrived:
			r.arrived = true
			r.arrive_time = t
			targets.has_order = false
	if samples_3s > 0:
		r.authority_3s /= samples_3s
		r.permitted_3s /= samples_3s
	r.final_position = state.position
	return r


func _distance_to_route(route: PackedVector3Array, p: Vector3) -> float:
	var best := INF
	for k in range(1, route.size()):
		var a := route[k - 1]
		var ab := route[k] - a
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
