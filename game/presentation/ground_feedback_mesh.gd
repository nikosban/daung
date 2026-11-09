class_name GroundFeedbackMesh
## Builds flat feedback geometry on the local X/Z plane in world metres.

const SEGMENTS_PER_TURN := 96


## Appends a band whose outer edge lies at the radius and whose stroke extends inward.
## A partial arc is centred on local -Z.
static func add_band(mesh: ImmediateMesh, radius: float, stroke: float, arc_degrees := 360.0) -> void:
	var inner := maxf(0.0, radius - stroke)
	var span := deg_to_rad(arc_degrees)
	var segments := maxi(1, ceili(SEGMENTS_PER_TURN * arc_degrees / 360.0))
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for index in range(segments + 1):
		var angle := span * (float(index) / segments - 0.5)
		var direction := Vector3(sin(angle), 0.0, -cos(angle))
		mesh.surface_add_vertex(direction * radius)
		mesh.surface_add_vertex(direction * inner)
	mesh.surface_end()
