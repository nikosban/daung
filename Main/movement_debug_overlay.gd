extends CanvasLayer
## Temporary F3 movement readout of one ship: speed, velocity, heading, turning (course heading, rate and its limit,
## applied angular acceleration, rudder multiplier, shared-capacity scale), desired speed, planned braking, main-engine and thruster
## commands, active destination and order state, and the reaction-delay queue (physics clock, pending count, next
## pending command and its due time, last receipt and activation times). Reads Movement only; Movement never calls it. Hidden until F3.
## F3 also turns the world-space movement trail on and off with it (a fresh trace each time it turns on).

@export var ship: ShipMovement
@export var trail: MovementTrail

var _label := Label.new()


func _ready() -> void:
	visible = false
	_label.position = Vector2(12.0, 12.0)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	add_child(_label)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_F3:
		visible = not visible
		trail.set_active(visible)


func _process(_delta: float) -> void:
	if not visible:
		return
	var velocity := Vector3(ship.velocity.x, 0.0, ship.velocity.z)
	var thruster := ship.get_thruster_command()
	var destination := ship.get_destination()
	_label.text = "speed %6.2f m/s  velocity (x %6.2f, z %6.2f)\nheading %7.1f°  course %7.1f°\nturn rate %7.1f / %5.1f °/s  turn accel %7.1f °/s²  rudder %4.2f×  shared %4.2f\ndesired %6.2f m/s  planned braking %5.2f m/s²\nmain %6.2f m/s²\nthrusters %6.2f m/s²  (x %6.2f, z %6.2f)\n%s\nclock %7.2f s  pending %d%s  last received %s  last activated %s" % [
		velocity.length(), velocity.x, velocity.z,
		ship.get_heading(), ship.get_target_heading(),
		ship.get_turn_rate(), ship.get_turn_rate_limit(), ship.get_turn_acceleration(), ship.get_rudder_multiplier(), ship.get_shared_scale(),
		ship.get_desired_speed(), ship.get_planned_braking(),
		ship.get_main_command(),
		thruster.length(), thruster.x, thruster.z,
		"active destination (%.1f, %.1f)" % [destination.x, destination.z] if ship.has_order() else "no active order",
		ship.get_clock(), ship.get_pending_count(), _next_pending_text(), _time_text(ship.get_last_received_time()), _time_text(ship.get_last_activated_time()),
	]


func _next_pending_text() -> String:
	var next := ship.get_next_pending()
	if next.is_empty():
		return ""
	if next.kind == "move":
		return " (next move (%.1f, %.1f) due %.2f s)" % [next.position.x, next.position.z, next.due]
	return " (next stop due %.2f s)" % next.due


func _time_text(time: float) -> String:
	return "—" if time < 0.0 else "%.2f s" % time
