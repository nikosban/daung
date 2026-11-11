extends CanvasLayer
## Temporary F3 movement readout of the fleet's selected ships. With one ship selected, the full readout (#102): speed,
## velocity and its parts along the bow and sideways, heading, turn rate and its limit, applied and available RCS
## acceleration, applied main and retro acceleration with their capacities and speed limits, whether the diagnostic
## control is active, active destination and order state, the latest order's outcome (planning, accepted, declined with
## its reason, stopped or a contact stop), and the reaction-delay queue (physics clock, pending count, next pending
## command and its due time, last receipt and activation times, from Orders). Reads Movement and Orders only; Movement
## never calls it. Hidden until F3.
## With several selected, one compact block per ship in roster order (name, speed, heading, destination, order status,
## traffic status, queue); with none, "no ship selected". Reads Fleet, Movement and Orders only.
## F3 also shows the selected ships' world-space movement trails (a fresh trace when F3 turns on or a ship becomes
## selected) and hides the others.
## F3 also shows and hides the red collision-shape outlines (Task #44).
## Each ship's text includes its ship traffic status (Task 38, #79); after F7, a note that the crossing test is valid
## only in a fresh run.

@export var fleet: FleetCommand
## One trail per roster ship (ShipMovement -> MovementTrail), supplied by the suite.
var trails := {}
## Ships whose trails are currently active.
var _shown: Array[ShipMovement] = []
## F3 red outlines of collision shapes (Task #44); shown and hidden with the readout.
@export var collision_outlines: Array[CollisionShapeOutline] = []
## Set by the suite when F7 issued the crossing orders.
var crossing_issued := false

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
	if crossing_issued:
		_label.text += "\n\nF7 crossing orders issued: valid only in a fresh run, from the start positions"


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


## One ship's compact block: name, speed, heading, destination, order status, traffic status and the Orders queue.
func _compact_text(ship: ShipMovement) -> String:
	var orders := ship.get_node("%Orders") as ShipOrders
	return "%s  speed %6.2f m/s  heading %7.1f°\n%s\norder: %s\ntraffic: %s\nqueue: pending %d%s" % [
		ship.name, Vector2(ship.velocity.x, ship.velocity.z).length(), ship.get_heading(),
		_destination_text(ship, ship.get_destination()) if ship.has_order() else "no active order",
		ship.get_order_status(), ship.get_traffic_status(), orders.get_pending_count(), _next_pending_text(orders),
	]


## The full single-ship readout (#102 propulsion).
func _full_text(ship: ShipMovement) -> String:
	var orders := ship.get_node("%Orders") as ShipOrders
	var velocity := Vector3(ship.velocity.x, 0.0, ship.velocity.z)
	var bow := ShipPropulsion.bow_of(ship.rotation.y)
	var right := Vector3(-bow.z, 0.0, bow.x)
	var destination := ship.get_destination()
	return "speed %6.2f m/s  velocity (x %6.2f, z %6.2f)  along bow %+6.2f m/s  sideways %+6.2f m/s
heading %7.1f°  turn rate %+7.2f °/s (limit %5.2f)  RCS %+7.2f of %5.2f °/s²
main %5.3f of %5.3f m/s² (forward limit %.1f m/s)  retro %5.3f of %5.3f m/s² (reverse limit %.1f m/s)
diagnostic control %s
%s
order: %s
traffic: %s
clock %7.2f s  pending %d%s  last received %s  last activated %s" % [
		velocity.length(), velocity.x, velocity.z, velocity.dot(bow), velocity.dot(right),
		ship.get_heading(), ship.get_turn_rate(), ship.get_turn_rate_limit(), ship.get_turn_acceleration(), ship.get_turn_authority(),
		ship.get_main_command(), ship.profile.main_acceleration, ship.profile.max_speed,
		ship.get_retro_command(), ship.profile.retro_acceleration, ship.profile.max_reverse_speed,
		"active" if ship.is_diagnostic_active() else "off",
		_destination_text(ship, destination) if ship.has_order() else "no active order",
		ship.get_order_status(), ship.get_traffic_status(),
		orders.get_clock(), orders.get_pending_count(), _next_pending_text(orders), _time_text(orders.get_last_received_time()), _time_text(orders.get_last_activated_time()),
	]


## The active destination and, when it differs (Task #54: a resolved destination), the requested click.
func _destination_text(ship: ShipMovement, destination: Vector3) -> String:
	var requested := ship.get_requested_destination()
	var text := "active destination (%.1f, %.1f)" % [destination.x, destination.z]
	if Vector2(requested.x - destination.x, requested.z - destination.z).length() > 0.01:
		text += "  requested (%.1f, %.1f)" % [requested.x, requested.z]
	return text


func _next_pending_text(orders: ShipOrders) -> String:
	var next := orders.get_next_pending()
	if next.is_empty():
		return ""
	if next.kind == "move":
		return " (next move (%.1f, %.1f) due %.2f s)" % [next.position.x, next.position.z, next.due]
	return " (next stop due %.2f s)" % next.due


func _time_text(time: float) -> String:
	return "—" if time < 0.0 else "%.2f s" % time
