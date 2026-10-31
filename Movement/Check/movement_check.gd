extends Node3D

## Permanent MovementCheck scene. Right-click the ground to order the ship,
## press C to stop it.

@onready var _camera: Camera3D = $Camera3D
@onready var _ship: MovementController = $Ship
@onready var _label: Label = $HUD/Label

var _completed_count := 0


func _ready() -> void:
	_ship.order_completed.connect(_on_order_completed)


func _unhandled_input(event: InputEvent) -> void:
	var mouse := event as InputEventMouseButton
	if mouse and mouse.pressed and mouse.button_index == MOUSE_BUTTON_RIGHT:
		var origin := _camera.project_ray_origin(mouse.position)
		var direction := _camera.project_ray_normal(mouse.position)
		var hit: Variant = Plane(Vector3.UP, _ship.global_position.y).intersects_ray(origin, direction)
		if hit != null:
			_ship.move_to(hit)
		return
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.keycode == KEY_C:
		_ship.stop()


func _process(_delta: float) -> void:
	var destination := _ship.get_destination()
	var desired := _ship.get_desired_direction()
	_label.text = "\n".join([
		"Right-click: move_to   C: stop",
		"State: %s" % MovementController.State.keys()[_ship.get_state()],
		"Speed: %.2f units/s" % _ship.velocity.length(),
		"Heading: %.1f°" % rad_to_deg(_ship.rotation.y),
		"Desired direction: (%.2f, %.2f)" % [desired.x, desired.z],
		"Destination: (%.1f, %.1f)" % [destination.x, destination.z],
		"order_completed: %d" % _completed_count,
	])


func _on_order_completed() -> void:
	_completed_count += 1
	print("order_completed")
