class_name Traffic
extends RefCounted
## Ship traffic (Task 38, #79), internal to Movement and shared by every ship on a navigation map, like Navigator.
## Once per physics frame, after Navigator.service() and before any ship moves, update() takes a snapshot of every
## registered ship and decides who gives way. Every ship then reads the same decision (decision_of()) in its own tick;
## ShipMovement stays the only writer of motion.
##
## - Path ahead: the remaining route polyline, or the straight line to the destination, cut at stopping distance
##   (v² / 2 HullProbe.minimum_braking) + detour_lookahead_distance. Each ship sweeps a capsule of radius
##   reach + plan_clearance_buffer along it; two capsules that overlap share space. The path distance at which a ship's
##   centre first enters the other's capsule is its s; a ship with s at 0 or below its stopping distance is committed.
## - Priority: committed first, then rated forward acceleration (cached at registration), then traffic slot.
## - A grant (winner, loser) holds until the winner's centre passes the far end of the shared space (and the capsules no
##   longer overlap), or either ship's order changes. The loser holds at s - (reach + buffer) on its own path, course
##   unchanged. The winner keeps its priority but brakes while another ship physically obstructs its passage.
## - Making room: a loser that sits in the winner's path tries, once each, a point back along its approach and the
##   shorter side point perpendicular to the winner's path (offset reach + reach + buffer, ties to the right).
## - Parked blocker: a ship without an order (or blocked) is an obstacle. A moving ship whose path ahead meets it steers
##   to a guide beside it (shorter side first), then back onto its path beyond it; exhaustion blocks the order.
## - Deadlock: when no ship of a conflict group improves its remaining path by arrival_tolerance within
##   departure_max_time, its lowest-ranked ship makes room once; if that is exhausted, F3 reports it. No wait cap.
## Recovery attempts give up below arrival_tolerance progress within departure_max_time.

const OPEN := "open"

static var _ships: Array[ShipMovement] = []
static var _rated := {}
static var _frame := -1
static var _clock := 0.0
## Wall-clock cost of the latest pass (µs), for cost reports; it is also charged to Navigator's shared allowance.
static var _last_usec := 0
static var _grants: Array[Grant] = []
static var _decisions := {}
static var _rooms := {}
static var _escapes := {}
## Ships whose deadlock recovery is exhausted (F3 report until their grant ends).
static var _deadlocked := {}
static var _progress := {}


## What one ship does this tick.
class Decision:
	var status := OPEN
	## Hold point on the ship's own path (yielding); the steering distance is cut to it.
	var hold := false
	var hold_point := Vector3.ZERO
	## Path distance from the ship to its hold point (m).
	var hold_distance := 0.0
	## A recovery guide (making room or going around a parked ship), steered through Navigator.reposition().
	var guided := false
	var guide := Vector3.ZERO
	## Parked-blocker recovery is exhausted: the ship abandons its order.
	var blocked := false
	## A ship that this one has right of way over (null when none): the winner keeps its priority but still brakes
	## when another ship physically obstructs its passage.
	var right_of_way_over: ShipMovement


class Grant:
	var winner: ShipMovement
	var loser: ShipMovement
	var winner_serial := 0
	var loser_serial := 0
	## The far end of the shared space on the winner's path, and the winner's path direction there.
	var far_point := Vector3.ZERO
	var far_direction := Vector3.ZERO
	## The loser's hold point on its own path.
	var hold_point := Vector3.ZERO


## A bounded recovery: options tried once each, every option a sequence of guides.
class Recovery:
	var other: ShipMovement
	var options: Array[PackedVector3Array] = []
	var option := 0
	var stage := 0
	var best := INF
	var waited := 0.0
	var finished := false
	var exhausted := false
	var serial := 0

	func guide() -> Vector3:
		return options[option][stage]


class Snap:
	var ship: ShipMovement
	var position := Vector3.ZERO
	var radius := 0.0
	var reach := 0.0
	var stopping := 0.0
	var active := false
	var serial := 0
	var map: RID
	## Remaining path from the ship (full) and the part ahead within the traffic horizon.
	var full: PackedVector3Array
	var ahead: PackedVector3Array
	var ahead_lengths: PackedFloat32Array


static func register(ship: ShipMovement) -> void:
	if not _ships.has(ship):
		_ships.push_back(ship)
	var profile := ship.profile
	_rated[ship] = profile.main_acceleration + profile.forward_directional_acceleration * profile.directional_thrust_curve.sample(0.0)


static func unregister(ship: ShipMovement) -> void:
	_ships.erase(ship)
	_rated.erase(ship)
	_decisions.erase(ship)
	_rooms.erase(ship)
	_escapes.erase(ship)
	_deadlocked.erase(ship)
	_progress.erase(ship)
	for i in range(_grants.size() - 1, -1, -1):
		if _grants[i].winner == ship or _grants[i].loser == ship:
			_grants.remove_at(i)


## Cost of the latest traffic pass in µs (cost reports only).
static func get_last_usec() -> int:
	return _last_usec


## This tick's decision for the ship (open when it has none).
static func decision_of(ship: ShipMovement) -> Decision:
	return _decisions.get(ship, Decision.new())


## Runs once per physics frame; later calls in the same frame do nothing.
static func update(delta: float) -> void:
	if _frame == Engine.get_physics_frames():
		return
	_frame = Engine.get_physics_frames()
	var start := Navigator.measure()
	_clock += delta
	_decisions.clear()
	var snaps: Array[Snap] = []
	var by_ship := {}
	for ship in _ships:
		if is_instance_valid(ship) and ship.is_inside_tree():
			var snap := _snap(ship)
			snaps.push_back(snap)
			by_ship[ship] = snap
	_update_grants(snaps, by_ship)
	for snap in snaps:
		if snap.active:
			_decide(snap, snaps, by_ship, delta)
	_deadlocks(by_ship, delta)
	_last_usec = Time.get_ticks_usec() - start
	Navigator.account(start)


static func _snap(ship: ShipMovement) -> Snap:
	var snap := Snap.new()
	snap.ship = ship
	snap.position = RouteGuidance.planar(ship.global_position)
	snap.reach = ship.get_hull_reach()
	snap.radius = snap.reach + ship.profile.plan_clearance_buffer
	var speed := RouteGuidance.planar(ship.velocity).length()
	var braking := HullProbe.minimum_braking(ship.profile)
	snap.stopping = speed * speed / (2.0 * braking) if braking > 0.0 else INF
	snap.active = ship.has_order() and not ship.is_blocked()
	snap.serial = ship.get_traffic_serial()
	snap.map = ship.get_world_3d().navigation_map
	snap.full = ship.get_remaining_path()
	snap.ahead = _cut(snap.full, snap.stopping + ship.profile.detour_lookahead_distance)
	snap.ahead_lengths = _lengths(snap.ahead)
	return snap


## Releases finished grants, refreshes held ones and creates grants for new conflicts.
static func _update_grants(snaps: Array[Snap], by_ship: Dictionary) -> void:
	for i in range(_grants.size() - 1, -1, -1):
		var grant := _grants[i]
		var winner: Snap = by_ship.get(grant.winner)
		var loser: Snap = by_ship.get(grant.loser)
		var release := winner == null or loser == null or not winner.active or not loser.active \
			or winner.serial != grant.winner_serial or loser.serial != grant.loser_serial
		if not release:
			var overlap := _overlap(winner.ahead, winner.ahead_lengths, loser.ahead, loser.ahead_lengths, winner.radius + loser.radius)
			if overlap.is_empty():
				# A held loser's horizon is short; release only when the winner also clears one more loser radius
				# beyond it, so the loser does not resume and stop again on every other tick.
				var reach := _cut(loser.full, loser.ahead_lengths[loser.ahead_lengths.size() - 1] + loser.radius)
				if not _overlap(winner.ahead, winner.ahead_lengths, reach, _lengths(reach), winner.radius + loser.radius).is_empty():
					continue
				release = (winner.position - grant.far_point).dot(grant.far_direction) > 0.0
			else:
				_refresh_grant(grant, winner, loser, overlap)
		if release:
			_grants.remove_at(i)
			_end_room(grant.loser, grant.winner)
	for a in snaps.size():
		for b in range(a + 1, snaps.size()):
			var first := snaps[a]
			var second := snaps[b]
			if not first.active or not second.active or first.map != second.map or _granted(first.ship, second.ship):
				continue
			var overlap := _overlap(first.ahead, first.ahead_lengths, second.ahead, second.ahead_lengths, first.radius + second.radius)
			if overlap.is_empty():
				continue
			var first_wins := _outranks(first, overlap.a_in, second, overlap.b_in)
			var grant := Grant.new()
			grant.winner = first.ship if first_wins else second.ship
			grant.loser = second.ship if first_wins else first.ship
			grant.winner_serial = (first if first_wins else second).serial
			grant.loser_serial = (second if first_wins else first).serial
			var swapped := overlap if first_wins else {a_in = overlap.b_in, a_out = overlap.b_out, b_in = overlap.a_in, b_out = overlap.a_out}
			_refresh_grant(grant, by_ship[grant.winner], by_ship[grant.loser], swapped)
			_grants.push_back(grant)


## Moves the grant's far end (winner) and hold point (loser) to the current shared space.
static func _refresh_grant(grant: Grant, winner: Snap, loser: Snap, overlap: Dictionary) -> void:
	var far: float = overlap.a_out
	grant.far_point = _point_at(winner.ahead, winner.ahead_lengths, far)
	grant.far_direction = _direction_at(winner.ahead, winner.ahead_lengths, far)
	grant.hold_point = _point_at(loser.ahead, loser.ahead_lengths, maxf(float(overlap.b_in) - loser.radius, 0.0))


static func _granted(a: ShipMovement, b: ShipMovement) -> bool:
	for grant in _grants:
		if (grant.winner == a and grant.loser == b) or (grant.winner == b and grant.loser == a):
			return true
	return false


## Committed first, then rated forward acceleration, then traffic slot (roster order).
static func _outranks(a: Snap, s_a: float, b: Snap, s_b: float) -> bool:
	var committed_a := s_a <= 0.0 or s_a < a.stopping
	var committed_b := s_b <= 0.0 or s_b < b.stopping
	if committed_a != committed_b:
		return committed_a
	var rated_a: float = _rated.get(a.ship, 0.0)
	var rated_b: float = _rated.get(b.ship, 0.0)
	if not is_equal_approx(rated_a, rated_b):
		return rated_a > rated_b
	var slot_a := a.ship.get_traffic_slot()
	var slot_b := b.ship.get_traffic_slot()
	if slot_a != slot_b:
		return slot_b < 0 or (slot_a >= 0 and slot_a < slot_b)
	return a.ship.get_instance_id() < b.ship.get_instance_id()


static func _decide(snap: Snap, snaps: Array[Snap], by_ship: Dictionary, delta: float) -> void:
	var decision := Decision.new()
	_decisions[snap.ship] = decision
	for grant in _grants:
		if grant.winner == snap.ship:
			decision.right_of_way_over = grant.loser
			break
	# Parked blockers ahead: the nearest one along the path.
	var blocker: Snap = null
	var blocker_s := INF
	for other in snaps:
		if other == snap or other.active or other.map != snap.map:
			continue
		var hit := _nearest(snap.ahead, snap.ahead_lengths, other.position)
		if hit.distance < snap.radius + other.radius and hit.s > 0.0 and hit.s < blocker_s:
			blocker = other
			blocker_s = hit.s
	# The encounter lasts while the same parked ship stays ahead on the whole remaining path, so a ship that slows (and
	# so shortens its horizon) does not restart its attempts.
	var escape: Recovery = _escapes.get(snap.ship)
	if escape != null and (escape.serial != snap.serial or not _still_ahead(snap, by_ship.get(escape.other))):
		_escapes.erase(snap.ship)
		escape = null
	if escape != null and blocker != null and blocker.ship != escape.other:
		_escapes.erase(snap.ship)
		escape = null
	if blocker != null and escape == null:
		escape = _escape(snap, blocker, blocker_s)
		_escapes[snap.ship] = escape
	if escape != null:
		_advance(escape, snap, delta)
		if escape.exhausted:
			decision.blocked = true
			decision.status = "blocked by parked ship %s" % escape.other.name
			return
		if not escape.finished:
			decision.guided = true
			decision.guide = escape.guide()
			decision.status = "going around parked ship %s" % escape.other.name
			return
	# Yielding: the nearest hold point among this ship's grants.
	var winner: ShipMovement = null
	var hold_s := INF
	for grant in _grants:
		if grant.loser != snap.ship:
			continue
		var hold := _nearest(snap.full, _lengths(snap.full), grant.hold_point)
		if winner == null or hold.s < hold_s:
			winner = grant.winner
			hold_s = hold.s
			decision.hold_point = grant.hold_point
			decision.hold_distance = hold.s
	if winner == null:
		return
	decision.hold = true
	decision.status = "yielding to %s" % winner.name
	var winner_snap: Snap = by_ship[winner]
	var room: Recovery = _rooms.get(snap.ship)
	if room != null and (room.other != winner or room.serial != snap.serial):
		_rooms.erase(snap.ship)
		room = null
	if room == null and _in_path(snap, winner_snap):
		room = _room(snap, winner_snap)
		_rooms[snap.ship] = room
	if room == null:
		return
	if not room.finished and not room.exhausted:
		_advance(room, snap, delta)
		# Reaching a guide while still in the winner's path counts as that option failing.
		if room.finished and _in_path(snap, winner_snap):
			room.finished = false
			_next_option(room)
		if not room.finished and not room.exhausted:
			decision.guided = true
			decision.guide = room.guide()
			decision.status = "making room for %s" % winner.name
			return
	if room.exhausted and _deadlocked.has(snap.ship):
		decision.status = "traffic deadlock: recovery exhausted"


## Whether a parked ship is still ahead on the ship's whole remaining path, within both radii.
static func _still_ahead(snap: Snap, parked: Snap) -> bool:
	if parked == null or parked.active:
		return false
	var hit := _nearest(snap.full, _lengths(snap.full), parked.position)
	return hit.s > 0.0 and hit.distance < snap.radius + parked.radius


## Whether the loser's centre sits within the winner's swept capsule ahead of the winner.
static func _in_path(loser: Snap, winner: Snap) -> bool:
	var hit := _nearest(winner.ahead, winner.ahead_lengths, loser.position)
	return hit.s > 0.0 and hit.distance < winner.radius + loser.radius


## Making room: back along the approach, then the shorter side of the winner's path.
static func _room(loser: Snap, winner: Snap) -> Recovery:
	var recovery := Recovery.new()
	recovery.other = winner.ship
	recovery.serial = loser.serial
	var offset := loser.reach + winner.reach + loser.ship.profile.plan_clearance_buffer
	var approach := _direction_at(loser.full, _lengths(loser.full), 0.0)
	if approach == Vector3.ZERO:
		approach = ShipPilot.bow_of(loser.ship.rotation.y)
	recovery.options.push_back(PackedVector3Array([loser.position - approach * offset]))
	var hit := _nearest(winner.ahead, winner.ahead_lengths, loser.position)
	var along := _direction_at(winner.ahead, winner.ahead_lengths, hit.s)
	if along == Vector3.ZERO:
		along = ShipPilot.bow_of(winner.ship.rotation.y)
	var right := along.cross(Vector3.UP).normalized()
	var side := -1.0 if (loser.position - hit.point).dot(right) < 0.0 else 1.0
	recovery.options.push_back(PackedVector3Array([hit.point + right * side * offset]))
	return recovery


## Going around a parked ship: beside it (shorter side first), then back on the path beyond it.
static func _escape(snap: Snap, blocker: Snap, blocker_s: float) -> Recovery:
	var recovery := Recovery.new()
	recovery.other = blocker.ship
	recovery.serial = snap.serial
	var lengths := _lengths(snap.full)
	var along := _direction_at(snap.full, lengths, blocker_s)
	var right := along.cross(Vector3.UP).normalized()
	var projection := _point_at(snap.full, lengths, blocker_s)
	var offset := snap.radius + blocker.radius + snap.ship.profile.arrival_tolerance
	var side := 1.0 if (blocker.position - projection).dot(right) < 0.0 else -1.0
	var beyond := _point_at(snap.full, lengths, minf(blocker_s + snap.radius + blocker.radius, lengths[lengths.size() - 1]))
	for sign in [side, -side]:
		recovery.options.push_back(PackedVector3Array([blocker.position + right * sign * offset, beyond]))
	return recovery


## Advances a recovery: a guide counts as reached within arrival_tolerance; an option is abandoned when the distance
## to its guide has not improved by arrival_tolerance within departure_max_time.
static func _advance(recovery: Recovery, snap: Snap, delta: float) -> void:
	if recovery.finished or recovery.exhausted:
		return
	var profile := snap.ship.profile
	var distance := RouteGuidance.planar(recovery.guide() - snap.position).length()
	if distance <= profile.arrival_tolerance:
		recovery.stage += 1
		recovery.best = INF
		recovery.waited = 0.0
		if recovery.stage >= recovery.options[recovery.option].size():
			recovery.finished = true
		return
	if distance < recovery.best - profile.arrival_tolerance:
		recovery.best = distance
		recovery.waited = 0.0
		return
	recovery.waited += delta
	if recovery.waited > profile.departure_max_time:
		_next_option(recovery)


static func _next_option(recovery: Recovery) -> void:
	recovery.option += 1
	recovery.stage = 0
	recovery.best = INF
	recovery.waited = 0.0
	if recovery.option >= recovery.options.size():
		recovery.option = recovery.options.size() - 1
		recovery.exhausted = true


static func _end_room(ship: ShipMovement, winner: ShipMovement) -> void:
	var room: Recovery = _rooms.get(ship)
	if room != null and room.other == winner:
		_rooms.erase(ship)
	_deadlocked.erase(ship)


## Deadlock rule: per conflict group (ships joined by grants), the best remaining path distance of each ship. When none
## improves by arrival_tolerance within departure_max_time, the lowest-ranked ship makes room once. A ship's wait counts
## only within its current grants: gaining or losing one restarts it, so waiting behind a ship that was moving (a grant
## that has just ended) is not mistaken for a deadlock of the group that remains.
static func _deadlocks(by_ship: Dictionary, delta: float) -> void:
	for ship: ShipMovement in by_ship:
		var snap: Snap = by_ship[ship]
		var remaining := _lengths(snap.full)[snap.full.size() - 1]
		var grants := _grants_of(ship)
		var entry: Dictionary = _progress.get(ship, {})
		if entry.is_empty() or entry.serial != snap.serial or entry.grants != grants or remaining < entry.best - ship.profile.arrival_tolerance:
			_progress[ship] = {serial = snap.serial, grants = grants, best = remaining, stalled = 0.0}
		else:
			entry.stalled += delta
	var seen := {}
	for grant in _grants:
		if seen.has(grant.loser):
			continue
		var group := _group(grant.loser)
		for member in group:
			seen[member] = true
		var stalled := true
		for member in group:
			if _progress.get(member, {}).get("stalled", 0.0) <= member.profile.departure_max_time:
				stalled = false
				break
		if not stalled:
			continue
		# Lowest-ranked: a loser that wins no grant in the group, last in roster order.
		var lowest: ShipMovement = null
		for member in group:
			var wins := false
			for other in _grants:
				if other.winner == member:
					wins = true
			if not wins and (lowest == null or member.get_traffic_slot() > lowest.get_traffic_slot()):
				lowest = member
		if lowest == null:
			continue
		for member in group:
			_progress[member].stalled = 0.0
		var winner_ship: ShipMovement = null
		for other in _grants:
			if other.loser == lowest:
				winner_ship = other.winner
		if winner_ship == null or not by_ship.has(winner_ship):
			continue
		var room: Recovery = _rooms.get(lowest)
		if room == null or room.other != winner_ship:
			_rooms[lowest] = _room(by_ship[lowest], by_ship[winner_ship])
		elif room.exhausted:
			# Its making-room options were already tried in this encounter: report it.
			_deadlocked[lowest] = true
			if _decisions.has(lowest):
				_decisions[lowest].status = "traffic deadlock: recovery exhausted"


## The grants a ship takes part in, as the instance IDs of its winners and losers (a comparable value).
static func _grants_of(ship: ShipMovement) -> Array[int]:
	var ids: Array[int] = []
	for grant in _grants:
		if grant.winner == ship:
			ids.push_back(grant.loser.get_instance_id())
		elif grant.loser == ship:
			ids.push_back(-grant.winner.get_instance_id())
	return ids


static func _group(start: ShipMovement) -> Array[ShipMovement]:
	var group: Array[ShipMovement] = [start]
	var i := 0
	while i < group.size():
		for grant in _grants:
			for pair in [[grant.winner, grant.loser], [grant.loser, grant.winner]]:
				if pair[0] == group[i] and not group.has(pair[1]):
					group.push_back(pair[1])
		i += 1
	return group


# --- Path geometry (planar) ------------------------------------------------------------------------------------------

## Path distances where each path's centre line enters and leaves the other's capsule (radius = the sum of both
## radii), or an empty Dictionary when the capsules do not overlap: {a_in, a_out, b_in, b_out}.
static func _overlap(a: PackedVector3Array, a_lengths: PackedFloat32Array, b: PackedVector3Array, b_lengths: PackedFloat32Array, radius: float) -> Dictionary:
	var a_range := _entry(a, a_lengths, b, radius)
	if a_range.x > a_range.y:
		return {}
	var b_range := _entry(b, b_lengths, a, radius)
	if b_range.x > b_range.y:
		return {}
	return {a_in = a_range.x, a_out = a_range.y, b_in = b_range.x, b_out = b_range.y}


static func _entry(path: PackedVector3Array, lengths: PackedFloat32Array, other: PackedVector3Array, radius: float) -> Vector2:
	var result := Vector2(INF, -INF)
	for i in maxi(path.size() - 1, 1):
		var p0 := path[i]
		var p1 := path[mini(i + 1, path.size() - 1)]
		var length := lengths[mini(i + 1, lengths.size() - 1)] - lengths[i]
		for j in maxi(other.size() - 1, 1):
			var interval := _capsule_interval(p0, p1, other[j], other[mini(j + 1, other.size() - 1)], radius)
			if interval.x <= interval.y:
				result.x = minf(result.x, lengths[i] + interval.x * length)
				result.y = maxf(result.y, lengths[i] + interval.y * length)
	return result


## Parameters t in [0, 1] along p0-p1 whose points lie within radius of segment q0-q1 (a convex capsule, so one
## interval), or (INF, -INF).
static func _capsule_interval(p0: Vector3, p1: Vector3, q0: Vector3, q1: Vector3, radius: float) -> Vector2:
	var result := Vector2(INF, -INF)
	for centre in [q0, q1]:
		var disk := _disk_interval(p0, p1, centre, radius)
		result = Vector2(minf(result.x, disk.x), maxf(result.y, disk.y))
	var axis := RouteGuidance.planar(q1 - q0)
	var length := axis.length()
	if length > 0.0:
		var u := axis / length
		var n := Vector3(-u.z, 0.0, u.x)
		var d := RouteGuidance.planar(p1 - p0)
		var w := RouteGuidance.planar(p0 - q0)
		var strip := Vector2(0.0, 1.0)
		strip = _clip(strip, w.dot(u), d.dot(u), 0.0, length)
		strip = _clip(strip, w.dot(n), d.dot(n), -radius, radius)
		if strip.x <= strip.y:
			result = Vector2(minf(result.x, strip.x), maxf(result.y, strip.y))
	return result


## Restricts interval t to where low <= c0 + c1 t <= high.
static func _clip(t: Vector2, c0: float, c1: float, low: float, high: float) -> Vector2:
	if absf(c1) < 1e-9:
		return t if c0 >= low and c0 <= high else Vector2(INF, -INF)
	var t0 := (low - c0) / c1
	var t1 := (high - c0) / c1
	return Vector2(maxf(t.x, minf(t0, t1)), minf(t.y, maxf(t0, t1)))


static func _disk_interval(p0: Vector3, p1: Vector3, centre: Vector3, radius: float) -> Vector2:
	var d := RouteGuidance.planar(p1 - p0)
	var f := RouteGuidance.planar(p0 - centre)
	var a := d.dot(d)
	var c := f.dot(f) - radius * radius
	if a < 1e-12:
		return Vector2(0.0, 1.0) if c <= 0.0 else Vector2(INF, -INF)
	var b := 2.0 * f.dot(d)
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return Vector2(INF, -INF)
	var root := sqrt(discriminant)
	var t := Vector2(maxf((-b - root) / (2.0 * a), 0.0), minf((-b + root) / (2.0 * a), 1.0))
	return t if t.x <= t.y else Vector2(INF, -INF)


## The path's nearest point to a point: {s, point, distance}.
static func _nearest(path: PackedVector3Array, lengths: PackedFloat32Array, point: Vector3) -> Dictionary:
	var best := {s = 0.0, point = path[0], distance = RouteGuidance.planar(point - path[0]).length()}
	for i in path.size() - 1:
		var closest := Geometry3D.get_closest_point_to_segment(RouteGuidance.planar(point), path[i], path[i + 1])
		var distance := RouteGuidance.planar(point - closest).length()
		if distance < best.distance:
			best = {s = lengths[i] + RouteGuidance.planar(closest - path[i]).length(), point = closest, distance = distance}
	return best


static func _lengths(path: PackedVector3Array) -> PackedFloat32Array:
	var lengths := PackedFloat32Array([0.0])
	for i in range(1, path.size()):
		lengths.push_back(lengths[i - 1] + RouteGuidance.planar(path[i] - path[i - 1]).length())
	return lengths


static func _cut(path: PackedVector3Array, horizon: float) -> PackedVector3Array:
	var result := PackedVector3Array([path[0]])
	var travelled := 0.0
	for i in range(1, path.size()):
		var step := RouteGuidance.planar(path[i] - path[i - 1]).length()
		if travelled + step >= horizon:
			if step > 0.0:
				result.push_back(path[i - 1].lerp(path[i], (horizon - travelled) / step))
			return result
		travelled += step
		result.push_back(path[i])
	return result


static func _point_at(path: PackedVector3Array, lengths: PackedFloat32Array, s: float) -> Vector3:
	for i in range(1, path.size()):
		if s <= lengths[i] or i == path.size() - 1:
			var length := lengths[i] - lengths[i - 1]
			return path[i - 1].lerp(path[i], 0.0 if length <= 0.0 else clampf((s - lengths[i - 1]) / length, 0.0, 1.0))
	return path[path.size() - 1]


static func _direction_at(path: PackedVector3Array, lengths: PackedFloat32Array, s: float) -> Vector3:
	for i in range(1, path.size()):
		if (s <= lengths[i] or i == path.size() - 1) and lengths[i] > lengths[i - 1]:
			return RouteGuidance.planar(path[i] - path[i - 1]).normalized()
	return Vector3.ZERO
