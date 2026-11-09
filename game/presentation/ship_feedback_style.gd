class_name ShipFeedbackStyle
extends Resource
## Shared appearance in output pixels. Ring sizes are measured along camera right.

@export var material: StandardMaterial3D
@export var pending_material: StandardMaterial3D
@export_range(1.0, 256.0, 0.1, "suffix:px") var selection_radius := 32.0
@export_range(1.0, 256.0, 0.1, "suffix:px") var destination_inner_radius := 30.0
@export_range(1.0, 256.0, 0.1, "suffix:px") var destination_outer_radius := 45.0
@export_range(0.1, 359.9, 0.1, "degrees") var destination_arc_degrees := 120.0
@export_range(0.1, 32.0, 0.1, "suffix:px") var ring_stroke := 4.0
@export_range(0.1, 32.0, 0.1, "suffix:px") var line_width := 3.0
@export_range(0.0, 64.0, 0.1, "suffix:px") var line_gap := 8.0


## Camera right lies in the ground plane for the shared camera rig.
static func metres_per_pixel(camera: Camera3D, point: Vector3, screen_scale: Vector2) -> float:
	if camera.is_position_behind(point):
		return 0.0
	var right := camera.get_camera_transform().basis.x
	var width := (camera.unproject_position(point + right).x - camera.unproject_position(point).x) * screen_scale.x
	return 1.0 / width if width > 0.0 else 0.0


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
