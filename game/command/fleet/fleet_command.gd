class_name FleetCommand
extends Node3D
## Fleet: one controller per playable viewport. Owns the roster and the ordered selection, and sends the player's
## orders to every selected ship through its Orders. Preserve input order when picking in the physics tick.
## Keys: select_fleet selects the whole roster; select_ship_1..3 select one roster slot (a missing slot does nothing).
## Fleet orders (Task 37, #78): with several ships selected, each gets its own preferred point across the direction of
## travel, keeping their left-to-right order; one ship gets the click itself. While any of that order's ships is still
## pending in Orders or planning in Movement, one shared pending marker stays at the click.

const MOVE_PLANE := Plane(Vector3.UP, 0.0)
const SLOT_ACTIONS: Array[StringName] = [&"select_ship_1", &"select_ship_2", &"select_ship_3"]

## Roster slots in order: middle, left, right.
@export var roster: Array[ShipMovement] = []
@export var style: ShipFeedbackStyle

var _clicks: Array[Dictionary] = []
## Selected ships, always in roster order.
var _selection: Array[ShipMovement] = []
## The latest fleet order: its click and each ship's receipt ({ship, orders, receipt}).
var _fleet_click := Vector3.ZERO
var _fleet_receipts: Array[Dictionary] = []

@onready var _marker: ShipMoveFeedback = $PendingMarker


func _ready() -> void:
	for i in roster.size():
		roster[i].set_traffic_slot(i)
	_marker.top_level = true
	_marker.configure(style)
	set_process(false)


## The selected ships in roster order. The returned array is a copy.
func get_selection() -> Array[ShipMovement]:
	return _selection.duplicate()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and not event.is_echo():
		if event.is_action_pressed(&"select_fleet"):
			_select(roster)
			get_viewport().set_input_as_handled()
			return
		for i in SLOT_ACTIONS.size():
			if event.is_action_pressed(SLOT_ACTIONS[i]):
				if i < roster.size():
					_select([roster[i]])
				get_viewport().set_input_as_handled()
				return
	var click := event as InputEventMouseButton
	if click == null or not click.pressed:
		return
	var picking := click.button_index == MOUSE_BUTTON_LEFT
	var moving := click.button_index == MOUSE_BUTTON_RIGHT and not click.shift_pressed
	if not picking and not moving:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var origin := camera.project_ray_origin(click.position)
	var direction := camera.project_ray_normal(click.position)
	if moving and _clicks.is_empty():
		_move_selection(origin, direction)
	else:
		_clicks.append({picking = picking, origin = origin, direction = direction, reach = camera.far})
	get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	for click in _clicks:
		if click.picking:
			_pick(click.origin, click.origin + click.direction * click.reach)
		else:
			_move_selection(click.origin, click.direction)
	_clicks.clear()


func _move_selection(origin: Vector3, direction: Vector3) -> void:
	var target: Variant = MOVE_PLANE.intersects_ray(origin, direction)
	if target == null:
		return
	var ships: Array[ShipMovement] = []
	for ship in _selection:
		if is_instance_valid(ship):
			ships.push_back(ship)
	if ships.size() == 1:
		(ships[0].get_node("%Orders") as ShipOrders).move(target)
		return
	if ships.is_empty():
		return
	var points := _preferred_points(ships, target)
	_fleet_click = target
	_fleet_receipts.clear()
	for ship in ships:
		var orders := ship.get_node("%Orders") as ShipOrders
		var receipt := orders.move(points[ship])
		_fleet_receipts.push_back({ship = ship, orders = orders, receipt = receipt})
		var presentation := ship.get_node_or_null("%CommandPresentation") as ShipCommandPresentation
		if presentation != null:
			presentation.set_fleet_order(receipt, target)
	set_process(true)


## Each ship's preferred point (ShipMovement -> Vector3): travel direction d from the ships' centroid to the click,
## across-axis r = d x up (world +X when the click is at the centroid); ships sorted along r (roster order on ties),
## the k-th of n at click + r (k - (n - 1) / 2) spacing, spacing twice the largest reservation radius.
func _preferred_points(ships: Array[ShipMovement], click: Vector3) -> Dictionary:
	var centroid := Vector3.ZERO
	var spacing := 0.0
	for ship in ships:
		centroid += ship.global_position
		spacing = maxf(spacing, 2.0 * ship.get_reservation_radius())
	centroid /= ships.size()
	var travel := Vector3(click.x - centroid.x, 0.0, click.z - centroid.z)
	var across := Vector3.RIGHT if travel.is_zero_approx() else travel.normalized().cross(Vector3.UP)
	var sorted := ships.duplicate()
	sorted.sort_custom(func(a: ShipMovement, b: ShipMovement) -> bool:
		var offset_a := a.global_position.dot(across)
		var offset_b := b.global_position.dot(across)
		if offset_a != offset_b:
			return offset_a < offset_b
		return roster.find(a) < roster.find(b))
	var points := {}
	for k in sorted.size():
		points[sorted[k]] = click + across * ((k - (sorted.size() - 1) * 0.5) * spacing)
	return points


## The shared pending marker: at the click while any ship of the latest fleet order is pending in Orders or planning
## in Movement and at least one of them is selected; its arc faces the centroid of that order's ships.
func _process(_delta: float) -> void:
	var pending := false
	var selected := false
	var centroid := Vector3.ZERO
	var count := 0
	for entry in _fleet_receipts:
		if not is_instance_valid(entry.ship):
			continue
		var ship: ShipMovement = entry.ship
		centroid += ship.get_global_transform_interpolated().origin
		count += 1
		selected = selected or _selection.has(ship)
		if (entry.orders as ShipOrders).get_pending_destination(entry.receipt) != null 				or ship.get_planning_move_destination(entry.receipt) != null:
			pending = true
	if not pending or count == 0:
		_marker.hide()
		_fleet_receipts.clear()
		set_process(false)
		return
	if not selected:
		_marker.hide()
		return
	centroid /= count
	_marker.global_position = Vector3(centroid.x, 0.0, centroid.z)
	_marker.show_destination(Vector3(_fleet_click.x - centroid.x, 0.0, _fleet_click.z - centroid.z), true, true, false)


func _pick(from: Vector3, to: Vector3) -> void:
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var ship := hit.get("collider") as ShipMovement
	_select([ship] if ship != null and roster.has(ship) else [])


## Replaces the selection with these ships, kept in roster order, and updates each roster ship's presentation.
func _select(ships: Array) -> void:
	_selection.clear()
	for ship in roster:
		if ships.has(ship):
			_selection.push_back(ship)
	for ship in roster:
		var presentation := ship.get_node_or_null("%CommandPresentation") as ShipCommandPresentation
		if presentation != null:
			presentation.set_selected(_selection.has(ship))
