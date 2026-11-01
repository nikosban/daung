extends SceneTree

## Task #14 regression runner; no production command system or test framework.
## godot --headless --path . --fixed-fps 60 --script Movement/Check/rotation_lead_check.gd
## CSV traces and JSON results go to the ignored project builds/issue-14 folder.
## Each step is one real engine physics frame, manually invoking the production
## controller once at 1/60 s with its automatic processing disabled.

const STEP := 1.0 / 60.0
const OUTPUT := "res://builds/issue-14"


const ObservedShip = preload("res://Movement/Check/movement_check.gd").ObservedShip


class HeldNavigation extends StaticNavigation:
	var hold := false

	func is_ready(kind: NavigationClearance) -> bool:
		return not hold and super(kind)


var _fixture: Node3D
var _ships: Array[ObservedShip] = []
var _results: Array[Dictionary] = []
var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	Engine.physics_ticks_per_second = 60
	call_deferred("_run")


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
		push_error(message)


func _load_fixture(scene_name: String, hold_navigation := false) -> ObservedShip:
	if _fixture:
		for ship in _ships:
			if ship.trace:
				ship.trace.close()
		_fixture.free()
	_ships.clear()
	_fixture = load("res://Movement/Check/" + scene_name + ".tscn").instantiate()
	var nav := _fixture.get_node_or_null("StaticNavigation")
	if nav:
		nav.set_script(HeldNavigation)
		nav.hold = hold_navigation
	for child in _fixture.get_children():
		if child is MovementController:
			var config := [child.profile, child.clearance, child.navigation, child.direct_route]
			child.set_script(ObservedShip)
			child.profile = config[0].duplicate()
			child.clearance = config[1]
			child.navigation = config[2]
			child.direct_route = config[3]
			_ships.append(child)
	root.add_child(_fixture)
	_fixture.set_process(false)
	_fixture.set_physics_process(false)
	_fixture.set_process_unhandled_input(false)
	for ship in _ships:
		ship.set_physics_process(false)
	# Let the existing static shapes and asynchronous navigation maps synchronize.
	await process_frame
	await process_frame
	if nav:
		# Poll the real readiness probe, bypassing only the test hold.
		nav.hold = false
		for frame in 300:
			if nav.is_ready(_ships[0].clearance):
				break
			await physics_frame
		_expect(nav.is_ready(_ships[0].clearance), "navigation became ready")
		nav.hold = hold_navigation
	return _ships[0]


func _step(count := 1) -> void:
	for tick in count:
		await physics_frame
		for ship in _ships:
			ship._physics_process(STEP)


func _finish(ship: ObservedShip, label: String, limit := 9000, check_free_velocity := true) -> void:
	for tick in limit:
		if ship.get_state() == MovementController.State.ARRIVED:
			break
		await _step()
	_expect(ship.get_state() == MovementController.State.ARRIVED, label + ": arrived")
	_expect(ship.completed == [ship.generation], label + ": only current generation completes once")
	_expect(ship.failed.is_empty(), label + ": no failure")
	var final_yaw := ship.rotation.y
	# Arrival may retain sqrt(2 * braking * tolerance) speed; one second is
	# shorter than its allowed stopping time with the frigate's current values.
	for tick in 180:
		if ship.velocity.is_zero_approx():
			break
		await _step()
	await _step(2)
	_expect(ship.completed == [ship.generation], label + ": no repeated completion")
	_expect(is_equal_approx(ship.rotation.y, final_yaw), label + ": no final alignment")
	_expect(ship.velocity.is_zero_approx(), label + ": brakes to rest")
	_expect(ship._rotation_lead_distance_remaining == 0.0, label + ": arrival cleared lead")
	_expect(ship._rotation_lead_timeout_remaining == 0.0 and ship._rotation_lead_stall_remaining == 0.0, label + ": arrival cleared fallback clocks")
	_check_limits(ship, label, check_free_velocity)


func _check_limits(ship: ObservedShip, label: String, check_free_velocity := true) -> void:
	_expect(ship.max_yaw_step <= ship.profile.yaw_rate * STEP + 0.0001, label + ": bounded yaw")
	_expect(ship.max_reverse_request <= ship.profile.max_reverse_speed + 0.00001, label + ": reverse request limit")
	_expect(ship.max_lateral_request <= ship.profile.max_lateral_speed + 0.00001, label + ": lateral request limit")
	_expect(ship.max_forward_request <= ship.profile.max_forward_speed + 0.00001, label + ": forward request limit")
	_expect(ship.max_vertical_travel == 0.0, label + ": XZ travel only")
	# Single-precision positions introduce a small readback error at large coordinates.
	# Contact/recovery can change actual velocity even on a query-clear tick.
	# Those fixtures verify contact semantics separately, not free-space inertia.
	if check_free_velocity:
		_expect(ship.max_free_velocity_error < 0.002, label + ": no noncontact velocity snap")
	_expect(ship.lead_restarts == 0, label + ": no waypoint/contact lead restart")


func _record(label: String, ship: ObservedShip, extra := {}) -> void:
	var result := ship.metrics()
	result["case"] = label
	result.merge(extra)
	_results.append(result)
	print(JSON.stringify(result))


func _direct(label: String, goal: Vector3, no_reverse := false) -> void:
	var ship := await _load_fixture("movement_check")
	if no_reverse:
		ship.profile.max_reverse_speed = 0.0
	if label == "rest_40_behind":
		ship.open_trace("rest_40_behind.csv")
	ship.move_to(goal)
	await _step()
	_expect(ship.rotation.y == 0.0, label + ": first tick holds yaw")
	if no_reverse and goal.x == 0.0:
		_expect(ship.velocity.is_zero_approx(), label + ": no reverse request")
	else:
		_expect(not ship.requested.is_zero_approx(), label + ": immediate translation request")
		_expect(ship.global_position.length() > 0.0, label + ": immediate actual travel")
	await _finish(ship, label)
	if no_reverse and goal.x == 0.0:
		_expect(ship.first_yaw_tick == 2 and ship.first_motion_tick == 3, label + ": prompt no-reverse recovery")
		_expect(ship.release_reason == "zero request", label + ": zero feasible request release")
	else:
		_expect(ship.directional_before_yaw >= ship.profile.rotation_lead_distance_from_rest, label + ": actual directional distance before yaw")
		_expect(ship.release_reason == "distance", label + ": distance release, not fallback")
	if label == "rest_40_behind":
		_expect(ship.first_yaw_tick == 86, label + ": onset at 1-unit crossing")
	_record(label, ship)


func _moving(speed: float) -> void:
	var ship := await _load_fixture("movement_check")
	ship.move_to(Vector3(0, 0, -100))
	for tick in 600:
		if ship.velocity.length() >= speed - 0.001:
			break
		await _step()
	var receipt_velocity := ship.velocity
	var receipt_yaw := ship.rotation.y
	var receipt_position := ship.global_position
	var label := "moving_retarget_%.0f" % speed
	if speed == 5.0:
		ship.open_trace("moving_5_retarget.csv")
	ship.move_to(Vector3(40, 0, 0))
	_expect(is_equal_approx(ship._rotation_lead_distance_remaining, 0.5), label + ": shorter lead selected")
	await _step()
	_expect(ship.rotation.y == receipt_yaw, label + ": initial yaw preserved")
	_expect(ship.requested.x > 0.0 and ship.requested.z > 0.0, label + ": request redirects immediately")
	_expect(ship.velocity.distance_to(receipt_velocity) <= ship.profile.braking * STEP + 0.0001, label + ": inertia preserved")
	if speed == 5.0:
		await _step(5)
		_expect(ship.total_travel > 0.45 and ship.directional_travel == 0.0, label + ": old-course drift earns zero directional credit")
		_expect(ship.rotation.y == receipt_yaw, label + ": old drift cannot release yaw")
	await _finish(ship, label)
	_expect(ship.directional_before_yaw >= ship.profile.rotation_lead_distance_while_moving, label + ": credited new-direction travel before yaw")
	_expect(ship.release_reason == "distance", label + ": no premature stall/timeout release")
	_record(label, ship, {"receipt_speed": receipt_velocity.length(), "receipt_position": [receipt_position.x, receipt_position.z], "goal": [40, 0]})


func _lifecycle() -> void:
	var ship := await _load_fixture("movement_check")
	for speed in [0.0, 0.05, 0.0501]:
		ship.velocity = Vector3(speed, 0, 0)
		# Vector3 components are float32; 0.05 is not exactly representable.
		# Exercise equality against the actual measured value on a private copy.
		ship.profile.blocked_speed_tolerance = ship.velocity.length() if speed == 0.05 else 0.05
		ship.move_to(Vector3(0, 0, 40))
		var selected := 1.0 if speed <= 0.05 else 0.5
		_expect(is_equal_approx(ship._rotation_lead_distance_remaining, selected), "speed threshold %.4f" % speed)
	ship.profile.blocked_speed_tolerance = 0.05
	ship.stop()
	ship.velocity = Vector3.ZERO
	ship.move_to(Vector3(0, 0, 40))
	await _step(8)
	var old_yaw := ship.rotation.y
	ship.stop()
	_expect(ship._rotation_lead_distance_remaining == 0.0, "stop clears lead")
	await _step()
	_expect(ship.get_state() == MovementController.State.IDLE and ship.velocity.length() > 0.05, "Idle coasting remains physical")
	ship.move_to(Vector3(40, 0, 0))
	_expect(is_equal_approx(ship._rotation_lead_distance_remaining, 0.5), "Idle coasting selects moving lead")
	await _step(2)
	ship.stop()
	await _step(60)
	_expect(ship.rotation.y == old_yaw, "no late yaw after stop")
	_expect(ship.completed.is_empty() and ship.failed.is_empty(), "cancellation emits no events")
	_expect(ship.velocity.is_zero_approx(), "stop brakes to rest")
	_record("stop_and_coasting", ship)

	ship = await _load_fixture("movement_check")
	ship.move_to(Vector3(0, 0, 0.5))
	await _step()
	_expect(ship.get_state() == MovementController.State.ARRIVED and ship.rotation.y == 0.0, "short order arrives during lead without yaw")
	_expect(ship._rotation_lead_distance_remaining == 0.0, "short arrival clears lead")
	_expect(ship.velocity.length() > 0.0, "arrival retains braking velocity")
	ship.move_to(Vector3(40, 0, 0))
	_expect(is_equal_approx(ship._rotation_lead_distance_remaining, 1.0), "Arrived coasting below threshold selects rest lead")
	ship.stop()
	ship.velocity = Vector3(0.2, 0, 0)
	ship._state = MovementController.State.ARRIVED
	ship.move_to(Vector3(40, 0, 0))
	_expect(is_equal_approx(ship._rotation_lead_distance_remaining, 0.5), "Arrived coasting above threshold selects moving lead")
	_record("arrival_during_lead", ship)

	ship = await _load_fixture("movement_check")
	ship.profile.rotation_lead_distance_from_rest = 0.0
	ship.profile.rotation_lead_distance_while_moving = 0.0
	ship.move_to(Vector3(0, 0, 40))
	await _step()
	_expect(ship.first_yaw_tick == 1, "zero lead restores immediate yaw")
	_record("zero_lead", ship)

	ship = await _load_fixture("movement_check")
	for goal in [Vector3(0, 0, 40), Vector3(-40, 0, 0), Vector3(0, 0, -40), Vector3(40, 0, 0)]:
		ship.move_to(goal)
		await _step(2)
	await _finish(ship, "rapid_replacement")
	_record("rapid_replacement", ship)

	ship = await _load_fixture("movement_check")
	ship.order_completed.connect(func() -> void:
		if ship.generation == 1:
			ship.move_to(Vector3(40, 0, 0))
	)
	ship.move_to(Vector3(0, 0, 0.5))
	await _step()
	_expect(ship.generation == 2 and ship._rotation_lead_distance_remaining > 0.0, "completion callback preserves replacement lead")
	_expect(ship.completed == [1], "completion callback is once-only for old generation")
	_record("completion_reentrancy", ship)

	ship = await _load_fixture("movement_check")
	ship.velocity = Vector3(0, 0, -5)
	ship.move_to(Vector3(0, 0, -2))
	await _finish(ship, "two_unit_overshoot")
	_record("two_unit_overshoot", ship)


func _fallbacks_and_reversal() -> void:
	var ship := await _load_fixture("movement_check")
	ship.move_to(Vector3(0, 0, -100))
	for tick in 600:
		if ship.velocity.length() >= 4.999:
			break
		await _step()
	ship.move_to(ship.global_position + Vector3(0, 0, 40))
	ship.open_trace("moving_opposite.csv")
	await _finish(ship, "moving_opposite")
	_expect(ship.directional_before_yaw >= 0.5 and ship.release_reason == "distance", "opposing momentum reverses before distance release, without stall fallback")
	_expect(ship.first_positive_progress_tick > 200 and ship.first_yaw_tick < 361, "opposing momentum preserves inertia within hard bound")
	_record("moving_opposite", ship)

	ship = await _load_fixture("movement_check")
	# A private slow-lateral profile reaches neither distance nor stall criteria.
	# Exercise the real six-second bound rather than shortening it for the test.
	ship.profile.max_lateral_speed = 0.1
	ship.profile.rotation_lead_distance_from_rest = 5.0
	ship.move_to(Vector3(40, 0, 0))
	await _step(363)
	_expect(ship.release_reason == "timeout" and ship.release_tick >= 360 and ship.release_tick <= 361, "six-second bound releases insufficient directional progress")
	_expect(ship.first_yaw_tick == ship.release_tick + 1 and ship.directional_before_yaw < 5.0, "timeout release is distinct from successful distance release")
	_record("overall_timeout", ship)


func _navigation_lifecycle() -> void:
	var ship := await _load_fixture("routing_check", true)
	var nav: HeldNavigation = ship.navigation
	ship.move_to(Vector3(-60, 0, -50))
	await _step(30)
	_expect(ship._route_pending and is_equal_approx(ship._rotation_lead_distance_remaining, 1.0), "pending navigation does not consume lead")
	_expect(ship._rotation_lead_stall_remaining == 0.25 and ship._rotation_lead_timeout_remaining == 6.0, "pending navigation consumes neither fallback clock")
	_expect(ship.global_position == Vector3(-60, 0, 60) and ship.rotation.y == 0.0, "pending rest has no travel or yaw")
	ship.stop()
	nav.hold = false
	await _step(30)
	_expect(ship.get_state() == MovementController.State.IDLE and ship.completed.is_empty(), "stop cancels pending route")
	nav.hold = true
	ship.move_to(Vector3(80, 0, -10))
	ship.move_to(Vector3(-60, 0, -50))
	nav.hold = false
	await _step()
	_expect(not ship._route_pending and ship.failed.is_empty(), "replacement cancels stale unreachable request")
	_expect(ship.rotation.y == 0.0 and ship.velocity.length() > 0.0, "first ready tick translates without yaw")
	_expect(ship.preferred_direction.x < 0.0, "wall onset follows the local detour, not a direct line through the wall")
	await _finish(ship, "wall_detour")
	_expect(ship.waypoint_changes > 1, "wall detour crosses multiple waypoints")
	_record("pending_and_wall_detour", ship)

	ship = await _load_fixture("routing_check")
	ship.move_to(Vector3(-60, 0, -50))
	await _step(5)
	ship.move_to(Vector3(80, 0, -10))
	_expect(ship.failed == [2] and ship._rotation_lead_distance_remaining == 0.0, "unreachable during lead fails once and clears lead")
	var old_yaw := ship.rotation.y
	await _step(60)
	_expect(ship.rotation.y == old_yaw and ship.completed.is_empty() and ship.failed == [2], "failure has no late yaw or repeated event")
	_record("unreachable_during_lead", ship)

	ship = await _load_fixture("routing_check")
	ship.order_failed.connect(func() -> void:
		if ship.generation == 1:
			ship.move_to(Vector3(-60, 0, -50))
	)
	ship.move_to(Vector3(80, 0, -10))
	_expect(ship.generation == 2 and ship._rotation_lead_distance_remaining > 0.0, "failure callback preserves replacement lead")
	_expect(ship.failed == [1] and ship.get_state() == MovementController.State.MOVING, "failure callback activates new order")
	_record("failure_reentrancy", ship)


func _collisions() -> void:
	var ship := await _load_fixture("collision_check")
	# Contact from rest during the lead, including a goal inside arrival tolerance.
	ship.position = Vector3(-40, 0, 10.501)
	await process_frame
	await process_frame
	ship.move_to(Vector3(-40, 0, 10.0))
	await _step(5)
	_expect(ship.get_state() == MovementController.State.BLOCKED and ship.completed.is_empty(), "contact takes precedence over nearby arrival during lead")
	_expect(ship._rotation_lead_stall_remaining < 0.25 and ship._rotation_lead_distance_remaining > 0.0, "Blocked ticks consume stall clock")
	await _step(30)
	_expect(ship._rotation_lead_distance_remaining == 0.0, "contact cannot freeze lead")
	_expect(ship.release_reason == "stall" and ship.release_tick <= 17, "contact promptly releases by stall fallback")
	var previous_blocked_ticks := ship.blocked_ticks
	await _step(90)
	_expect(ship.blocked_ticks > previous_blocked_ticks and ship.completed.is_empty() and ship.failed.is_empty(), "solid obstacle retains order and retries")
	_expect(ship.global_position.z >= 10.48, "solid obstacle prevents travel through its footprint")
	_record("obstacle_held", ship)
	_fixture.get_node("Obstacle").queue_free()
	await _finish(ship, "obstacle_removed_retry", 9000, false)
	_record("collision_precedence_and_retry", ship)

	ship = await _load_fixture("collision_check")
	var second := _ships[1]
	var third := _ships[2]
	second.move_to(third.global_position)
	third.move_to(second.global_position)
	await _step(1500)
	_expect(second.get_state() == MovementController.State.BLOCKED and third.get_state() == MovementController.State.BLOCKED, "head-on ships wait Blocked")
	_expect(second.completed.is_empty() and third.completed.is_empty(), "head-on contact never completes")
	_expect(second.global_position.distance_to(third.global_position) >= 20.99, "ship footprints remain separated within engine margin")
	_check_limits(second, "head_on_second", false)
	_check_limits(third, "head_on_third", false)
	_record("head_on_second", second)
	_record("head_on_third", third)

	# Investigate a fresh order at resting contact against zero-lead behavior.
	# Report the existing engine/controller edge case; don't change its policy.
	var resting_contact_results: Array[Dictionary] = []
	for lead in [0.0, 1.0]:
		ship = await _load_fixture("collision_check")
		ship.profile.rotation_lead_distance_from_rest = lead
		ship.position = Vector3(-40, 0, 10.501)
		await process_frame
		await process_frame
		ship.move_to(Vector3(-40, 0, 10.0))
		await _step(35)
		ship.move_to(Vector3(-40, 0, -30))
		await _step(90)
		_record("resting_contact_replacement_lead_%.2f" % lead, ship)
		resting_contact_results.append({"state": ship.get_state(), "position": ship.global_position})
	_expect(resting_contact_results[0] == resting_contact_results[1], "resting-contact replacement unchanged from zero-lead baseline")


func _wall_distance(ship: ObservedShip) -> float:
	var closest := INF
	for child in _fixture.get_children():
		if child is StaticBody3D:
			var shape: BoxShape3D = child.get_node("CollisionShape3D").shape
			var local: Vector3 = child.to_local(ship.global_position)
			var offset := Vector2(maxf(absf(local.x) - shape.size.x / 2.0, 0.0), maxf(absf(local.z) - shape.size.z / 2.0, 0.0))
			closest = minf(closest, offset.length())
	return closest


func _sweep() -> void:
	for replacement_tick in range(1650, 2151, 25):
		var ship := await _load_fixture("routing_check")
		ship.move_to(Vector3(-60, 0, -50))
		# Tick T is the first tick following the replacement, as in PR #12.
		await _step(replacement_tick - 1)
		var receipt_speed := ship.velocity.length()
		ship.move_to(Vector3(-60, 0, 60))
		if replacement_tick == 1800:
			ship.open_trace("wall_replacement_T1800.csv")
		ship.contact_ticks = 0
		ship.blocked_ticks = 0
		ship.yaw_positive = 0.0
		ship.yaw_negative = 0.0
		var minimum := _wall_distance(ship)
		var geometric_contact_ticks := 0
		for tick in 9000:
			await _step()
			var distance := _wall_distance(ship)
			minimum = minf(minimum, distance)
			if distance <= ship.clearance.footprint.radius:
				geometric_contact_ticks += 1
			if ship.get_state() == MovementController.State.ARRIVED:
				break
		var label := "wall_replacement_T%d" % replacement_tick
		_expect(minimum > ship.clearance.footprint.radius, label + ": no geometric contact")
		_expect(ship.contact_ticks == 0 and ship.blocked_ticks == 0, label + ": no collision/Blocked ticks")
		await _finish(ship, label, 1)
		_record(label, ship, {"replacement_tick": replacement_tick, "receipt_speed": receipt_speed, "min_wall_edge_distance": minimum, "geometric_contact_ticks": geometric_contact_ticks})


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--visual="):
			await _visual_check(argument.get_slice("=", 1))
			return
	await _direct("rest_6_behind", Vector3(0, 0, 6))
	await _direct("rest_40_behind", Vector3(0, 0, 40))
	await _direct("rest_side", Vector3(40, 0, 0))
	await _direct("rest_diagonal", Vector3(40, 0, 40))
	await _direct("zero_reverse_behind", Vector3(0, 0, 40), true)
	await _direct("zero_reverse_diagonal", Vector3(40, 0, 40), true)
	await _moving(1.0)
	await _moving(3.0)
	await _moving(5.0)
	await _lifecycle()
	await _fallbacks_and_reversal()
	await _navigation_lifecycle()
	await _collisions()
	await _sweep()
	var shared: MovementProfile = load("res://Movement/Profiles/arrata_frigate_movement.tres")
	_expect(shared.max_reverse_speed == 1.5 and shared.rotation_lead_distance_from_rest == 1.0 and shared.rotation_lead_distance_while_moving == 0.5 and shared.rotation_lead_stall_timeout == 0.25 and shared.rotation_lead_timeout == 6.0, "test copies did not mutate shared profile")
	var report := {"checks": _checks, "failures": _failures, "cases": _results}
	var output := FileAccess.open(OUTPUT.path_join("results.json"), FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t"))
	output.close()
	print("ROTATION_LEAD_CHECK: %d checks, %d failures; %s" % [_checks, _failures.size(), OUTPUT])
	if _fixture:
		for ship in _ships:
			if ship.trace:
				ship.trace.close()
		_fixture.free()
	quit(0 if _failures.is_empty() else 1)


func _visual_check(command: String) -> void:
	if DisplayServer.get_name() == "headless" or command not in ["B", "M"]:
		push_error("Visual check needs a rendered window and --visual=B or --visual=M.")
		quit(1)
		return
	var scene: Node3D = load("res://Movement/Check/movement_check.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var ship: ObservedShip = scene.get_node("Ship")
	var event := InputEventKey.new()
	event.keycode = KEY_B if command == "B" else KEY_M
	event.pressed = true
	Input.parse_input_event(event)
	var expected_generation := 1 if command == "B" else 2
	var before_saved := false
	for frame in 1800:
		await process_frame
		if ship.generation != expected_generation:
			continue
		if ship.release_reason == "distance" and ship.first_yaw_tick == 0 and not before_saved:
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(OUTPUT.path_join(command + "_before_yaw.png"))
			before_saved = true
		if ship.first_yaw_tick > 0 and ship.order_tick >= ship.first_yaw_tick + 60:
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(OUTPUT.path_join(command + "_after_yaw.png"))
			_expect(before_saved, command + ": captured distance crossing before first yaw")
			_expect(ship.release_reason == "distance" and ship.directional_before_yaw >= ship.selected_distance, command + ": rendered key command reached directional target")
			var snapshot := ship.metrics()
			snapshot["hud"] = scene.get_node("HUD/Label").text + "\n" + scene.get_node("HUD/OnsetLabel").text
			var output := FileAccess.open(OUTPUT.path_join(command + "_preview.json"), FileAccess.WRITE)
			output.store_string(JSON.stringify(snapshot, "\t"))
			output.close()
			print("VISUAL_CHECK_" + command + ": " + JSON.stringify(snapshot))
			scene.free()
			quit(0 if _failures.is_empty() else 1)
			return
	push_error(command + ": visual check timed out")
	scene.free()
	quit(1)
