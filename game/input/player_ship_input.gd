extends Node3D
## One controller per playable viewport. Preserve input order when picking in the physics tick.

const MOVE_PLANE := Plane(Vector3.UP, 0.0)

var _clicks: Array[Dictionary] = []
var _selection: ShipCommandPresentation


func _unhandled_input(event: InputEvent) -> void:
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
		_move_ship(origin, direction)
	else:
		_clicks.append({picking = picking, origin = origin, direction = direction, reach = camera.far})
	get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	for click in _clicks:
		if click.picking:
			_select_ship(click.origin, click.origin + click.direction * click.reach)
		else:
			_move_ship(click.origin, click.direction)
	_clicks.clear()


func _move_ship(origin: Vector3, direction: Vector3) -> void:
	if not is_instance_valid(_selection):
		return
	var target: Variant = MOVE_PLANE.intersects_ray(origin, direction)
	if target != null:
		_selection.orders.move(target)


func _select_ship(from: Vector3, to: Vector3) -> void:
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var ship := hit.get("collider") as ShipMovement
	if is_instance_valid(_selection):
		_selection.set_selected(false)
	_selection = null
	if ship != null:
		_selection = ship.get_node_or_null("%CommandPresentation") as ShipCommandPresentation
		if _selection != null:
			_selection.set_selected(true)
