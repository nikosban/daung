class_name ShipFeedbackStyle
extends Resource
## Shared appearance. Radius values are measured to the outside edge of each ring.

@export var material: StandardMaterial3D
@export_range(0.01, 1000.0, 0.01, "or_greater", "suffix:m") var selection_radius := 12.0
@export_range(0.01, 1000.0, 0.01, "or_greater", "suffix:m") var destination_inner_radius := 5.0
@export_range(0.01, 1000.0, 0.01, "or_greater", "suffix:m") var destination_outer_radius := 7.5
@export_range(0.1, 359.9, 0.1, "degrees") var destination_arc_degrees := 120.0
@export_range(0.01, 1000.0, 0.01, "or_greater", "suffix:m") var ring_stroke := 0.75
@export_range(0.01, 1000.0, 0.01, "or_greater", "suffix:m") var line_width := 0.65
@export_range(0.0, 1000.0, 0.01, "or_greater", "suffix:m") var plane_lift := 0.1


## The arc is centered on local +X. Use an even segment count to include that point.
func make_ring(radius: float, arc_degrees: float = 360.0) -> Mesh:
	var ring := ImmediateMesh.new()
	var inner_edge := maxf(0.0, radius - ring_stroke)
	var half_angle := deg_to_rad(arc_degrees * 0.5)
	var segments := 2 * ceili(48.0 * arc_degrees / 360.0)
	ring.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, material)
	for index in range(segments + 1):
		var angle := lerpf(-half_angle, half_angle, float(index) / segments)
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		ring.surface_add_vertex(direction * radius)
		ring.surface_add_vertex(direction * inner_edge)
	ring.surface_end()
	return ring
