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
	_clicks.append({
		picking = picking,
		origin = camera.project_ray_origin(click.position),
		direction = camera.project_ray_normal(click.position),
		reach = camera.far,
	})
	get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	for click in _clicks:
		if click.picking:
			_select_ship(click.origin, click.origin + click.direction * click.reach)
		elif is_instance_valid(_selection):
			var target: Variant = MOVE_PLANE.intersects_ray(click.origin, click.direction)
			if target != null:
				_selection.record_move(_selection.ship.move_to(target))
	_clicks.clear()


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
