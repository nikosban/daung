class_name EndpointReservations
extends RefCounted
## Endpoint reservations (Task 37, #78), shared by every ship on one navigation map, like Navigator. Each ship's area
## is a disk of its reservation radius (hull reach + plan_clearance_buffer + arrival allowance). A ship with an
## accepted order reserves its endpoint (Navigator.Job.advance); arrival keeps it. Activation (move or stop), removal,
## static contact and terminal blockage release it. A ship without a reservation that has no order, or whose order is
## blocked, occupies its live position. A ship whose order is still planning occupies nothing.

## Registered ships and their navigation map (ShipMovement -> RID).
static var _ships := {}
## Reserved endpoints (ShipMovement -> Vector3).
static var _reserved := {}


static func register(ship: ShipMovement) -> void:
	_ships[ship] = ship.get_world_3d().navigation_map


static func unregister(ship: ShipMovement) -> void:
	_ships.erase(ship)
	_reserved.erase(ship)


static func reserve(ship: ShipMovement, point: Vector3) -> void:
	if _ships.has(ship):
		_reserved[ship] = point


static func release(ship: ShipMovement) -> void:
	_reserved.erase(ship)


## Why this ship may not end at point, or "" when it may. inside_only tests only whether point lies inside another
## ship's area; otherwise the two areas must not overlap (distance below the sum of both radii).
static func conflict(ship: ShipMovement, point: Vector3, inside_only: bool) -> String:
	var map: RID = _ships.get(ship, RID())
	for other: ShipMovement in _ships:
		if other == ship or _ships[other] != map or not is_instance_valid(other):
			continue
		var at: Vector3
		var reason := "reserved by %s"
		if _reserved.has(other):
			at = _reserved[other]
		elif not other.has_order() or other.is_blocked():
			at = other.global_position
			reason = "occupied by %s"
		else:
			continue
		var limit := other.get_reservation_radius()
		if not inside_only:
			limit += ship.get_reservation_radius()
		# Areas that only touch (Fleet spaces preferred points exactly two radii apart) do not overlap.
		if Vector2(point.x - at.x, point.z - at.z).length() < limit - RoutePlanner.DUPLICATE_DISTANCE:
			return reason % other.name
	return ""
