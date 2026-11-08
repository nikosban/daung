extends CanvasLayer
## Temporary F3 movement readout of one ship: speed, velocity, heading, turning (course heading, rate and its limit,
## applied and available angular acceleration, shared-capacity scale), desired speed, planned braking, main-engine and thruster
## commands, active destination and order state, the latest order's outcome (Task #46: planning, accepted, declined
## with its reason, arrived, stopped or static-contact stop), and the reaction-delay queue (physics clock, pending count, next
## pending command and its due time, last receipt and activation times). Reads Movement only; Movement never calls it. Hidden until F3.
## F3 also turns the world-space movement trail on and off with it (a fresh trace each time it turns on).
## F3 also shows the debug destination marker where the ship will go (Task #38, owner decision in PR #55): at the latest
## received right-click from its receipt, and at the resolved destination once that click's order has been planned to a
## different point (Task #54). It is forgotten once the ship has no active order and no pending command. Never changes
## Movement's queue.
## F3 also shows and hides the red collision-shape outlines (Task #44).

## Display height of the destination marker above its XZ (rendering detail, not motion data).
const MARKER_DISPLAY_HEIGHT := 0.1

@export var ship: ShipMovement
@export var trail: MovementTrail
@export var destination_marker: MeshInstance3D
## F3 red outlines of collision shapes (Task #44); shown and hidden with the readout.
@export var collision_outlines: Array[CollisionShapeOutline] = []

@onready var _label: Label = $Layout/Margins/Telemetry
var _has_request := false
var _requested_position := Vector3.ZERO


func _ready() -> void:
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_F3:
		visible = not visible
		trail.set_active(visible)
		for outline in collision_outlines:
			outline.visible = visible
		_update_marker()


## Connected to the input's move_requested: caches the latest received move target, also while F3 is hidden.
func record_move_request(world_position: Vector3) -> void:
	_has_request = true
	_requested_position = world_position
	_update_marker()


func _process(_delta: float) -> void:
	if _has_request and not ship.has_order() and ship.get_pending_count() == 0:
		_has_request = false
		_update_marker()
	if not visible:
		return
	_update_marker()
	var velocity := Vector3(ship.velocity.x, 0.0, ship.velocity.z)
	var thruster := ship.get_thruster_command()
	var destination := ship.get_destination()
	_label.text = "speed %6.2f m/s  velocity (x %6.2f, z %6.2f)\nheading %7.1f°  course %7.1f°  steering target %7.1f°  bow–travel %5.1f° (max %5.1f°)\nturn rate %7.2f / %5.2f °/s (permitted at %.2f m/s)  turn accel applied %7.2f of %5.2f °/s² available  shared %4.2f\ndesired %6.2f m/s  planned braking %5.2f m/s²\nforward: main engine %5.3f m/s²  forward thrusters %5.3f m/s² (limit %5.3f)\nthrusters %6.2f m/s²  (x %6.2f, z %6.2f)  sideways %5.2f m/s²  directional effectiveness %4.2f×\n%s\norder: %s\n%s\nclock %7.2f s  pending %d%s  last received %s  last activated %s" % [
		velocity.length(), velocity.x, velocity.z,
		ship.get_heading(), ship.get_course_heading(), ship.get_target_heading(), ship.get_bow_travel_angle(), ship.get_max_bow_angle(),
		ship.get_turn_rate(), ship.get_turn_rate_limit(), velocity.length(), ship.get_turn_acceleration(), ship.get_turn_authority(), ship.get_shared_scale(),
		ship.get_desired_speed(), ship.get_planned_braking(),
		ship.get_main_command(), maxf(thruster.dot(-ship.global_basis.z.normalized()), 0.0), ship.profile.forward_directional_acceleration * ship.get_directional_effectiveness(),
		thruster.length(), thruster.x, thruster.z, absf(thruster.dot(ship.global_basis.x.normalized())), ship.get_directional_effectiveness(),
		_destination_text(destination) if ship.has_order() else "no active order",
		ship.get_order_status(),
		_reversal_text(),
		ship.get_clock(), ship.get_pending_count(), _next_pending_text(), _time_text(ship.get_last_received_time()), _time_text(ship.get_last_activated_time()),
	]


## The active destination and, when it differs (Task #54: a resolved destination), the requested click.
func _destination_text(destination: Vector3) -> String:
	var requested := ship.get_requested_destination()
	var text := "active destination (%.1f, %.1f)" % [destination.x, destination.z]
	if Vector2(requested.x - destination.x, requested.z - destination.z).length() > 0.01:
		text += "  requested (%.1f, %.1f)" % [requested.x, requested.z]
	return text


## Reversal rule: the latest move's course-change angle at activation, whether reversal braking was selected and
## whether it has completed.
func _reversal_text() -> String:
	var angle := ship.get_reversal_angle()
	if angle < 0.0:
		return "course change at activation —  (stop, near rest or arrival)  reversal braking no"
	var braking := "no"
	if ship.is_reversal():
		braking = "yes, %s" % ("complete" if ship.is_reversal_braking_complete() else "braking")
	return "course change at activation %5.1f°  (reversal from %.1f°)  reversal braking %s" % [angle, ship.profile.near_opposite_angle, braking]


func _next_pending_text() -> String:
	var next := ship.get_next_pending()
	if next.is_empty():
		return ""
	if next.kind == "move":
		return " (next move (%.1f, %.1f) due %.2f s)" % [next.position.x, next.position.z, next.due]
	return " (next stop due %.2f s)" % next.due


func _time_text(time: float) -> String:
	return "—" if time < 0.0 else "%.2f s" % time


func _update_marker() -> void:
	destination_marker.visible = visible and _has_request
	if destination_marker.visible:
		var target := _marker_target()
		destination_marker.global_position = Vector3(target.x, MARKER_DISPLAY_HEIGHT, target.z)


## Where the ship will go for the latest click: its resolved destination once the active order is that click's and
## nothing newer is pending (Task #54), otherwise the click itself.
func _marker_target() -> Vector3:
	var requested := ship.get_requested_destination()
	if ship.has_order() and ship.get_pending_count() == 0 and Vector2(requested.x - _requested_position.x, requested.z - _requested_position.z).length() <= 0.01:
		return ship.get_destination()
	return _requested_position
