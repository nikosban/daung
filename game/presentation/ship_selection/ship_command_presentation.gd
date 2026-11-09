class_name ShipCommandPresentation
extends Node3D
## Per-ship visual state. Only the selected instance needs frame updates.

@export var ship: ShipMovement
@export var style: ShipFeedbackStyle

@onready var _selection_ring: GroundFeedbackRing = $SelectionRing
@onready var _move_feedback: ShipMoveFeedback = $MoveFeedback

var _latest_move_receipt := 0


func _ready() -> void:
	_selection_ring.configure(style.selection_radius, style.ring_stroke)
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
	var viewport := get_viewport()
	var camera := viewport.get_camera_3d()
	if camera == null:
		_selection_ring.hide()
		_move_feedback.hide()
		return

	var ship_position := ship.get_global_transform_interpolated().origin
	global_position = Vector3(ship_position.x, 0.0, ship_position.z)
	var screen_scale := viewport.get_screen_transform().get_scale()
	_selection_ring.draw(camera, screen_scale, style.material.albedo_color)

	var target: Variant = ship.get_resolved_move_destination(_latest_move_receipt)
	var pending: bool = target == null
	if pending:
		target = ship.get_pending_move_destination(_latest_move_receipt)
	if target == null:
		_move_feedback.hide()
		return
	var offset := Vector3(target.x - ship_position.x, 0.0, target.z - ship_position.z)
	_move_feedback.show_destination(camera, screen_scale, offset, pending)
