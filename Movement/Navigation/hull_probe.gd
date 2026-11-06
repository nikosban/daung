class_name HullProbe
extends RefCounted
## Occupancy tests with a ship's own collision hull at predicted planar poses (Task #46). It reads the ship's
## CollisionShape3D once (the single authoritative hull source) and only queries the physics space: overlap
## (intersect_shape) and straight sweeps (cast_motion). It never moves anything.
##
## The hull rotates about the ship root's vertical axis. reach is the farthest hull point from that axis, so a yaw
## change of dpsi moves every hull point by at most reach x |dpsi|; a translation dp moves it by |dp|. A hull grown
## by that bound in X and Z therefore contains every intermediate pose (conservative, for geometry that is static
## while the plan is made; not a proof for moving bodies).
##
## Only BoxShape3D hulls are supported (the only hull today); others log an error and fail every test.

var reach := 0.0
## Task 28 scratch (#59): the hull box's length along the bow (m), for the pursuit lookahead.
var length := 0.0
## Smallest planar half extent of the hull (m): route sampling and coarse-segment spacing.
var half_width := 0.0
## Shape queries made since the counter was last reset (evidence and cost reports).
var queries := 0

var _valid := false
var _size := Vector3.ZERO
var _offset := Transform3D.IDENTITY
var _height := 0.0
var _exclude: Array[RID] = []
var _mask := 1
var _space: PhysicsDirectSpaceState3D
var _box := BoxShape3D.new()
var _cylinder := CylinderShape3D.new()
var _query := PhysicsShapeQueryParameters3D.new()


func _init(body: CollisionObject3D, collision_shape: CollisionShape3D) -> void:
	if collision_shape == null or not collision_shape.shape is BoxShape3D:
		push_error("HullProbe needs a CollisionShape3D with a BoxShape3D; navigation will decline every plan.")
		return
	_size = (collision_shape.shape as BoxShape3D).size
	_offset = collision_shape.transform
	_height = _size.y
	var half := _size * 0.5
	var corner_x := absf(_offset.origin.x) + half.x
	var corner_z := absf(_offset.origin.z) + half.z
	reach = Vector2(corner_x, corner_z).length()
	half_width = minf(half.x, half.z)
	length = _size.z
	_exclude = [body.get_rid()]
	_mask = body.collision_mask
	_space = body.get_world_3d().direct_space_state
	_query.collision_mask = _mask
	_query.exclude = _exclude
	_query.margin = 0.0
	_valid = true


func is_valid() -> bool:
	return _valid


## Whether the hull at the planar pose, grown by grow metres in X and Z, overlaps occupied space.
func overlaps(position: Vector3, yaw: float, grow: float) -> bool:
	if not _valid:
		return true
	_box.size = Vector3(_size.x + 2.0 * grow, _size.y, _size.z + 2.0 * grow)
	_query.shape = _box
	_query.transform = _pose(position, yaw)
	_query.motion = Vector3.ZERO
	queries += 1
	return not _space.intersect_shape(_query, 1).is_empty()


## Whether a vertical cylinder of the given radius (hull height) around the root is free: the hull is then clear at
## any yaw. A cheap positive shortcut only; an occupied cylinder proves nothing.
func cylinder_clear(position: Vector3, radius: float) -> bool:
	if not _valid:
		return false
	_cylinder.radius = radius
	_cylinder.height = _height
	_query.shape = _cylinder
	_query.transform = Transform3D(Basis.IDENTITY, Vector3(position.x, position.y + _offset.origin.y, position.z))
	_query.motion = Vector3.ZERO
	queries += 1
	return _space.intersect_shape(_query, 1).is_empty()


## One predicted tick from (position, yaw) by motion and dyaw is safe when:
## 1. the exact hull at the start pose does not overlap (cast_motion ignores an initial overlap). Only needed for
##    the first pose of a prediction (check_start): every later pose lies inside the previous tick's checked sweep;
## 2. for a yaw change, the hull grown by reach x |dyaw| at the start pose does not overlap (no corner can enter);
## 3. that hull swept along the translation is free over the whole motion (cast_motion safe fraction 1).
## A touching ship may therefore translate away from the contact, but cannot rotate until it has clearance.
func step_clear(position: Vector3, yaw: float, motion: Vector3, dyaw: float, check_start: bool) -> bool:
	if check_start and overlaps(position, yaw, 0.0):
		return false
	var grow := reach * absf(dyaw)
	if grow > 0.0 and overlaps(position, yaw, grow):
		return false
	if motion.length_squared() == 0.0:
		return true
	_box.size = Vector3(_size.x + 2.0 * grow, _size.y, _size.z + 2.0 * grow)
	_query.shape = _box
	_query.transform = _pose(position, yaw)
	_query.motion = Vector3(motion.x, 0.0, motion.z)
	queries += 1
	var fractions := _space.cast_motion(_query)
	_query.motion = Vector3.ZERO
	return fractions[0] >= 1.0


func _pose(position: Vector3, yaw: float) -> Transform3D:
	var root := Transform3D(Basis(Vector3.UP, yaw), position)
	return root * _offset
