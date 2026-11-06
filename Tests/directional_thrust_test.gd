extends SceneTree
## Headless open-space check of directional thrust (no scene, no navigation): drives ShipPilot.step() directly at 60 Hz,
## as the navigator's predictions do, and compares it with the pilot at the baseline commit (BASELINE, the previous
## orientation implementation: speed-dependent directional thrust with forward thrust at the sideways limit), read from
## Git at run time. Run from the project folder:
##   godot --headless --path . --script res://Tests/directional_thrust_test.gd
## Prints measurements and PASS/FAIL lines; exits with code 1 when any check fails.

const BASELINE := "81299ce"
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

	_test_limits(profile)
	_test_main_engine_dominates(profile)
	_test_sideways(profile, "3. Stationary", Vector3.ZERO, Vector3(40, 0, 0), 20.0)
	_test_sideways(profile, "4. Cruise 15 m/s,", Vector3.FORWARD * 15.0, Vector3(40, 0, -300), 6.0)
	_test_braking(profile, "retro thrusters", false)
	_test_braking(no_retro, "no retro thrusters", false)
	_test_braking(profile, "retro thrusters", true)
	_test_braking(no_retro, "no retro thrusters", true)
	_test_stern_first_stop(profile)
	_test_capacity(profile)
	_test_translate_and_rotate(profile)

	print("\n8. Profile unchanged at run time")
	_check(_snapshot(profile) == before, "frigate profile (every property and curve point) identical after all runs")
	_check(no_retro.directional_thrust_curve == profile.directional_thrust_curve and profile.retro_thrusters, "no-retro test copy did not touch the shared profile")
	print("\n%s (%d failed)" % ["ALL PASSED" if _failures == 0 else "FAILURES", _failures])
	quit(1 if _failures > 0 else 0)


# 1. Directional thruster limits, measured from one step() at each speed.
func _test_limits(profile: MovementProfile) -> void:
	print("\n1. Directional thruster limits (one pilot tick, saturated request, no turning)")
	var a_t := profile.thruster_strength / profile.mass
	# Measurement copy: max_speed raised only so the speed cap cannot hide a pure sideways or forward request at
	# 15 m/s; the curve's domain is in m/s, so effectiveness is unaffected.
	var probe: MovementProfile = profile.duplicate()
	probe.max_speed = 1000.0
	print("   speed   forward thr (expected)   main engine   sideways (expected)   sternward")
	for entry in [[0.0, 0.25], [5.0, 0.1875], [10.0, 0.125], [15.0, 0.0625]]:
		var v: float = entry[0]
		var e := ShipPilot.effectiveness_of(profile, v)
		var forward_out := ShipPilot.Output.new()
		var forward_total := _one_tick_accel(probe, v, Vector3.FORWARD * 10.0, forward_out).dot(Vector3.FORWARD)
		var forward := forward_out.thruster_command.dot(Vector3.FORWARD)
		var sideways := _one_tick_accel(probe, v, Vector3.RIGHT * 10.0).dot(Vector3.RIGHT)
		var sternward := -_one_tick_accel(probe, v, Vector3.BACK * 10.0).dot(Vector3.FORWARD)
		print("   %5.1f   %9.4f (%6.4f)        %9.4f   %9.4f (%6.4f)      %9.4f   total forward %.4f" % [v, forward, entry[1], forward_out.main_command, sideways, a_t * e, sternward, forward_total])
		_check(absf(forward - entry[1]) < 1e-5, "forward directional at %.0f m/s = %.4f m/s² (approved %.4f)" % [v, forward, entry[1]])
		_check(absf(forward_out.main_command - profile.main_acceleration) < 1e-6 and forward < forward_out.main_command, "main engine %.2f m/s² along the bow, above the directional %.4f" % [forward_out.main_command, forward])
		_check(absf(sideways - a_t * e) < 1e-4, "sideways at %.0f m/s = %.3f m/s² (unchanged)" % [v, sideways])
		_check(absf(sternward - a_t) < 1e-4, "sternward braking at %.0f m/s keeps %.3f m/s²" % [v, sternward])


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
	targets.steer_distance = 1000.0
	# Exact desired speed: pick the steer distance from the planned braking so sqrt(2 a d) − lag = |desired|.
	var trial := ShipPilot.Output.new()
	ShipPilot.step(profile, state.copy(), targets, DELTA, trial)
	var a := trial.planned_braking
	var lag := a * profile.pilot_response_time
	targets.steer_distance = pow(desired.length() + lag, 2.0) / (2.0 * a)
	ShipPilot.step(profile, state, targets, DELTA, out)
	return (state.velocity - Vector3.FORWARD * v) / DELTA


# 2. From rest, straight ahead to cruise: the main engine supplies most of the forward acceleration on every tick.
func _test_main_engine_dominates(profile: MovementProfile) -> void:
	print("\n2. Acceleration from rest toward cruise (order 1000 m ahead, no turning)")
	for pilot in ["baseline", "new"]:
		var script: Variant = _old if pilot == "baseline" else ShipPilot
		var state: Variant = script.State.new()
		var targets: Variant = script.Targets.new()
		targets.has_order = true
		targets.destination = Vector3(0, 0, -1000)
		targets.has_course = true
		var out: Variant = script.Output.new()
		var worst_share := 1.0
		var main_sum := 0.0
		var thr_sum := 0.0
		var marks := {}
		var rows: Array[String] = []
		var next_row := 0.0
		for i in 3600:
			var v: float = state.velocity.length()
			if v >= next_row and next_row <= 14.0:
				rows.push_back("%5.1f m/s: main %.4f + thrusters %.4f m/s²" % [v, out.main_command, out.thruster_command.dot(Vector3.FORWARD)])
				next_row += 2.0 if next_row < 14.0 else 100.0
			_step(script, profile, state, targets, out)
			var main: float = out.main_command
			var thr := maxf(out.thruster_command.dot(Vector3.FORWARD), 0.0)
			if main + thr > 1e-6:
				worst_share = minf(worst_share, main / (main + thr))
				main_sum += main
				thr_sum += thr
			var speed: float = state.velocity.length()
			for mark in [5.0, 10.0, 14.0, 14.9]:
				if speed >= mark and not marks.has(mark):
					marks[mark] = (i + 1) * DELTA
			if speed >= 14.9:
				break
		print("   %-8s time to 5 / 10 / 14 / 14.9 m/s: %s / %s / %s / %s s; distance %.1f m; main share of forward acceleration: overall %.1f%%, lowest tick %.1f%%" % [pilot, _t(marks, 5.0), _t(marks, 10.0), _t(marks, 14.0), _t(marks, 14.9), -state.position.z, 100.0 * main_sum / maxf(main_sum + thr_sum, 1e-9), 100.0 * worst_share])
		print("            per tick at: %s" % "; ".join(rows))
		if pilot == "new":
			_check(worst_share > 0.5, "main engine provides most of the forward acceleration on every tick (lowest %.1f%%)" % (100.0 * worst_share))
			_check(marks.has(14.9), "the ship still reaches cruise")


func _t(marks: Dictionary, key: float) -> String:
	return "%.2f" % marks[key] if marks.has(key) else "—"


# 3 and 4. Sideways repositioning (no hull turn, no forward component): identical to the baseline tick by tick.
# Also prints the same order with the course turn on, which is not pure sideways once the hull has turned.
func _test_sideways(profile: MovementProfile, label: String, velocity: Vector3, destination: Vector3, seconds: float) -> void:
	print("\n%s order %s, sideways repositioning" % [label, destination])
	var pure_old := _run("baseline", profile, velocity, destination, seconds, true, false)
	var pure_new := _run("new", profile, velocity, destination, seconds, true, false)
	for row in [["baseline", pure_old], ["new", pure_new]]:
		var r: Dictionary = row[1]
		print("   %-8s (no course turn) first 1 s sideways accel %.4f m/s², peak %.4f, sideways speed at 2 s %.4f, sideways offset at 6 s %.3f m, forward speed at 6 s %.3f, max forward thrusters %.4f m/s²" % [row[0], r.side_accel_1s, r.peak_side, r.side_speed_2s, r.side_offset_6s, r.fwd_speed_6s, r.max_fwd_thr])
	_check(pure_old.trace == pure_new.trace, "sideways repositioning identical to the baseline on every tick (%d ticks, position and velocity)" % pure_new.ticks)
	for pilot in ["baseline", "new"]:
		var r := _run(pilot, profile, velocity, destination, 30.0, true, true)
		print("   %-8s (with course turn) first 1 s sideways accel %.4f m/s², sideways speed at 2 s %.3f, at 4 s %.3f, sideways offset at 6 s %.2f m, heading after 30 s %.1f°, arrived %s at %.2f s" % [pilot, r.side_accel_1s, r.side_speed_2s, r.side_speed_4s, r.side_offset_6s, r.heading_change, r.arrived, r.arrive_time])


# 5. Straight braking from 15 m/s: idle stop (no order) and arrival at a point ahead.
func _test_braking(profile: MovementProfile, label: String, arrival: bool) -> void:
	print("\n5. Straight braking from 15 m/s, %s, %s" % [label, "arrival at a point 80 m ahead" if arrival else "stop (no order)"])
	var rows := {}
	for pilot in ["baseline", "new"]:
		var destination := Vector3(0, 0, -80) if arrival else Vector3.ZERO
		var r := _run(pilot, profile, Vector3.FORWARD * 15.0, destination, 40.0, arrival, true)
		rows[pilot] = r
		print("   %-8s stop time %.3f s, stop distance %.3f m, peak deceleration %.3f m/s²%s" % [pilot, r.stop_time, r.stop_distance, r.peak_decel, (", arrived %s at %.2f s, final distance to point %.3f m" % [r.arrived, r.arrive_time, r.final_miss]) if arrival else ""])
	var old_r: Dictionary = rows["baseline"]
	var new_r: Dictionary = rows["new"]
	_check(old_r.trace == new_r.trace, "identical to baseline on every tick (%s, %s)" % [label, "arrival" if arrival else "stop"])


# Measurement only (no check): stopping stern-first travel needs bow-forward thrust, now the forward limit, and the main
# engine never brakes, so this braking changes on purpose with the forward limit.
func _test_stern_first_stop(profile: MovementProfile) -> void:
	print("
5b. Stern-first stop from 5 m/s (no order; measurement, consequence of the forward limit)")
	for pilot in ["baseline", "new"]:
		var r := _run(pilot, profile, Vector3.BACK * 5.0, Vector3.ZERO, 60.0, false, false)
		print("   %-8s stop time %.2f s, stop distance %.1f m, peak deceleration %.4f m/s²" % [pilot, r.stop_time, r.stop_distance, r.peak_decel])


# 6. Forward, sideways, braking and turning together stay inside every limit and the shared capacity.
func _test_capacity(profile: MovementProfile) -> void:
	print("\n6. Combined demands within the limits and the shared capacity")
	var a_t := profile.thruster_strength / profile.mass
	var bow := Vector3.FORWARD
	var e := ShipPilot.effectiveness_of(profile, 15.0)
	var side_limit := a_t * e
	var fwd_limit := profile.forward_directional_acceleration * e
	var command := ShipPilot.allocate(Vector3(3, 0, 3), bow, 1.0, bow, a_t, side_limit, fwd_limit)
	print("   allocate at 15 m/s: request braking 3.000 + sideways 3.000 → braking %.3f, sideways %.3f, envelope use %.4f" % [-command.dot(bow), command.x, ShipPilot.envelope_norm(command, bow, a_t, side_limit, fwd_limit)])
	_check(absf(-command.dot(bow) - 3.0) < 1e-6 and absf(ShipPilot.envelope_norm(command, bow, a_t, side_limit, fwd_limit) - 1.0) < 1e-4, "braking served first, sideways only the remainder (unchanged)")
	command = ShipPilot.allocate(Vector3(3, 0, -3), bow, 1.0, bow, a_t, side_limit, fwd_limit)
	print("   allocate at 15 m/s: request forward 3.000 + sideways 3.000 → forward %.4f, sideways %.4f (limits %.4f / %.4f)" % [command.dot(bow), command.x, fwd_limit, side_limit])
	_check(command.dot(bow) <= fwd_limit + 1e-6 and command.x <= side_limit + 1e-6, "combined forward and sideways inside both limits")

	# Simulated orders from different states: braking, sideways correction, forward acceleration and large turns.
	var cases := [
		[Vector3.FORWARD * 10.0, Vector3(30, 0, 20), "10 m/s, order behind and to the side"],
		[Vector3.ZERO, Vector3(-50, 0, -60), "rest, order ahead-left"],
		[Vector3(6, 0, -6), Vector3(-80, 0, -10), "drifting, order across the drift"],
		[Vector3.BACK * 5.0, Vector3(0, 0, -100), "5 m/s stern-first, order ahead"],
	]
	var turn_limit_rated := deg_to_rad(profile.turn_authority / profile.mass)
	for case in cases:
		var state := ShipPilot.State.new()
		state.velocity = case[0]
		var targets := _targets(state, case[1])
		var out := ShipPilot.Output.new()
		var worst := {planar = 0.0, total = 0.0, magnitude = 0.0, forward = 0.0, sideways = 0.0, main = 0.0}
		var heavy := 0
		for i in 2400:
			var speed := Vector3(state.velocity.x, 0, state.velocity.z).length()
			var bow_now := ShipPilot.bow_of(state.yaw)
			var right := Vector3(-bow_now.z, 0, bow_now.x)
			var e_now := ShipPilot.effectiveness_of(profile, speed)
			var side_now := a_t * e_now
			var fwd_now := profile.forward_directional_acceleration * e_now
			var rudder := profile.rudder_curve.sample(clampf(speed / profile.max_speed, 0.0, 1.0))
			_step(ShipPilot, profile, state, targets, out)
			var planar_use := ShipPilot.envelope_norm(out.thruster_command, bow_now, a_t, side_now, fwd_now)
			var turn_use := absf(out.turn_acceleration) / (turn_limit_rated * rudder) if rudder > 0.0 else 0.0
			worst.planar = maxf(worst.planar, planar_use)
			worst.total = maxf(worst.total, planar_use + turn_use)
			worst.magnitude = maxf(worst.magnitude, out.thruster_command.length() / a_t)
			worst.forward = maxf(worst.forward, out.thruster_command.dot(bow_now) / fwd_now if fwd_now > 0.0 else 0.0)
			worst.sideways = maxf(worst.sideways, absf(out.thruster_command.dot(right)) / side_now)
			worst.main = maxf(worst.main, out.main_command / profile.main_acceleration)
			if planar_use > 0.5 and turn_use > 0.2:
				heavy += 1
			if out.arrived:
				targets.has_order = false
		print("   %-38s use of limit (1 = at the limit): planar envelope %.4f, planar + turning %.4f, forward thrusters %.4f, sideways %.4f, thruster rating %.4f, main engine %.4f; heavy thrust + turning ticks %d; final speed %.3f m/s" % [case[2], worst.planar, worst.total, worst.forward, worst.sideways, worst.magnitude, worst.main, heavy, state.velocity.length()])
		var ok: bool = worst.planar <= 1.0 + 1e-4 and worst.total <= 1.0 + 1e-4 and worst.forward <= 1.0 + 1e-4 and worst.sideways <= 1.0 + 1e-4 and worst.magnitude <= 1.0 + 1e-4 and worst.main <= 1.0 + 1e-6
		_check(ok, "never above a limit or the shared capacity (%s)" % case[2])


# 7. Translation and rotation at the same time: from rest, ordered 60 m at 60° off the bow.
func _test_translate_and_rotate(profile: MovementProfile) -> void:
	print("\n7. Translate while rotating (from rest, order 60 m at 60° off the bow)")
	for pilot in ["baseline", "new"]:
		var script: Variant = _old if pilot == "baseline" else ShipPilot
		var state: Variant = script.State.new()
		var targets: Variant = script.Targets.new()
		targets.has_order = true
		targets.destination = Vector3(60 * sin(deg_to_rad(60.0)), 0, -60 * cos(deg_to_rad(60.0)))
		targets.has_course = true
		targets.course_yaw = atan2(-targets.destination.x, -targets.destination.z)
		var out: Variant = script.Output.new()
		var both := 0
		var at_2s := ""
		var arrived := -1.0
		for i in 1800:
			_step(script, profile, state, targets, out)
			if absf(state.turn_rate) > 1e-4 and out.thruster_command.length() > 0.1:
				both += 1
			if i == 119:
				at_2s = "speed %.2f m/s, turn rate %.2f °/s, heading %.1f°, thrusters %.2f m/s²" % [state.velocity.length(), rad_to_deg(state.turn_rate), rad_to_deg(state.yaw), out.thruster_command.length()]
			if out.arrived and arrived < 0.0:
				arrived = (i + 1) * DELTA
				targets.has_order = false
		print("   %-8s at 2 s: %s; ticks (of 1800) with the hull turning and the thrusters pushing %d; arrived at %.2f s" % [pilot, at_2s, both, arrived])
		if pilot == "new":
			_check(both > 60, "translation and rotation happen simultaneously")


## Runs one pilot (baseline or new) from the origin with bow −Z at the given velocity toward a destination (an order
## when `order`, with the course turn when `course`), and measures it. `trace` holds every tick's position and velocity.
func _run(pilot: String, profile: MovementProfile, velocity: Vector3, destination: Vector3, seconds: float, order: bool, course: bool) -> Dictionary:
	var script: Variant = _old if pilot == "baseline" else ShipPilot
	var state: Variant = script.State.new()
	state.velocity = velocity
	var targets: Variant = script.Targets.new()
	targets.has_order = order and destination != Vector3.ZERO
	targets.destination = destination
	targets.has_course = course and targets.has_order
	targets.course_yaw = atan2(-destination.x, -destination.z)
	var out: Variant = script.Output.new()
	var r := {peak_side = 0.0, side_accel_1s = 0.0, side_speed_2s = 0.0, side_speed_4s = 0.0, arrived = false, arrive_time = -1.0,
		heading_change = 0.0, fwd_speed_6s = 0.0, side_offset_6s = 0.0, max_fwd_thr = 0.0,
		stop_time = -1.0, stop_distance = 0.0, peak_decel = 0.0, final_miss = 0.0, trace = PackedVector3Array(), ticks = 0}
	var start_dir := velocity.normalized() if velocity != Vector3.ZERO else Vector3.FORWARD
	var right := Vector3(-start_dir.z, 0, start_dir.x)
	var ticks := roundi(seconds / DELTA)
	r.ticks = ticks
	for i in ticks:
		var t := (i + 1) * DELTA
		var before: Vector3 = state.velocity
		var bow_now := ShipPilot.bow_of(state.yaw)
		_step(script, profile, state, targets, out)
		r.trace.push_back(state.position)
		r.trace.push_back(state.velocity)
		var accel: Vector3 = (state.velocity - before) / DELTA
		r.peak_side = maxf(r.peak_side, absf(accel.dot(right)))
		r.peak_decel = maxf(r.peak_decel, -accel.dot(start_dir))
		r.max_fwd_thr = maxf(r.max_fwd_thr, out.thruster_command.dot(bow_now))
		if out.arrived and not r.arrived:
			r.arrived = true
			r.arrive_time = t
			targets.has_order = false
		if r.stop_time < 0.0 and velocity != Vector3.ZERO and state.velocity.length() < 0.05:
			r.stop_time = t
			r.stop_distance = state.position.length()
		if i == 59:
			r.side_accel_1s = state.velocity.dot(right) / 1.0
		if i == 119:
			r.side_speed_2s = state.velocity.dot(right)
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
