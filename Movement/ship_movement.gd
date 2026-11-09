class_name ShipMovement
extends CharacterBody3D
## Authoritative planar movement for a ship (Movement v3): the only writer of its XZ position, its one
## world-space planar velocity (the built-in velocity) and its yaw. Only Orders (game/command/orders) activates
## commands, through activate_move() and activate_stop(); command intake and the crew delay belong to Orders.
##
## Each physics tick the pilot computes a desired velocity toward the destination that falls with the
## remaining distance (arrival steering) and requests the acceleration that closes the gap to the actual
## velocity within pilot_response_time. The main engine supplies the useful part along the bow; the
## directional thrusters supply the rest. Turning acceleration and the turn-rate limit are curves of actual speed
## (profile.turn_acceleration_curve, profile.turn_rate_curve). While the ship moves bow-first, the steering target is the course limited to
## profile.bow_alignment_curve (actual speed) either side of the travel direction (bow alignment). Their sideways acceleration (thruster_strength / mass) and bow-forward acceleration
## (forward_directional_acceleration for thrust that pushes the ship forward, below the main engine) fade with actual
## speed (profile.directional_thrust_curve); sternward, and bow-forward when braking stern-first motion, they keep their
## physical rating. Within their share, per hull axis, braking against the velocity comes first, sideways maneuvering
## second and forward assistance last, and the approach is planned with the braking the thrusters can actually deliver
## against the travel direction. Turning demand is computed first, so the approach speed is planned
## with the braking that sharing will leave. The pilot also steers the hull toward the order's course heading
## (set once by activate_move(), toward the destination) with bounded angular acceleration and a turn-rate limit, both
## curves of actual speed (weak at rest, peaking at low speed, falling toward cruise). Planar
## and turning demand share the directional thrusters' capacity proportionally. Only applied acceleration
## is integrated; yaw never rotates the velocity, and rotation does not persist without powered turning.
## The desired speed is lowered by the pilot's response lag so braking starts in time (Task #41).
##
## Retro rule (profile.retro_thrusters false): the directional thrusters' acceleration toward the stern (the
## component along -bow) never exceeds no_retro_braking_effectiveness x thruster_strength / mass. It is applied
## after proportional sharing by removing only the excess sternward part (lateral and bow-forward parts are
## untouched, nothing is scaled up). The pilot plans its approach braking with the same limit, projected onto
## the direction of the velocity it must slow (the direction to the destination only at a standstill).
##
## Activation: Orders calls activate_move() or activate_stop() at the start of a physics tick, before any ship moves.
## Activation replaces the active order immediately; Movement has no queue or delay of its own.
##
## Static contact (Task #44): driving into a stationary StaticBody3D ends the active order and zeroes planar
## velocity and turn rate; see _stop_on_static_contact().
##
## Reversal rule: when a move activates, the angle between the actual planar velocity and the direction to the click
## is measured once (ShipPilot.reversal_angle_of()). At or beyond profile.near_opposite_angle the order commits to
## braking first (ShipPilot.Targets.brake_first): the pilot brakes to near rest with no commanded turn, then follows
## the order as from rest. The decision is never re-evaluated; a later move or stop replaces it. The planning job is
## told, so its predictions brake first as well.
##
## Navigation (#60): one ordinary Godot route, with the existing destination resolver. A pending job does not
## remove the active pilot target. Clear space uses a conservative stopping-room query; only nearby constraints
## need local pilot/hull lookahead. Physical clearance can request braking; an unnegotiable route stays blocked.
## No navigation code writes a transform or velocity. Alternative passages belong to a later ticket.

@export var profile: MovementProfile

## Physics clock in seconds (the sum of physics ticks so far), used only for status and log text.
var _clock := 0.0
var _active_move_receipt := 0
## Whether the profile passed validation; activation is ignored otherwise.
var _valid := false
## Roster slot from Fleet (-1 = none). Stored only, for the later ship-traffic tie-break; nothing reads it yet.
var _traffic_slot := -1
var _destination := Vector3.ZERO
## The requested click of the active or last move (Task #54); _destination becomes the resolved point once planned.
var _requested := Vector3.ZERO
var _has_order := false
## Course heading of the current order (yaw in radians), set by activate_move(); no course for a zero-length order.
var _course_yaw := 0.0
var _has_course := false
## Turn rate in rad/s (per ship); zero whenever powered turning is not requested.
var _turn_rate := 0.0
## Previous tick's planar demand fraction on the directional thrusters (0–1). It measures last tick's actual
## thruster demand, so it carries over order replacement and stop(); it starts at 0 (no demand before the
## first tick). Used only to plan the yaw braking authority.
var _planar_fraction_prev := 0.0
## Whether the direct order's course still follows the bearing to the destination (ShipPilot.Targets.course_follows).
var _course_follows := false
## Reversal rule: the activated move's course-change angle (radians, -1 = not measured: near rest or an arrival),
## whether it selected reversal braking, and whether that braking is still to complete (ShipPilot.Targets.brake_first).
var _reversal_angle := -1.0
var _reversal := false
var _brake_first := false
## Previous tick's start-of-tick planar speed (m/s), for the pilot's turn planning while the ship slows.
var _speed_prev := 0.0
## Pilot state, targets and last tick's values (read-only debug getters), reused every tick.
var _pilot_state := ShipPilot.State.new()
var _pilot_targets := ShipPilot.Targets.new()
var _pilot_out := ShipPilot.Output.new()
## Navigation (Task #46): the hull probe, the active order's planning job (null when none) and the plan the pilot
## follows (null for the direct order) with its progress.
var _probe: HullProbe
var _job: Navigator.Job
var _plan: RouteGuidance.Plan
var _follow: RouteGuidance.Follow
## Outcome of the latest activated command for F3 (Task #46): planning, accepted, declined with its reason, arrived,
## stopped or static-contact stop. Kept after the order ends.
var _order_status := "no order yet"
var _navigation_baseline := false
var _clearance_status := ""
var _blocked := false
var _route_refreshed := false
var _reposition_guide := Vector3.ZERO
var _reposition_distance := INF
var _reposition_route_distance := INF
var _reposition_used := 0.0
var _navigation_on_mesh := false
## Endpoint reservation radius (Task 37, #78, m): hull reach + plan_clearance_buffer + arrival allowance.
var _reservation_radius := 0.0


func _ready() -> void:
	if not _profile_valid():
		push_error("ShipMovement needs a MovementProfile with every value above 0, turn acceleration and turn rate curves, a directional thrust curve, forward_directional_acceleration at least 0 and a bow alignment curve; the ship will not move.")
		set_physics_process(false)
		return
	var hull: CollisionShape3D = null
	for child in get_children():
		if child is CollisionShape3D:
			hull = child
			break
	_probe = HullProbe.new(self, hull)
	_reservation_radius = _probe.reach + profile.plan_clearance_buffer + RoutePlanner.arrival_allowance_of(profile)
	_valid = true
	Navigator.register_ship(self)
	EndpointReservations.register(self)


func _exit_tree() -> void:
	Navigator.unregister_ship(self)
	EndpointReservations.unregister(self)


## Called only by Orders when a move becomes due: replaces the active order now; the course is taken from the ship's
## position. Y is ignored. The current velocity carries over. move_receipt is the Orders receipt of this move.
func activate_move(world_position: Vector3, move_receipt: int) -> void:
	if not _valid:
		return
	_active_move_receipt = move_receipt
	_navigation_baseline = false
	_clearance_status = ""
	_blocked = false
	_route_refreshed = false
	_reposition_guide = Vector3.ZERO
	_reposition_distance = INF
	_reposition_route_distance = INF
	_reposition_used = 0.0
	_destination = Vector3(world_position.x, global_position.y, world_position.z)
	_requested = _destination
	_has_order = true
	var course := _destination - global_position
	course.y = 0.0
	_has_course = course != Vector3.ZERO
	_course_follows = _has_course
	if _has_course:
		_course_yaw = atan2(-course.x, -course.z)
	_reversal_angle = ShipPilot.reversal_angle_of(profile, velocity, course)
	_reversal = ShipPilot.is_reversal(profile, _reversal_angle)
	_brake_first = _reversal
	EndpointReservations.release(self)
	_end_navigation()
	_job = Navigator.start_job(self, _probe, world_position, _brake_first)
	_order_status = "planning (%.1f, %.1f)" % [world_position.x, world_position.z]


## Called only by Orders when a stop becomes due: ends the active order now; the ship then brakes toward zero
## velocity with its thrusters and does not hold position.
func activate_stop() -> void:
	if not _valid:
		return
	_clearance_status = ""
	_blocked = false
	_route_refreshed = false
	_has_order = false
	_reversal_angle = -1.0
	_reversal = false
	_brake_first = false
	EndpointReservations.release(self)
	_end_navigation()
	# Orders activates before this ship's tick advances _clock, so report this tick's time.
	_order_status = "stopped at %.2f s" % (_clock + get_physics_process_delta_time())


## Stores this ship's roster slot (a tie-break number for later ship traffic). No behavior uses it yet.
func set_traffic_slot(slot: int) -> void:
	_traffic_slot = slot


## Endpoint reservation radius in metres (Task 37, #78); Fleet spaces its preferred points by twice this.
func get_reservation_radius() -> float:
	return _reservation_radius


## Whether the active order is abandoned after exhausted local recovery (it then holds no reservation).
func is_blocked() -> bool:
	return _blocked


## Whether an order is active (activated and not yet arrived or stopped; also while its plan is being made).
## Commands waiting in Orders do not count.
func has_order() -> bool:
	return _has_order


## Destination of the active order (or of the last one): the click until its plan is taken, then the destination the
## plan leads to (the click, or the resolved point, Task #54).
func get_destination() -> Vector3:
	return _destination


## Returns the accepted destination for this active move, or null while it is unavailable.
## A route refresh keeps the accepted endpoint while it runs.
func get_resolved_move_destination(move_receipt: int) -> Variant:
	if move_receipt <= 0 or move_receipt != _active_move_receipt or not _has_order or _blocked:
		return null
	if _job != null and not _job.refresh:
		return null
	return _destination


## Returns the requested point while this active move's first plan is pending, or null.
func get_planning_move_destination(move_receipt: int) -> Variant:
	if move_receipt > 0 and move_receipt == _active_move_receipt and _has_order and not _blocked and _job != null and not _job.refresh:
		return _requested
	return null


## The requested click of the active or last move (Task #54).
func get_requested_destination() -> Vector3:
	return _requested


## Heading in degrees of yaw (0 = bow toward −Z, positive = counter-clockwise seen from above).
func get_heading() -> float:
	return rad_to_deg(rotation.y)


## Steering target in degrees (same convention as get_heading()): the course heading, limited by bow alignment while
## the ship moves bow-first.
func get_target_heading() -> float:
	return rad_to_deg(wrapf(_pilot_out.target_yaw, -PI, PI))


## Course heading the pilot was given last tick in degrees (the order's course, or route guidance's).
func get_course_heading() -> float:
	return rad_to_deg(wrapf(_pilot_out.course_yaw, -PI, PI))


## Actual angle between bow and travel direction in degrees (0–180; 0 at rest), at the start of last tick.
func get_bow_travel_angle() -> float:
	return rad_to_deg(_pilot_out.bow_travel_angle)


## Largest commanded bow-to-travel angle at last tick's actual speed in degrees (180 = unrestricted).
func get_max_bow_angle() -> float:
	return rad_to_deg(_pilot_out.max_bow_angle)


## Current turn rate in °/s (positive = counter-clockwise).
func get_turn_rate() -> float:
	return rad_to_deg(_turn_rate)


## Last turn-rate limit at the actual speed, in °/s.
func get_turn_rate_limit() -> float:
	return rad_to_deg(_pilot_out.turn_rate_limit)


## Last applied angular acceleration in °/s², after shared-capacity scaling.
func get_turn_acceleration() -> float:
	return rad_to_deg(_pilot_out.turn_acceleration)


## Last available angular acceleration at the actual speed in °/s² (turn_acceleration_curve, before sharing).
func get_turn_authority() -> float:
	return rad_to_deg(_pilot_out.turn_authority)


## Last shared-capacity scale applied to both thruster and turning demand (1 = not saturated).
func get_shared_scale() -> float:
	return _pilot_out.shared_scale


## Last desired approach speed in m/s.
func get_desired_speed() -> float:
	return _pilot_out.desired_speed


## Last planar braking acceleration the pilot planned its approach with, in m/s²: the thruster envelope's reach
## against the travel direction / (1 + turn fraction), further limited by the retro rule when the hull has no retro
## thrusters.
func get_planned_braking() -> float:
	return _pilot_out.planned_braking


## Last directional-thruster effectiveness (0–1) sampled from the profile's curve at the actual speed.
func get_directional_effectiveness() -> float:
	return _pilot_out.directional_effectiveness


## Last main-engine acceleration along the bow, 0 to main_acceleration, in m/s².
func get_main_command() -> float:
	return _pilot_out.main_command


## Last directional thruster acceleration (world XZ) in m/s²: up to thruster_strength / mass sternward, that x the
## directional effectiveness sideways, and forward_directional_acceleration x the effectiveness bow-forward.
func get_thruster_command() -> Vector3:
	return _pilot_out.thruster_command


## The latest activated command's outcome as text (F3 debugging): planning, accepted, declined with its reason, arrived,
## stopped or static-contact stop. It stays after the order ends.
func get_order_status() -> String:
	return _order_status + ("; " + _clearance_status if _has_order and _clearance_status != "" else "")


## Reversal rule (F3): the latest command's course-change angle at activation in degrees (-1 = not measured: a stop, a
## ship near rest or an arrival), whether reversal braking was selected, and whether that braking has completed.
func get_reversal_angle() -> float:
	return rad_to_deg(_reversal_angle) if _reversal_angle >= 0.0 else -1.0


func is_reversal() -> bool:
	return _reversal


func is_reversal_braking_complete() -> bool:
	return _reversal and not _brake_first


## Whether the active order is still waiting for its ordinary route (movement can already respond).
func is_planning() -> bool:
	return _job != null


## The ship's planar pilot state now, as the pilot reads it at the start of a tick (navigation planning).
func get_pilot_state() -> ShipPilot.State:
	var state := ShipPilot.State.new()
	var bow := -global_basis.z
	bow.y = 0.0
	state.position = global_position
	state.velocity = velocity
	state.yaw = rotation.y
	state.bow = bow.normalized()
	state.turn_rate = _turn_rate
	state.planar_fraction_prev = _planar_fraction_prev
	state.speed_prev = _speed_prev
	return state


func _physics_process(delta: float) -> void:
	_clock += delta
	Navigator.service()
	if _job != null and _job.status != Navigator.Status.PENDING:
		var handoff_started := Navigator.measure()
		_take_plan()
		Navigator.account(handoff_started)

	var bow := -global_basis.z
	bow.y = 0.0
	_pilot_state.position = global_position
	_pilot_state.velocity = velocity
	_pilot_state.yaw = rotation.y
	_pilot_state.bow = bow.normalized()
	_pilot_state.turn_rate = _turn_rate
	_pilot_state.planar_fraction_prev = _planar_fraction_prev
	_pilot_state.speed_prev = _speed_prev
	var guidance_started := Navigator.measure()
	_pilot_targets.has_order = _has_order
	if _plan != null and _has_order:
		RouteGuidance.guide(_plan, _follow, global_position, rotation.y, _pilot_targets)
	else:
		_pilot_targets.destination = _destination
		_pilot_targets.use_steer = false
		_pilot_targets.has_course = _has_course
		_pilot_targets.course_yaw = _course_yaw
		_pilot_targets.course_follows = _course_follows
		_pilot_targets.bend_from = 0
		_pilot_targets.bend_radii = PackedFloat32Array()
	_pilot_targets.brake_first = _brake_first
	var corrected := false
	if _has_order and not _navigation_baseline and not _blocked:
		var map := get_world_3d().navigation_map
		if not _navigation_on_mesh and NavigationServer3D.map_get_iteration_id(map) > 0:
			_navigation_on_mesh = RouteGuidance.planar(NavigationServer3D.map_get_closest_point(map, global_position) - global_position).length() <= NavigationServer3D.map_get_cell_size(map)
		var clearance := Navigator.clearance(profile, _probe, _pilot_state, _pilot_targets, delta, map, _navigation_on_mesh)
		_clearance_status = "open stopping room" if clearance == Navigator.Clearance.OPEN else "local hull/stop clearance"
		if clearance == Navigator.Clearance.SLOW:
			_clearance_status = "slowing for physical clearance"
			if velocity.length() <= profile.arrival_speed_tolerance:
				if not _route_refreshed and _job == null:
					# The accepted guide may now be behind an obstacle after a momentum-preserving drift.
					# Refresh once from the actual pose, keeping the same order and resolved destination.
					_route_refreshed = true
					_job = Navigator.start_job(self, _probe, _destination, _brake_first, true)
				elif _job == null:
					var guide := _destination if _plan == null else _plan.route[_follow.index]
					var distance := RouteGuidance.planar(guide - global_position).length()
					var route_distance := 0.0 if _plan == null else RouteGuidance.planar(_follow.point - global_position).length()
					if guide != _reposition_guide:
						_reposition_guide = guide
						_reposition_distance = distance
						_reposition_route_distance = route_distance
						_reposition_used = 0.0
					if distance < _reposition_distance - RoutePlanner.DUPLICATE_DISTANCE or route_distance < _reposition_route_distance - RoutePlanner.DUPLICATE_DISTANCE:
						_reposition_distance = minf(_reposition_distance, distance)
						_reposition_route_distance = minf(_reposition_route_distance, route_distance)
						_reposition_used = 0.0
					if _reposition_used < profile.departure_max_time:
						_reposition_used += delta
						# Return toward the current ordinary route before its corner if drift left us off it.
						# This restores route-following room; it does not follow an unrelated nearest boundary.
						if route_distance > RoutePlanner.DUPLICATE_DISTANCE:
							guide = _follow.point
						var candidate := Navigator.reposition(profile, _probe, _pilot_state, _pilot_targets, delta, map, guide, _navigation_on_mesh)
						if candidate == null and guide != _reposition_guide:
							candidate = Navigator.reposition(profile, _probe, _pilot_state, _pilot_targets, delta, map, _reposition_guide, _navigation_on_mesh)
						if candidate != null:
							_pilot_targets = candidate
							corrected = true
							_clearance_status = "repositioning for physical clearance toward next route guide"
					elif velocity.length() <= ManeuverRollout.REST_SPEED:
						_blocked = true
						EndpointReservations.release(self)
						_clearance_status = "Stage 2 distinct-passage recovery needed: ordinary path refresh and checked local corrections could not restore progress"
			if not corrected:
				_pilot_targets.has_order = false
	if _blocked:
		_pilot_targets.has_order = false
	Navigator.account(guidance_started, true)
	ShipPilot.step(profile, _pilot_state, _pilot_targets, delta, _pilot_out)
	_brake_first = _pilot_targets.brake_first
	if _plan == null and not corrected:
		_course_yaw = _pilot_targets.course_yaw
		_course_follows = _pilot_targets.course_follows
	if _follow != null:
		_follow.time += delta
	if _pilot_out.arrived:
		_has_order = false
		_end_navigation()
		_order_status = "arrived at (%.1f, %.1f) at %.2f s" % [_destination.x, _destination.z, _clock]

	_turn_rate = _pilot_state.turn_rate
	_planar_fraction_prev = _pilot_state.planar_fraction_prev
	_speed_prev = _pilot_state.speed_prev
	velocity = _pilot_state.velocity
	rotation.y = _pilot_state.yaw
	var attempted := Vector3(velocity.x, 0.0, velocity.z)
	move_and_slide()
	_stop_on_static_contact(attempted)


## Static contact (Task #44): when this tick's slide hit a stationary StaticBody3D (not an AnimatableBody3D) while
## the attempted planar motion drove into its surface, the active order ends (commands pending in Orders stay) and
## planar velocity and turn rate become zero at the engine's contact-constrained position. Resting or outward
## contact never qualifies, so a new order away from a touching obstacle is not stopped.
func _stop_on_static_contact(attempted: Vector3) -> void:
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var collider := collision.get_collider()
		if not collider is StaticBody3D or collider is AnimatableBody3D:
			continue
		var normal := collision.get_normal()
		normal.y = 0.0
		if attempted.dot(normal) >= 0.0:
			continue
		_has_order = false
		EndpointReservations.release(self)
		_end_navigation()
		velocity = Vector3.ZERO
		_turn_rate = 0.0
		_order_status = "static-contact stop (%s) at %.2f s" % [collider.name, _clock]
		print("Movement: static contact with %s at %.3f s, normal (%.2f, %.2f), speed %.2f m/s; order ended" % [collider.name, _clock, normal.x, normal.z, attempted.length()])
		return


## Hands the finished planning job's result to the pilot once (or ends a declined order).
func _take_plan() -> void:
	var job := _job
	_job = null
	if job.status == Navigator.Status.DECLINED:
		if job.refresh:
			# A failed ordinary query is not proof that a checked local return to the route cannot work.
			# Keep the order/guide and let the same bounded local correction attempt run before settling.
			_order_status += "; " + job.reason
			return
		_has_order = false
		_order_status = "declined (%.1f, %.1f): %s" % [job.click.x, job.click.z, job.reason]
		print("Movement: order to (%.1f, %.1f) declined at %.3f s: %s (%d µs over %d ticks, worst tick %d µs)" % [job.click.x, job.click.z, _clock, job.reason, job.used_usec, job.ticks, job.worst_tick_usec])
		_print_resolution(job)
		return
	if job.status != Navigator.Status.DONE:
		return
	_destination = job.destination
	_plan = null
	_follow = null
	_navigation_baseline = job.baseline
	_order_status = "accepted (%.1f, %.1f): %s; %s" % [job.click.x, job.click.z, ["direct", "route", "departure"][job.plan.kind], job.summary.get_slice(";", 0)]
	if job.resolution != "":
		_order_status += "; %s" % job.resolution
	if job.plan.kind == RouteGuidance.Kind.DIRECT:
		# The direct order keeps its course from the ship's position now (the activation tick when planning took one
		# tick, as before Task #46).
		var course := _destination - global_position
		course.y = 0.0
		_has_course = course != Vector3.ZERO
		_course_follows = _has_course
		if _has_course:
			_course_yaw = atan2(-course.x, -course.z)
	else:
		_plan = job.plan
		_follow = RouteGuidance.Follow.new()
	var route := ""
	if job.plan.kind != RouteGuidance.Kind.DIRECT:
		var points: Array[String] = []
		for point in job.plan.route:
			points.push_back("(%.2f, %.2f)" % [point.x, point.z])
		route = " via " + " ".join(points)
	print("Movement: plan for (%.1f, %.1f) at %.3f s: %s%s; %s (%d µs over %d ticks, worst tick %d µs)" % [job.click.x, job.click.z, _clock, ["direct", "route", "departure"][job.plan.kind], route, job.summary, job.used_usec, job.ticks, job.worst_tick_usec])
	_print_resolution(job)


## Destination resolution evidence (Task #54): the summary, every tested candidate in test order and the query counts.
func _print_resolution(job: Navigator.Job) -> void:
	if job.resolution_log.is_empty():
		return
	print("Movement: destination resolution for (%.1f, %.1f): %s; %s" % [job.click.x, job.click.z, job.resolution if job.resolution != "" else "no destination", job.query_text()])
	for line in job.resolution_log:
		print("  %s" % line)


## Cancels the planning job and drops the plan (a new command activated, or the order ended).
func _end_navigation() -> void:
	var start := Navigator.measure()
	if _job != null:
		_job.cancel()
	_job = null
	_plan = null
	_follow = null
	Navigator.account(start)


func _profile_valid() -> bool:
	return profile != null and profile.mass > 0.0 and profile.main_acceleration > 0.0 \
		and profile.thruster_strength > 0.0 and profile.max_speed > 0.0 and profile.pilot_response_time > 0.0 \
		and profile.arrival_tolerance > 0.0 and profile.arrival_speed_tolerance > 0.0 \
		and profile.no_retro_braking_effectiveness > 0.0 and profile.no_go_tolerance >= 0.0 \
		and profile.turn_acceleration_curve != null and profile.turn_rate_curve != null \
		and profile.directional_thrust_curve != null and profile.forward_directional_acceleration >= 0.0 \
		and profile.bow_alignment_curve != null
