extends CanvasLayer
## Temporary F3 movement readout of the fleet's selected ships. With one ship selected, the full readout: speed, velocity, heading, turning (course heading, rate and its limit,
## applied and available angular acceleration, shared-capacity scale), desired speed, planned braking, main-engine and thruster
## commands, active destination and order state, the latest order's outcome (Task #46: planning, accepted, declined
## with its reason, arrived, stopped or static-contact stop), and the reaction-delay queue (physics clock, pending count, next
## pending command and its due time, last receipt and activation times, from Orders). Reads Movement and Orders only; Movement never calls it. Hidden until F3.
## With several selected, one compact block per ship in roster order (name, speed, heading, destination, order status,
## queue); with none, "no ship selected". Reads Fleet, Movement and Orders only.
## F3 also shows the selected ships' world-space movement trails (a fresh trace when F3 turns on or a ship becomes
## selected) and hides the others.
## F3 also shows and hides the red collision-shape outlines (Task #44).

@export var fleet: FleetCommand
## One trail per roster ship (ShipMovement -> MovementTrail), supplied by the suite.
var trails := {}
## Ships whose trails are currently active.
var _shown: Array[ShipMovement] = []
## F3 red outlines of collision shapes (Task #44); shown and hidden with the readout.
@export var collision_outlines: Array[CollisionShapeOutline] = []

@onready var _label: Label = $Layout/Margins/Telemetry


func _ready() -> void:
	visible = false
	get_viewport().size_changed.connect(_update_font_size)
	_update_font_size()


## Keep this diagnostic readout near its screen-pixel cap while ordinary UI scales normally.
func _update_font_size() -> void:
	var stretch := get_viewport().get_stretch_transform().get_scale()
	var screen_scale := maxf(stretch.x, stretch.y)
	var cap := _label.get_theme_constant("max_screen_font_size")
	var font_size := mini(ThemeDB.get_project_theme().default_font_size, maxi(1, floori(cap / screen_scale)))
	_label.add_theme_font_size_override("font_size", font_size)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_F3:
		visible = not visible
		_shown.clear()
		for trail in trails.values():
			trail.set_active(false)
		_follow_selection()
		for outline in collision_outlines:
			outline.visible = visible


func _process(_delta: float) -> void:
	if not visible:
		return
	var selection := _follow_selection()
	if selection.is_empty():
		_label.text = "no ship selected"
	elif selection.size() == 1:
		_label.text = _full_text(selection[0])
	else:
		var blocks: Array[String] = []
		for ship in selection:
			blocks.push_back(_compact_text(ship))
		_label.text = "\n\n".join(blocks)


## Starts the trail of each newly selected ship and stops the trails of deselected ones. Returns the selection.
func _follow_selection() -> Array[ShipMovement]:
	var selection: Array[ShipMovement] = []
	if visible:
		selection = fleet.get_selection()
	for ship in _shown:
		if not selection.has(ship) and trails.has(ship):
			trails[ship].set_active(false)
	for ship in selection:
		if not _shown.has(ship) and trails.has(ship):
			trails[ship].set_active(true)
	_shown = selection
	return selection


## One ship's compact block: name, speed, heading, destination, order status and the Orders queue.
func _compact_text(ship: ShipMovement) -> String:
	var orders := ship.get_node("%Orders") as ShipOrders
	return "%s  speed %6.2f m/s  heading %7.1f°\n%s\norder: %s\nqueue: pending %d%s" % [
		ship.name, Vector2(ship.velocity.x, ship.velocity.z).length(), ship.get_heading(),
		_destination_text(ship, ship.get_destination()) if ship.has_order() else "no active order",
		ship.get_order_status(), orders.get_pending_count(), _next_pending_text(orders),
	]


## Today's full single-ship readout.
func _full_text(ship: ShipMovement) -> String:
	var orders := ship.get_node("%Orders") as ShipOrders
	var velocity := Vector3(ship.velocity.x, 0.0, ship.velocity.z)
	var thruster := ship.get_thruster_command()
	var destination := ship.get_destination()
	return "speed %6.2f m/s  velocity (x %6.2f, z %6.2f)\nheading %7.1f°  course %7.1f°  steering target %7.1f°  bow–travel %5.1f° (max %5.1f°)\nturn rate %7.2f / %5.2f °/s (permitted at %.2f m/s)  turn accel applied %7.2f of %5.2f °/s² available  shared %4.2f\ndesired %6.2f m/s  planned braking %5.2f m/s²\nforward: main engine %5.3f m/s²  forward thrusters %5.3f m/s² (limit %5.3f)\nthrusters %6.2f m/s²  (x %6.2f, z %6.2f)  sideways %5.2f m/s²  directional effectiveness %4.2f×\n%s\norder: %s\n%s\nclock %7.2f s  pending %d%s  last received %s  last activated %s" % [
		velocity.length(), velocity.x, velocity.z,
		ship.get_heading(), ship.get_course_heading(), ship.get_target_heading(), ship.get_bow_travel_angle(), ship.get_max_bow_angle(),
		ship.get_turn_rate(), ship.get_turn_rate_limit(), velocity.length(), ship.get_turn_acceleration(), ship.get_turn_authority(), ship.get_shared_scale(),
		ship.get_desired_speed(), ship.get_planned_braking(),
		ship.get_main_command(), maxf(thruster.dot(-ship.global_basis.z.normalized()), 0.0), ship.profile.forward_directional_acceleration * ship.get_directional_effectiveness(),
		thruster.length(), thruster.x, thruster.z, absf(thruster.dot(ship.global_basis.x.normalized())), ship.get_directional_effectiveness(),
		_destination_text(ship, destination) if ship.has_order() else "no active order",
		ship.get_order_status(),
		_reversal_text(ship),
		orders.get_clock(), orders.get_pending_count(), _next_pending_text(orders), _time_text(orders.get_last_received_time()), _time_text(orders.get_last_activated_time()),
	]


## The active destination and, when it differs (Task #54: a resolved destination), the requested click.
func _destination_text(ship: ShipMovement, destination: Vector3) -> String:
	var requested := ship.get_requested_destination()
	var text := "active destination (%.1f, %.1f)" % [destination.x, destination.z]
	if Vector2(requested.x - destination.x, requested.z - destination.z).length() > 0.01:
		text += "  requested (%.1f, %.1f)" % [requested.x, requested.z]
	return text


## Reversal rule: the latest move's course-change angle at activation, whether reversal braking was selected and
## whether it has completed.
func _reversal_text(ship: ShipMovement) -> String:
	var angle := ship.get_reversal_angle()
	if angle < 0.0:
		return "course change at activation —  (stop, near rest or arrival)  reversal braking no"
	var braking := "no"
	if ship.is_reversal():
		braking = "yes, %s" % ("complete" if ship.is_reversal_braking_complete() else "braking")
	return "course change at activation %5.1f°  (reversal from %.1f°)  reversal braking %s" % [angle, ship.profile.near_opposite_angle, braking]


func _next_pending_text(orders: ShipOrders) -> String:
	var next := orders.get_next_pending()
	if next.is_empty():
		return ""
	if next.kind == "move":
		return " (next move (%.1f, %.1f) due %.2f s)" % [next.position.x, next.position.z, next.due]
	return " (next stop due %.2f s)" % next.due


func _time_text(time: float) -> String:
	return "—" if time < 0.0 else "%.2f s" % time
