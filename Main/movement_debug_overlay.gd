extends CanvasLayer
## Temporary F3 movement readout: phase, commanded and actual heading and speed, and slip of one ship.
## Reads Movement only; Movement never calls it. Hidden until F3 is pressed.

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
	var commanded := ship.get_commanded_heading()
	_label.text = "phase %s\nheading %7.1f°  commanded %s\nspeed %6.2f m/s  commanded %.2f m/s\nslip %6.2f m/s" % [
		ship.get_phase_name(),
		ship.get_heading(),
		"—" if is_nan(commanded) else "%.1f°" % commanded,
		ship.get_speed(),
		ship.get_commanded_speed(),
		ship.get_slip(),
	]
