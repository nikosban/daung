extends Node
## Temporary scene input for the world XZ plane point under the cursor: right-click orders the ship there.
## Shift + right-click does nothing until routes are rebuilt.
## F4 calls stop(): a temporary test-only diagnostic for the Task #29 stopping comparison, not a game control.
## Both are received by Movement and act after the profile's reaction delay (Task #30).
## Each accepted right-click also emits move_requested with the same point, for the F3 destination marker (Task #38).

signal move_requested(world_position: Vector3)

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
		move_requested.emit(hit)
