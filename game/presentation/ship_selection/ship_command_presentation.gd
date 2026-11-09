class_name ShipCommandPresentation
extends Node3D
## Per-ship visual state. Only the selected instance needs frame updates.

const HULL_MASK := preload("res://game/presentation/ship_selection/selected_hull_mask.tres")

@export var ship: ShipMovement
@export var style: ShipFeedbackStyle
@export var hull_visual: Node3D

@onready var _selection_ring: GroundFeedbackRing = $SelectionRing
@onready var _move_feedback: ShipMoveFeedback = $MoveFeedback

var _latest_move_receipt := 0
var _original_hull_overlays: Dictionary[MeshInstance3D, Material] = {}


func _ready() -> void:
	_selection_ring.configure(style.selection_radius, style.ring_stroke)
	_move_feedback.configure(style)
	set_selected(false)


func set_selected(selected: bool) -> void:
	set_process(selected)
	visible = selected
	if selected:
		_apply_hull_mask()
	else:
		_clear_hull_mask()
		_move_feedback.hide()


func _exit_tree() -> void:
	_clear_hull_mask()


func _apply_hull_mask() -> void:
	if hull_visual == null or not _original_hull_overlays.is_empty():
		return
	if hull_visual is MeshInstance3D:
		_mask_mesh(hull_visual as MeshInstance3D)
	for mesh in hull_visual.find_children("*", "MeshInstance3D", true, false):
		_mask_mesh(mesh as MeshInstance3D)


func _mask_mesh(mesh: MeshInstance3D) -> void:
	var original := mesh.material_overlay
	_original_hull_overlays[mesh] = original
	if original == null:
		mesh.material_overlay = HULL_MASK
	else:
		# Keep an authored overlay active without editing either shared material.
		var mask := HULL_MASK.duplicate() as ShaderMaterial
		mask.next_pass = original
		mesh.material_overlay = mask


func _clear_hull_mask() -> void:
	for mesh in _original_hull_overlays:
		if is_instance_valid(mesh):
			mesh.material_overlay = _original_hull_overlays[mesh]
	_original_hull_overlays.clear()


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
	# Camera coordinates need only the viewport's stretch into its render target.
	var screen_scale := viewport.get_stretch_transform().get_scale()
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
