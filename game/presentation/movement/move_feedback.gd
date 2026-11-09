class_name ShipMoveFeedback
extends Node3D
## Draws a straight connector and the destination glyph relative to the ship's display origin.

@onready var _connector: MeshInstance3D = $Connector
@onready var _destination: Node3D = $Destination
@onready var _inner_ring: MeshInstance3D = $Destination/InnerRing
@onready var _outer_arc: MeshInstance3D = $Destination/OuterArc

var _style: ShipFeedbackStyle


func configure(style: ShipFeedbackStyle) -> void:
	_style = style
	_connector.material_override = style.material
	_inner_ring.mesh = style.make_ring(style.destination_inner_radius)
	_outer_arc.mesh = style.make_ring(style.destination_outer_radius, style.destination_arc_degrees)


func show_destination(offset: Vector3) -> void:
	_destination.position = offset
	var distance := offset.length()
	var direction := offset.normalized() if distance > 0.0 else Vector3.RIGHT
	_destination.rotation.y = atan2(direction.z, -direction.x)

	var length := distance - _style.selection_radius - _style.destination_outer_radius
	_connector.visible = length > 0.0
	if _connector.visible:
		_connector.position = direction * (_style.selection_radius + length * 0.5)
		_connector.rotation.y = atan2(-direction.z, direction.x)
		_connector.scale = Vector3(length, 1.0, _style.line_width)
	show()
