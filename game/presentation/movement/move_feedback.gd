class_name ShipMoveFeedback
extends Node3D
## Draws a straight connector and the destination glyph relative to the ship's display origin.

@onready var _connector: MeshInstance3D = $Connector
@onready var _destination: MeshInstance3D = $Destination

var _style: ShipFeedbackStyle
var _ribbon := ImmediateMesh.new()


func configure(style: ShipFeedbackStyle) -> void:
	_style = style
	_connector.mesh = _ribbon
	var glyph := ImmediateMesh.new()
	GroundFeedbackMesh.add_band(glyph, style.destination_inner_radius, style.ring_stroke)
	GroundFeedbackMesh.add_band(glyph, style.destination_outer_radius, style.ring_stroke,
		style.destination_arc_degrees)
	_destination.mesh = glyph


## glyph and connector false hide that part (Task 37, #78: a fleet order's shared marker and its ships' connectors).
func show_destination(offset: Vector3, pending: bool, glyph := true, connector := true) -> void:
	var material := _style.pending_material if pending else _style.material
	if _destination.material_override != material:
		_destination.material_override = material
		_connector.material_override = material

	_destination.position = offset
	if not offset.is_zero_approx():
		# The outer arc is centred on local -Z, so it faces the ship.
		_destination.basis = Basis.looking_at(-offset)
	_destination.visible = glyph
	_connector.visible = connector and _draw_connector(offset)
	show()


func _draw_connector(offset: Vector3) -> bool:
	var distance := offset.length()
	var start := _style.selection_radius + _style.line_gap
	var end := distance - _style.destination_outer_radius - _style.line_gap
	if end <= start:
		return false

	var along := offset / distance
	var side := Vector3(-along.z, 0.0, along.x) * (_style.line_width * 0.5)
	_ribbon.clear_surfaces()
	_ribbon.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for point in [along * start, along * end]:
		_ribbon.surface_add_vertex(point + side)
		_ribbon.surface_add_vertex(point - side)
	_ribbon.surface_end()
	return true
