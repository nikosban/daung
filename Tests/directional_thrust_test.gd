extends SceneTree
## Headless open-space check of speed-dependent directional thrust (no scene, no navigation): drives ShipPilot.step()
## directly at 60 Hz, as the navigator's predictions do, and compares it with the pilot at the baseline commit
## (BASELINE, read from Git at run time). Run from the project folder:
##   godot --headless --path . --script res://Tests/directional_thrust_test.gd
## Prints measurements and PASS/FAIL lines; exits with code 1 when any check fails.

const BASELINE := "777483b"
const DELTA := 1.0 / 60.0
const PROFILE_PATH := "res://Movement/Profiles/frigate_movement_profile.tres"

var _failures := 0
var _old: GDScript


func _init() -> void:
	var profile: MovementProfile = load(PROFILE_PATH)
	var before := _snapshot(profile)
	_old = _load_baseline()
	if _old == null:
		_fail("baseline pilot %s could not be loaded" % BASELINE)
		quit(1)
		return
	var no_retro: MovementProfile = profile.duplicate()
	no_retro.retro_thrusters = false

	_test_curve(profile)
	_test_stationary(profile)
	_test_cruise(profile)
	_test_braking(profile, "retro thrusters", false)
	_test_braking(no_retro, "no retro thrusters", false)
	_test_braking(profile, "retro thrusters", true)
	_test_braking(no_retro, "no retro thrusters", true)
	_test_capacity(profile)
	_test_translate_and_rotate(profile)

	print("\n7. Profile unchanged at run time")
	_check(_snapshot(profile) == before, "frigate profile (every property and curve point) identical after all runs")
	_check(no_retro.directional_thrust_curve == profile.directional_thrust_curve and profile.retro_thrusters, "no-retro test copy did not touch the shared profile")
	print("\n%s (%d failed)" % ["ALL PASSED" if _failures == 0 else "FAILURES", _failures])
	quit(1 if _failures > 0 else 0)


# 1. Directional repositioning acceleration against the curve, measured from one step() at each speed.
func _test_curve(profile: MovementProfile) -> void:
	print("\n1. Directional repositioning acceleration (one pilot tick, saturated request, no turning)")
	var a_t := profile.thruster_strength / profile.mass
	# Measurement copy: max_speed raised only so the speed cap cannot hide a pure sideways or forward request at
	# 15 m/s; the curve's domain is in m/s, so effectiveness is unaffected.
	var probe: MovementProfile = profile.duplicate()
	probe.max_speed = 1000.0
	print("   speed   expected   sideways   forward(thr)   sternward   stern-first rated")
	for entry in [[0.0, 1.0], [5.0, 0.75], [10.0, 0.5], [15.0, 0.25]]:
		var v: float = entry[0]
		var expected: float = a_t * entry[1]
		var sideways := _one_tick_accel(probe, v, Vector3.RIGHT * 10.0).dot(Vector3.RIGHT)
		# Forward: the main engine adds its 0.5 m/s²; subtract it to report the directional thrusters alone.
		var forward_out := ShipPilot.Output.new()
		var forward := _one_tick_accel(probe, v, Vector3.FORWARD * 10.0, forward_out).dot(Vector3.FORWARD) - forward_out.main_command
		var sternward := -_one_tick_accel(probe, v, Vector3.BACK * 10.0).dot(Vector3.FORWARD)
		print("   %5.1f   %8.3f   %8.3f   %12.3f   %9.3f" % [v, expected, sideways, forward, sternward])
		_check(absf(sideways - expected) < 1e-3, "sideways at %.0f m/s = %.3f m/s² (curve %.0f%%)" % [v, sideways, entry[1] * 100.0])
		_check(absf(forward - expected) < 1e-3, "bow-forward thrusters at %.0f m/s = %.3f m/s²" % [v, forward])
		_check(absf(sternward - a_t) < 1e-3, "sternward braking at %.0f m/s keeps %.3f m/s²" % [v, sternward])
	for v in [2.5, 7.5, 12.5, 20.0]:
		print("   interpolated/clamped effectiveness at %4.1f m/s: %.3f" % [v, ShipPilot.effectiveness_of(profile, v)])
	_check(absf(ShipPilot.effectiveness_of(profile, 7.5) - 0.625) < 1e-4 and absf(ShipPilot.effectiveness_of(profile, 20.0) - 0.25) < 1e-4, "linear between points, clamped past the end")


## Velocity change of one tick at speed v along the bow (bow = −Z, no turning) when the desired velocity differs from
## the actual one by `change` (m/s), divided by delta.
func _one_tick_accel(profile: MovementProfile, v: float, change: Vector3, out := ShipPilot.Output.new()) -> Vector3:
	var state := ShipPilot.State.new()
	state.velocity = Vector3.FORWARD * v
	var desired := state.velocity + change
	var targets := ShipPilot.Targets.new()
	targets.has_order = true
	targets.destination = Vector3(0, 0, -100000)
	targets.use_steer = true
	targets.steer_direction = desired.normalized()
	targets.steer_distance = desired.length_squared() / (2.0 * 0.01) + 1000.0
	# Exact desired speed: pick the steer distance from the planned braking so sqrt(2 a d) − lag = |desired|.
	var trial := ShipPilot.Output.new()
	ShipPilot.step(profile, state.copy(), targets, DELTA, trial)
	var a := trial.planned_braking
	var lag := a * profile.pilot_response_time
	targets.steer_distance = pow(desired.length() + lag, 2.0) / (2.0 * a)
	ShipPilot.step(profile, state, targets, DELTA, out)
	return (state.velocity - Vector3.FORWARD * v) / DELTA


# 2. A stationary ship ordered 40 m to its beam (abeam, course toward it).
func _test_stationary(profile: MovementProfile) -> void:
	print("\n2. Stationary ship, order 40 m abeam (open space)")
	# The order also turns the hull toward the destination, so proportional sharing gives the planar thrust about half
	# the capacity in the first second in both pilots; strong means as strong as the baseline at low speed.
	var rows := {}
	for pilot in ["baseline", "new"]:
		var r := _run(pilot, profile, Vector3.ZERO, Vector3(40, 0, 0), 30.0)
		rows[pilot] = r
		print("   %-8s peak sideways accel %.3f m/s² (first 1 s mean %.3f), sideways speed at 2 s %.2f m/s, at 4 s %.2f m/s, arrived %s at %.2f s, heading change %.1f°" % [pilot, r.peak_side, r.side_accel_1s, r.side_speed_2s, r.side_speed_4s, r.arrived, r.arrive_time, r.heading_change])
	var new_r: Dictionary = rows["new"]
	var old_r: Dictionary = rows["baseline"]
	_check(new_r.side_accel_1s >= 0.9 * old_r.side_accel_1s, "stationary sideways acceleration over the first second %.3f m/s² is at least 90%% of baseline %.3f" % [new_r.side_accel_1s, old_r.side_accel_1s])
	_check(new_r.arrived, "stationary ship reaches the abeam destination")


# 3. The same 40 m sideways correction from cruise (15 m/s along the bow): order 40 m abeam of a point 300 m ahead.
func _test_cruise(profile: MovementProfile) -> void:
	print("\n3. Cruise 15 m/s, same 40 m sideways correction (order 300 m ahead, 40 m abeam)")
	var results := {}
	for pilot in ["baseline", "new"]:
		var r := _run(pilot, profile, Vector3.FORWARD * 15.0, Vector3(40, 0, -300), 6.0)
		results[pilot] = r
		print("   %-8s first 1 s: sideways accel %.3f m/s², peak %.3f; forward speed at 1 s %.2f, 3 s %.2f, 6 s %.2f m/s; sideways speed at 2 s %.2f m/s; sideways offset at 6 s %.1f m" % [pilot, r.side_accel_1s, r.peak_side, r.fwd_speed_1s, r.fwd_speed_3s, r.fwd_speed_6s, r.side_speed_2s, r.side_offset_6s])
	var stationary := _run("new", profile, Vector3.ZERO, Vector3(40, 0, 0), 2.0)
	var new_r: Dictionary = results["new"]
	var old_r: Dictionary = results["baseline"]
	_check(new_r.side_accel_1s < 0.35 * stationary.side_accel_1s, "cruise sideways acceleration over the first second %.3f m/s² vs stationary %.3f m/s² (%.0f%%)" % [new_r.side_accel_1s, stationary.side_accel_1s, 100.0 * new_r.side_accel_1s / stationary.side_accel_1s])
	_check(new_r.side_accel_1s < 0.35 * old_r.side_accel_1s, "cruise sideways acceleration vs baseline cruise %.3f m/s²" % old_r.side_accel_1s)
	# Peak bound: directional thrusters at 15 m/s plus the main engine's sideways share while the hull turns.
	var bound := profile.thruster_strength / profile.mass * ShipPilot.effectiveness_of(profile, 15.0) + profile.main_acceleration
	_check(new_r.peak_side <= bound, "cruise peak sideways acceleration %.3f m/s² within thrusters at 15 m/s + main engine (%.3f)" % [new_r.peak_side, bound])
	_check(new_r.fwd_speed_1s > 14.0, "forward momentum kept: %.2f m/s after 1 s" % new_r.fwd_speed_1s)


# 4. Straight braking from 15 m/s: idle stop (no order) and arrival at a point ahead.
func _test_braking(profile: MovementProfile, label: String, arrival: bool) -> void:
	print("\n4. Straight braking from 15 m/s, %s, %s" % [label, "arrival at a point 80 m ahead" if arrival else "stop (no order)"])
	var rows := {}
	for pilot in ["baseline", "new"]:
		var destination := Vector3(0, 0, -80) if arrival else Vector3.ZERO
		var r := _run(pilot, profile, Vector3.FORWARD * 15.0, destination, 40.0, arrival)
		rows[pilot] = r
		print("   %-8s stop time %.3f s, stop distance %.3f m, peak deceleration %.3f m/s²%s" % [pilot, r.stop_time, r.stop_distance, r.peak_decel, (", arrived %s at %.2f s, final distance to point %.3f m" % [r.arrived, r.arrive_time, r.final_miss]) if arrival else ""])
	var old_r: Dictionary = rows["baseline"]
	var new_r: Dictionary = rows["new"]
	_check(absf(old_r.stop_time - new_r.stop_time) < 1e-6 and absf(old_r.stop_distance - new_r.stop_distance) < 1e-4, "identical to baseline (%s, %s)" % [label, "arrival" if arrival else "stop"])


# 5. Braking, sideways correction and turning together stay inside the shared capacity.
func _test_capacity(profile: MovementProfile) -> void:
	print("\n5. Combined braking + sideways correction + turning within capacity")
	var a_t := profile.thruster_strength / profile.mass
	# Direct allocation at 15 m/s: braking 3 m/s² sternward and 3 m/s² sideways requested, full planar share.
	var bow := Vector3.FORWARD
	var limit := a_t * ShipPilot.effectiveness_of(profile, 15.0)
	var command := ShipPilot.allocate(Vector3(3, 0, 3), bow, 1.0, bow, a_t, limit)
	print("   allocate at 15 m/s: request braking 3.000 + sideways 3.000 → braking %.3f, sideways %.3f, envelope use %.4f" % [-command.dot(bow), command.x, ShipPilot.envelope_norm(command, bow, a_t, limit)])
	_check(absf(-command.dot(bow) - 3.0) < 1e-6, "braking served in full first")
	_check(absf(ShipPilot.envelope_norm(command, bow, a_t, limit) - 1.0) < 1e-4 and command.x < 3.0, "sideways gets only the remaining capacity")
	var uniform := Vector3(3, 0, 3) / ShipPilot.envelope_norm(Vector3(3, 0, 3), bow, a_t, limit)
	print("   (uniform scaling would give braking %.3f, sideways %.3f)" % [-uniform.dot(bow), uniform.x])

	# Simulated: 10 m/s along the bow, ordered to a point behind and to the side (braking, sideways and a large turn).
	var state := ShipPilot.State.new()
	state.velocity = Vector3.FORWARD * 10.0
	var targets := _targets(state, Vector3(30, 0, 20))
	var out := ShipPilot.Output.new()
	var worst_norm := 0.0
	var worst_total := 0.0
	var worst_magnitude := 0.0
	var both_ticks := 0
	var turn_limit_rated := deg_to_rad(profile.turn_authority / profile.mass)
	for i in 1800:
		var speed := Vector3(state.velocity.x, 0, state.velocity.z).length()
		var bow_now := ShipPilot.bow_of(state.yaw)
		var rudder := profile.rudder_curve.sample(clampf(speed / profile.max_speed, 0.0, 1.0))
		var lim := a_t * ShipPilot.effectiveness_of(profile, speed)
		_step(ShipPilot, profile, state, targets, out)
		var planar_use := ShipPilot.envelope_norm(out.thruster_command, bow_now, a_t, lim)
		var turn_use := absf(out.turn_acceleration) / (turn_limit_rated * rudder) if rudder > 0.0 else 0.0
		worst_norm = maxf(worst_norm, planar_use)
		worst_total = maxf(worst_total, planar_use + turn_use)
		worst_magnitude = maxf(worst_magnitude, out.thruster_command.length())
		if planar_use > 0.5 and turn_use > 0.2:
			both_ticks += 1
		if out.arrived:
			targets.has_order = false
	print("   sim 30 s: worst planar envelope use %.4f, worst planar + turning use %.4f, largest thruster acceleration %.3f m/s² (rating %.3f), ticks with heavy thrust and turning together %d, final speed %.3f m/s" % [worst_norm, worst_total, worst_magnitude, a_t, both_ticks, state.velocity.length()])
	_check(worst_norm <= 1.0 + 1e-4 and worst_total <= 1.0 + 1e-4 and worst_magnitude <= a_t + 1e-4, "never more than the shared capacity or the thruster rating")


# 6. Translation and rotation at the same time: from rest, ordered 60 m at 60° off the bow.
func _test_translate_and_rotate(profile: MovementProfile) -> void:
	print("\n6. Translate while rotating (from rest, order 60 m at 60° off the bow)")
	var state := ShipPilot.State.new()
	var targets := _targets(state, Vector3(60 * sin(deg_to_rad(60.0)), 0, -60 * cos(deg_to_rad(60.0))))
	var out := ShipPilot.Output.new()
	var both := 0
	for i in 600:
		_step(ShipPilot, profile, state, targets, out)
		if absf(state.turn_rate) > 1e-4 and out.thruster_command.length() > 0.1:
			both += 1
		if i == 119:
			print("   at 2 s: speed %.2f m/s, turn rate %.2f °/s, heading %.1f°, thrusters %.2f m/s²" % [state.velocity.length(), rad_to_deg(state.turn_rate), rad_to_deg(state.yaw), out.thruster_command.length()])
	print("   ticks (of 600) with the hull turning and the thrusters pushing at once: %d" % both)
	_check(both > 60, "translation and rotation happen simultaneously")


## Runs one pilot (baseline or new) from the origin with bow −Z at the given velocity toward a destination (an order
## unless `order` is false and the destination is zero), and measures it.
func _run(pilot: String, profile: MovementProfile, velocity: Vector3, destination: Vector3, seconds: float, order := true) -> Dictionary:
	var script: Variant = _old if pilot == "baseline" else ShipPilot
	var state: Variant = script.State.new()
	state.velocity = velocity
	var targets: Variant = script.Targets.new()
	targets.has_order = order and destination != Vector3.ZERO
	targets.destination = destination
	targets.has_course = targets.has_order
	targets.course_yaw = atan2(-destination.x, -destination.z)
	var out: Variant = script.Output.new()
	var r := {peak_side = 0.0, side_accel_1s = 0.0, side_speed_2s = 0.0, side_speed_4s = 0.0, arrived = false, arrive_time = -1.0,
		heading_change = 0.0, fwd_speed_1s = 0.0, fwd_speed_3s = 0.0, fwd_speed_6s = 0.0, side_offset_6s = 0.0,
		stop_time = -1.0, stop_distance = 0.0, peak_decel = 0.0, final_miss = 0.0}
	var start_dir := velocity.normalized() if velocity != Vector3.ZERO else Vector3.FORWARD
	var right := Vector3(-start_dir.z, 0, start_dir.x)
	var ticks := roundi(seconds / DELTA)
	for i in ticks:
		var t := (i + 1) * DELTA
		var before: Vector3 = state.velocity
		_step(script, profile, state, targets, out)
		var accel: Vector3 = (state.velocity - before) / DELTA
		r.peak_side = maxf(r.peak_side, absf(accel.dot(right)))
		r.peak_decel = maxf(r.peak_decel, -accel.dot(start_dir))
		if out.arrived and not r.arrived:
			r.arrived = true
			r.arrive_time = t
			targets.has_order = false
		if r.stop_time < 0.0 and velocity != Vector3.ZERO and state.velocity.length() < 0.05:
			r.stop_time = t
			r.stop_distance = state.position.length()
		if i == 59:
			r.side_accel_1s = state.velocity.dot(right) / 1.0
			r.fwd_speed_1s = state.velocity.dot(start_dir)
		if i == 119:
			r.side_speed_2s = state.velocity.dot(right)
		if i == 179:
			r.fwd_speed_3s = state.velocity.dot(start_dir)
		if i == 239:
			r.side_speed_4s = state.velocity.dot(right)
		if i == 359:
			r.fwd_speed_6s = state.velocity.dot(start_dir)
			r.side_offset_6s = state.position.dot(right)
	r.heading_change = rad_to_deg(state.yaw)
	r.final_miss = (state.position - destination).length()
	return r


func _targets(state: ShipPilot.State, destination: Vector3) -> ShipPilot.Targets:
	var targets := ShipPilot.Targets.new()
	targets.has_order = true
	targets.destination = destination
	var course := destination - state.position
	targets.has_course = true
	targets.course_yaw = atan2(-course.x, -course.z)
	return targets


## One tick as ShipMovement and the navigator's rollout do it, with the position integrated in open space.
func _step(script: Variant, profile: MovementProfile, state: Variant, targets: Variant, out: Variant) -> void:
	state.bow = ShipPilot.bow_of(state.yaw)
	script.step(profile, state, targets, DELTA, out)
	state.position += state.velocity * DELTA


func _load_baseline() -> GDScript:
	var output := []
	if OS.execute("git", ["show", "%s:Movement/pilot.gd" % BASELINE], output, true) != 0:
		return null
	var source: String = output[0].replace("class_name ShipPilot", "")
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		return null
	return script


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
