extends CanvasLayer
## Temporary F3 movement readout of one ship: speed, velocity, heading, main-engine and thruster
## commands, destination and order state. Reads Movement only; Movement never calls it. Hidden until F3.

@export var ship: ShipMovement

var _label := Label.new()


func _ready() -> void:
	visible = false
	_label.position = Vector2(12.0, 12.0)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	add_child(_label)


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_F3:
		visible = not visible


func _process(_delta: float) -> void:
	if not visible:
		return
	var velocity := Vector3(ship.velocity.x, 0.0, ship.velocity.z)
	var thruster := ship.get_thruster_command()
	var destination := ship.get_destination()
	_label.text = "speed %6.2f m/s  velocity (x %6.2f, z %6.2f)\nheading %7.1f°\nmain %6.2f m/s²\nthrusters %6.2f m/s²  (x %6.2f, z %6.2f)\ndestination (%.1f, %.1f)  %s" % [
		velocity.length(), velocity.x, velocity.z,
		ship.get_heading(),
		ship.get_main_command(),
		thruster.length(), thruster.x, thruster.z,
		destination.x, destination.z,
		"active" if ship.has_order() else "no order",
	]
