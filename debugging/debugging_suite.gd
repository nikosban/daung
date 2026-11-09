extends Node3D
## Reusable scene composition for Daung's existing movement diagnostics and test controls.
## Main supplies world dependencies; Movement never depends on this suite.

const MARKER_SCENE := preload("res://debugging/debug_marker.tscn")

@export var ship: ShipMovement
@export var collision_shapes: Array[CollisionShape3D] = []
## World-space positions of the optional amber reference rings, supplied by the host scene.
@export var reference_marker_positions := PackedVector3Array()

var _outlines: Array[CollisionShapeOutline] = []


func _ready() -> void:
	$MovementTrail.ship = ship
	$MovementDebugOverlay.ship = ship
	for shape in collision_shapes:
		var outline := CollisionShapeOutline.new()
		outline.name = "CollisionOutline"
		shape.add_child(outline)
		_outlines.push_back(outline)
	$MovementDebugOverlay.collision_outlines = _outlines
	for position in reference_marker_positions:
		var marker := MARKER_SCENE.instantiate() as MeshInstance3D
		$ReferenceMarkers.add_child(marker)
		marker.top_level = true
		marker.global_transform = Transform3D(Basis.IDENTITY, position)


func _exit_tree() -> void:
	# These visuals are parented to external collision shapes, so own their lifetime explicitly.
	for outline in _outlines:
		if is_instance_valid(outline):
			outline.queue_free()
	_outlines.clear()


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_F4:
		if is_instance_valid(ship):
			ship.stop()
