extends Node
## Temporary scene input for the world XZ plane point under the cursor: right-click replaces the
## route with a move request; Shift + right-click appends a waypoint.

@export var camera: Camera3D
@export var ship: ShipMovement

var _plane := Plane(Vector3.UP, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if click == null or not click.pressed or click.button_index != MOUSE_BUTTON_RIGHT:
		return
	var hit: Variant = _plane.intersects_ray(camera.project_ray_origin(click.position), camera.project_ray_normal(click.position))
	if hit == null:
		return
	if click.shift_pressed:
		ship.append_waypoint(hit)
	else:
		ship.move_to(hit)
