class_name ShipCommandPresentation
extends Node3D
## Per-ship visual state. Only the selected instance needs frame updates.

@export var ship: ShipMovement
@export var orders: ShipOrders
@export var style: ShipFeedbackStyle

@onready var _selection_ring: MeshInstance3D = $SelectionRing
@onready var _move_feedback: ShipMoveFeedback = $MoveFeedback

func _ready() -> void:
	var ring := ImmediateMesh.new()
	GroundFeedbackMesh.add_band(ring, style.selection_radius, style.selection_stroke)
	_selection_ring.mesh = ring
	_selection_ring.material_override = style.material
	_move_feedback.configure(style)
	set_selected(false)


func set_selected(selected: bool) -> void:
	set_process(selected)
	visible = selected
	if not selected:
		_move_feedback.hide()


func _process(_delta: float) -> void:
	var ship_position := ship.get_global_transform_interpolated().origin
	global_position = Vector3(ship_position.x, 0.0, ship_position.z)

	var receipt := orders.get_latest_receipt()
	var target: Variant = ship.get_resolved_move_destination(receipt)
	var pending: bool = target == null
	if pending:
		target = ship.get_planning_move_destination(receipt)
	if target == null:
		target = orders.get_pending_destination(receipt)
	if target == null:
		_move_feedback.hide()
		return
	var offset := Vector3(target.x - ship_position.x, 0.0, target.z - ship_position.z)
	_move_feedback.show_destination(offset, pending)
