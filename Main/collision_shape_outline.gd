class_name CollisionShapeOutline
extends MeshInstance3D
## Temporary F3 outline of the physics shape of its parent CollisionShape3D (Task #44): thin unshaded red lines,
## drawn over the models (no depth test). As a child of the collision shape it inherits its exact (interpolated)
## transform, offset included. Box: its 12 edges; sphere: three great circles. Built once from the shape's
## dimensions and rebuilt only when the shape changes. Read-only debug glue: no collision, starts hidden; the
## F3 overlay sets its visibility.

## Segments per sphere circle (rendering detail, not physics data).
const CIRCLE_SEGMENTS := 64

var _immediate := ImmediateMesh.new()
var _material := StandardMaterial3D.new()
var _shape: Shape3D


func _ready() -> void:
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.no_depth_test = true
	_material.albedo_color = Color(1.0, 0.1, 0.1)
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh = _immediate
	visible = false
	var collision_shape := get_parent() as CollisionShape3D
	if collision_shape == null or collision_shape.shape == null:
		push_warning("CollisionShapeOutline needs a CollisionShape3D parent with a shape; nothing is drawn.")
		return
	_shape = collision_shape.shape
	_shape.changed.connect(_rebuild)
	_rebuild()


func _rebuild() -> void:
	_immediate.clear_surfaces()
	var lines := PackedVector3Array()
	if _shape is BoxShape3D:
		var h: Vector3 = (_shape as BoxShape3D).size * 0.5
		for a in [-1.0, 1.0]:
			for b in [-1.0, 1.0]:
				lines.append_array([Vector3(-h.x, a * h.y, b * h.z), Vector3(h.x, a * h.y, b * h.z)])
				lines.append_array([Vector3(a * h.x, -h.y, b * h.z), Vector3(a * h.x, h.y, b * h.z)])
				lines.append_array([Vector3(a * h.x, b * h.y, -h.z), Vector3(a * h.x, b * h.y, h.z)])
	elif _shape is SphereShape3D:
		var r := (_shape as SphereShape3D).radius
		for i in CIRCLE_SEGMENTS:
			var a0 := TAU * i / CIRCLE_SEGMENTS
			var a1 := TAU * (i + 1) / CIRCLE_SEGMENTS
			var p0 := Vector2(cos(a0), sin(a0)) * r
			var p1 := Vector2(cos(a1), sin(a1)) * r
			lines.append_array([Vector3(p0.x, 0.0, p0.y), Vector3(p1.x, 0.0, p1.y)])
			lines.append_array([Vector3(p0.x, p0.y, 0.0), Vector3(p1.x, p1.y, 0.0)])
			lines.append_array([Vector3(0.0, p0.x, p0.y), Vector3(0.0, p1.x, p1.y)])
	else:
		push_warning("CollisionShapeOutline draws only BoxShape3D and SphereShape3D; nothing is drawn for %s." % _shape.get_class())
		return
	_immediate.surface_begin(Mesh.PRIMITIVE_LINES, _material)
	for point in lines:
		_immediate.surface_add_vertex(point)
	_immediate.surface_end()
