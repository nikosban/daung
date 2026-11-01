extends Node3D

## Permanent MovementCheck script, shared by the check scenes. Every child
## MovementController is a ship, numbered 1-9 in scene order. Number keys
## select a ship, right-click orders it, C stops it. The selected ship's
## remaining route is drawn as a line.

@onready var _camera: Camera3D = $Camera3D
@onready var _label: Label = $HUD/Label

var _ships: Array[MovementController] = []
var _completed_counts: Array[int] = []
var _failed_counts: Array[int] = []
var _selected := 0
var _route_mesh := ImmediateMesh.new()


func _ready() -> void:
	for child in get_children():
		var ship := child as MovementController
		if ship:
			ship.order_completed.connect(_on_order_completed.bind(_ships.size()))
			ship.order_failed.connect(_on_order_failed.bind(_ships.size()))
			_ships.append(ship)
			_completed_counts.append(0)
			_failed_counts.append(0)
	var route_line := MeshInstance3D.new()
	route_line.mesh = _route_mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.1, 0.4, 1.0)
	route_line.material_override = material
	add_child(route_line)


func _unhandled_input(event: InputEvent) -> void:
	var ship := _ships[_selected]
	var mouse := event as InputEventMouseButton
	if mouse and mouse.pressed and mouse.button_index == MOUSE_BUTTON_RIGHT:
		var origin := _camera.project_ray_origin(mouse.position)
		var direction := _camera.project_ray_normal(mouse.position)
		var hit: Variant = Plane(Vector3.UP, ship.global_position.y).intersects_ray(origin, direction)
		if hit != null:
			ship.move_to(hit)
		return
	var key := event as InputEventKey
	if not key or not key.pressed or key.echo:
		return
	if key.keycode == KEY_C:
		ship.stop()
	elif key.keycode >= KEY_1 and key.keycode < KEY_1 + _ships.size():
		_selected = key.keycode - KEY_1


func _process(_delta: float) -> void:
	var ship := _ships[_selected]
	var destination := ship.get_destination()
	var desired := ship.get_desired_direction()
	var route := ship.get_route()
	_label.text = "\n".join([
		"1-%d: select ship   Right-click: move_to   C: stop" % _ships.size(),
		"Selected: %d (%s)" % [_selected + 1, ship.name],
		"State: %s" % MovementController.State.keys()[ship.get_state()],
		"Speed: %.2f units/s" % ship.velocity.length(),
		"Heading: %.1f°" % rad_to_deg(ship.rotation.y),
		"Desired direction: (%.2f, %.2f)" % [desired.x, desired.z],
		"Destination: (%.1f, %.1f)" % [destination.x, destination.z],
		"Waypoint: %d / %d" % [mini(ship.get_waypoint_index() + 1, route.size()), route.size()],
		"order_completed: %d   order_failed: %d" % [_completed_counts[_selected], _failed_counts[_selected]],
	])
	_draw_route(ship, route)


func _draw_route(ship: MovementController, route: PackedVector3Array) -> void:
	_route_mesh.clear_surfaces()
	if route.is_empty():
		return
	_route_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	var height := ship.global_position.y + 3.0
	_route_mesh.surface_add_vertex(Vector3(ship.global_position.x, height, ship.global_position.z))
	for i in range(ship.get_waypoint_index(), route.size()):
		_route_mesh.surface_add_vertex(Vector3(route[i].x, height, route[i].z))
	_route_mesh.surface_end()


func _on_order_completed(index: int) -> void:
	_completed_counts[index] += 1
	print("order_completed: ship %d" % (index + 1))


func _on_order_failed(index: int) -> void:
	_failed_counts[index] += 1
	print("order_failed: ship %d" % (index + 1))
