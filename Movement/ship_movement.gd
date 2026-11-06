class_name ShipMovement
extends CharacterBody3D
## Authoritative planar movement for a ship (Movement v3): the only writer of its XZ position, its one
## world-space planar velocity (the built-in velocity) and its yaw. Callers request movement through
## move_to() and stop().
##
## Each physics tick the pilot computes a desired velocity toward the destination that falls with the
## remaining distance (arrival steering) and requests the acceleration that closes the gap to the actual
## velocity within pilot_response_time. The main engine supplies the useful part along the bow; the
## directional thrusters supply the rest. Their sideways acceleration (thruster_strength / mass) and bow-forward acceleration
## (forward_directional_acceleration, below the main engine) fade with actual speed (profile.directional_thrust_curve); sternward they keep the full rating. Within their share, braking against the
## actual travel is served before sideways correction, and the approach is planned with the braking the thrusters
## can actually deliver against the travel direction. Turning demand is computed first, so the approach speed is planned
## with the braking that sharing will leave. The pilot also steers the hull toward the order's course heading
## (set once by move_to(), toward the destination) with bounded angular acceleration whose authority grows
## with actual speed (zero at rest), and a turn-rate limit that also follows speed (zero at rest). Planar
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
## Reaction delay: move_to() and stop() only receive a command. Each waits its own profile.reaction_delay on
## the physics clock in one FIFO queue and is then activated at the start of a physics tick, in receipt order;
## nothing is cancelled or skipped. Until then the active order stands.
##
## Static contact (Task #44): driving into a stationary StaticBody3D ends the active order and zeroes planar
## velocity and turn rate; see _stop_on_static_contact().
##
## Navigation (Task #46): each activated move starts one planning job (Navigator). Until the job finishes the ship
## brakes as it does without an order; the job's plan is then handed to the pilot once and followed every tick (the
## unchanged direct order, a route around obstacles, or a departure that holds heading before following the route).
## A declined plan ends the order. Nothing is re-planned without a new order; a later move or stop cancels the job.
## The pilot itself is ShipPilot; this script stays the single writer of position, velocity and yaw.

@export var profile: MovementProfile

## Physics clock in seconds: the sum of physics ticks so far.
var _clock := 0.0
## Received commands waiting for activation, in receipt order: {kind: "move" | "stop", position, received, due}.
var _pending: Array[Dictionary] = []
## Physics clock of the last receipt and the last activation (-1 = none yet).
var _last_received := -1.0
var _last_activated := -1.0
var _destination := Vector3.ZERO
## The requested click of the active or last move (Task #54); _destination becomes the resolved point once planned.
var _requested := Vector3.ZERO
var _has_order := false
## Course heading of the current order (yaw in radians), set by move_to(); no course for a zero-length order.
var _course_yaw := 0.0
var _has_course := false
## Turn rate in rad/s (per ship); zero whenever powered turning is not requested.
var _turn_rate := 0.0
## Previous tick's planar demand fraction on the directional thrusters (0–1). It measures last tick's actual
## thruster demand, so it carries over order replacement and stop(); it starts at 0 (no demand before the
## first tick). Used only to plan the yaw braking authority.
var _planar_fraction_prev := 0.0
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


func _ready() -> void:
	if not _profile_valid():
		push_error("ShipMovement needs a MovementProfile with every value above 0 (reaction_delay at least 0), a rudder curve above 0 at full speed, a directional thrust curve and forward_directional_acceleration at least 0; the ship will not move.")
		set_physics_process(false)
		return
	var hull: CollisionShape3D = null
	for child in get_children():
		if child is CollisionShape3D:
			hull = child
			break
	_probe = HullProbe.new(self, hull)


## Receives an order to the point. After the reaction delay it replaces the active order; the course is
## taken from the ship's position then. Y is ignored. The current velocity carries over.
func move_to(world_position: Vector3) -> void:
	_receive("move", world_position)


## Receives a stop. After the reaction delay it ends the active order; the ship then brakes toward zero
## velocity with its thrusters and does not hold position.
func stop() -> void:
	_receive("stop", Vector3.ZERO)


## Whether an order is active (activated and not yet arrived or stopped; also while its plan is being made).
## Pending commands do not count.
func has_order() -> bool:
	return _has_order


## Destination of the active order (or of the last one): the click until its plan is taken, then the destination the
## plan leads to (the click, or the resolved point, Task #54).
func get_destination() -> Vector3:
	return _destination


## The requested click of the active or last move (Task #54).
func get_requested_destination() -> Vector3:
	return _requested


## Physics clock in seconds.
func get_clock() -> float:
	return _clock


## Number of received commands waiting for activation.
func get_pending_count() -> int:
	return _pending.size()


## The next command to activate ({kind, position, received, due}), or an empty Dictionary if none is pending.
func get_next_pending() -> Dictionary:
	if _pending.is_empty():
		return {}
	return _pending[0].duplicate()


## Physics clock of the last received command, or -1 if none.
func get_last_received_time() -> float:
	return _last_received


## Physics clock of the last activated command, or -1 if none.
func get_last_activated_time() -> float:
	return _last_activated


## Heading in degrees of yaw (0 = bow toward −Z, positive = counter-clockwise seen from above).
func get_heading() -> float:
	return rad_to_deg(rotation.y)


## Course heading of the current order in degrees (same convention as get_heading()).
func get_target_heading() -> float:
	return rad_to_deg(_pilot_out.target_yaw)


## Current turn rate in °/s (positive = counter-clockwise).
func get_turn_rate() -> float:
	return rad_to_deg(_turn_rate)


## Last turn-rate limit at the actual speed, in °/s.
func get_turn_rate_limit() -> float:
	return rad_to_deg(_pilot_out.turn_rate_limit)


## Last applied angular acceleration in °/s², after shared-capacity scaling.
func get_turn_acceleration() -> float:
	return rad_to_deg(_pilot_out.turn_acceleration)


## Last rudder multiplier sampled from the rudder curve at the actual speed.
func get_rudder_multiplier() -> float:
	return _pilot_out.rudder_multiplier


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
	return _order_status


## Whether the active order is still waiting for its navigation plan (the ship brakes meanwhile).
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
	return state


func _physics_process(delta: float) -> void:
	_clock += delta
	while not _pending.is_empty() and _pending[0].due <= _clock:
		_activate(_pending.pop_front())
	Navigator.service()
	if _job != null and _job.status != Navigator.Status.PENDING:
		_take_plan()

	var bow := -global_basis.z
	bow.y = 0.0
	_pilot_state.position = global_position
	_pilot_state.velocity = velocity
	_pilot_state.yaw = rotation.y
	_pilot_state.bow = bow.normalized()
	_pilot_state.turn_rate = _turn_rate
	_pilot_state.planar_fraction_prev = _planar_fraction_prev
	_pilot_targets.has_order = _has_order and _job == null
	if _plan != null and _has_order:
		RouteGuidance.guide(_plan, _follow, global_position, rotation.y, _pilot_targets)
	else:
		_pilot_targets.destination = _destination
		_pilot_targets.use_steer = false
		_pilot_targets.has_course = _has_course
		_pilot_targets.course_yaw = _course_yaw
		_pilot_targets.bend_from = 0
		_pilot_targets.bend_radii = PackedFloat32Array()
	ShipPilot.step(profile, _pilot_state, _pilot_targets, delta, _pilot_out)
	if _follow != null:
		_follow.time += delta
	if _pilot_out.arrived:
		_has_order = false
		_plan = null
		_follow = null
		_order_status = "arrived at (%.1f, %.1f) at %.2f s" % [_destination.x, _destination.z, _clock]

	_turn_rate = _pilot_state.turn_rate
	_planar_fraction_prev = _pilot_state.planar_fraction_prev
	velocity = _pilot_state.velocity
	rotation.y = _pilot_state.yaw
	var attempted := Vector3(velocity.x, 0.0, velocity.z)
	move_and_slide()
	_stop_on_static_contact(attempted)


## Static contact (Task #44): when this tick's slide hit a stationary StaticBody3D (not an AnimatableBody3D) while
## the attempted planar motion drove into its surface, the active order ends (pending commands stay queued) and
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
		_end_navigation()
		velocity = Vector3.ZERO
		_turn_rate = 0.0
		_order_status = "static-contact stop (%s) at %.2f s" % [collider.name, _clock]
		print("Movement: static contact with %s at %.3f s, normal (%.2f, %.2f), speed %.2f m/s; order ended" % [collider.name, _clock, normal.x, normal.z, attempted.length()])
		return


func _receive(kind: String, world_position: Vector3) -> void:
	var delay := profile.reaction_delay if profile != null else 0.0
	var command := {kind = kind, position = world_position, received = _clock, due = _clock + delay}
	_pending.push_back(command)
	_last_received = _clock
	print("Movement: received %s at %.3f s, due %.3f s" % [_describe(command), command.received, command.due])


func _activate(command: Dictionary) -> void:
	if command.kind == "move":
		var world_position: Vector3 = command.position
		_destination = Vector3(world_position.x, global_position.y, world_position.z)
		_requested = _destination
		_has_order = true
		var course := _destination - global_position
		course.y = 0.0
		_has_course = course != Vector3.ZERO
		if _has_course:
			_course_yaw = atan2(-course.x, -course.z)
		_end_navigation()
		_job = Navigator.start_job(self, _probe, world_position)
		_order_status = "planning (%.1f, %.1f)" % [world_position.x, world_position.z]
	else:
		_has_order = false
		_end_navigation()
		_order_status = "stopped at %.2f s" % _clock
	_last_activated = _clock
	print("Movement: activated %s at %.3f s (%.3f s after receipt)" % [_describe(command), _clock, _clock - command.received])


## Hands the finished planning job's result to the pilot once (or ends a declined order).
func _take_plan() -> void:
	var job := _job
	_job = null
	if job.status == Navigator.Status.DECLINED:
		_has_order = false
		_order_status = "declined (%.1f, %.1f): %s" % [job.click.x, job.click.z, job.reason]
		print("Movement: order to (%.1f, %.1f) declined at %.3f s: %s (%d µs over %d ticks, worst tick %d µs)" % [job.click.x, job.click.z, _clock, job.reason, job.used_usec, job.ticks, job.worst_tick_usec])
		_print_resolution(job)
		return
	if job.status != Navigator.Status.DONE:
		return
	_destination = job.destination
	_order_status = "accepted (%.1f, %.1f): %s; %s" % [job.click.x, job.click.z, ["direct", "route", "departure"][job.plan.kind], job.summary.get_slice(";", 0)]
	if job.resolution != "":
		_order_status += "; %s" % job.resolution
	if job.plan.kind == RouteGuidance.Kind.DIRECT:
		# The direct order keeps its course from the ship's position now (the activation tick when planning took one
		# tick, as before Task #46).
		var course := _destination - global_position
		course.y = 0.0
		_has_course = course != Vector3.ZERO
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
	if _job != null:
		_job.cancel()
	_job = null
	_plan = null
	_follow = null


func _describe(command: Dictionary) -> String:
	if command.kind == "move":
		return "move (%.1f, %.1f)" % [command.position.x, command.position.z]
	return "stop"


func _profile_valid() -> bool:
	return profile != null and profile.mass > 0.0 and profile.main_acceleration > 0.0 \
		and profile.thruster_strength > 0.0 and profile.max_speed > 0.0 and profile.pilot_response_time > 0.0 \
		and profile.arrival_tolerance > 0.0 and profile.arrival_speed_tolerance > 0.0 \
		and profile.turn_authority > 0.0 and profile.max_turn_rate_at_max_speed > 0.0 \
		and profile.no_retro_braking_effectiveness > 0.0 and profile.reaction_delay >= 0.0 and profile.no_go_tolerance >= 0.0 and profile.rudder_curve != null and profile.rudder_curve.sample(1.0) > 0.0 \
		and profile.directional_thrust_curve != null and profile.forward_directional_acceleration >= 0.0
