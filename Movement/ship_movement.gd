class_name ShipMovement
extends CharacterBody3D
## Authoritative planar movement for a ship (V4 propulsion, #102): the only writer of its XZ position, its one
## world-space planar velocity (the built-in velocity) and its yaw. Only Orders (game/command/orders) activates
## commands, through activate_move() and activate_stop(); command intake and the crew delay belong to Orders.
##
## Propulsion (ShipPropulsion): main engines along the bow, retro thrusters toward the stern and RCS rotation, each with
## its own capacity. Velocity changes only by applied main/retro thrust and by contact; rotating the hull never
## rotates it. There is no pilot in #102: an order does not choose any propulsion command, so a ship keeps its motion
## until propulsion or contact changes it. The only propulsion commands come from the diagnostic controls
## (set_diagnostic_propulsion(), Debugging), which apply while held.
##
## Orders: activation replaces the active order and keeps the ship's physical motion. A move is planned (destination
## resolution, endpoint reservation, route) and stays active until a new move or stop replaces it; nothing completes
## it by arrival in #102. A stop ends the active order without braking.
##
## Contact (Tasks #44 and 38): driving into a stationary StaticBody3D or another ship ends the active order and zeroes
## planar velocity and turn rate (the other ship's too); see _stop_on_contact().

@export var profile: MovementProfile

## Physics clock in seconds (the sum of physics ticks so far), used only for status and log text.
var _clock := 0.0
var _active_move_receipt := 0
## Whether the profile passed validation; activation is ignored otherwise.
var _valid := false
## Roster slot from Fleet (-1 = none): ship traffic's last tie-break.
var _traffic_slot := -1
## Changes whenever the active order starts or ends (activation, contact). Read only by Traffic, which the V4
## experiment does not run.
var _traffic_serial := 0
var _destination := Vector3.ZERO
## The requested click of the active or last move (Task #54); _destination becomes the resolved point once planned.
var _requested := Vector3.ZERO
var _has_order := false
## Propulsion state and last step's applied values (read-only debug getters), reused every tick.
var _state := ShipPropulsion.State.new()
var _command := ShipPropulsion.Command.new()
var _out := ShipPropulsion.Output.new()
## Diagnostic propulsion command (#102) and whether any part of it is active.
var _diagnostic := ShipPropulsion.Command.new()
var _diagnostic_active := false
## Navigation: the hull probe, the active order's planning job (null when none) and its route with the progress along
## it (null for the direct order).
var _probe: HullProbe
var _job: Navigator.Job
var _plan: RouteGuidance.Plan
var _follow: RouteGuidance.Follow
## Outcome of the latest activated command for F3: planning, accepted, declined with its reason, stopped or a contact
## stop. Kept after the order ends.
var _order_status := "no order yet"
## Endpoint reservation radius (m): hull reach + plan_clearance_buffer + arrival allowance.
var _reservation_radius := 0.0


func _ready() -> void:
	if not _profile_valid():
		push_error("ShipMovement needs a MovementProfile with every value above 0 and turn acceleration and turn rate curves; the ship will not move.")
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


## Called only by Orders when a move becomes due: replaces the active order now. Y is ignored. The ship's position,
## velocity, heading and turn rate are untouched. move_receipt is the Orders receipt of this move.
func activate_move(world_position: Vector3, move_receipt: int) -> void:
	if not _valid:
		return
	_active_move_receipt = move_receipt
	_traffic_serial += 1
	_destination = Vector3(world_position.x, global_position.y, world_position.z)
	_requested = _destination
	_has_order = true
	EndpointReservations.release(self)
	_end_navigation()
	_job = Navigator.start_job(self, _probe, world_position)
	_order_status = "planning (%.1f, %.1f)" % [world_position.x, world_position.z]


## Called only by Orders when a stop becomes due: ends the active order now. No braking is applied (#102: no pilot).
func activate_stop() -> void:
	if not _valid:
		return
	_has_order = false
	_traffic_serial += 1
	EndpointReservations.release(self)
	_end_navigation()
	# Orders activates before this ship's tick advances _clock, so report this tick's time.
	_order_status = "stopped at %.2f s" % (_clock + get_physics_process_delta_time())


## Diagnostic propulsion (#102; Debugging only, not a player control): main and retro throttle 0–1 and RCS -1 (right)
## to 1 (left). Applies from this ship's next physics tick while any part is non-zero; all zero releases it.
func set_diagnostic_propulsion(main: float, retro: float, rcs: float) -> void:
	_diagnostic.main = main
	_diagnostic.retro = retro
	_diagnostic.rcs = rcs
	_diagnostic_active = main != 0.0 or retro != 0.0 or rcs != 0.0


## Whether the diagnostic propulsion command is active (F3).
func is_diagnostic_active() -> bool:
	return _diagnostic_active


## Stores this ship's roster slot: ship traffic's last tie-break (lower slot first; -1 = none).
func set_traffic_slot(slot: int) -> void:
	_traffic_slot = slot


func get_traffic_slot() -> int:
	return _traffic_slot


## Ship traffic status (F3). Ship traffic is not run in the V4 experiment (#102: no pilot to yield, and spec FLT-01
## drops it); ships do not register with Traffic.
func get_traffic_status() -> String:
	return "not active (V4, #102)"


## Called by another ship that drove into this one (Task 38, #79): this ship stops in the same tick. Its active order
## ends, velocity and turn rate become zero and its reservation is released; commands pending in Orders stay.
func contact_stop(other: ShipMovement) -> void:
	_halt("ship-contact stop (%s)" % other.name)
	# Report the caller's clock: both stop in the same physics frame, whichever ship has run its tick already.
	print("Movement: %s stopped by ship contact with %s at %.3f s; order ended" % [name, other.name, other._clock])


## Where the ship would come to rest (planar, metres): its position plus v² / (2 × HullProbe.minimum_braking()) along the
## travel direction. Provisional compatibility estimate (#102, Fleet orders its places by it); it is the position at
## rest.
func get_stopping_point() -> Vector3:
	var here := RouteGuidance.planar(global_position)
	var planar_velocity := RouteGuidance.planar(velocity)
	var speed := planar_velocity.length()
	var braking := HullProbe.minimum_braking(profile) if _valid else 0.0
	if speed == 0.0 or braking <= 0.0:
		return here
	return here + planar_velocity / speed * (speed * speed / (2.0 * braking))


## Farthest hull point from the vertical axis (m), for ship traffic.
func get_hull_reach() -> float:
	return _probe.reach


## Order serial for ship traffic: it changes whenever the active order starts or ends.
func get_traffic_serial() -> int:
	return _traffic_serial


## The remaining path from the ship's planar position: the rest of the route, or the straight line to the
## destination (also while planning). Just the position without an order.
func get_remaining_path() -> PackedVector3Array:
	var path := PackedVector3Array([RouteGuidance.planar(global_position)])
	if not _has_order:
		return path
	if _plan != null and _plan.kind != RouteGuidance.Kind.DIRECT and _follow != null:
		for i in range(_follow.index, _plan.route.size()):
			path.push_back(RouteGuidance.planar(_plan.route[i]))
	else:
		path.push_back(RouteGuidance.planar(_destination))
	return path


## The path the ship is expected to fly, for ship traffic's anticipation. Provisional compatibility (#102, no pilot):
## the remaining path.
func get_predicted_path() -> PackedVector3Array:
	return get_remaining_path()


## Endpoint reservation radius in metres (Task 37, #78); Fleet spaces its preferred points by twice this.
func get_reservation_radius() -> float:
	return _reservation_radius


## Whether the active order is abandoned after exhausted recovery. #102 has no recovery: never.
func is_blocked() -> bool:
	return false


## Whether an order is active (activated and not yet replaced, stopped or ended by contact; also while planning).
## Commands waiting in Orders do not count.
func has_order() -> bool:
	return _has_order


## Destination of the active order (or of the last one): the click until its plan is taken, then the destination the
## plan leads to (the click, or the resolved point, Task #54).
func get_destination() -> Vector3:
	return _destination


## Returns the accepted destination for this active move, or null while it is unavailable.
func get_resolved_move_destination(move_receipt: int) -> Variant:
	if move_receipt <= 0 or move_receipt != _active_move_receipt or not _has_order:
		return null
	if _job != null and not _job.refresh:
		return null
	return _destination


## Returns the requested point while this active move's first plan is pending, or null.
func get_planning_move_destination(move_receipt: int) -> Variant:
	if move_receipt > 0 and move_receipt == _active_move_receipt and _has_order and _job != null and not _job.refresh:
		return _requested
	return null


## The requested click of the active or last move (Task #54).
func get_requested_destination() -> Vector3:
	return _requested


## Heading in degrees of yaw (0 = bow toward −Z, positive = counter-clockwise seen from above).
func get_heading() -> float:
	return rad_to_deg(rotation.y)


## Current turn rate in °/s (positive = counter-clockwise).
func get_turn_rate() -> float:
	return rad_to_deg(_state.turn_rate)


## Last turn-rate limit at the actual speed, in °/s.
func get_turn_rate_limit() -> float:
	return rad_to_deg(_out.turn_rate_limit)


## Last applied RCS angular acceleration in °/s² (signed).
func get_turn_acceleration() -> float:
	return rad_to_deg(_out.turn_acceleration)


## Last available RCS angular acceleration at the actual speed in °/s².
func get_turn_authority() -> float:
	return rad_to_deg(_out.turn_authority)


## Last applied main-engine acceleration along the bow, 0 to main_acceleration, in m/s².
func get_main_command() -> float:
	return _out.main_acceleration


## Last applied retro acceleration toward the stern, 0 to retro_acceleration, in m/s².
func get_retro_command() -> float:
	return _out.retro_acceleration


## The latest activated command's outcome as text (F3 debugging). It stays after the order ends.
func get_order_status() -> String:
	return _order_status


## Whether the active order is still waiting for its route.
func is_planning() -> bool:
	return _job != null


## The ship's planar propulsion state now (navigation planning reads its position).
func get_propulsion_state() -> ShipPropulsion.State:
	var state := ShipPropulsion.State.new()
	state.position = global_position
	state.velocity = velocity
	state.yaw = rotation.y
	state.turn_rate = _state.turn_rate
	return state


func _physics_process(delta: float) -> void:
	_clock += delta
	Navigator.service()
	if _job != null and _job.status != Navigator.Status.PENDING:
		var handoff_started := Navigator.measure()
		_take_plan()
		Navigator.account(handoff_started)
	# Route progress only (the remaining path); nothing steers along the route in #102.
	if _plan != null and _follow != null and _has_order:
		RouteGuidance.track(_plan, _follow, global_position)

	# No pilot (#102): without the diagnostic command, no propulsion is commanded.
	_command.main = _diagnostic.main if _diagnostic_active else 0.0
	_command.retro = _diagnostic.retro if _diagnostic_active else 0.0
	_command.rcs = _diagnostic.rcs if _diagnostic_active else 0.0
	_state.position = global_position
	_state.velocity = velocity
	_state.yaw = rotation.y
	ShipPropulsion.step(profile, _state, _command, delta, _out)
	velocity = _state.velocity
	rotation.y = _state.yaw
	var attempted := Vector3(velocity.x, 0.0, velocity.z)
	move_and_slide()
	_stop_on_contact(attempted)


## Contact (Tasks #44 and 38): when this tick's slide hit a stationary StaticBody3D (not an AnimatableBody3D) or another
## ship while the attempted planar motion drove into its surface, the active order ends (commands pending in Orders
## stay) and planar velocity and turn rate become zero at the engine's contact-constrained position. Another ship is
## stopped in the same tick (contact_stop()). Resting or outward contact never qualifies.
func _stop_on_contact(attempted: Vector3) -> void:
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var collider := collision.get_collider()
		var ship := collider as ShipMovement
		if ship == null and (not collider is StaticBody3D or collider is AnimatableBody3D):
			continue
		var normal := collision.get_normal()
		normal.y = 0.0
		if attempted.dot(normal) >= 0.0:
			continue
		if ship != null:
			_halt("ship-contact stop (%s)" % ship.name)
			print("Movement: %s ship contact with %s at %.3f s, normal (%.2f, %.2f), speed %.2f m/s; order ended" % [name, ship.name, _clock, normal.x, normal.z, attempted.length()])
			ship.contact_stop(self)
			return
		_halt("static-contact stop (%s)" % collider.name)
		print("Movement: static contact with %s at %.3f s, normal (%.2f, %.2f), speed %.2f m/s; order ended" % [collider.name, _clock, normal.x, normal.z, attempted.length()])
		return


## Ends the active order at once: zero planar velocity and turn rate, reservation released, navigation cancelled.
func _halt(reason: String) -> void:
	_has_order = false
	_traffic_serial += 1
	EndpointReservations.release(self)
	_end_navigation()
	velocity = Vector3.ZERO
	_state.turn_rate = 0.0
	_order_status = "%s at %.2f s" % [reason, _clock]


## Takes the finished planning job's result once (or ends a declined order).
func _take_plan() -> void:
	var job := _job
	_job = null
	if job.status == Navigator.Status.DECLINED:
		if job.refresh:
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
	_order_status = "accepted (%.1f, %.1f): %s; %s" % [job.click.x, job.click.z, ["direct", "route", "departure"][job.plan.kind], job.summary.get_slice(";", 0)]
	if job.resolution != "":
		_order_status += "; %s" % job.resolution
	if job.plan.kind != RouteGuidance.Kind.DIRECT:
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
	return profile != null and profile.main_acceleration > 0.0 and profile.retro_acceleration > 0.0 \
		and profile.max_speed > 0.0 and profile.max_reverse_speed > 0.0 \
		and profile.arrival_tolerance > 0.0 and profile.arrival_speed_tolerance > 0.0 and profile.no_go_tolerance >= 0.0 \
		and profile.turn_acceleration_curve != null and profile.turn_rate_curve != null
