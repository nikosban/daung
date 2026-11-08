extends Node3D
## Temporary #60 setup. Run this inherited Main scene with F6, then press F3. No permanent player controls.
@export_enum("Test asteroid and moving redirect", "A2 activating at 6 s", "Tight C11-C12 passage") var scenario := 0

var _ship: ShipMovement
var _second_sent := false

func _ready() -> void:
	_ship = get_node("Ship")
	if scenario == 1:
		_ship.global_position = Vector3(238, 0, -162)
		get_node("Camera3D").global_position = Vector3(245, 70, -90)
		_order(Vector3(170, 0, -90))
	elif scenario == 2:
		_ship.global_position = Vector3(120, 0, 235)
		get_node("Camera3D").global_position = Vector3(120, 70, 370)
		_order(Vector3(120, 0, 330))
		_second_sent = true
	else:
		_order(Vector3(130, 0, 0))
	_ship.reset_physics_interpolation()

func _physics_process(_delta: float) -> void:
	if _second_sent:
		return
	var due := 6.0 - _ship.profile.reaction_delay if scenario == 1 else 8.0
	if _ship.get_clock() + 1e-7 >= due:
		_second_sent = true
		_order(Vector3(240, 0, -201) if scenario == 1 else Vector3(60, 0, -40))

func _order(point: Vector3) -> void:
	_ship.move_to(point)
	get_node("RightClickMoveInput").emit_signal("move_requested", point)
