extends Node
## Temporary playtest scene for Task #56 (remove after review): reproduces the moving A2 redirect of PR #55 in Main.
## The frigate starts at rest at (238, 0, −162) and is ordered to (170, 0, −90) on the first physics tick; asteroid A2
## (240, 0, −201) is then ordered so that the redirect activates at redirect_time on the Movement clock (5 s is the
## decisive check, 6 s the regression). Run with F6 (Run Current Scene) and press F3 for the trail, the destination
## marker and the order status. No input binding is added; the scene only issues the two orders.

## Movement-clock time at which the A2 order activates (s): the order is sent one reaction delay earlier.
@export_range(0.5, 20.0, 0.1, "suffix:s") var redirect_time: float = 5.0

const START := Vector3(238.0, 0.0, -162.0)
const FIRST_ORDER := Vector3(170.0, 0.0, -90.0)
const A2_ORDER := Vector3(240.0, 0.0, -201.0)
## Camera over the A2 area, looking down at 45° as Main's camera does (pan and zoom still work).
const CAMERA_POSITION := Vector3(205.0, 150.0, -15.0)

var _first_sent := false
var _redirect_sent := false

@onready var _ship: ShipMovement = $Main/Ship
@onready var _camera: Camera3D = $Main/Camera3D


func _ready() -> void:
	_ship.global_position = START
	_camera.global_position = CAMERA_POSITION


func _physics_process(_delta: float) -> void:
	if not _first_sent:
		_first_sent = true
		_ship.move_to(FIRST_ORDER)
		return
	if not _redirect_sent and _ship.get_clock() >= redirect_time - _ship.profile.reaction_delay:
		_redirect_sent = true
		_ship.move_to(A2_ORDER)
