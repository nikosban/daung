class_name FleetCommand
extends Node3D
## Fleet: one controller per playable viewport. Owns the roster and the ordered selection, and sends the player's
## orders to every selected ship through its Orders. Preserve input order when picking in the physics tick.
## Keys: select_fleet selects the whole roster; select_ship_1..3 select one roster slot (a missing slot does nothing).

const MOVE_PLANE := Plane(Vector3.UP, 0.0)
const SLOT_ACTIONS: Array[StringName] = [&"select_ship_1", &"select_ship_2", &"select_ship_3"]

## Roster slots in order: middle, left, right.
@export var roster: Array[ShipMovement] = []

var _clicks: Array[Dictionary] = []
## Selected ships, always in roster order.
var _selection: Array[ShipMovement] = []


func _ready() -> void:
	for i in roster.size():
		roster[i].set_traffic_slot(i)


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
	for ship in _selection:
		if is_instance_valid(ship):
			(ship.get_node("%Orders") as ShipOrders).move(target)


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
