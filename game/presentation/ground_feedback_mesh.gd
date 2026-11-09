class_name GroundFeedbackMesh
extends ImmediateMesh
## Projects a screen-space quad onto Y = 0 so feedback uses world depth.

const GROUND := Plane(Vector3.UP, 0.0)


static func viewport_pixels(camera: Camera3D, screen_scale: Vector2) -> Vector2:
	return camera.get_viewport().get_visible_rect().size * screen_scale


static func floor_aspect(camera: Camera3D) -> float:
	# The shared rig has pitch and yaw, with no roll.
	return absf(camera.get_camera_transform().basis.z.y)


func draw_quad(camera: Camera3D, screen_scale: Vector2, origin: Vector3,
		corners: PackedVector2Array) -> bool:
	var vertices := PackedVector3Array()
	for corner in corners:
		var pixel := corner / screen_scale
		# project_position inverts unproject_position in viewport coordinates.
		# The input-ray methods apply the canvas transform as well.
		var near_point := camera.project_position(pixel, camera.near)
		var far_point := camera.project_position(pixel, camera.far)
		var hit: Variant = GROUND.intersects_ray(near_point, far_point - near_point)
		if hit == null:
			return false
		vertices.append(Vector3(hit.x - origin.x, 0.0, hit.z - origin.z))

	clear_surfaces()
	surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for vertex in vertices:
		surface_add_vertex(vertex)
	surface_end()
	return true
