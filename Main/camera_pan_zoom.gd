extends Camera3D
## Temporary scene camera control for the movement test area: middle-mouse drag pans over the world
## XZ plane (the ground point under the cursor stays under it); the mouse wheel zooms along the view
## axis, keeping the camera's pitch. Never follows the ship and never rotates.

## Fraction of the camera's height moved per wheel notch (provisional).
@export_range(0.02, 0.5, 0.01) var zoom_step: float = 0.1
## Camera height limits while zooming (provisional).
@export_range(1.0, 1000.0, 1.0, "suffix:m") var min_height: float = 15.0
@export_range(1.0, 1000.0, 1.0, "suffix:m") var max_height: float = 400.0

var _plane := Plane(Vector3.UP, 0.0)
var _panning := false


func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null:
		if button.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = button.pressed
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(-1.0)
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(1.0)
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _panning:
		var before: Variant = _ground_point(motion.position - motion.relative)
		var after: Variant = _ground_point(motion.position)
		if before != null and after != null:
			var shift: Vector3 = before - after
			global_position += Vector3(shift.x, 0.0, shift.z)


## Moves along the view axis by zoom_step of the current height; out when direction > 0.
func _zoom(direction: float) -> void:
	var forward := -global_basis.z
	if is_zero_approx(forward.y):
		return
	var height := clampf(global_position.y * (1.0 + direction * zoom_step), min_height, max_height)
	global_position += forward * ((height - global_position.y) / forward.y)


func _ground_point(screen_position: Vector2) -> Variant:
	return _plane.intersects_ray(project_ray_origin(screen_position), project_ray_normal(screen_position))
