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
		var hit: Variant = GROUND.intersects_ray(camera.project_ray_origin(pixel), camera.project_ray_normal(pixel))
		if hit == null:
			return false
		vertices.append(Vector3(hit.x - origin.x, 0.0, hit.z - origin.z))

	clear_surfaces()
	surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for vertex in vertices:
		surface_add_vertex(vertex)
	surface_end()
	return true
