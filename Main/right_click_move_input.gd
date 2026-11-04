extends Node
## Temporary scene input for the world XZ plane point under the cursor: right-click orders the ship there.
## Shift + right-click does nothing until routes are rebuilt.
## F4 calls stop(): a temporary test-only diagnostic for the Task #29 stopping comparison, not a game control.

@export var camera: Camera3D
@export var ship: ShipMovement

var _plane := Plane(Vector3.UP, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_F4:
		ship.stop()
		return
	var click := event as InputEventMouseButton
	if click == null or not click.pressed or click.button_index != MOUSE_BUTTON_RIGHT or click.shift_pressed:
		return
	var hit: Variant = _plane.intersects_ray(camera.project_ray_origin(click.position), camera.project_ray_normal(click.position))
	if hit != null:
		ship.move_to(hit)
