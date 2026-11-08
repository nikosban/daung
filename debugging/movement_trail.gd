class_name MovementTrail
extends MeshInstance3D
## Temporary F3 world-space trail of one ship's actual travelled path: a line through its recorded authoritative
## positions, sampled after the ship's physics move each tick. Never draws to a destination or predicts a route.
## Reads Movement only; Movement never calls it. Hidden and inactive until the overlay's F3 turns it on.

## Display height of the line above the sampled XZ (rendering detail, not motion data).
const DISPLAY_HEIGHT := 0.05

@export var ship: ShipMovement
@export var settings: MovementTrailSettings

var _points := PackedVector3Array()
var _immediate := ImmediateMesh.new()
var _material := StandardMaterial3D.new()


func _ready() -> void:
	# Vertices are sampled in world space, independently of the suite host transform.
	top_level = true
	global_transform = Transform3D.IDENTITY
	# Runs after the ship's _physics_process (priority 0), so each sample is the position after this tick's move.
	process_physics_priority = 1
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = Color(0.2, 0.9, 1.0)
	mesh = _immediate
	set_active(false)


## On: clears any old trail and seeds it at the ship's current position. Off: clears and hides it, stops sampling.
func set_active(on: bool) -> void:
	_points.clear()
	_immediate.clear_surfaces()
	if on:
		_points.append(_flat(ship.global_position))
	visible = on
	set_physics_process(on)


func _physics_process(_delta: float) -> void:
	var position_now := _flat(ship.global_position)
	if _points.size() > 0 and position_now.distance_to(_points[_points.size() - 1]) < settings.min_sample_distance:
		return
	_points.append(position_now)
	while _points.size() > settings.max_trail_points:
		_points.remove_at(0)
	_rebuild()


func _rebuild() -> void:
	_immediate.clear_surfaces()
	if _points.size() < 2:
		return
	_immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, _material)
	for point in _points:
		_immediate.surface_add_vertex(point)
	_immediate.surface_end()


func _flat(world_position: Vector3) -> Vector3:
	return Vector3(world_position.x, DISPLAY_HEIGHT, world_position.z)
