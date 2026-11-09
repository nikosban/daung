class_name GroundFeedbackRing
extends MeshInstance3D
## Keeps a fixed projected ellipse while its depth-tested quad lies on the floor.

const RING_SHADER := preload("res://game/presentation/ground_feedback_ring.gdshader")

var _quad := GroundFeedbackMesh.new()
var _material := ShaderMaterial.new()
var _extent: float
var _arc_radius: float


func configure(radius: float, stroke: float, arc_radius := 0.0, arc_degrees := 0.0) -> void:
	_extent = maxf(radius, arc_radius)
	_arc_radius = arc_radius
	mesh = _quad
	_material.shader = RING_SHADER
	_material.set_shader_parameter("ring_radius", radius)
	_material.set_shader_parameter("stroke", stroke)
	_material.set_shader_parameter("arc_radius", arc_radius)
	_material.set_shader_parameter("arc_cosine", cos(deg_to_rad(arc_degrees * 0.5)))
	material_override = _material


func draw(camera: Camera3D, screen_scale: Vector2, color: Color, toward := Vector3.ZERO) -> void:
	var aspect := GroundFeedbackMesh.floor_aspect(camera)
	if aspect <= 0.0 or camera.is_position_behind(global_position):
		hide()
		return
	var viewport_size := GroundFeedbackMesh.viewport_pixels(camera, screen_scale)
	var center := camera.unproject_position(global_position) * screen_scale
	var extent := Vector2(_extent, _extent * aspect)
	var bounds := Rect2(center - extent, extent * 2.0).intersection(Rect2(Vector2.ZERO, viewport_size))
	if not bounds.has_area():
		hide()
		return

	_material.set_shader_parameter("viewport_pixels", viewport_size)
	_material.set_shader_parameter("center", center)
	_material.set_shader_parameter("floor_aspect", aspect)
	_material.set_shader_parameter("ring_color", color)
	if _arc_radius > 0.0:
		# Project a direction at the marker so it still faces a ship behind the camera.
		var toward_point := global_position + toward.normalized()
		var facing := camera.unproject_position(toward_point) * screen_scale - center
		facing.y /= aspect
		_material.set_shader_parameter("arc_direction", Vector2.RIGHT if facing.is_zero_approx() else facing.normalized())

	visible = _quad.draw_quad(camera, screen_scale, global_position, PackedVector2Array([
		bounds.position, Vector2(bounds.end.x, bounds.position.y),
		Vector2(bounds.position.x, bounds.end.y), bounds.end,
	]))
