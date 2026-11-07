class_name ManeuverRollout
extends RefCounted
const REST_SPEED := 0.01 # Existing technical near-rest criterion; never snaps velocity.
## Local physical lookahead near a real clearance constraint (#60). No full flight, stopping simulation,
## predicted checkpoints or persistent certificates. The ordinary clear-space path never calls the pilot here.


## Check the next actual pilot response and room for its physical braking. A false result asks navigation to slow
## for clearance, not to declare the destination unreachable. ShipMovement remains the only movement writer.
static func local_clear(profile: MovementProfile, probe: HullProbe, actual: ShipPilot.State,
		targets: ShipPilot.Targets, delta: float, map: RID, on_mesh := true) -> bool:
	var state := actual.copy()
	var aim := _copy_targets(targets)
	var out := ShipPilot.Output.new()
	ShipPilot.step(profile, state, aim, delta, out)
	var motion := state.velocity * delta
	if not probe.step_clear(actual.position, actual.yaw, motion, state.yaw - actual.yaw, true):
		return false
	state.position += motion
	state.bow = ShipPilot.bow_of(state.yaw)
	if not centre_leg_clear(map, profile, actual.position, state.position, on_mesh):
		return false
	return stopping_room(profile, probe, state, delta, map, on_mesh)


## Brake-to-rest distance bound: at least the weakest directional reach until braking becomes proportional,
## plus the complete response-time remainder and one integration tick. No-rest/timer shortcuts are used.
static func stopping_room(profile: MovementProfile, probe: HullProbe, state: ShipPilot.State, delta: float, map: RID, on_mesh := true) -> bool:
	var weakest := HullProbe.minimum_braking(profile)
	if weakest <= 0.0 or delta > profile.pilot_response_time:
		return false
	var speed := state.velocity.length()
	if speed == 0.0:
		return not probe.overlaps(state.position, state.yaw, 0.0)
	var direction := state.velocity / speed
	var rating := profile.thruster_strength / profile.mass
	if profile.retro_thrusters:
		# With no component cap, zero-target thrust is parallel to -velocity; yaw stops with the ordinary pilot.
		weakest = ShipPilot.reach_of(-direction, state.bow, rating, weakest, weakest)
	var distance := speed * speed / (2.0 * weakest) + speed * (profile.pilot_response_time + delta)
	if not profile.retro_thrusters:
		# The component cap can bend a stop. Use the full enclosing ball rather than assume a straight stop.
		return HullProbe.disk_on_mesh(map, state.position, distance) and probe.cylinder_clear(state.position, distance + probe.reach)
	var end := state.position + direction * distance
	if not probe.step_clear(state.position, state.yaw, end - state.position, 0.0, true):
		return false
	return centre_leg_clear(map, profile, state.position, end, on_mesh)


## Test the actual centre rule, including its tolerance, when the stricter whole-mesh geometric proof fails.
## Distance to a closed mesh is 1-Lipschitz: reserving half a sample interval covers the points between samples.
static func centre_leg_clear(map: RID, profile: MovementProfile, start: Vector3, end: Vector3, on_mesh := true) -> bool:
	if HullProbe.capsule_on_mesh(map, start, end, 0.0):
		return true
	var distance := RouteGuidance.planar(end - start).length()
	var cell := NavigationServer3D.map_get_cell_size(map)
	# The tolerance itself sets the sampling scale; the Lipschitz margin below covers every intermediate point.
	# Using the bake cell here needlessly repeated closest-point queries along long, otherwise clear stops.
	var spacing := profile.no_go_tolerance
	if spacing <= 0.0:
		return false
	var samples := maxi(1, ceili(distance / spacing))
	var margin := distance / samples * 0.5
	for i in samples + 1:
		var point := start.lerp(end, float(i) / samples)
		var nearest := NavigationServer3D.map_get_closest_point(map, point)
		var off_mesh := RouteGuidance.planar(nearest - point).length()
		if off_mesh <= cell:
			on_mesh = true
		if on_mesh and off_mesh + margin > profile.no_go_tolerance:
			return false
	return true


static func _copy_targets(source: ShipPilot.Targets) -> ShipPilot.Targets:
	var copy := ShipPilot.Targets.new()
	copy.has_order = source.has_order
	copy.destination = source.destination
	copy.use_steer = source.use_steer
	copy.steer_direction = source.steer_direction
	copy.steer_distance = source.steer_distance
	copy.has_course = source.has_course
	copy.course_yaw = source.course_yaw
	copy.course_follows = source.course_follows
	copy.brake_first = source.brake_first
	copy.bend_lengths = source.bend_lengths
	copy.bend_radii = source.bend_radii
	copy.bend_from = source.bend_from
	copy.bend_s = source.bend_s
	return copy
