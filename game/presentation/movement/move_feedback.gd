class_name ShipMoveFeedback
extends Node3D
## Draws a straight connector and the destination glyph relative to the ship's display origin.

@onready var _connector: MeshInstance3D = $Connector
@onready var _destination: GroundFeedbackRing = $Destination

var _style: ShipFeedbackStyle
var _ribbon := GroundFeedbackMesh.new()


func configure(style: ShipFeedbackStyle) -> void:
	_style = style
	_connector.mesh = _ribbon
	_destination.configure(style.destination_inner_radius, style.ring_stroke,
		style.destination_outer_radius, style.destination_arc_degrees)


func show_destination(camera: Camera3D, screen_scale: Vector2, offset: Vector3, selection_radius: float,
		pending: bool) -> void:
	var material := _style.pending_material if pending else _style.material
	if _connector.material_override != material:
		_connector.material_override = material

	_destination.position = offset
	_destination.draw(camera, screen_scale, material.albedo_color, -offset)
	_connector.visible = _draw_connector(camera, screen_scale, offset, selection_radius)
	show()


func _draw_connector(camera: Camera3D, screen_scale: Vector2, offset: Vector3, selection_radius: float) -> bool:
	var aspect := GroundFeedbackMesh.floor_aspect(camera)
	if aspect <= 0.0 or offset.length() <= selection_radius:
		return false

	# Start at the actual circle edge, then trim the destination and gaps in pixels.
	var start := global_position + offset.normalized() * selection_radius
	var end := global_position + offset
	var camera_transform := camera.get_camera_transform()
	var start_depth := camera_transform.basis.z.dot(camera_transform.origin - start)
	var end_depth := camera_transform.basis.z.dot(camera_transform.origin - end)
	var depth_span := _clip_axis(Vector2(0.0, 1.0), start_depth, end_depth, camera.near, camera.far)
	if depth_span.x >= depth_span.y:
		return false

	var a := camera.unproject_position(start.lerp(end, depth_span.x)) * screen_scale
	var b := camera.unproject_position(start.lerp(end, depth_span.y)) * screen_scale
	var span := b - a
	var distance := span.length()
	if is_zero_approx(distance):
		return false
	var along := span / distance
	var ellipse_scale := Vector2(along.x, along.y / aspect).length()
	var start_trim := _style.line_gap if depth_span.x == 0.0 and selection_radius > 0.0 else 0.0
	var end_trim := _style.destination_outer_radius / ellipse_scale + _style.line_gap if depth_span.y == 1.0 else 0.0
	if distance <= start_trim + end_trim:
		return false
	a += along * start_trim
	b -= along * end_trim

	# Clip the centerline before casting the ribbon corners back onto the ground.
	var half_width := _style.line_width * 0.5
	var view := Rect2(Vector2.ZERO, GroundFeedbackMesh.viewport_pixels(camera, screen_scale)).grow(half_width)
	var screen_span := _clip_axis(Vector2(0.0, 1.0), a.x, b.x, view.position.x, view.end.x)
	screen_span = _clip_axis(screen_span, a.y, b.y, view.position.y, view.end.y)
	if screen_span.x >= screen_span.y:
		return false

	var from := a.lerp(b, screen_span.x)
	var to := a.lerp(b, screen_span.y)
	var normal := along.orthogonal() * half_width
	return _ribbon.draw_quad(camera, screen_scale, global_position,
		PackedVector2Array([from + normal, from - normal, to + normal, to - normal]))


## Intersect a segment's parameter interval with the slab for one coordinate.
static func _clip_axis(span: Vector2, from: float, to: float, lower: float, upper: float) -> Vector2:
	var delta := to - from
	if delta == 0.0:
		return span if from >= lower and from <= upper else Vector2(1.0, 0.0)
	var enter := (lower - from) / delta
	var leave := (upper - from) / delta
	return Vector2(maxf(span.x, minf(enter, leave)), minf(span.y, maxf(enter, leave)))
