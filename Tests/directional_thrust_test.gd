extends SceneTree
## Headless open-space check of directional thrust (no scene, no navigation): drives ShipPilot.step() directly at 60 Hz,
## as the navigator's predictions do, and compares it with two earlier pilots read from Git at run time:
##   SPEED_FADE (81299ce): speed-dependent directional thrust, forward thrust at the sideways limit;
##   BEFORE (4b1d646): the separate forward limit applied to all bow-forward thrust (braking included), before the
##   braking / sideways / forward priority fix.
## Run from the project folder:
##   godot --headless --path . --script res://Tests/directional_thrust_test.gd
## Prints measurements and PASS/FAIL lines; exits with code 1 when any check fails.

const SPEED_FADE := "81299ce"
const BEFORE := "4b1d646"
const DELTA := 1.0 / 60.0
const PROFILE_PATH := "res://Movement/Profiles/frigate_movement_profile.tres"
const EPS := 1e-4
const Baseline := preload("res://Tests/baseline_pilot.gd")

var _failures := 0
var _pilots := {}
## Each earlier commit's own frigate profile, and cached variants of them.
var _base_profiles := {}
var _variants := {}


func _init() -> void:
	var profile: MovementProfile = load(PROFILE_PATH)
	var before := _snapshot(profile)
	_pilots["now"] = ShipPilot
	for commit in [SPEED_FADE, BEFORE]:
		var script := Baseline.load_pilot(commit)
		var old_profile := Baseline.load_profile(commit)
		if script == null or old_profile == null:
			_fail("pilot or profile at %s could not be loaded" % commit)
			quit(1)
			return
		_pilots[commit] = script
		_base_profiles[commit] = old_profile
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
	_test_stern_first(profile)
	_test_combined_allocation(profile)
	_test_moving_and_turning(profile)
	_test_capacity(profile)
	_test_translate_and_rotate(profile)

	print("\n11. Profile unchanged at run time")
	_check(_snapshot(profile) == before, "frigate profile (every property and curve point) identical after all runs")
	_check(no_retro.directional_thrust_curve == profile.directional_thrust_curve and profile.retro_thrusters, "no-retro test copy did not touch the shared profile")
	print("\n%s (%d failed)" % ["ALL PASSED" if _failures == 0 else "FAILURES", _failures])
	quit(1 if _failures > 0 else 0)


# 1. Limits, measured from one step() at each speed (saturated request, no turning).
func _test_limits(profile: MovementProfile) -> void:
	print("\n1. Directional thruster limits (one pilot tick, saturated request, no turning)")
	var a_t := profile.thruster_strength / profile.mass
	# Measurement copy: max_speed raised only so the speed cap cannot hide a pure sideways or forward request at
	# 15 m/s; the curve's domain is in m/s, so effectiveness is unaffected.
	var probe: MovementProfile = profile.duplicate()
	probe.max_speed = 1000.0
	print("   speed   forward assist (expected)   main     sideways (expected)   sternward   stern-first braking (expected)")
	for v in [0.0, 5.0, 10.0, 15.0]:
		var e := ShipPilot.effectiveness_of(profile, v)
		# Was a fixed table of the earlier approved values (0.25 / 0.1875 / 0.125 / 0.0625); now read from the profile.
		var expected_forward := profile.forward_directional_acceleration * e
		var forward_out := ShipPilot.Output.new()
		_one_tick_accel(probe, Vector3.FORWARD * v, Vector3.FORWARD * 10.0, forward_out)
		var forward := forward_out.thruster_command.dot(Vector3.FORWARD)
		# Sideways and sternward limits on the pilot's own allocator with a saturated request: the pilot's guidance turns a
		# desired velocity far off the travel direction progressively (momentum-preserving course changes), so a desired
		# velocity change no longer saturates these directions in one tick.
		var sideways := _allocated(profile, Vector3.FORWARD * v, Vector3.RIGHT).dot(Vector3.RIGHT)
		var sternward := -_allocated(profile, Vector3.FORWARD * v, Vector3.BACK).dot(Vector3.FORWARD)
		# Stern-first at v, desired velocity zero (stop): braking with bow-forward thrust.
		var stern_first := 0.0
		if v > 0.0:
			stern_first = _stop_tick_accel(probe, Vector3.BACK * v).dot(Vector3.FORWARD)
		print("   %5.1f   %9.4f (%6.4f)          %6.4f   %8.4f (%6.4f)      %8.4f    %8.4f (%6.4f)" % [v, forward, expected_forward, forward_out.main_command, sideways, a_t * e, sternward, stern_first, a_t * e if v > 0.0 else 0.0])
		_check(absf(forward - expected_forward) < 1e-5, "forward assistance at %.0f m/s = %.4f m/s² (forward_directional_acceleration × curve %.4f)" % [v, forward, expected_forward])
		_check(absf(forward_out.main_command - profile.main_acceleration) < 1e-6 and forward < forward_out.main_command, "main engine %.2f m/s² along the bow, above the forward assistance" % forward_out.main_command)
		_check(absf(sideways - a_t * e) < EPS, "sideways at %.0f m/s = %.3f m/s² (unchanged)" % [v, sideways])
		_check(absf(sternward - a_t) < EPS, "sternward at %.0f m/s keeps %.3f m/s²" % [v, sternward])
		if v > 0.0:
			_check(absf(stern_first - a_t * e) < EPS, "stern-first braking at %.0f m/s = %.3f m/s² (physical bow-forward capacity, not the forward-assistance limit)" % [v, stern_first])


## The thruster command for a saturated request along `direction` at `velocity` (bow = −Z, no turning), on the whole
## planar capacity: ShipPilot.allocate() with the speed-dependent limits, then the retro rule, as in ShipPilot.step().
func _allocated(profile: MovementProfile, velocity: Vector3, direction: Vector3) -> Vector3:
	var a_t := profile.thruster_strength / profile.mass
	var e := ShipPilot.effectiveness_of(profile, velocity.length())
	var command := ShipPilot.allocate(direction * 1000.0, velocity, 1.0, Vector3.FORWARD, profile.pilot_response_time, a_t, a_t * e, profile.forward_directional_acceleration * e)
	var sternward_limit := ShipPilot.sternward_limit_of(profile, a_t)
	var sternward := -command.dot(Vector3.FORWARD)
	if sternward > sternward_limit:
		command += Vector3.FORWARD * (sternward - sternward_limit)
	return command


## Velocity change of one tick from `velocity` (bow = −Z, no turning) when the desired velocity differs from it by
## `change` (m/s), divided by delta.
func _one_tick_accel(profile: MovementProfile, velocity: Vector3, change: Vector3, out := ShipPilot.Output.new()) -> Vector3:
	var state := ShipPilot.State.new()
	state.velocity = velocity
	var desired := velocity + change
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
	return (state.velocity - velocity) / DELTA


func _stop_tick_accel(profile: MovementProfile, velocity: Vector3) -> Vector3:
	var state := ShipPilot.State.new()
	state.velocity = velocity
	var targets := ShipPilot.Targets.new()
	ShipPilot.step(profile, state, targets, DELTA, ShipPilot.Output.new())
	return (state.velocity - velocity) / DELTA


# 2. From rest, straight ahead to cruise: the main engine supplies most of the forward acceleration on every tick.
func _test_main_engine_dominates(profile: MovementProfile) -> void:
	print("\n2. Acceleration from rest toward cruise (order 1000 m ahead, no turning)")
	var traces := {}
	var cruise := {}
	for pilot in [SPEED_FADE, BEFORE, "now"]:
		var script: Variant = _pilots[pilot]
		var pilot_profile := _profile_for(pilot, profile)
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
		var trace := PackedVector3Array()
		for i in 3600:
			_step(script, pilot_profile, state, targets, out)
			trace.push_back(state.velocity)
			var main: float = out.main_command
			var thr := maxf(out.thruster_command.dot(Vector3.FORWARD), 0.0)
			if main + thr > 1e-6:
				worst_share = minf(worst_share, main / (main + thr))
				main_sum += main
				thr_sum += thr
			var speed: float = state.velocity.length()
			for mark in [5.0, 10.0, 14.9]:
				if speed >= mark and not marks.has(mark):
					marks[mark] = (i + 1) * DELTA
			if speed >= 14.9:
				break
		traces[pilot] = trace
		cruise[pilot] = marks.has(14.9)
		print("   %-8s time to 5 / 10 / 14.9 m/s: %s / %s / %s s; distance %.1f m; main engine share of forward acceleration: overall %.1f%%, lowest tick %.1f%%" % [pilot, _t(marks, 5.0), _t(marks, 10.0), _t(marks, 14.9), -state.position.z, 100.0 * main_sum / maxf(main_sum + thr_sum, 1e-9), 100.0 * worst_share])
		if pilot == "now":
			_check(worst_share > 0.5, "main engine provides most of the forward acceleration on every tick (lowest %.1f%%)" % (100.0 * worst_share))
	# Was: identical to BEFORE on every tick (obsolete after the #86 propulsion retune).
	var lateral := 0.0
	for v in traces["now"]:
		lateral = maxf(lateral, absf(v.x))
	_check(lateral == 0.0 and cruise["now"], "straight-ahead acceleration stays on the bow axis (largest sideways speed %.6f m/s) and reaches 14.9 m/s" % lateral)


func _t(marks: Dictionary, key: float) -> String:
	return "%.2f" % marks[key] if marks.has(key) else "—"


# 3 and 4. Sideways repositioning (no hull turn, no forward component): identical to SPEED_FADE tick by tick.
func _test_sideways(profile: MovementProfile, label: String, velocity: Vector3, destination: Vector3, seconds: float) -> void:
	print("\n%s order %s, sideways repositioning" % [label, destination])
	var rows := {}
	for pilot in [SPEED_FADE, BEFORE, "now"]:
		rows[pilot] = _run(pilot, profile, velocity, destination, seconds, true, false)
		var r: Dictionary = rows[pilot]
		print("   %-8s (no course turn) first 1 s sideways accel %.4f m/s², sideways speed at 2 s %.4f, sideways offset at 6 s %.3f m, forward speed at 6 s %.3f" % [pilot, r.side_accel_1s, r.side_speed_2s, r.side_offset_6s, r.fwd_speed_6s])
	if velocity == Vector3.ZERO:
		# Was: identical to SPEED_FADE on every tick (obsolete after the #86 propulsion retune).
		var limit := profile.thruster_strength / profile.mass * ShipPilot.effectiveness_of(profile, 0.0)
		var rest_r: Dictionary = rows["now"]
		_check(rest_r.side_accel_1s >= limit - 2e-3 and absf(rest_r.fwd_speed_6s) < 1e-6 and rest_r.arrived, "sideways repositioning uses the full sideways limit at rest (%.4f vs %.4f m/s²), no forward motion (%.6f m/s at 6 s), arrives (%.2f s)" % [rest_r.side_accel_1s, limit, rest_r.fwd_speed_6s, rest_r.arrive_time])
	else:
		# Per-axis braking no longer counts part of the sideways correction as braking against the growing drift, so the
		# moving case may differ from SPEED_FADE, but only toward more sideways authority and with the same momentum.
		var now_r: Dictionary = rows["now"]
		var fade_r: Dictionary = rows[SPEED_FADE]
		# Momentum-preserving course changes keep the speed SPEED_FADE shed while braking for the new direction, and the
		# sideways limit falls with speed, so the comparison is against the limit at the speed actually held: the
		# sideways correction must use it in full, keep the forward speed and reach the same offset.
		var held_limit := profile.thruster_strength / profile.mass * ShipPilot.effectiveness_of(profile, velocity.length())
		_check(now_r.side_accel_1s >= held_limit - 2e-3 and now_r.side_offset_6s >= fade_r.side_offset_6s - 0.05 and now_r.fwd_speed_6s >= fade_r.fwd_speed_6s - 1e-3, "moving sideways repositioning uses the full sideways limit at the speed held (%.4f vs %.4f m/s²; %s %.4f at its lower speed), offset %.3f m (%.3f m), forward speed kept (%.3f vs %.3f m/s)" % [now_r.side_accel_1s, held_limit, SPEED_FADE, fade_r.side_accel_1s, now_r.side_offset_6s, fade_r.side_offset_6s, now_r.fwd_speed_6s, fade_r.fwd_speed_6s])
	for pilot in [SPEED_FADE, BEFORE, "now"]:
		var r := _run(pilot, profile, velocity, destination, 30.0, true, true)
		print("   %-8s (with course turn) first 1 s sideways accel %.4f m/s², sideways speed at 2 s %.3f, at 4 s %.3f, sideways offset at 6 s %.2f m, arrived %s at %.2f s" % [pilot, r.side_accel_1s, r.side_speed_2s, r.side_speed_4s, r.side_offset_6s, r.arrived, r.arrive_time])


# 5. Straight braking from 15 m/s: idle stop (no order) and arrival at a point ahead.
func _test_braking(profile: MovementProfile, label: String, arrival: bool) -> void:
	print("\n5. Straight braking from 15 m/s, %s, %s" % [label, "arrival at a point 80 m ahead" if arrival else "stop (no order)"])
	var rows := {}
	for pilot in [SPEED_FADE, BEFORE, "now"]:
		var destination := Vector3(0, 0, -80) if arrival else Vector3.ZERO
		rows[pilot] = _run(pilot, profile, Vector3.FORWARD * 15.0, destination, 120.0, arrival, true)
		var r: Dictionary = rows[pilot]
		print("   %-8s stop time %.3f s, stop distance %.3f m, peak deceleration %.3f m/s²%s" % [pilot, r.stop_time, r.stop_distance, r.peak_decel, (", arrived %s at %.2f s" % [r.arrived, r.arrive_time]) if arrival else ""])
	# Was: identical to both earlier pilots on every tick (obsolete after the #86 propulsion retune). Now: braking never
	# beyond the sternward limit (retro rule included); a stop brakes at that limit throughout; an arrival arrives.
	var a_t := profile.thruster_strength / profile.mass
	var limit: float = a_t if profile.retro_thrusters else profile.no_retro_braking_effectiveness * a_t
	var n: Dictionary = rows["now"]
	if arrival:
		# The overshoot-and-return (stop distance beyond 80 m) turns the hull, so the main engine then also pushes back
		# along the start direction; the limit itself is checked on the stop above.
		_check(n.arrived, "%s, arrival: arrives (%.2f s; peak deceleration along the start direction %.3f m/s², braking limit %.3f)" % [label, n.arrive_time, n.peak_decel, limit])
	else:
		_check(n.stop_time > 0.0 and n.peak_decel <= limit + 1e-3 and n.stop_time <= 15.0 / limit + 0.5 and n.stop_distance >= 15.0 * 15.0 / (2.0 * limit) - 0.5, "%s, stop: at the limit %.3f m/s² throughout (%.2f s, %.1f m; at the limit %.2f s, %.1f m), never beyond it (peak %.3f)" % [label, limit, n.stop_time, n.stop_distance, 15.0 / limit, 15.0 * 15.0 / (2.0 * limit), n.peak_decel])


# 6. Regression: braking stern-first travel (bow-forward thrust against the momentum).
func _test_stern_first(profile: MovementProfile) -> void:
	print("\n6. Stern-first braking (regression)")
	for v in [5.0, 10.0, 15.0]:
		var rows := {}
		for pilot in [SPEED_FADE, BEFORE, "now"]:
			rows[pilot] = _run(pilot, profile, Vector3.BACK * v, Vector3.ZERO, 120.0, false, false)
		print("   stop from %4.1f m/s stern-first (no order): %s %.2f s / %.1f m; %s %.2f s / %.1f m; now %.2f s / %.1f m" % [v, SPEED_FADE, rows[SPEED_FADE].stop_time, rows[SPEED_FADE].stop_distance, BEFORE, rows[BEFORE].stop_time, rows[BEFORE].stop_distance, rows["now"].stop_time, rows["now"].stop_distance])
		# Was: identical to SPEED_FADE on every tick (obsolete after the #86 propulsion retune). Now: bow-forward braking at
		# the physical stern-first limit (thruster_strength / mass × curve), not the forward-assistance limit.
		var limit := profile.thruster_strength / profile.mass * ShipPilot.effectiveness_of(profile, v)
		var n: Dictionary = rows["now"]
		_check(n.stop_time > 0.0 and n.peak_decel <= limit + 1e-3 and n.stop_time <= v / limit + 0.5 and n.stop_distance >= v * v / (2.0 * limit) - 0.5, "stern-first stop from %.0f m/s at the limit %.3f m/s² (%.2f s, %.1f m; at the limit %.2f s, %.1f m), never beyond it (peak %.3f)" % [v, limit, n.stop_time, n.stop_distance, v / limit, v * v / (2.0 * limit), n.peak_decel])
	# Moving and turning: 5 m/s stern-first, ordered 100 m ahead and 40 m to the side with the course turn on.
	var destination := Vector3(40, 0, -100)
	var results := {}
	for pilot in [SPEED_FADE, BEFORE, "now"]:
		results[pilot] = _run(pilot, profile, Vector3.BACK * 5.0, destination, 60.0, true, true, pilot == "now")
		var r: Dictionary = results[pilot]
		print("   %-8s 5 m/s stern-first, order (40, −100) with turning: stern-first speed at 2 s %.3f m/s, below 0.5 m/s after %.2f s, gone (crosses zero) after %.2f s; %.2f m astern; arrived %s at %.2f s; priority/limit violations %d" % [pilot, r.stern_speed_2s, r.reverse_10pct, r.reverse_gone, r.astern, r.arrived, r.arrive_time, r.violations])
	var now_r: Dictionary = results["now"]
	var fade_r: Dictionary = results[SPEED_FADE]
	# Was: as effective as SPEED_FADE (its 3.33 m/s² thrusters; obsolete after the #86 propulsion retune). Now: the
	# stern-first motion is braked out and the ship arrives; times are reported, not compared.
	_check(now_r.reverse_10pct > 0.0 and now_r.reverse_gone > 0.0 and now_r.arrived, "stern-first motion braked out while turning (90%% gone after %.2f s, gone after %.2f s, %.2f m astern; %s %.2f s on its own profile) and arrives (%.2f s)" % [now_r.reverse_10pct, now_r.reverse_gone, now_r.astern, SPEED_FADE, fade_r.reverse_10pct, now_r.arrive_time])
	_check(now_r.violations == 0, "every tick: braking first, then sideways, then forward; inside every limit (%s)" % now_r.first_violation)


# 7. Regression: combined forward and sideways requests, allocated directly.
func _test_combined_allocation(profile: MovementProfile) -> void:
	print("\n7. Combined forward and sideways requests at 15 m/s (allocate(), full planar share)")
	var a_t := profile.thruster_strength / profile.mass
	var e := ShipPilot.effectiveness_of(profile, 15.0)
	var side := a_t * e
	var fwd := profile.forward_directional_acceleration * e
	var bow := Vector3.FORWARD
	var right := Vector3.RIGHT
	var tau := profile.pilot_response_time
	var cases := [
		["bow-first, forward 3 + sideways 3", bow, bow * 3.0 + right * 3.0],
		["bow-first, forward 3 + sideways 0.4", bow, bow * 3.0 + right * 0.4],
		["bow-first, braking 0.9 × a_t + sideways 3", bow, -bow * 0.9 * a_t + right * 3.0],
		["drifting right, braking 0.5 + forward 3", right, -right * 0.5 + bow * 3.0],
		["drifting right, braking 3 + forward 3", right, -right * 3.0 + bow * 3.0],
	]
	for case in cases:
		var travel: Vector3 = case[1]
		var request: Vector3 = case[2]
		var command := ShipPilot.allocate(request, travel * 15.0, 1.0, bow, tau, a_t, side, fwd)
		var before := _allocate_before(request, travel, 1.0, bow, a_t, side, fwd)
		print("   %-42s now: forward %+.4f, sideways %+.4f (envelope %.4f); %s: forward %+.4f, sideways %+.4f" % [case[0], command.dot(bow), command.dot(right), ShipPilot.envelope_norm(command, bow, a_t, side, side), BEFORE, before.dot(bow), before.dot(right)])
	var c1 := ShipPilot.allocate(cases[0][2], bow * 15.0, 1.0, bow, tau, a_t, side, fwd)
	_check(absf(c1.dot(right) - side) < EPS and absf(c1.dot(bow)) < EPS, "forward 3 + sideways 3: sideways gets its full %.4f m/s², forward assistance none" % side)
	var c2 := ShipPilot.allocate(cases[1][2], bow * 15.0, 1.0, bow, tau, a_t, side, fwd)
	_check(absf(c2.dot(right) - 0.4) < EPS and c2.dot(bow) > 0.0 and c2.dot(bow) <= fwd + 1e-6, "forward 3 + sideways 0.4: sideways served in full (0.4), forward gets %.4f ≤ %.4f" % [c2.dot(bow), fwd])
	var c3 := ShipPilot.allocate(cases[2][2], bow * 15.0, 1.0, bow, tau, a_t, side, fwd)
	# Was: braking 3 m/s² (below the earlier 3.33 m/s² rating); now 0.9 × the thruster rating, so it still fits.
	_check(absf(-c3.dot(bow) - 0.9 * a_t) < EPS, "braking %.4f + sideways 3: braking served in full first" % (0.9 * a_t))
	var c4 := ShipPilot.allocate(cases[3][2], right * 15.0, 1.0, bow, tau, a_t, side, fwd)
	_check(absf(-c4.dot(right) - 0.5) < EPS and c4.dot(bow) <= fwd + 1e-6, "drifting: braking 0.5 in full, forward assistance ≤ %.4f" % fwd)
	var c5 := ShipPilot.allocate(cases[4][2], right * 15.0, 1.0, bow, tau, a_t, side, fwd)
	_check(absf(-c5.dot(right) - side) < EPS and absf(c5.dot(bow)) < EPS, "drifting: braking 3 takes the whole sideways capacity %.4f, forward none" % side)


## 4b1d646's allocation for comparison: braking first, then the rest scaled together in the envelope with the forward
## limit as its forward semi-axis.
func _allocate_before(request: Vector3, travel: Vector3, capacity: float, bow: Vector3, a_t: float, side: float, fwd: float) -> Vector3:
	return _pilots[BEFORE].allocate(request, travel, capacity, bow, a_t, side, fwd)


# 8. Regression: moving and turning with forward and sideways demands at once; per-tick priority and limits.
func _test_moving_and_turning(profile: MovementProfile) -> void:
	print("\n8. Moving and turning with forward and sideways demand (per-tick priority and limits)")
	var cases := [
		["cruise 15 m/s, order 300 ahead / 40 abeam", Vector3.FORWARD * 15.0, Vector3(40, 0, -300)],
		["5 m/s, order 45° ahead-right 150 m", Vector3.FORWARD * 5.0, Vector3(106, 0, -106)],
		["10 m/s, order 90° right 80 m", Vector3.FORWARD * 10.0, Vector3(80, 0, 0)],
	]
	for case in cases:
		var rows := {}
		for pilot in [SPEED_FADE, BEFORE, "now"]:
			rows[pilot] = _run(pilot, profile, case[1], case[2], 40.0, true, true, pilot == "now")
		for pilot in [SPEED_FADE, BEFORE, "now"]:
			var r: Dictionary = rows[pilot]
			print("   %-44s %-8s first 1 s sideways accel %.4f m/s², sideways speed at 2 s %.3f, forward speed at 6 s %.2f, arrived %s at %.2f s%s" % [case[0], pilot, r.side_accel_1s, r.side_speed_2s, r.fwd_speed_6s, r.arrived, r.arrive_time, ("; violations %d" % r.violations) if pilot == "now" else ""])
		var now_r: Dictionary = rows["now"]
		_check(now_r.violations == 0, "every tick: braking first, sideways second, forward last; inside every limit (%s) %s" % [case[0], now_r.first_violation])


# 9. Forward, sideways, braking and turning together stay inside every limit and the shared capacity.
func _test_capacity(profile: MovementProfile) -> void:
	print("\n9. Combined demands within the limits and the shared capacity (40 s each)")
	var cases := [
		[Vector3.FORWARD * 10.0, Vector3(30, 0, 20), "10 m/s, order behind and to the side"],
		[Vector3.ZERO, Vector3(-50, 0, -60), "rest, order ahead-left"],
		[Vector3(6, 0, -6), Vector3(-80, 0, -10), "drifting, order across the drift"],
		[Vector3.BACK * 5.0, Vector3(0, 0, -100), "5 m/s stern-first, order ahead"],
	]
	for case in cases:
		var r := _run("now", profile, case[0], case[1], 40.0, true, true, true)
		print("   %-38s use of limit (1 = at it): physical envelope %.4f, planar + turning %.4f, forward assistance %.4f, thruster rating %.4f, main engine %.4f; violations %d; arrived %s at %.2f s" % [case[2], r.worst_planar, r.worst_total, r.worst_forward, r.worst_magnitude, r.worst_main, r.violations, r.arrived, r.arrive_time])
		_check(r.violations == 0, "never above a limit or the shared capacity; priority kept (%s) %s" % [case[2], r.first_violation])


# 10. Translation and rotation at the same time: from rest, ordered 60 m at 60° off the bow.
func _test_translate_and_rotate(profile: MovementProfile) -> void:
	print("\n10. Translate while rotating (from rest, order 60 m at 60° off the bow)")
	for pilot in [SPEED_FADE, BEFORE, "now"]:
		var r := _run(pilot, profile, Vector3.ZERO, Vector3(60 * sin(deg_to_rad(60.0)), 0, -60 * cos(deg_to_rad(60.0))), 30.0, true, true, pilot == "now")
		print("   %-8s ticks (of 1800) with the hull turning and the thrusters pushing %d; arrived at %.2f s%s" % [pilot, r.turn_and_thrust, r.arrive_time, ("; violations %d" % r.violations) if pilot == "now" else ""])
		if pilot == "now":
			_check(r.turn_and_thrust > 60 and r.violations == 0, "translation and rotation happen simultaneously, within every limit")


## Runs one pilot from the origin with bow −Z at the given velocity toward a destination (an order when `order`, with the
## course turn when `course`), and measures it. `trace` holds every tick's position and velocity. With `audit` (current
## pilot only) every tick is checked for priority and limits.
func _run(pilot: String, profile: MovementProfile, velocity: Vector3, destination: Vector3, seconds: float, order: bool, course: bool, audit := false) -> Dictionary:
	var script: Variant = _pilots[pilot]
	var pilot_profile := _profile_for(pilot, profile)
	var state: Variant = script.State.new()
	state.velocity = velocity
	var targets: Variant = script.Targets.new()
	targets.has_order = order and destination != Vector3.ZERO
	targets.destination = destination
	targets.has_course = course and targets.has_order
	targets.course_yaw = atan2(-destination.x, -destination.z)
	# As ShipMovement: a direct order's course follows the bearing until arrival braking (pilots before that rule ignore it).
	targets.set("course_follows", targets.has_course)
	var out: Variant = script.Output.new()
	var r := {side_accel_1s = 0.0, side_speed_2s = 0.0, side_speed_4s = 0.0, arrived = false, arrive_time = -1.0,
		fwd_speed_6s = 0.0, side_offset_6s = 0.0, stop_time = -1.0, stop_distance = 0.0, peak_decel = 0.0,
		reverse_gone = -1.0, reverse_10pct = -1.0, stern_speed_2s = 0.0, astern = 0.0, turn_and_thrust = 0, trace = PackedVector3Array(), ticks = 0,
		violations = 0, first_violation = "", worst_planar = 0.0, worst_total = 0.0, worst_forward = 0.0, worst_magnitude = 0.0, worst_main = 0.0}
	var start_dir := velocity.normalized() if velocity != Vector3.ZERO else Vector3.FORWARD
	var right := Vector3(-start_dir.z, 0, start_dir.x)
	var ticks := roundi(seconds / DELTA)
	r.ticks = ticks
	for i in ticks:
		var t := (i + 1) * DELTA
		var before_velocity: Vector3 = state.velocity
		var before_yaw: float = state.yaw
		_step(script, pilot_profile, state, targets, out)
		r.trace.push_back(state.position)
		r.trace.push_back(state.velocity)
		if audit:
			var problem := _audit_tick(profile, before_velocity, before_yaw, out, r)
			if problem != "":
				r.violations += 1
				if r.first_violation == "":
					r.first_violation = "first at %.2f s: %s" % [t, problem]
		var accel: Vector3 = (state.velocity - before_velocity) / DELTA
		r.peak_decel = maxf(r.peak_decel, -accel.dot(start_dir))
		if absf(state.turn_rate) > 1e-4 and out.thruster_command.length() > 0.1:
			r.turn_and_thrust += 1
		if out.arrived and not r.arrived:
			r.arrived = true
			r.arrive_time = t
			targets.has_order = false
		if r.stop_time < 0.0 and velocity != Vector3.ZERO and state.velocity.length() < 0.05:
			r.stop_time = t
			r.stop_distance = state.position.length()
		var bow0 := Vector3.FORWARD
		if velocity.dot(bow0) < 0.0:
			if r.reverse_10pct < 0.0 and -state.velocity.dot(bow0) <= 0.1 * -velocity.dot(bow0):
				r.reverse_10pct = t
			if r.reverse_gone < 0.0 and state.velocity.dot(bow0) >= 0.0:
				r.reverse_gone = t
				r.astern = state.position.dot(-bow0)
			if i == 119:
				r.stern_speed_2s = -state.velocity.dot(bow0)
		if i == 59:
			r.side_accel_1s = state.velocity.dot(right) / 1.0
		if i == 119:
			r.side_speed_2s = state.velocity.dot(right)
		if i == 239:
			r.side_speed_4s = state.velocity.dot(right)
		if i == 359:
			r.fwd_speed_6s = state.velocity.dot(start_dir)
			r.side_offset_6s = state.position.dot(right)
	return r


## One tick's checks for the current pilot (retro thrusters on, so the command is the allocation): the command is the
## allocation of the request; inside the physical envelope's share, the forward-assistance limit, the thruster rating, the
## shared capacity with turning and the main-engine limit; and the priority, checked independently of allocate(): each
## part (braking, then maneuvering, then forward assistance) is either served in full or as far as the envelope allows on
## top of the parts before it (its scale cannot grow), so a later part never uses capacity an earlier one could use.
func _audit_tick(profile: MovementProfile, velocity: Vector3, yaw: float, out: ShipPilot.Output, r: Dictionary) -> String:
	var a_t := profile.thruster_strength / profile.mass
	var tau := profile.pilot_response_time
	var planar := Vector3(velocity.x, 0, velocity.z)
	var speed := planar.length()
	var bow := ShipPilot.bow_of(yaw)
	var e := ShipPilot.effectiveness_of(profile, speed)
	var side := a_t * e
	var fwd := profile.forward_directional_acceleration * e
	var share := out.planar_share
	var request := out.thruster_request
	var command := out.thruster_command
	var parts := ShipPilot.split(request, planar, bow, tau)
	var k := ShipPilot.allocation_scales(request, planar, share, bow, tau, a_t, side, fwd)
	var turn_use := absf(out.turn_acceleration) / out.turn_authority if out.turn_authority > 0.0 else 0.0
	var physical := ShipPilot.envelope_norm(command, bow, a_t, side, side)
	var forward_assist := parts[2].length() * k.z
	r.worst_planar = maxf(r.worst_planar, physical)
	r.worst_total = maxf(r.worst_total, share + turn_use)
	r.worst_forward = maxf(r.worst_forward, forward_assist / fwd if fwd > 0.0 else 0.0)
	r.worst_magnitude = maxf(r.worst_magnitude, command.length() / a_t)
	r.worst_main = maxf(r.worst_main, out.main_command / profile.main_acceleration)
	if ((parts[0] + parts[1] + parts[2]) - request).length() > 1e-5:
		return "split does not sum to the request"
	if (command - (parts[0] * k.x + parts[1] * k.y + parts[2] * k.z)).length() > 1e-5:
		return "command is not the allocation of the request"
	if physical > share + EPS:
		return "physical envelope %.4f above share %.4f" % [physical, share]
	if forward_assist > share * fwd + 1e-6:
		return "forward assistance %.5f above %.5f" % [forward_assist, share * fwd]
	if command.length() > a_t + EPS or share + turn_use > 1.0 + EPS or out.main_command > profile.main_acceleration + 1e-6:
		return "rating, shared capacity or main engine exceeded"
	# Priority: a part left short must sit on the envelope's share edge (or its own forward limit) on top of the earlier parts.
	var base := Vector3.ZERO
	var names := ["braking", "maneuvering", "forward assistance"]
	var scales := [k.x, k.y, k.z]
	for i in 3:
		var part: Vector3 = parts[i]
		var scale: float = scales[i]
		var cap := 1.0 if i < 2 else ShipPilot.forward_scale_cap(part, share, fwd)
		if part != Vector3.ZERO and scale < cap - 1e-6:
			var used := ShipPilot.envelope_norm(base + part * scale, bow, a_t, side, side)
			# 1e-4: the 20-step bisection fixes k to about 1e-6 of the part, which moves the norm by up to about 1e-5 to 1e-4.
			if used < share - EPS:
				return "%s left short (scale %.6f, envelope %.6f of share %.6f) although capacity remained" % [names[i], scale, used, share]
		base += part * scale
	return ""


## One tick as ShipMovement and the navigator's rollout do it, with the position integrated in open space.
func _step(script: Variant, profile: Resource, state: Variant, targets: Variant, out: Variant) -> void:
	state.bow = ShipPilot.bow_of(state.yaw)
	script.step(profile, state, targets, DELTA, out)
	state.position += state.velocity * DELTA


## The profile a pilot runs with: the current one for "now", otherwise that commit's own frigate profile with this
## test's variations (retro thrusters, max_speed) copied onto a cached duplicate.
func _profile_for(pilot: String, profile: MovementProfile) -> Resource:
	if pilot == "now":
		return profile
	var key := "%s|%s|%s" % [pilot, profile.retro_thrusters, profile.max_speed]
	if not _variants.has(key):
		var variant: Resource = _base_profiles[pilot].duplicate()
		variant.retro_thrusters = profile.retro_thrusters
		variant.max_speed = profile.max_speed
		_variants[key] = variant
	return _variants[key]


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
