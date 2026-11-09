class_name ShipMoveFeedback
extends Node3D
## Draws a straight connector and the destination glyph relative to the ship's display origin.

const GROUND := Plane(Vector3.UP, 0.0)

@onready var _connector: MeshInstance3D = $Connector
@onready var _destination: Node3D = $Destination
@onready var _inner_ring: MeshInstance3D = $Destination/InnerRing
@onready var _outer_arc: MeshInstance3D = $Destination/OuterArc

var _style: ShipFeedbackStyle
var _ribbon := ImmediateMesh.new()


func configure(style: ShipFeedbackStyle) -> void:
	_style = style
	_connector.mesh = _ribbon
	_connector.material_override = style.material
	_inner_ring.mesh = style.make_ring(style.destination_inner_radius)
	_outer_arc.mesh = style.make_ring(style.destination_outer_radius, style.destination_arc_degrees)


func show_destination(camera: Camera3D, screen_scale: Vector2, offset: Vector3, ship_metres_per_pixel: float,
		pending: bool) -> void:
	var material := _style.pending_material if pending else _style.material
	if _connector.material_override != material:
		_connector.material_override = material
		_inner_ring.material_override = material
		_outer_arc.material_override = material

	_destination.position = offset
	var direction := offset.normalized()
	_destination.rotation.y = atan2(direction.z, -direction.x)
	var destination_metres_per_pixel := ShipFeedbackStyle.metres_per_pixel(camera, global_position + offset, screen_scale)
	_destination.visible = destination_metres_per_pixel > 0.0
	if _destination.visible:
		_destination.scale = Vector3(destination_metres_per_pixel, 1.0, destination_metres_per_pixel)

	_connector.visible = _draw_connector(camera, screen_scale, offset, _style.selection_radius * ship_metres_per_pixel,
		_style.destination_outer_radius * destination_metres_per_pixel)
	show()


func _draw_connector(camera: Camera3D, screen_scale: Vector2, offset: Vector3, ship_radius: float,
		destination_radius: float) -> bool:
	if offset.length() <= ship_radius + destination_radius:
		return false

	# Trim in world space to the rings, then clip to the camera depth before projecting.
	var direction := offset.normalized()
	var start := global_position + direction * ship_radius
	var end := global_position + offset - direction * destination_radius
	var camera_transform := camera.get_camera_transform()
	var start_depth := camera_transform.basis.z.dot(camera_transform.origin - start)
	var end_depth := camera_transform.basis.z.dot(camera_transform.origin - end)
	var depth_span := _clip_axis(Vector2(0.0, 1.0), start_depth, end_depth, camera.near, camera.far)
	if depth_span.x >= depth_span.y:
		return false

	var a := camera.unproject_position(start.lerp(end, depth_span.x)) * screen_scale
	var b := camera.unproject_position(start.lerp(end, depth_span.y)) * screen_scale
	var along := (b - a).normalized()
	var start_gap := _style.line_gap if depth_span.x == 0.0 else 0.0
	var end_gap := _style.line_gap if depth_span.y == 1.0 else 0.0
	if a.distance_to(b) <= start_gap + end_gap:
		return false
	a += along * start_gap
	b -= along * end_gap

	# Clip the centerline before casting the ribbon corners back onto the ground.
	var half_width := _style.line_width * 0.5
	var view := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size * screen_scale).grow(half_width)
	var screen_span := _clip_axis(Vector2(0.0, 1.0), a.x, b.x, view.position.x, view.end.x)
	screen_span = _clip_axis(screen_span, a.y, b.y, view.position.y, view.end.y)
	if screen_span.x >= screen_span.y:
		return false

	var from := a.lerp(b, screen_span.x)
	var to := a.lerp(b, screen_span.y)
	var normal := along.orthogonal() * half_width
	var vertices := PackedVector3Array()
	for corner: Vector2 in [from + normal, from - normal, to + normal, to - normal]:
		var point := corner / screen_scale
		var hit: Variant = GROUND.intersects_ray(camera.project_ray_origin(point), camera.project_ray_normal(point))
		if hit == null:
			return false
		vertices.append(Vector3(hit.x - global_position.x, 0.0, hit.z - global_position.z))

	_ribbon.clear_surfaces()
	_ribbon.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for vertex in vertices:
		_ribbon.surface_add_vertex(vertex)
	_ribbon.surface_end()
	return true


## Intersect a segment's parameter interval with the slab for one coordinate.
static func _clip_axis(span: Vector2, from: float, to: float, lower: float, upper: float) -> Vector2:
	var delta := to - from
	if delta == 0.0:
		return span if from >= lower and from <= upper else Vector2(1.0, 0.0)
	var enter := (lower - from) / delta
	var leave := (upper - from) / delta
	return Vector2(maxf(span.x, minf(enter, leave)), minf(span.y, maxf(enter, leave)))
