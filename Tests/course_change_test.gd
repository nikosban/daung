extends SceneTree
## Headless open-space check of momentum-preserving course changes (no scene, no navigation queries): drives
## ShipPilot.step() at 60 Hz, as ShipMovement and the navigator's predictions do, and compares it with the pilot and
## frigate profile at BASELINE (the orientation branch before this change), read from Git at run time. Run from the
## project folder:
##   godot --headless --path . --script res://Tests/course_change_test.gd
## Prints measurements and PASS/FAIL lines; exits with code 1 when any check fails.

const BASELINE := "91f1e8b"
const DELTA := 1.0 / 60.0
const PROFILE_PATH := "res://Movement/Profiles/frigate_movement_profile.tres"
const Baseline := preload("res://Tests/baseline_pilot.gd")
const EPS := 1e-4

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

	_test_course_changes()
	_test_arrivals()
	_test_regressions()
	_test_route()

	print("\n5. Profile unchanged at run time")
	_check(_snapshot(_profile) == before, "frigate profile (every property and curve point) identical after all runs")
	print("\n%s (%d failed)" % ["ALL PASSED" if _failures == 0 else "FAILURES", _failures])
	quit(1 if _failures > 0 else 0)


# 1. Course changes of 45 / 90 / 135° from 5 / 10 / 15 m/s with room to turn (order 1500 m away).
func _test_course_changes() -> void:
	print("\n1. Moving course changes (bow −Z, order 1500 m away at the given angle to the right)")
	for angle in [45.0, 90.0, 135.0]:
		for v in [5.0, 10.0, 15.0]:
			var a := deg_to_rad(angle)
			var destination := Vector3(1500 * sin(a), 0, -1500 * cos(a))
			var rows := {}
			for pilot in ["baseline", "now"]:
				var r := _run(pilot, Vector3.FORWARD * v, destination, 300.0)
				rows[pilot] = r
				print("   %3.0f° from %4.1f m/s %-8s speed at 0/5/10/15/20/30 s %s; until the course: min speed %5.2f m/s, braking max %4.2f m/s², total %5.2f m/s; whole run braking %5.2f m/s; course within 5° after %5.1f s and %6.1f m travelled; bow–travel max %5.1f°; heading change %6.1f°; arrived %s at %6.2f s" % [angle, v, pilot, r.speeds, r.turn_min_speed, r.turn_max_braking, r.turn_braking, r.total_braking, r.course_time, r.course_distance, r.max_bow_travel, r.heading_travel, r.arrived, r.arrive_time])
				print("      trajectory to the course (every 5 s): %s" % r.path)
			var n: Dictionary = rows["now"]
			var b: Dictionary = rows["baseline"]
			_check(n.arrived and n.course_time > 0.0, "%.0f° from %.0f m/s: establishes the course (%.1f s) and arrives (%.1f s, %s %.1f s)" % [angle, v, n.course_time, n.arrive_time, BASELINE, b.arrive_time])
			_check(n.turn_min_speed >= b.turn_min_speed - 0.05 and n.turn_braking <= b.turn_braking + 0.05, "%.0f° from %.0f m/s: keeps at least the baseline's momentum through the turn (min speed %.2f vs %.2f m/s, speed lost to braking %.2f vs %.2f m/s)" % [angle, v, n.turn_min_speed, b.turn_min_speed, n.turn_braking, b.turn_braking])
			_check(n.heading_travel <= angle + 30.0 and n.stops == 0 and n.violations == 0, "%.0f° from %.0f m/s: no circling, no stop before arrival, inside every limit (heading change %.1f°, stops %d, violations %d)" % [angle, v, n.heading_travel, n.stops, n.violations])
			if angle == 90.0 and v == 15.0:
				_check(n.turn_min_speed > b.turn_min_speed + 3.0, "90° from 15 m/s: carries momentum through the turn (min speed %.2f m/s vs %s %.2f m/s)" % [n.turn_min_speed, BASELINE, b.turn_min_speed])


# 2. Moving redirects that end in an arrival close by.
func _test_arrivals() -> void:
	print("\n2. Moving redirects followed by arrival")
	var cases := [
		["15 m/s, order 400 m at 90°", Vector3.FORWARD * 15.0, _at(90.0, 400.0)],
		["15 m/s, order 150 m abeam", Vector3.FORWARD * 15.0, _at(90.0, 150.0)],
		["10 m/s, order 100 m abeam", Vector3.FORWARD * 10.0, _at(90.0, 100.0)],
		["5 m/s, order 60 m abeam", Vector3.FORWARD * 5.0, _at(90.0, 60.0)],
		["15 m/s, order 300 m at 45°", Vector3.FORWARD * 15.0, _at(45.0, 300.0)],
		["15 m/s, order 200 m at 135°", Vector3.FORWARD * 15.0, _at(135.0, 200.0)],
		["10 m/s, order 120 m at 135°", Vector3.FORWARD * 10.0, _at(135.0, 120.0)],
	]
	for case in cases:
		var rows := {}
		for pilot in ["baseline", "now"]:
			var r := _run(pilot, case[1], case[2], 180.0)
			rows[pilot] = r
			print("   %-30s %-8s arrived %s at %6.2f s; min speed %5.2f m/s; braking max %4.2f m/s², total %5.2f m/s; trajectory turns %6.1f°, hull %6.1f°, reversals %d; stops before arrival %d (nearest %.1f m away); bow–travel max %5.1f°" % [case[0], pilot, r.arrived, r.arrive_time, r.min_speed, r.max_braking, r.total_braking, r.travel_turn, r.heading_travel, r.reversals, r.stops, r.stop_distance, r.max_bow_travel])
		var n: Dictionary = rows["now"]
		_check(n.arrived and n.rotation_after == 0.0 and n.violations == 0, "%s: arrives (%.2f s, %s %.2f s), no rotation after arrival, inside every limit" % [case[0], n.arrive_time, BASELINE, rows["baseline"].arrive_time])
		_check(n.stops == 0 and n.travel_turn < 360.0 and n.heading_travel <= n.travel_turn + 30.0 and n.reversals <= 1, "%s: no stop-and-reverse, no loop, no hull swing beyond the trajectory (stops %d; trajectory turns %.1f°, hull %.1f°; turn-rate reversals %d)" % [case[0], n.stops, n.travel_turn, n.heading_travel, n.reversals])
		_check(n.held and not n.course_changed_after_hold, "%s: the course holds from the start of arrival braking (no late arrival spin)" % case[0])


# 3. Regressions: behaviour that does not involve a moving course change, and the shared limits.
func _test_regressions() -> void:
	print("\n3. Regressions")
	var same := [
		["straight acceleration from rest (main engine)", Vector3.ZERO, Vector3(0, 0, -1000), true],
		["straight stop from 15 m/s", Vector3.FORWARD * 15.0, Vector3.ZERO, false],
		["straight arrival 80 m ahead from 15 m/s", Vector3.FORWARD * 15.0, Vector3(0, 0, -80), true],
		["stern-first stop from 5 m/s", Vector3.BACK * 5.0, Vector3.ZERO, false],
		["short arrival 30 m abeam from rest", Vector3.ZERO, Vector3(30, 0, 0), true],
	]
	# Was: identical to BASELINE on every tick (obsolete after the #86 propulsion retune). Now: inside every limit, the
	# hull does not rotate on the bow axis, stops come to rest, arrivals arrive without rotation afterwards.
	for case in same:
		var new_r := _run("now", case[1], case[2], 60.0, case[3])
		var destination: Vector3 = case[2]
		var on_axis := destination.x == 0.0
		var outcome: bool
		var text: String
		if not case[3]:
			outcome = new_r.final_speed < 0.01
			text = "comes to rest"
		elif destination.length() > 500.0:
			outcome = new_r.stops == 0 and new_r.min_speed_after_5 > 1.0
			text = "accelerates without stopping"
		else:
			outcome = new_r.arrived and new_r.rotation_after == 0.0
			text = "arrives (%.2f s; stops before arrival %d), no rotation after arrival" % [new_r.arrive_time, new_r.stops]
		_check(new_r.violations == 0 and outcome and (not on_axis or new_r.heading_travel == 0.0), "%s: %s, %sinside every limit (%d violations)" % [case[0], text, "no hull rotation (%.4f°), " % new_r.heading_travel if on_axis else "", new_r.violations])
	# Orders whose course now follows the bearing (the order-time course is replaced, PR #32 revised): no longer
	# identical tick by tick to the baseline; they must still translate and turn together, arrive promptly and not spin.
	var followed := [
		["stationary sideways repositioning with rotation (rest, order 40 m abeam)", Vector3.ZERO, Vector3(40, 0, 0)],
		["stationary repositioning at 60° (rest, order 60 m)", Vector3.ZERO, _at(60.0, 60.0)],
		["stern-first, order ahead-right (40, −100)", Vector3.BACK * 5.0, Vector3(40, 0, -100)],
	]
	for case in followed:
		var new_f := _run("now", case[1], case[2], 60.0)
		# Was: arrival within 0.5 s of BASELINE and reversals at most BASELINE's + 1 (obsolete after the #86 propulsion
		# retune). Now: at most one settle at the course.
		_check(new_f.arrived and new_f.rotation_after == 0.0 and new_f.reversals <= 1 and new_f.violations == 0 and new_f.stops == 0, "%s: arrives (%.2f s), no rotation after arrival (%.2f°), turn-rate reversals %d (at most 1), no stop (%d), inside every limit (%d violations)" % [case[0], new_f.arrive_time, new_f.rotation_after, new_f.reversals, new_f.stops, new_f.violations])
	var rest := _run("now", Vector3.ZERO, Vector3(40, 0, 0), 2.0)
	_check(rest.both_ticks > 60, "at rest the hull rotates while it translates (%d ticks of both in 2 s)" % rest.both_ticks)
	var straight := _run("now", Vector3.ZERO, Vector3(0, 0, -1000), 30.0)
	_check(straight.main_share >= 0.6, "main engine supplies most of the forward acceleration (lowest share %.1f%% on any accelerating tick)" % (straight.main_share * 100.0))
	# Directional thrust effectiveness: the thrusters' sideways limit at a given speed, on the shared allocator.
	var a_t := _profile.thruster_strength / _profile.mass
	var ok := true
	var row := ""
	for v in [0.0, 5.0, 10.0, 15.0]:
		var e := ShipPilot.effectiveness_of(_profile, v)
		var sideways := ShipPilot.allocate(Vector3.RIGHT * 1000.0, Vector3.FORWARD * v, 1.0, Vector3.FORWARD, _profile.pilot_response_time, a_t, a_t * e, _profile.forward_directional_acceleration * e).dot(Vector3.RIGHT)
		row += " %.0f m/s %.4f;" % [v, sideways]
		ok = ok and absf(sideways - a_t * e) < EPS
	var expected := []
	for v in [0.0, 5.0, 10.0, 15.0]:
		expected.push_back("%.4f" % (a_t * ShipPilot.effectiveness_of(_profile, v)))
	_check(ok, "sideways thruster limit follows the effectiveness curve (%s expected %s m/s²)" % [row, " / ".join(expected)])
	var moving := _run("now", Vector3.FORWARD * 15.0, Vector3(40, 0, -300), 30.0, true, PackedVector3Array(), false)
	# Was also: arrives no later than BASELINE + 0.05 s (obsolete after the #86 propulsion retune).
	_check(moving.arrived and moving.peak_sideways >= a_t * ShipPilot.effectiveness_of(_profile, 15.0) - 1e-3 and moving.violations == 0, "moving sideways repositioning (15 m/s, 40 m abeam, 300 m ahead) uses the full sideways limit at its speed (peak %.4f m/s², limit at 15 m/s %.4f) and arrives (%.2f s)" % [moving.peak_sideways, a_t * ShipPilot.effectiveness_of(_profile, 15.0), moving.arrive_time])
	# Bow alignment during sustained movement and weaker turning at speed.
	var cruise := _run("now", Vector3.FORWARD * 15.0, _at(45.0, 1500.0), 120.0)
	_check(cruise.target_breaches == 0 and cruise.final_bow_travel < 5.0, "bow alignment: steering target never beyond the curve, bow and travel aligned in sustained travel (final %.2f°)" % cruise.final_bow_travel)
	var slow := _run("now", Vector3.FORWARD * 5.0, _at(90.0, 1500.0), 3.0)
	var fast := _run("now", Vector3.FORWARD * 15.0, _at(90.0, 1500.0), 3.0)
	_check(fast.authority_start < slow.authority_start and fast.peak_rate < slow.peak_rate, "turning weaker at speed (authority %.2f vs %.2f °/s², peak rate in 3 s %.2f vs %.2f °/s at 15 vs 5 m/s)" % [fast.authority_start, slow.authority_start, fast.peak_rate, slow.peak_rate])


# 4. Route following and final approach (open-space polyline with two 45° bends).
func _test_route() -> void:
	print("\n4. Route following: (0,0) → (0,−120) → (85,−205) → (85,−400)")
	var route := PackedVector3Array([Vector3.ZERO, Vector3(0, 0, -120), Vector3(85, 0, -205), Vector3(85, 0, -400)])
	for v0 in [0.0, 15.0]:
		var rows := {}
		for pilot in ["baseline", "now"]:
			rows[pilot] = _run(pilot, Vector3.FORWARD * v0, route[route.size() - 1], 120.0, true, route)
			var r: Dictionary = rows[pilot]
			print("   from %4.1f m/s %-8s arrived %s at %6.2f s; largest distance off the route %5.2f m; min speed after 5 s %5.2f m/s; heading change %6.1f°, reversals %d" % [v0, pilot, r.arrived, r.arrive_time, r.off_route, r.min_speed_after_5, r.heading_travel, r.reversals])
		var n: Dictionary = rows["now"]
		var b: Dictionary = rows["baseline"]
		_check(n.arrived and n.off_route <= b.off_route + 1.0 and n.heading_travel <= b.heading_travel + 30.0 and n.stops == 0 and n.violations == 0, "route from %.0f m/s: arrives (%.2f s, %s %.2f s), off route at most %.2f m (%.2f m), no oscillation or stop, inside every limit" % [v0, n.arrive_time, BASELINE, b.arrive_time, n.off_route, b.off_route])


func _at(angle: float, distance: float) -> Vector3:
	var a := deg_to_rad(angle)
	return Vector3(distance * sin(a), 0, -distance * cos(a))


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
	var plan: RouteGuidance.Plan = null
	var follow: RouteGuidance.Follow = null
	var guided := ShipPilot.Targets.new()
	if not route.is_empty():
		plan = RouteGuidance.make_plan(RouteGuidance.Kind.ROUTE, route, destination, _profile.detour_lookahead_distance)
		follow = RouteGuidance.Follow.new()
	var out: Variant = script.Output.new()
	var a_t: float = profile.thruster_strength / profile.mass
	var r := {trace = PackedVector3Array(), arrived = false, arrive_time = -1.0, speeds = "", min_speed = velocity.length(),
		min_speed_after_5 = INF, max_braking = 0.0, total_braking = 0.0, turn_min_speed = velocity.length(), turn_max_braking = 0.0,
		turn_braking = 0.0, first_difference = -1.0, course_time = -1.0, course_distance = 0.0, path = "",
		max_bow_travel = 0.0, final_bow_travel = 0.0, heading_travel = 0.0, reversals = 0, stops = 0, stop_distance = INF,
		rotation_after = 0.0, travel_turn = 0.0, held = false, held_course = 0.0, course_changed_after_hold = false, both_ticks = 0, main_share = 1.0, peak_sideways = 0.0, target_breaches = 0, authority_start = 0.0,
		peak_rate = 0.0, off_route = 0.0, violations = 0, final_speed = velocity.length()}
	var travelled := 0.0
	var last_sign := 0
	var stopped := false
	var ticks := roundi(seconds / DELTA)
	for i in ticks:
		var t := (i + 1) * DELTA
		state.bow = ShipPilot.bow_of(state.yaw)
		var bow: Vector3 = state.bow
		var v_before: Vector3 = state.velocity
		var speed := v_before.length()
		var yaw_before: float = state.yaw
		if plan != null and targets.has_order:
			RouteGuidance.guide(plan, follow, state.position, state.yaw, guided)
			for field in ["destination", "use_steer", "steer_direction", "steer_distance", "has_course", "course_yaw", "course_follows", "bend_lengths", "bend_radii", "bend_from", "bend_s"]:
				targets.set(field, guided.get(field))
		var had_order: bool = targets.has_order
		script.step(profile, state, targets, DELTA, out)
		var position_before: Vector3 = state.position
		state.position += state.velocity * DELTA
		travelled += (state.position - position_before).length()
		if follow != null:
			follow.time += DELTA
		r.trace.push_back(state.position)
		r.trace.push_back(state.velocity)
		var v: Vector3 = state.velocity
		var new_speed := v.length()
		if speed > 1.0 and new_speed > 1.0:
			r.travel_turn += rad_to_deg(absf(wrapf(atan2(-v.x, -v.z) - atan2(-v_before.x, -v_before.z), -PI, PI)))
		# Course hold (no late arrival spin): once the course stops following, it never changes for the rest of the order.
		if now and had_order and targets.has_course and plan == null:
			if r.held and targets.course_yaw != r.held_course:
				r.course_changed_after_hold = true
			if not r.held and not targets.course_follows:
				r.held = true
				r.held_course = targets.course_yaw
		# Limits: thrusters within their share of the envelope, share + turning within one capacity, main engine.
		if now:
			var e: float = out.directional_effectiveness
			var norm := ShipPilot.envelope_norm(out.thruster_command, bow, a_t, a_t * e, a_t * e)
			var turn_use: float = absf(out.turn_acceleration) / out.turn_authority if out.turn_authority > 0.0 else 0.0
			if norm > out.planar_share + 1e-3 or out.planar_share + turn_use > 1.0 + 1e-3 or out.main_command > profile.main_acceleration + 1e-6:
				r.violations += 1
			if had_order and targets.has_course and speed > 0.0 and v_before.dot(bow) > 0.0:
				var travel_yaw := atan2(-v_before.x, -v_before.z)
				if absf(wrapf(out.target_yaw - travel_yaw, -PI, PI)) > out.max_bow_angle + 1e-4:
					r.target_breaches += 1
			if i == 0:
				r.authority_start = rad_to_deg(out.turn_authority)
			var forward_total: float = out.main_command + maxf(out.thruster_command.dot(bow), 0.0)
			if had_order and forward_total > 0.05 and out.main_command > 0.0 and plan == null and absf(v_before.cross(bow).y) < 1e-6:
				r.main_share = minf(r.main_share, out.main_command / forward_total)
			r.peak_sideways = maxf(r.peak_sideways, absf(out.thruster_command.dot(Vector3(-bow.z, 0, bow.x))))
		r.peak_rate = maxf(r.peak_rate, absf(rad_to_deg(state.turn_rate)))
		if had_order:
			var braking := (speed - new_speed) / DELTA
			if braking > 0.0:
				r.max_braking = maxf(r.max_braking, braking)
				r.total_braking += speed - new_speed
				if r.course_time < 0.0:
					r.turn_max_braking = maxf(r.turn_max_braking, braking)
					r.turn_braking += speed - new_speed
			r.min_speed = minf(r.min_speed, new_speed)
			if r.course_time < 0.0:
				r.turn_min_speed = minf(r.turn_min_speed, new_speed)
			if t > 5.0:
				r.min_speed_after_5 = minf(r.min_speed_after_5, new_speed)
			# A stop before arrival (below the arrival speed tolerance farther than the arrival tolerance away).
			var away: float = (destination - state.position).length()
			if new_speed < profile.arrival_speed_tolerance and away > profile.arrival_tolerance and velocity != Vector3.ZERO:
				if not stopped:
					r.stops += 1
					r.stop_distance = minf(r.stop_distance, away)
				stopped = true
			elif new_speed > 1.0:
				stopped = false
		r.final_speed = new_speed
		for mark in [0.0, 5.0, 10.0, 15.0, 20.0, 30.0]:
			if (mark == 0.0 and i == 0) or absf(t - mark) < DELTA * 0.5:
				r.speeds += "%5.2f " % new_speed
		if speed > 5.0 and v_before.dot(bow) > 0.0:
			r.max_bow_travel = maxf(r.max_bow_travel, rad_to_deg(acos(clampf(bow.dot(v_before / speed), -1.0, 1.0))))
		if new_speed > 0.5:
			r.final_bow_travel = rad_to_deg(acos(clampf(ShipPilot.bow_of(state.yaw).dot(v / new_speed), -1.0, 1.0)))
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
		# Course established: travel within 5° of the direction to the destination.
		if r.course_time < 0.0 and order and plan == null and new_speed > 0.5 and t > 0.5:
			var to: Vector3 = destination - state.position
			if absf(wrapf(atan2(-v.x, -v.z) - atan2(-to.x, -to.z), -PI, PI)) < deg_to_rad(5.0):
				r.course_time = t
				r.course_distance = travelled
		if r.course_time < 0.0 and i % 300 == 299:
			r.path += "(%.0f, %.0f) " % [state.position.x, state.position.z]
		if plan != null:
			r.off_route = maxf(r.off_route, _distance_to_route(route, state.position))
		if r.arrived:
			r.rotation_after += rad_to_deg(absf(state.yaw - yaw_before))
		if out.arrived and not r.arrived:
			r.arrived = true
			r.arrive_time = t
			targets.has_order = false
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
