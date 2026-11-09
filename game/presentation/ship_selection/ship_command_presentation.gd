class_name ShipCommandPresentation
extends Node3D
## Per-ship visual state. Only the selected instance needs frame updates.

const RING_SEGMENTS := 96

@export var ship: ShipMovement
@export var style: ShipFeedbackStyle

@onready var _selection_ring: MeshInstance3D = $SelectionRing
@onready var _move_feedback: ShipMoveFeedback = $MoveFeedback

var _latest_move_receipt := 0


func _ready() -> void:
	_selection_ring.mesh = _make_selection_ring()
	_move_feedback.configure(style)
	set_selected(false)


func set_selected(selected: bool) -> void:
	set_process(selected)
	visible = selected
	if not selected:
		_move_feedback.hide()


func record_move(receipt: int) -> void:
	_latest_move_receipt = receipt


func _process(_delta: float) -> void:
	var ship_position := ship.get_global_transform_interpolated().origin
	global_position = Vector3(ship_position.x, 0.0, ship_position.z)

	var viewport := get_viewport()
	var camera := viewport.get_camera_3d()
	if camera == null:
		_move_feedback.hide()
		return

	# Camera coordinates need only the viewport's stretch into its render target.
	var screen_scale := viewport.get_stretch_transform().get_scale()

	var target: Variant = ship.get_resolved_move_destination(_latest_move_receipt)
	var pending: bool = target == null
	if pending:
		target = ship.get_pending_move_destination(_latest_move_receipt)
	if target == null:
		_move_feedback.hide()
		return
	var offset := Vector3(target.x - ship_position.x, 0.0, target.z - ship_position.z)
	_move_feedback.show_destination(camera, screen_scale, offset, pending)


func _make_selection_ring() -> Mesh:
	var outer := style.selection_radius
	var inner := maxf(0.0, outer - style.selection_stroke)
	var ring := ImmediateMesh.new()
	ring.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, style.material)
	for index in range(RING_SEGMENTS + 1):
		var angle := TAU * index / RING_SEGMENTS
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		ring.surface_add_vertex(direction * outer)
		ring.surface_add_vertex(direction * inner)
	ring.surface_end()
	return ring
