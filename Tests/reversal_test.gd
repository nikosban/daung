extends SceneTree
## Headless open-space check of the reversal rule (no scene, no navigation queries): drives ShipPilot.step() at 60 Hz
## with the order classified once at activation as ShipMovement does (ShipPilot.reversal_angle_of() / is_reversal(),
## Targets.brake_first carried between ticks), and compares it with the pilot and frigate profile at BASELINE (the
## orientation branch before the rule), read from Git at run time. Run from the project folder:
##   godot --headless --path . --script res://Tests/reversal_test.gd
## Prints measurements and PASS/FAIL lines; exits with code 1 when any check fails.

const BASELINE := "978d873"
const DELTA := 1.0 / 60.0
const PROFILE_PATH := "res://Movement/Profiles/frigate_movement_profile.tres"
const Baseline := preload("res://Tests/baseline_pilot.gd")
## Orders are this far from the ship.
const ORDER_DISTANCE := 300.0

var _failures := 0
var _old: GDScript
var _old_profile: Resource
var _profile: MovementProfile


func _init() -> void:
	_profile = load(PROFILE_PATH)
	_old = Baseline.load_pilot(BASELINE)
	_old_profile = Baseline.load_profile(BASELINE)
	if _old == null or _old_profile == null:
		_fail("pilot or profile at %s could not be loaded" % BASELINE)
		quit(1)
		return
	_test_open_space()
	_test_classification()
	_test_commands()
	print("\n%s (%d failed)" % ["ALL PASSED" if _failures == 0 else "FAILURES", _failures])
	quit(1 if _failures > 0 else 0)


# 1. Open-space comparisons: 90 / 135 / 149 / 150 / 165 / 180° from 5 and 15 m/s, and from rest.
func _test_open_space() -> void:
	print("\n1. Open space: bow −Z moving −Z, order %.0f m away at the angle to the right" % ORDER_DISTANCE)
	var a_t := _profile.thruster_strength / _profile.mass
	# The existing stationary movement for the same order, the reference for the movement after reversal braking.
	var rest := {}
	for angle in [150.0, 165.0, 180.0]:
		rest[angle] = _run("now", Vector3.ZERO, 0.0, _at(angle, ORDER_DISTANCE), 120.0)
	for v in [5.0, 15.0]:
		for angle in [90.0, 135.0, 149.0, 150.0, 165.0, 180.0]:
			var destination := _at(angle, ORDER_DISTANCE)
			var old_r := _run("baseline", Vector3.FORWARD * v, 0.0, destination, 120.0)
			var new_r := _run("now", Vector3.FORWARD * v, 0.0, destination, 120.0)
			for pair in [["baseline", old_r], ["now", new_r]]:
				var r: Dictionary = pair[1]
				print("   %3.0f° from %4.1f m/s %-8s reversal %-5s speed at 0/2/4/6/8/10/15/20 s %s; near rest %s at %5.2f s after %5.1f m; hull turn while braking %5.1f°; arrived %s at %6.2f s; heading change %6.1f°, reversals %d; nearest approach behind start %.1f m" % [angle, v, pair[0], r.reversal, r.speeds, r.rest_reached, r.rest_time, r.brake_distance, r.brake_turn, r.arrived, r.arrive_time, r.heading_travel, r.reversals, r.overshoot])
				print("      path every 2 s: %s" % r.path)
			if angle < 150.0:
				_check(not new_r.reversal and new_r.trace == old_r.trace, "%.0f° from %.0f m/s: ordinary movement, identical to %s on every tick (arrived %.2f s)" % [angle, v, BASELINE, new_r.arrive_time])
				continue
			_check(new_r.reversal and new_r.rest_reached, "%.0f° from %.0f m/s: committed reversal, brakes to near rest (%.2f s, %.1f m)" % [angle, v, new_r.rest_time, new_r.brake_distance])
			var stop_time: float = (v - _profile.arrival_speed_tolerance) / a_t
			var stop_distance: float = (v * v - _profile.arrival_speed_tolerance * _profile.arrival_speed_tolerance) / (2.0 * a_t)
			_check(new_r.brake_turn == 0.0 and new_r.brake_lateral < 1e-4 and new_r.brake_speedup == 0 and new_r.brake_overlimit == 0, "%.0f° from %.0f m/s: while braking no turn (%.2f°), velocity keeps its direction (lateral %.5f m/s), never speeds up, never beyond the sternward limit (%d ticks)" % [angle, v, new_r.brake_turn, new_r.brake_lateral, new_r.brake_overlimit])
			_check(new_r.rest_time >= stop_time - 0.05 and new_r.brake_distance >= stop_distance - 0.5, "%.0f° from %.0f m/s: the stop costs physical time and distance (%.2f s, %.1f m; at the full thruster limit %.2f s, %.1f m)" % [angle, v, new_r.rest_time, new_r.brake_distance, stop_time, stop_distance])
			var ref: Dictionary = rest[angle]
			_check(new_r.arrived and new_r.stops_after == 0 and new_r.reversals <= ref.reversals + 1 and new_r.heading_travel <= ref.heading_travel + 20.0 and new_r.violations == 0 and new_r.rotation_after == 0.0, "%.0f° from %.0f m/s: after braking arrives (%.2f s, %s %.2f s) without stopping again or circling, turning no more than the same order from rest, one settle at the course allowed (heading change %.1f°, from rest %.1f°; turn-rate reversals %d, from rest %d), inside every limit" % [angle, v, new_r.arrive_time, BASELINE, old_r.arrive_time, new_r.heading_travel, ref.heading_travel, new_r.reversals, ref.reversals])
			_check(new_r.both_after > 30, "%.0f° from %.0f m/s: after braking the hull rotates while it translates (%d ticks)" % [angle, v, new_r.both_after])
	print("\n   From rest")
	for angle in [90.0, 180.0]:
		var destination := _at(angle, ORDER_DISTANCE)
		var old_r := _run("baseline", Vector3.ZERO, 0.0, destination, 120.0)
		var new_r := _run("now", Vector3.ZERO, 0.0, destination, 120.0)
		print("   %3.0f° from rest: reversal %s; arrived %s at %6.2f s (%s %6.2f s); heading change %6.1f°, reversals %d" % [angle, new_r.reversal, new_r.arrived, new_r.arrive_time, BASELINE, old_r.arrive_time, new_r.heading_travel, new_r.reversals])
		_check(not new_r.reversal and new_r.trace == old_r.trace, "%.0f° from rest: existing stationary movement, identical to %s on every tick" % [angle, BASELINE])


# 2. Classification: actual travel direction, not the bow; once per order.
func _test_classification() -> void:
	print("\n2. Classification")
	# Stern-first at 5 m/s (bow −Z, moving +Z); an order ahead of the bow is 180° from the travel.
	var stern := _run("now", Vector3.BACK * 5.0, 0.0, Vector3(0, 0, -200), 90.0)
	_check(stern.reversal and stern.rest_reached and stern.arrived, "stern-first, order ahead of the bow (180° from travel): reversal braking (angle %.1f°), then arrives (%.2f s)" % [rad_to_deg(stern.angle), stern.arrive_time])
	# Bow facing away from the travel (yaw 180°, moving −Z); an order further along the travel is 0° from it.
	var facing := _run("now", Vector3.FORWARD * 5.0, PI, Vector3(0, 0, -200), 90.0)
	_check(not facing.reversal, "moving stern-first toward an order (bow 180° from it, travel 0°): not a reversal (angle %.1f°)" % rad_to_deg(facing.angle))
	# A near-rest ship (below the arrival speed tolerance) is stationary; an order within the arrival tolerance is an arrival.
	var slow := ShipPilot.reversal_angle_of(_profile, Vector3.FORWARD * _profile.arrival_speed_tolerance, Vector3(0, 0, 100))
	var close := ShipPilot.reversal_angle_of(_profile, Vector3.FORWARD * 5.0, Vector3(0, 0, _profile.arrival_tolerance))
	_check(slow < 0.0 and close < 0.0, "at the arrival speed tolerance the ship counts as stationary, within the arrival tolerance an order is an arrival (no reversal)")
	_check(ShipPilot.is_reversal(_profile, deg_to_rad(150.0)) and not ShipPilot.is_reversal(_profile, deg_to_rad(149.9)), "threshold at near_opposite_angle %.1f° inclusive" % _profile.near_opposite_angle)
	# The decision never returns once braking has completed (no switching back and forth).
	var r := _run("now", Vector3.FORWARD * 15.0, 0.0, _at(160.0, ORDER_DISTANCE), 120.0)
	_check(r.flag_changes == 1, "160° from 15 m/s: the commitment clears once and never returns (%d changes)" % r.flag_changes)
	# Exactly 180°: no side flipping. The hull turns one way until it first passes the course (the from-rest overshoot
	# correction is the only reversal allowed), and the ship sets off at once after braking (no stall at rest).
	var straight := _run("now", Vector3.FORWARD * 15.0, 0.0, Vector3(0, 0, ORDER_DISTANCE), 120.0)
	_check(straight.reversals <= 1 and straight.arrived and straight.rest_stall < 0.5, "exactly 180° from 15 m/s: one turn direction until the course (reversals %d), at rest after braking for %.2f s, arrives (%.2f s)" % [straight.reversals, straight.rest_stall, straight.arrive_time])


# 3. New commands during reversal braking (replacement and stop), as ShipMovement activates them.
func _test_commands() -> void:
	print("\n3. Commands during reversal braking (15 m/s, 180° order, replaced at 2 s)")
	var behind := Vector3(0, 0, ORDER_DISTANCE)
	var ahead := _run("now", Vector3.FORWARD * 15.0, 0.0, behind, 90.0, 2.0, Vector3(0, 0, -ORDER_DISTANCE))
	_check(not ahead.second_reversal and ahead.arrived and ahead.second_destination_reached, "new order ahead (%.1f° from travel): ordinary movement at once, arrives (%.2f s)" % [ahead.second_angle, ahead.arrive_time])
	var again := _run("now", Vector3.FORWARD * 15.0, 0.0, behind, 90.0, 2.0, Vector3(40, 0, ORDER_DISTANCE))
	_check(again.second_reversal and again.arrived and again.second_destination_reached, "new order behind (%.1f°): reversal braking again, arrives (%.2f s)" % [again.second_angle, again.arrive_time])
	var stop := _run("now", Vector3.FORWARD * 15.0, 0.0, behind, 30.0, 2.0, Vector3.INF)
	_check(stop.final_speed < 0.01 and stop.brake_speedup == 0, "stop: brakes to rest (final speed %.4f m/s)" % stop.final_speed)


func _at(angle: float, distance: float) -> Vector3:
	var a := deg_to_rad(angle)
	return Vector3(distance * sin(a), 0, -distance * cos(a))


## Runs one pilot from the origin at yaw with `velocity` toward `destination`, classified as ShipMovement does ("now");
## at replace_time (s) the order is replaced by `second` (Vector3.INF: a stop) and classified again.
func _run(pilot: String, velocity: Vector3, yaw: float, destination: Vector3, seconds: float, replace_time := -1.0, second := Vector3.ZERO) -> Dictionary:
	var now := pilot == "now"
	var script: Variant = ShipPilot if now else _old
	var profile: Resource = _profile if now else _old_profile
	var state: Variant = script.State.new()
	state.velocity = velocity
	state.yaw = yaw
	var targets: Variant = script.Targets.new()
	var r := {trace = PackedVector3Array(), reversal = false, angle = -1.0, speeds = "", path = "", rest_reached = false,
		rest_time = -1.0, brake_distance = 0.0, brake_turn = 0.0, brake_lateral = 0.0, brake_speedup = 0, brake_overlimit = 0,
		arrived = false, arrive_time = -1.0, heading_travel = 0.0, reversals = 0, stops_after = 0, both_after = 0,
		rotation_after = 0.0, violations = 0, flag_changes = 0, overshoot = 0.0, second_reversal = false, second_angle = -1.0,
		second_destination_reached = false, final_speed = 0.0, rest_stall = 0.0}
	r.angle = _activate(script, profile, targets, state, destination, now)
	r.reversal = targets.get("brake_first") == true
	var a_t: float = profile.thruster_strength / profile.mass
	var sternward: float = a_t if profile.retro_thrusters else profile.no_retro_braking_effectiveness * a_t
	var out: Variant = script.Output.new()
	var last_sign := 0
	var flag: bool = r.reversal
	var stopped := false
	var start_direction := velocity.normalized()
	var ticks := roundi(seconds / DELTA)
	for i in ticks:
		var t := (i + 1) * DELTA
		if replace_time > 0.0 and absf(t - replace_time) < DELTA * 0.5:
			if second == Vector3.INF:
				targets.has_order = false
				targets.set("brake_first", false)
			else:
				destination = second
				r.second_angle = rad_to_deg(_activate(script, profile, targets, state, destination, now))
				r.second_reversal = targets.get("brake_first") == true
				flag = r.second_reversal
		state.bow = ShipPilot.bow_of(state.yaw)
		var bow: Vector3 = state.bow
		var v_before: Vector3 = state.velocity
		var speed := v_before.length()
		var yaw_before: float = state.yaw
		var had_order: bool = targets.has_order
		var braking_now: bool = targets.get("brake_first") == true
		script.step(profile, state, targets, DELTA, out)
		state.position += state.velocity * DELTA
		r.trace.push_back(state.position)
		r.trace.push_back(state.velocity)
		var v: Vector3 = state.velocity
		var new_speed := v.length()
		var flag_now: bool = targets.get("brake_first") == true
		if flag_now != flag:
			r.flag_changes += 1
			flag = flag_now
		var turned := absf(state.yaw - yaw_before)
		if braking_now and flag_now:
			r.brake_distance += (v * DELTA).length()
			r.brake_turn += rad_to_deg(turned)
			if start_direction != Vector3.ZERO:
				r.brake_lateral = maxf(r.brake_lateral, absf(v.cross(start_direction).y))
			if new_speed > speed + 1e-6:
				r.brake_speedup += 1
			# Deceleration along the bow-first or stern-first travel: at most the sternward or the thruster limit.
			var limit := sternward if v_before.dot(bow) > 0.0 else a_t
			if (speed - new_speed) / DELTA > limit + 1e-3:
				r.brake_overlimit += 1
		if r.reversal and not r.rest_reached and not flag_now:
			r.rest_reached = true
			r.rest_time = t - DELTA
		if had_order and r.rest_reached and new_speed < 0.01:
			r.rest_stall += DELTA
		if not had_order and new_speed > speed + 1e-6:
			r.brake_speedup += 1
		if now:
			var e: float = out.directional_effectiveness
			var norm := ShipPilot.envelope_norm(out.thruster_command, bow, a_t, a_t * e, a_t * e)
			var turn_use: float = absf(out.turn_acceleration) / out.turn_authority if out.turn_authority > 0.0 else 0.0
			if norm > out.planar_share + 1e-3 or out.planar_share + turn_use > 1.0 + 1e-3 or out.main_command > profile.main_acceleration + 1e-6:
				r.violations += 1
		if had_order and not flag_now and (r.rest_reached or not r.reversal):
			if new_speed < profile.arrival_speed_tolerance and (destination - state.position).length() > profile.arrival_tolerance and r.rest_reached and t > r.rest_time + 1.0:
				if not stopped:
					r.stops_after += 1
				stopped = true
			elif new_speed > 1.0:
				stopped = false
			if absf(state.turn_rate) > 1e-4 and out.thruster_command.length() + out.main_command > 0.05:
				r.both_after += 1
		if start_direction != Vector3.ZERO:
			r.overshoot = maxf(r.overshoot, state.position.dot(start_direction))
		for mark in [0.0, 2.0, 4.0, 6.0, 8.0, 10.0, 15.0, 20.0]:
			if (mark == 0.0 and i == 0) or absf(t - mark) < DELTA * 0.5:
				r.speeds += "%5.2f " % new_speed
		if i % 120 == 119 and t <= 40.0:
			r.path += "(%.0f, %.0f) " % [state.position.x, state.position.z]
		r.heading_travel += rad_to_deg(turned)
		var sign := 0
		if absf(state.turn_rate) > deg_to_rad(0.5):
			sign = 1 if state.turn_rate > 0.0 else -1
		if sign != 0:
			if last_sign != 0 and sign != last_sign:
				r.reversals += 1
			last_sign = sign
		if r.arrived:
			r.rotation_after += rad_to_deg(turned)
		if out.arrived and not r.arrived:
			r.arrived = true
			r.arrive_time = t
			r.second_destination_reached = replace_time > 0.0 and t > replace_time
			targets.has_order = false
		r.final_speed = new_speed
	return r


## Activates a move to `destination` as ShipMovement does: course toward it, following it, and ("now") the reversal
## classification from the actual velocity. Returns the course-change angle (radians, -1 when not measured).
func _activate(script: Variant, profile: Resource, targets: Variant, state: Variant, destination: Vector3, now: bool) -> float:
	var course: Vector3 = destination - state.position
	course.y = 0.0
	targets.has_order = true
	targets.destination = destination
	targets.has_course = course != Vector3.ZERO
	if targets.has_course:
		targets.course_yaw = atan2(-course.x, -course.z)
	targets.set("course_follows", targets.has_course)
	if not now:
		return -1.0
	var angle := ShipPilot.reversal_angle_of(profile, state.velocity, course)
	targets.brake_first = ShipPilot.is_reversal(profile, angle)
	return angle


func _check(condition: bool, text: String) -> void:
	print("   %s %s" % ["PASS" if condition else "FAIL", text])
	if not condition:
		_failures += 1


func _fail(text: String) -> void:
	print("FAIL %s" % text)
	_failures += 1
