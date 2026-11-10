extends SceneTree
## Headless open-space feel check of the frigate's propulsion (no scene, no navigation queries): drives ShipPilot.step()
## at 60 Hz with each order classified once at activation as ShipMovement does (ShipPilot.reversal_angle_of() /
## is_reversal(), Targets.brake_first carried between ticks), as Tests/reversal_test.gd does. Run from the project folder:
##   godot --headless --path . --script res://Tests/propulsion_feel_test.gd
## Prints the from-rest table, the stop from cruise and the cruise orders, then PASS/FAIL lines for the #86 feel criteria;
## exits with code 1 when any check fails.

const DELTA := 1.0 / 60.0
const PROFILE_PATH := "res://Movement/Profiles/frigate_movement_profile.tres"
## Frigate hull length in metres (#86), used only to express stopping distance in hull lengths.
const HULL_LENGTH := 20.3
## Stop from cruise: provisional band in hull lengths (#86 done-when 2).
const STOP_BAND := Vector2(4.0, 8.0)
const DISTANCES := [15.0, 40.0, 100.0, 300.0]
const ANGLES := [0.0, 45.0, 90.0, 135.0, 180.0]
const CRUISE_ANGLES := [0.0, 90.0, 149.0, 150.0, 180.0]
const CRUISE_DISTANCE := 300.0
const LIMIT_SECONDS := 240.0

var _failures := 0
var _profile: MovementProfile


func _init() -> void:
	_profile = load(PROFILE_PATH)
	_test_profile()
	var table := _test_from_rest()
	_test_stop()
	_test_cruise()
	_test_criteria(table)
	print("\n%s (%d failed)" % ["ALL PASSED" if _failures == 0 else "FAILURES", _failures])
	quit(1 if _failures > 0 else 0)


# 0. The profile: thrusters weaker than the main engine; directional effectiveness constant between its points.
func _test_profile() -> void:
	var a_t := _profile.thruster_strength / _profile.mass
	print("\n0. Profile: main engine %.3f m/s², thrusters %.3f / %.1f = %.3f m/s², forward assistance %.3f m/s², max speed %.1f m/s" % [_profile.main_acceleration, _profile.thruster_strength, _profile.mass, a_t, _profile.forward_directional_acceleration, _profile.max_speed])
	_check(a_t < _profile.main_acceleration, "thruster acceleration (%.3f) below the main engine (%.3f)" % [a_t, _profile.main_acceleration])
	var lowest := INF
	var highest := -INF
	for i in 61:
		var e := ShipPilot.effectiveness_of(_profile, i * 0.25)
		lowest = minf(lowest, e)
		highest = maxf(highest, e)
	_check(absf(lowest - 1.0) < 1e-6 and absf(highest - 1.0) < 1e-6, "directional effectiveness 1.0 at every 0.25 m/s from 0 to 15 m/s (min %.4f, max %.4f)" % [lowest, highest])
	var braking := HullProbe.minimum_braking(_profile)
	_check(absf(braking - a_t) < 1e-6, "stopping-room braking agrees with the curve (%.4f m/s², thrusters %.4f m/s²)" % [braking, a_t])


# 1. From rest, bow toward −Z: every distance and angle (angle measured to the right of the bow).
func _test_from_rest() -> Dictionary:
	print("\n1. From rest, bow −Z; order at the angle to the right of the bow")
	print("   distance  angle   arrived    time    peak bow-first   peak stern-first   peak sideways")
	var table := {}
	for d in DISTANCES:
		for angle in ANGLES:
			var r := _run(Vector3.ZERO, _at(angle, d))
			table["%d|%d" % [d, angle]] = r
			print("   %6.0f m  %4.0f°   %-5s  %7.2f s   %6.2f m/s       %6.2f m/s         %6.2f m/s" % [d, angle, r.arrived, r.arrive_time, r.peak_bow, r.peak_stern, r.peak_side])
	return table


# 2. Stop from cruise: 15 m/s bow-first, no order.
func _test_stop() -> void:
	print("\n2. Stop from cruise (%.1f m/s bow-first, no order)" % _profile.max_speed)
	var r := _run(Vector3.FORWARD * _profile.max_speed, Vector3.INF)
	var lengths: float = r.stop_distance / HULL_LENGTH
	print("   to rest (below 0.01 m/s) in %.2f s and %.1f m = %.2f hull lengths (hull %.1f m)" % [r.stop_time, r.stop_distance, lengths, HULL_LENGTH])
	_check(r.stop_time > 0.0 and lengths >= STOP_BAND.x and lengths <= STOP_BAND.y, "stop from cruise within %.0f–%.0f hull lengths (%.2f)" % [STOP_BAND.x, STOP_BAND.y, lengths])


# 3. Cruise orders: 15 m/s bow-first, order 300 m away at the angle from the travel direction.
func _test_cruise() -> void:
	print("\n3. Cruise orders (%.1f m/s bow-first, order %.0f m away; reversal from %.0f°)" % [_profile.max_speed, CRUISE_DISTANCE, _profile.near_opposite_angle])
	for angle in CRUISE_ANGLES:
		var r := _run(Vector3.FORWARD * _profile.max_speed, _at(angle, CRUISE_DISTANCE))
		print("   %4.0f°: reversal %-5s arrived %-5s at %7.2f s" % [angle, r.reversal, r.arrived, r.arrive_time])
		_check(r.arrived, "%.0f° from cruise: arrives (%.2f s)" % [angle, r.arrive_time])


# 4. #86 done-when 1 and 3.
func _test_criteria(table: Dictionary) -> void:
	print("\n4. Feel criteria")
	for d in [100.0, 300.0]:
		var ahead: Dictionary = table["%d|0" % d]
		var abeam: Dictionary = table["%d|90" % d]
		var astern: Dictionary = table["%d|180" % d]
		var all_arrived: bool = ahead.arrived and abeam.arrived and astern.arrived
		_check(all_arrived and ahead.arrive_time < abeam.arrive_time and abeam.arrive_time < astern.arrive_time, "%.0f m from rest: dead ahead fastest, abeam next, dead astern slowest (%.2f / %.2f / %.2f s)" % [d, ahead.arrive_time, abeam.arrive_time, astern.arrive_time])
	for d in DISTANCES:
		var bow_peak: float = table["%d|0" % d].peak_bow
		var stern_peak := 0.0
		for angle in ANGLES:
			stern_peak = maxf(stern_peak, table["%d|%d" % [d, angle]].peak_stern)
		_check(stern_peak < bow_peak, "%.0f m: peak stern-first speed on any order (%.2f m/s) below peak bow-first speed dead ahead (%.2f m/s)" % [d, stern_peak, bow_peak])


func _at(angle: float, distance: float) -> Vector3:
	var a := deg_to_rad(angle)
	return Vector3(distance * sin(a), 0, -distance * cos(a))


## Runs the pilot from the origin at yaw 0 (bow −Z) with `velocity` toward `destination` (Vector3.INF: no order, the
## thrusters brake to rest), classified once as ShipMovement does.
func _run(velocity: Vector3, destination: Vector3) -> Dictionary:
	var state := ShipPilot.State.new()
	state.velocity = velocity
	var targets := ShipPilot.Targets.new()
	var r := {arrived = false, arrive_time = -1.0, reversal = false, peak_bow = 0.0, peak_stern = 0.0, peak_side = 0.0,
		stop_time = -1.0, stop_distance = 0.0}
	if destination != Vector3.INF:
		var course := destination - state.position
		targets.has_order = true
		targets.destination = destination
		targets.has_course = true
		targets.course_yaw = atan2(-course.x, -course.z)
		targets.course_follows = true
		targets.brake_first = ShipPilot.is_reversal(_profile, ShipPilot.reversal_angle_of(_profile, state.velocity, course))
		r.reversal = targets.brake_first
	var out := ShipPilot.Output.new()
	for i in roundi(LIMIT_SECONDS / DELTA):
		var t := (i + 1) * DELTA
		state.bow = ShipPilot.bow_of(state.yaw)
		ShipPilot.step(_profile, state, targets, DELTA, out)
		state.position += state.velocity * DELTA
		var along := state.velocity.dot(state.bow)
		r.peak_bow = maxf(r.peak_bow, along)
		r.peak_stern = maxf(r.peak_stern, -along)
		r.peak_side = maxf(r.peak_side, absf(state.velocity.cross(state.bow).y))
		if destination == Vector3.INF:
			if state.velocity.length() < 0.01:
				r.stop_time = t
				r.stop_distance = state.position.length()
				break
		elif out.arrived:
			r.arrived = true
			r.arrive_time = t
			break
	return r


func _check(condition: bool, text: String) -> void:
	print("   %s %s" % ["PASS" if condition else "FAIL", text])
	if not condition:
		_failures += 1
