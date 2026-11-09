class_name ShipSelectionRing
extends MeshInstance3D
## A circular ground mesh with a zoom-compensated horizontal screen diameter.

const SEGMENTS := 96

var _pixel_radius: float


func configure(style: ShipFeedbackStyle) -> void:
	_pixel_radius = style.selection_radius
	var inner_radius := maxf(0.0, 1.0 - style.ring_stroke / _pixel_radius)
	var ring := ImmediateMesh.new()
	ring.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, style.material)
	for index in range(SEGMENTS + 1):
		var angle := TAU * index / SEGMENTS
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		ring.surface_add_vertex(direction)
		ring.surface_add_vertex(direction * inner_radius)
	ring.surface_end()
	mesh = ring


func draw(camera: Camera3D, screen_scale: Vector2) -> float:
	var radius := _world_radius(camera, screen_scale)
	visible = radius > 0.0
	if visible:
		scale = Vector3(radius, 1.0, radius)
	return radius


func _world_radius(camera: Camera3D, screen_scale: Vector2) -> float:
	var center := global_position
	if camera.is_position_behind(center):
		return 0.0
	var view := camera.get_camera_transform()
	var right := view.basis.x
	var pixels_per_metre := (camera.unproject_position(center + right).x - camera.unproject_position(center).x) * screen_scale.x
	if pixels_per_metre <= 0.0:
		return 0.0
	var linear_radius := _pixel_radius / pixels_per_metre
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return linear_radius

	# Fit the two screen-vertical tangent planes to the ground circle. A one-metre
	# projection through its center misses the perspective skew of its full outline.
	var offset := center - view.origin
	var depth := -offset.dot(view.basis.z)
	var lateral_ratio := offset.dot(right) / depth
	var radius_ratio := linear_radius / depth
	var depth_gradient_squared := Vector2(view.basis.z.x, view.basis.z.z).length_squared()
	var skew := depth_gradient_squared * lateral_ratio * lateral_ratio
	var depth_spread := depth_gradient_squared * radius_ratio * radius_ratio
	var base := 1.0 + skew
	var discriminant_root := sqrt(base * base + 4.0 * skew * depth_spread)
	return linear_radius * sqrt(2.0 / (base + 2.0 * depth_spread + discriminant_root))
