extends Node3D

## Permanent MovementCheck script, shared by the check scenes. Every child
## MovementController is a ship, numbered 1-9 in scene order. Number keys
## select a ship, right-click orders it, C stops it. The selected ship's
## remaining route is drawn as a line.

const STEP := 1.0 / 60.0
const OUTPUT := "res://builds/issue-14"

## Enabled only on the open-space scene; B/M are check commands, not game UI.
@export var onset_check_enabled := false

@onready var _camera: Camera3D = $Camera3D
@onready var _label: Label = $HUD/Label
@onready var _onset_label: Label = get_node_or_null("HUD/OnsetLabel")

var _ships: Array[MovementController] = []
var _completed_counts: Array[int] = []
var _failed_counts: Array[int] = []
var _selected := 0
var _route_mesh := ImmediateMesh.new()
var _onset_mesh := ImmediateMesh.new()
var _moving_demo_ship: MovementController


func _enter_tree() -> void:
	if not onset_check_enabled:
		return
	# Observe the reusable production ship without copying movement behavior.
	for child in get_children():
		if child is MovementController and not child is ObservedShip:
			var config := [child.profile, child.clearance, child.navigation, child.direct_route]
			child.set_script(ObservedShip)
			child.profile = config[0]
			child.clearance = config[1]
			child.navigation = config[2]
			child.direct_route = config[3]


func _ready() -> void:
	for child in get_children():
		var ship := child as MovementController
		if ship:
			ship.order_completed.connect(_on_order_completed.bind(_ships.size()))
			ship.order_failed.connect(_on_order_failed.bind(_ships.size()))
			_ships.append(ship)
			_completed_counts.append(0)
			_failed_counts.append(0)
	var route_line := MeshInstance3D.new()
	route_line.mesh = _route_mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.1, 0.4, 1.0)
	route_line.material_override = material
	add_child(route_line)
	if onset_check_enabled:
		var onset_line := MeshInstance3D.new()
		onset_line.mesh = _onset_mesh
		var onset_material := StandardMaterial3D.new()
		onset_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		onset_material.no_depth_test = true
		onset_material.albedo_color = Color(1.0, 0.65, 0.05)
		onset_line.material_override = onset_material
		add_child(onset_line)
		# The demo retarget reads actual velocity after the controller's tick.
		process_physics_priority = 1


func _unhandled_input(event: InputEvent) -> void:
	var ship := _ships[_selected]
	var mouse := event as InputEventMouseButton
	if mouse and mouse.pressed and mouse.button_index == MOUSE_BUTTON_RIGHT:
		var origin := _camera.project_ray_origin(mouse.position)
		var direction := _camera.project_ray_normal(mouse.position)
		var hit: Variant = Plane(Vector3.UP, ship.global_position.y).intersects_ray(origin, direction)
		if hit != null:
			_moving_demo_ship = null
			ship.move_to(hit)
		return
	var key := event as InputEventKey
	if not key or not key.pressed or key.echo:
		return
	if key.keycode == KEY_C:
		_moving_demo_ship = null
		ship.stop()
	elif onset_check_enabled and key.keycode == KEY_B:
		_moving_demo_ship = null
		ship.move_to(Vector3(0, ship.global_position.y, 40))
	elif onset_check_enabled and key.keycode == KEY_M:
		ship.move_to(Vector3(0, ship.global_position.y, -100))
		_moving_demo_ship = ship
	elif key.keycode >= KEY_1 and key.keycode < KEY_1 + _ships.size():
		_selected = key.keycode - KEY_1


func _physics_process(_delta: float) -> void:
	if _moving_demo_ship and _moving_demo_ship.velocity.length() >= _moving_demo_ship.profile.max_forward_speed - 0.001:
		var ship := _moving_demo_ship
		_moving_demo_ship = null
		ship.move_to(Vector3(40, ship.global_position.y, 0))


func _process(_delta: float) -> void:
	var ship := _ships[_selected]
	var destination := ship.get_destination()
	var desired := ship.get_desired_direction()
	var route := ship.get_route()
	_label.text = "\n".join([
		"1-%d: select ship   Right-click: move_to   C: stop" % _ships.size(),
		"Selected: %d (%s)" % [_selected + 1, ship.name],
		"State: %s" % MovementController.State.keys()[ship.get_state()],
		"Speed: %.2f units/s" % ship.velocity.length(),
		"Heading: %.1f°" % rad_to_deg(ship.rotation.y),
		"Desired direction: (%.2f, %.2f)" % [desired.x, desired.z],
		"Destination: (%.1f, %.1f)" % [destination.x, destination.z],
		"Waypoint: %d / %d" % [mini(ship.get_waypoint_index() + 1, route.size()), route.size()],
		"order_completed: %d   order_failed: %d" % [_completed_counts[_selected], _failed_counts[_selected]],
	])
	if onset_check_enabled and ship is ObservedShip:
		var observed := ship as ObservedShip
		_onset_label.text = "B: rest -> (0,40)   M: full-speed retarget -> (40,0)   Restart F6 between checks"
		_onset_label.text += "\nOnset order %d: %.2f directional units   Release: %s" % [observed.generation, observed.selected_distance, observed.release_reason]
		_onset_label.text += "\nActual travel: %.3f total / %.3f toward live route   Following: %.3f s" % [observed.total_travel, observed.directional_travel, observed.following_time]
		if observed.first_yaw_tick > 0:
			_onset_label.text += "\nFIRST YAW after %.3f s: %.3f total / %.3f directional units" % [observed.first_yaw_time, observed.distance_before_yaw, observed.directional_before_yaw]
		else:
			_onset_label.text += "\nFIRST YAW: order ended before yaw" if ship.get_state() in [MovementController.State.IDLE, MovementController.State.ARRIVED] and observed.generation > 0 else "\nFIRST YAW: not yet"
		_onset_label.text += "\nFirst motion tick: %d   Release at: %.3f s   Amber: order start + actual trail" % [observed.first_motion_tick, observed.release_time]
		_draw_onset(observed)
	_draw_route(ship, route)


func _draw_onset(ship: ObservedShip) -> void:
	_onset_mesh.clear_surfaces()
	if ship.generation == 0:
		return
	_onset_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var lift := Vector3(0, 3, 0)
	_onset_mesh.surface_add_vertex(ship.order_start + lift + Vector3(-1, 0, 0))
	_onset_mesh.surface_add_vertex(ship.order_start + lift + Vector3(1, 0, 0))
	_onset_mesh.surface_add_vertex(ship.order_start + lift + Vector3(0, 0, -1))
	_onset_mesh.surface_add_vertex(ship.order_start + lift + Vector3(0, 0, 1))
	for i in range(1, ship.trail.size()):
		_onset_mesh.surface_add_vertex(ship.trail[i - 1] + lift)
		_onset_mesh.surface_add_vertex(ship.trail[i] + lift)
	_onset_mesh.surface_end()


func _draw_route(ship: MovementController, route: PackedVector3Array) -> void:
	_route_mesh.clear_surfaces()
	if route.is_empty():
		return
	_route_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	var height := ship.global_position.y + 3.0
	_route_mesh.surface_add_vertex(Vector3(ship.global_position.x, height, ship.global_position.z))
	for i in range(ship.get_waypoint_index(), route.size()):
		_route_mesh.surface_add_vertex(Vector3(route[i].x, height, route[i].z))
	_route_mesh.surface_end()


func _on_order_completed(index: int) -> void:
	_completed_counts[index] += 1
	print("order_completed: ship %d" % (index + 1))


func _on_order_failed(index: int) -> void:
	_failed_counts[index] += 1
	print("order_failed: ship %d" % (index + 1))


# Shared test-only observer for the live HUD and headless regression runner.
class ObservedShip extends MovementController:
	var generation := 0
	var order_tick := 0
	var completed: Array[int] = []
	var completion_ticks: Array[int] = []
	var failed: Array[int] = []
	var requested := Vector3.ZERO
	var order_start := Vector3.ZERO
	var trail := PackedVector3Array()
	var selected_distance := 0.0
	var following_time := 0.0
	var first_yaw_time := 0.0
	var release_time := 0.0
	var preferred_direction := Vector3.ZERO
	var signed_projection := 0.0
	var total_travel := 0.0
	var directional_travel := 0.0
	var directional_before_yaw := 0.0
	var first_motion_tick := 0
	var first_positive_progress_tick := 0
	var release_reason := "pending"
	var release_tick := 0
	var trace: FileAccess
	var first_yaw_tick := 0
	var distance_before_yaw := 0.0
	var max_yaw_step := 0.0
	var max_velocity_step := 0.0
	var max_free_velocity_error := 0.0
	var max_reverse_request := 0.0
	var max_lateral_request := 0.0
	var max_forward_request := 0.0
	var max_vertical_travel := 0.0
	var contact_ticks := 0
	var blocked_ticks := 0
	var waypoint_changes := 0
	var lead_restarts := 0
	var yaw_positive := 0.0
	var yaw_negative := 0.0
	var yaw_direction_changes := 0
	var _last_turn_sign := 0
	var _contact := false
	var _expected_velocity := Vector3.ZERO
	var _tick_delta := STEP

	func _ready() -> void:
		super()
		order_completed.connect(func() -> void:
			completed.append(generation)
			completion_ticks.append(order_tick)
			if release_reason == "pending":
				release_reason = "arrival"
		)
		order_failed.connect(func() -> void:
			failed.append(generation)
			if release_reason == "pending":
				release_reason = "unreachable"
		)

	func stop() -> void:
		super()
		if release_reason == "pending":
			release_reason = "stopped"

	func move_to(goal: Vector3) -> void:
		generation += 1
		order_tick = 0
		first_yaw_tick = 0
		distance_before_yaw = 0.0
		directional_before_yaw = 0.0
		total_travel = 0.0
		directional_travel = 0.0
		first_motion_tick = 0
		first_positive_progress_tick = 0
		release_reason = "pending"
		release_tick = 0
		following_time = 0.0
		first_yaw_time = 0.0
		release_time = 0.0
		order_start = global_position
		trail = PackedVector3Array([order_start])
		selected_distance = profile.rotation_lead_distance_from_rest if _planar(velocity).length() <= profile.blocked_speed_tolerance else profile.rotation_lead_distance_while_moving
		if selected_distance == 0.0:
			release_reason = "immediate"
		yaw_direction_changes = 0
		_last_turn_sign = 0
		super(goal)

	func _limit_to_hull(preferred: Vector3) -> Vector3:
		requested = super(preferred)
		preferred_direction = _planar(preferred).normalized()
		max_reverse_request = maxf(max_reverse_request, requested.dot(global_basis.z))
		max_forward_request = maxf(max_forward_request, requested.dot(-global_basis.z))
		max_lateral_request = maxf(max_lateral_request, absf(requested.dot(global_basis.x)))
		var rate := profile.acceleration if requested.length() > velocity.length() else profile.braking
		_expected_velocity = velocity.move_toward(requested, rate * _tick_delta)
		# Query only: the same proposed motion and safe margin as the commit.
		# The reusable footprint is yaw-independent. No extra position writer.
		_contact = test_move(global_transform, _expected_velocity * _tick_delta)
		return requested

	func _advance_rotation_lead(preferred: Vector3, feasible: Vector3, travel: Vector3, delta: float) -> void:
		following_time += delta
		var before_distance := _rotation_lead_distance_remaining
		var before_stall := _rotation_lead_stall_remaining
		var before_timeout := _rotation_lead_timeout_remaining
		signed_projection = travel.dot(_planar(preferred).normalized())
		if signed_projection > 0.0 and first_positive_progress_tick == 0:
			first_positive_progress_tick = order_tick
		directional_travel += maxf(0.0, signed_projection)
		super(preferred, feasible, travel, delta)
		if before_distance > 0.0 and _rotation_lead_distance_remaining == 0.0:
			release_tick = order_tick
			release_time = following_time
			if maxf(0.0, signed_projection) >= before_distance:
				release_reason = "distance"
			elif not preferred.is_zero_approx() and feasible.is_zero_approx() and velocity.length() <= profile.blocked_speed_tolerance:
				release_reason = "zero request"
			elif velocity.length() <= profile.blocked_speed_tolerance and is_zero_approx(maxf(0.0, before_stall - delta)):
				release_reason = "stall"
			elif is_zero_approx(maxf(0.0, before_timeout - delta)):
				release_reason = "timeout"

	func _physics_process(delta: float) -> void:
		_tick_delta = delta
		var before := global_position
		var before_velocity := velocity
		var before_yaw := rotation.y
		var before_lead := _rotation_lead_distance_remaining
		var before_waypoint := _waypoint
		var before_generation := generation
		var rate := profile.braking
		_expected_velocity = velocity.move_toward(Vector3.ZERO, rate * delta)
		requested = Vector3.ZERO
		preferred_direction = Vector3.ZERO
		signed_projection = 0.0
		_contact = false
		order_tick += 1
		super(delta)
		var travel := global_position - before
		var yaw_step := rad_to_deg(angle_difference(before_yaw, rotation.y))
		max_yaw_step = maxf(max_yaw_step, absf(yaw_step))
		max_velocity_step = maxf(max_velocity_step, velocity.distance_to(before_velocity))
		max_vertical_travel = maxf(max_vertical_travel, absf(travel.y))
		if not _contact:
			max_free_velocity_error = maxf(max_free_velocity_error, velocity.distance_to(_expected_velocity))
		if before_generation == generation:
			total_travel += Vector2(travel.x, travel.z).length()
			if generation > 0 and not travel.is_zero_approx():
				trail.append(global_position)
			if first_motion_tick == 0 and not travel.is_zero_approx():
				first_motion_tick = order_tick
			if first_yaw_tick == 0:
				if absf(yaw_step) > 0.00001:
					first_yaw_tick = order_tick
					first_yaw_time = following_time - delta
				else:
					distance_before_yaw += Vector2(travel.x, travel.z).length()
					directional_before_yaw += maxf(0.0, signed_projection)
			if _waypoint != before_waypoint and not _route.is_empty():
				waypoint_changes += 1
			if _rotation_lead_distance_remaining > before_lead + 0.000001:
				lead_restarts += 1
		if _contact:
			contact_ticks += 1
		if get_state() == State.BLOCKED:
			blocked_ticks += 1
		yaw_positive += maxf(0.0, yaw_step)
		yaw_negative += minf(0.0, yaw_step)
		if absf(yaw_step) > 0.001:
			var turn_sign := 1 if yaw_step > 0.0 else -1
			if _last_turn_sign != 0 and _last_turn_sign != turn_sign:
				yaw_direction_changes += 1
			_last_turn_sign = turn_sign
		if trace:
			trace.store_csv_line(PackedStringArray([
				str(order_tick), "%.6f" % (order_tick * delta), str(generation),
				"%.6f" % global_position.x, "%.6f" % global_position.z,
				"%.6f" % travel.x, "%.6f" % travel.z,
				"%.6f" % requested.x, "%.6f" % requested.z,
				"%.6f" % velocity.x, "%.6f" % velocity.z,
				"%.6f" % rad_to_deg(rotation.y), "%.6f" % yaw_step,
				"%.9f" % _rotation_lead_distance_remaining, State.keys()[get_state()],
				str(completed.size()), str(failed.size()), str(_waypoint), str(_contact),
				"%.6f" % preferred_direction.x, "%.6f" % preferred_direction.z,
				"%.6f" % signed_projection, "%.6f" % directional_travel,
				"%.6f" % total_travel, release_reason,
				"%.6f" % _rotation_lead_stall_remaining, "%.6f" % _rotation_lead_timeout_remaining,
			]))

	func open_trace(filename: String) -> void:
		trace = FileAccess.open(OUTPUT.path_join(filename), FileAccess.WRITE)
		assert(trace != null, "Cannot create trace in project builds/issue-14.")
		trace.store_csv_line(PackedStringArray([
			"order_tick", "order_time_s", "generation", "x", "z", "dx", "dz",
			"requested_vx", "requested_vz", "actual_vx", "actual_vz",
			"yaw_deg", "delta_yaw_deg", "lead_distance_remaining", "state",
			"completed", "failed", "waypoint", "contact_query",
			"preferred_dir_x", "preferred_dir_z", "signed_projection", "credited_directional_travel",
			"total_actual_travel", "release_reason", "stall_remaining_s", "timeout_remaining_s",
		]))

	func metrics() -> Dictionary:
		return {
			"generation": generation, "first_yaw_tick": first_yaw_tick,
			"distance_before_yaw": distance_before_yaw, "ticks": order_tick,
			"directional_before_yaw": directional_before_yaw,
			"first_motion_tick": first_motion_tick, "release_reason": release_reason,
			"first_positive_progress_tick": first_positive_progress_tick,
			"release_tick": release_tick,
			"first_yaw_time": first_yaw_time, "release_time": release_time,
			"max_yaw_deg_per_tick": max_yaw_step, "max_velocity_step": max_velocity_step,
			"max_free_velocity_error": max_free_velocity_error,
			"max_reverse_request": max_reverse_request, "max_lateral_request": max_lateral_request,
			"max_forward_request": max_forward_request, "max_vertical_travel": max_vertical_travel,
			"contact_query_ticks": contact_ticks, "blocked_ticks": blocked_ticks,
			"completed_generations": completed.duplicate(), "failed_generations": failed.duplicate(),
			"completion_ticks": completion_ticks.duplicate(),
			"state": State.keys()[get_state()], "position": [global_position.x, global_position.z],
			"yaw_deg": rad_to_deg(rotation.y), "yaw_positive_deg": yaw_positive,
			"yaw_negative_deg": yaw_negative, "waypoint_changes": waypoint_changes,
			"yaw_direction_changes": yaw_direction_changes,
			"lead_restarts": lead_restarts,
		}
