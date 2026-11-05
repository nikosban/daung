class_name CorridorScan
extends RefCounted
## Drift corridor check (Task #46), resumable one sample at a time. A ship moving at speed v that follows a route can
## drift sideways off it by at most v² / a_t, its braking distance at the planar share the thrusters leave beside full
## turning (a_t / 2). The corridor is clear when the ship's position and every route sample ahead (every hull
## half-width, from arc length s on) have an empty cylinder of radius hull reach + clearance buffer + v² / a_t +
## off_route, where off_route is how far the ship is from the route (Task #50: callers only use the corridor for a
## ship within arrival_tolerance of its route); the ship then cannot touch anything on the rest of the route.
## Conservative for geometry that is static while planning.

enum { RUNNING, CLEAR, BLOCKED }

var _plan: RouteGuidance.Plan
var _probe: HullProbe
var _position := Vector3.ZERO
var _radius := 0.0
var _spacing := 0.0
var _at := 0.0
var _checked_position := false


func _init(plan: RouteGuidance.Plan, probe: HullProbe, profile: MovementProfile, position: Vector3, speed: float, s: float, off_route := 0.0) -> void:
	_plan = plan
	_probe = probe
	_position = position
	_radius = probe.reach + profile.plan_clearance_buffer + speed * speed / (profile.thruster_strength / profile.mass) + off_route
	_spacing = maxf(probe.half_width, 0.5)
	_at = s


## Checks one sample: RUNNING while samples remain, CLEAR or BLOCKED when decided.
func step() -> int:
	if not _checked_position:
		_checked_position = true
		return RUNNING if _probe.cylinder_clear(_position, _radius) else BLOCKED
	var total := _plan.total_length()
	var point := RouteGuidance.point_at(_plan, minf(_at, total))
	point.y = _position.y
	if not _probe.cylinder_clear(point, _radius):
		return BLOCKED
	if _at >= total:
		return CLEAR
	_at += _spacing
	return RUNNING
