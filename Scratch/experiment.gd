extends SceneTree
## Task 28 (#59) scratch measurement harness. Disposable; not part of the game.
## Usage: Godot --headless --path . --fixed-fps 60 --script res://Scratch/experiment.gd -- <scenario> <label> [main_accel]
## Writes Scratch/out/<label>/<scenario>.json (summary) and .csv (trace every 6th tick).

const MAX_TIME := 120.0
const CRUISE_TIME := 5.0
const SAMPLE_EVERY := 6
const ASTEROID_RADIUS := 7.5 # 6 m sphere scaled 1.25

var scenario := ""
var label := ""
var main_accel := -1.0
var main: Node
var ship: ShipMovement
var shared_profile: MovementProfile
var shared_snapshot := {}
var schedule: Array = [] # [time, kind, Vector3 or Callable]
var rows: Array = []
var tick := 0
var asteroids: Array[Vector3] = []
var map: RID
var hull_size := Vector2(5.9, 20.3)

# Measurement state.
var focus_received := -1.0 # receipt time of the measured command
var focus_activated := -1.0
var focus_origin := Vector3.ZERO
var focus_velocity := Vector3.ZERO
var focus_dest := Vector3.ZERO
var arrived_time := -1.0
var status_log: Array[String] = []
var last_status := ""
var max_thrust_fraction := 0.0
var max_off_mesh := 0.0
var min_hull_gap := INF
var contact := ""
var activations: Array = []
var last_activated := -1.0
var done := false


class Probe extends Node:
	var harness
	func _ready() -> void:
		process_physics_priority = 10
	func _physics_process(_delta: float) -> void:
		harness.after_tick()


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	var args := OS.get_cmdline_user_args()
	scenario = args[0]
	label = args[1]
	if args.size() > 2:
		main_accel = float(args[2])
	main = (load("res://Main/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	ship = main.get_node("Ship")
	shared_profile = ship.profile
	shared_snapshot = snapshot(shared_profile)
	if main_accel > 0.0 or scenario.ends_with("_noretro"):
		var copy: MovementProfile = shared_profile.duplicate(true)
		if main_accel > 0.0:
			copy.main_acceleration = main_accel
		if scenario.ends_with("_noretro"):
			copy.retro_thrusters = false
		ship.profile = copy
	for cluster in ["TestObstacle", "ClusterA", "ClusterB", "ClusterC"]:
		var node: Node3D = main.get_node(cluster)
		if node.get_child_count() == 0 or cluster == "TestObstacle":
			asteroids.append(node.global_position)
		else:
			for child in node.get_children():
				asteroids.append((child as Node3D).global_position)
	var trail = main.get_node("MovementTrail")
	trail.set_active(true)
	map = ship.get_world_3d().navigation_map
	setup()
	var probe := Probe.new()
	probe.harness = self
	main.add_child(probe)


func cruise(start: Vector3) -> void:
	# Bow +X (yaw -90°) at 15 m/s with a long order straight ahead (it is received at 0 and activates after the delay).
	place(start, -PI / 2.0, Vector3(15.0, 0.0, 0.0))
	schedule.append([0.0, "move", Vector3(start.x + 340.0, 0.0, start.z)])


func setup() -> void:
	match scenario:
		"turn90":
			cruise(Vector3(-320, 0, 40))
			schedule.append([CRUISE_TIME, "focus_move", Vector3(0, 0, 120)])
		"turn180":
			cruise(Vector3(-200, 0, 40))
			schedule.append([CRUISE_TIME, "focus_move", Vector3(-120, 0, 0)])
		"arrive":
			cruise(Vector3(-320, 0, 40))
			schedule.append([CRUISE_TIME, "focus_move", Vector3(120, 0, 0)])
		"brake", "brake_noretro":
			cruise(Vector3(-320, 0, 40))
			schedule.append([CRUISE_TIME, "focus_stop", null])
		"crab10":
			place(Vector3(-200, 0, 40), 0.0, Vector3.ZERO)
			schedule.append([0.0, "focus_move", Vector3(10, 0, 0)])
		"clear":
			place(Vector3.ZERO, 0.0, Vector3.ZERO)
			schedule.append([0.0, "focus_abs", Vector3(60, 0, -40)])
		"route":
			place(Vector3.ZERO, 0.0, Vector3.ZERO)
			schedule.append([0.0, "focus_abs", Vector3(150, 0, 0)])
		"a2_5", "a2_6":
			place(Vector3(238, 0, -162), 0.0, Vector3.ZERO)
			schedule.append([0.0, "move_abs", Vector3(170, 0, -90)])
			var at := 5.0 if scenario == "a2_5" else 6.0
			schedule.append([at - 0.3, "focus_abs", main.get_node("ClusterA/A2").global_position])
		"queue":
			place(Vector3.ZERO, 0.0, Vector3.ZERO)
			schedule.append([0.0, "move_abs", Vector3(60, 0, -40)])
			schedule.append([1.0, "move_abs", Vector3(-40, 0, -60)])
			schedule.append([1.0, "stop", null])
			schedule.append([1.5, "focus_abs", Vector3(60, 0, -40)])
		"crossover":
			pass
		_:
			push_error("unknown scenario " + scenario)


func place(position: Vector3, yaw: float, velocity: Vector3) -> void:
	ship.global_position = position
	ship.rotation.y = yaw
	ship.velocity = velocity


func _process(_delta: float) -> bool:
	if scenario == "crossover":
		finish_crossover()
		return true
	return done


func after_tick() -> void:
	tick += 1
	var clock := ship.get_clock()
	# Commands due this tick (issued after the ship's tick, so they are received at this clock).
	while not schedule.is_empty() and schedule[0][0] <= clock + 1e-6:
		var item: Array = schedule.pop_front()
		issue(item)
	if ship.get_last_activated_time() != last_activated:
		last_activated = ship.get_last_activated_time()
		activations.append(snappedf(last_activated, 0.001))
		if focus_received >= 0.0 and focus_activated < 0.0 and last_activated > focus_received - 1e-6:
			focus_activated = last_activated
			focus_origin = ship.global_position
			focus_velocity = ship.velocity
	var status := ship.get_order_status()
	if status != last_status:
		last_status = status
		status_log.append("%.2f %s" % [clock, status])
		if status.begins_with("static-contact") and contact == "":
			contact = status
	if focus_activated >= 0.0 and arrived_time < 0.0 and status.begins_with("arrived") and not ship.has_order():
		arrived_time = clock
	record(clock)
	var settled := arrived_time >= 0.0 and clock > arrived_time + 2.0
	if focus_activated >= 0.0 and scenario.begins_with("brake") and ship.velocity.length() < 0.01 and clock > focus_activated + 0.5:
		arrived_time = clock
		settled = true
	if focus_activated >= 0.0 and not ship.has_order() and not status.begins_with("arrived") and ship.get_pending_count() == 0 and not scenario.begins_with("brake") and clock > focus_activated + 0.1:
		settled = settled or ship.velocity.length() < 0.01
	if settled or clock >= MAX_TIME + maxf(focus_activated, 0.0):
		finish()


func issue(item: Array) -> void:
	var kind: String = item[1]
	if kind == "move":
		ship.move_to(item[2])
	elif kind == "move_abs":
		ship.move_to(item[2])
	elif kind == "stop":
		ship.stop()
	elif kind == "focus_move":
		focus_received = ship.get_clock()
		focus_dest = Vector3(ship.global_position.x, 0, ship.global_position.z) + item[2]
		ship.move_to(focus_dest)
	elif kind == "focus_abs":
		focus_received = ship.get_clock()
		focus_dest = item[2]
		ship.move_to(focus_dest)
	elif kind == "focus_stop":
		focus_received = ship.get_clock()
		ship.stop()


func record(clock: float) -> void:
	var p := ship.global_position
	var v := Vector3(ship.velocity.x, 0, ship.velocity.z)
	var yaw := ship.rotation.y
	var thrust := ship.get_thruster_command()
	var limit := ship.profile.thruster_strength / ship.profile.mass
	max_thrust_fraction = maxf(max_thrust_fraction, thrust.length() / limit)
	var closest := NavigationServer3D.map_get_closest_point(map, p)
	var off := Vector2(p.x - closest.x, p.z - closest.z).length()
	if ship.has_order() and not ship.is_planning():
		max_off_mesh = maxf(max_off_mesh, off)
	for a in asteroids:
		min_hull_gap = minf(min_hull_gap, hull_gap(p, yaw, a))
	var bow := ShipPilot.bow_of(yaw)
	var bow_travel := NAN
	if v.length() > 0.5:
		bow_travel = rad_to_deg(bow.signed_angle_to(v, Vector3.UP))
	var bow_path := NAN
	var tangent := path_tangent(p)
	if tangent != Vector3.ZERO:
		bow_path = rad_to_deg(bow.signed_angle_to(tangent, Vector3.UP))
	var stern := -thrust.dot(bow)
	var lateral := thrust.dot(Vector3(-bow.z, 0, bow.x))
	rows.append({t = clock, x = p.x, z = p.z, vx = v.x, vz = v.z, speed = v.length(), yaw = rad_to_deg(yaw),
		turn = ship.get_turn_rate(), main = ship.get_main_command(), stern = stern, lateral = lateral,
		thrust = thrust.length(), bow_travel = bow_travel, bow_path = bow_path, target = ship.get_target_heading(),
		order = ship.has_order(), off = off})


func path_tangent(p: Vector3) -> Vector3:
	if focus_activated < 0.0 or not ship.has_order():
		return Vector3.ZERO
	var plan = ship.get("_plan")
	if plan != null and plan.route.size() >= 2:
		var best := INF
		var tangent := Vector3.ZERO
		for k in range(1, plan.route.size()):
			var a: Vector3 = plan.route[k - 1]
			var b: Vector3 = plan.route[k]
			var seg := Vector3(b.x - a.x, 0, b.z - a.z)
			if seg.length() < 1e-6:
				continue
			var t := clampf(Vector3(p.x - a.x, 0, p.z - a.z).dot(seg) / seg.length_squared(), 0, 1)
			var q := a + seg * t
			var d := Vector2(p.x - q.x, p.z - q.z).length()
			if d < best:
				best = d
				tangent = seg.normalized()
		return tangent
	var dest := ship.get_destination()
	var seg := Vector3(dest.x - focus_origin.x, 0, dest.z - focus_origin.z)
	return seg.normalized() if seg.length() > 1e-6 else Vector3.ZERO


func hull_gap(p: Vector3, yaw: float, a: Vector3) -> float:
	var d := Vector2(a.x - p.x, a.z - p.z)
	var bow := Vector2(-sin(yaw), -cos(yaw))
	var side := Vector2(-bow.y, bow.x)
	var local := Vector2(d.dot(side), d.dot(bow))
	var q := Vector2(maxf(absf(local.x) - hull_size.x / 2, 0), maxf(absf(local.y) - hull_size.y / 2, 0))
	return q.length() - ASTEROID_RADIUS


func snapshot(profile: Resource) -> Dictionary:
	var out := {}
	for prop in profile.get_property_list():
		if prop.usage & PROPERTY_USAGE_STORAGE:
			var value = profile.get(prop.name)
			if value is Curve:
				var pts := []
				for i in value.point_count:
					pts.append(value.get_point_position(i))
				value = pts
			out[prop.name] = var_to_str(value)
	return out


func finish() -> void:
	if done:
		return
	done = true
	var r := summarize()
	r["profile_unchanged"] = snapshot(shared_profile) == shared_snapshot
	write(r)


func summarize() -> Dictionary:
	var r := {scenario = scenario, label = label, main_accel = ship.profile.main_acceleration,
		retro = ship.profile.retro_thrusters, focus_received = focus_received, focus_activated = focus_activated,
		activations = activations, status = status_log, contact = contact,
		max_thrust_fraction = max_thrust_fraction, max_off_mesh = max_off_mesh, min_hull_gap = min_hull_gap}
	var after := rows.filter(func(row): return focus_activated >= 0.0 and row.t >= focus_activated - 1e-6)
	if after.is_empty():
		return r
	var start: Dictionary = after[0]
	var last: Dictionary = after[-1]
	var dest := ship.get_destination()
	r.arrived = arrived_time >= 0.0 and not scenario.begins_with("brake")
	r.end_time = last.t - focus_activated
	r.arrival_time = (arrived_time - focus_activated) if arrived_time >= 0.0 else -1.0
	r.speed_at_activation = start.speed
	r.final_position = [last.x, last.z]
	r.destination = [dest.x, dest.z]
	r.final_miss = Vector2(last.x - dest.x, last.z - dest.z).length()
	r.final_speed = last.speed
	var min_speed := INF
	var max_speed_after := 0.0
	for row in after:
		min_speed = minf(min_speed, row.speed)
	r.min_speed = min_speed
	# Turn exit: first tick the travel direction is within 10° of the direction to the destination (moving > 0.5 m/s).
	# Speed lost is measured up to there, so the final arrival braking does not count.
	var exit_index := -1
	for k in after.size():
		var row: Dictionary = after[k]
		var to_dest := Vector2(dest.x - row.x, dest.z - row.z)
		if row.speed > 0.5 and to_dest.length() > 1.0 and absf(Vector2(row.vx, row.vz).angle_to(to_dest)) < deg_to_rad(10.0) and row.t > focus_activated + 0.5:
			exit_index = k
			break
	var turn_min := INF
	for k in (exit_index + 1 if exit_index >= 0 else after.size()):
		turn_min = minf(turn_min, after[k].speed)
	r.turn_exit_time = (after[exit_index].t - focus_activated) if exit_index >= 0 else -1.0
	r.turn_exit_speed = after[exit_index].speed if exit_index >= 0 else -1.0
	r.speed_lost = start.speed - turn_min
	var old_dir := Vector3(focus_velocity.x, 0, focus_velocity.z).normalized()
	if old_dir == Vector3.ZERO:
		old_dir = ShipPilot.bow_of(start.yaw * PI / 180.0)
	var origin := focus_origin
	match scenario:
		"turn90":
			# Destination line: the line through the destination along the new direction; drift = how far the ship
			# went past it along the old travel direction.
			var drift := -INF
			for row in after:
				drift = maxf(drift, Vector3(row.x - dest.x, 0, row.z - dest.z).dot(old_dir))
			r.drift_past_destination_line = drift
		"turn180":
			var drift := -INF
			for row in after:
				drift = maxf(drift, Vector3(row.x - origin.x, 0, row.z - origin.z).dot(old_dir))
			r.forward_overshoot_past_order_point = drift
		"brake", "brake_noretro":
			r.stopping_distance = Vector2(last.x - origin.x, last.z - origin.z).length()
			r.stopping_time = last.t - focus_activated
			var peak := 0.0
			var lat := 0.0
			for row in after:
				peak = maxf(peak, row.stern)
				lat = maxf(lat, absf(row.lateral))
			r.peak_sternward_thrust = peak
			r.peak_lateral_thrust = lat
			# Speed must fall monotonically (no snap, no re-acceleration).
			var monotonic := true
			for k in range(1, after.size()):
				if after[k].speed > after[k - 1].speed + 1e-4:
					monotonic = false
			r.speed_monotonic = monotonic
			var max_step := 0.0
			for k in range(1, after.size()):
				max_step = maxf(max_step, after[k - 1].speed - after[k].speed)
			r.max_speed_drop_per_tick = max_step
		"crab10":
			var dir := Vector3(dest.x - origin.x, 0, dest.z - origin.z).normalized()
			var dev := 0.0
			var peak := 0.0
			for row in after:
				var off := Vector3(row.x - origin.x, 0, row.z - origin.z)
				dev = maxf(dev, absf(off.dot(Vector3(-dir.z, 0, dir.x))))
				peak = maxf(peak, row.speed)
			r.max_line_deviation = dev
			r.peak_speed = peak
			r.displacement = Vector2(last.x - origin.x, last.z - origin.z).length()
			r.yaw_change = wrapf(last.yaw - start.yaw, -180, 180)
	# Turn geometry: radius from the travel-direction change between 10 % and 90 % of the total.
	if scenario in ["turn90", "turn180", "route", "a2_5", "a2_6", "clear"]:
		var headings := []
		for row in after:
			if row.speed > 0.5:
				headings.append([row.t, atan2(row.vz, row.vx), row.speed, row.x, row.z])
		if headings.size() > 2:
			var unwrapped := [headings[0][1]]
			for k in range(1, headings.size()):
				unwrapped.append(unwrapped[-1] + wrapf(headings[k][1] - headings[k - 1][1], -PI, PI))
			var total: float = unwrapped[-1] - unwrapped[0]
			r.travel_turn_deg = rad_to_deg(total)
			var lo := -1
			var hi := -1
			for k in unwrapped.size():
				var f: float = (unwrapped[k] - unwrapped[0]) / total if absf(total) > 1e-3 else 0.0
				if lo < 0 and f >= 0.1:
					lo = k
				if hi < 0 and f >= 0.9:
					hi = k
			if lo >= 0 and hi > lo:
				var arc := 0.0
				var slowest := INF
				for k in range(lo + 1, hi + 1):
					arc += Vector2(headings[k][3] - headings[k - 1][3], headings[k][4] - headings[k - 1][4]).length()
					slowest = minf(slowest, headings[k][2])
				var turned := absf(unwrapped[hi] - unwrapped[lo])
				r.turn_radius = arc / turned if turned > 1e-3 else -1.0
				r.turn_min_speed = slowest
		# Bow alignment: last time each angle was ≥ 5° while the order was active and the ship moved (> 0.5 m/s).
		var last_travel := -1.0
		var last_path := -1.0
		var max_travel := 0.0
		var max_path := 0.0
		for row in after:
			if not row.order:
				continue
			if not is_nan(row.bow_travel):
				max_travel = maxf(max_travel, absf(row.bow_travel))
				if absf(row.bow_travel) >= 5.0:
					last_travel = row.t - focus_activated
			if not is_nan(row.bow_path) and row.speed > 0.5:
				max_path = maxf(max_path, absf(row.bow_path))
				if absf(row.bow_path) >= 5.0:
					last_path = row.t - focus_activated
		r.max_bow_to_travel = max_travel
		r.max_bow_to_path = max_path
		r.bow_to_travel_last_over_5deg = last_travel
		r.bow_to_path_last_over_5deg = last_path
		# Heading flips: sign changes of the turn rate in the last 10 s before arrival or end.
		var flips := 0
		var prev := 0.0
		var end_t: float = last.t
		for row in after:
			if row.t < end_t - 10.0:
				continue
			if absf(row.turn) > 0.5:
				if prev != 0.0 and signf(row.turn) != signf(prev):
					flips += 1
				prev = row.turn
		r.turn_sign_flips_last_10s = flips
	return r


func finish_crossover() -> void:
	var p := shared_profile
	var limit := p.thruster_strength / p.mass
	var has_curve := "lateral_authority_curve" in p and p.get("lateral_authority_curve") != null
	var keel := float(p.get("keel_drag")) if "keel_drag" in p else 0.0
	var cross := -1.0
	var table := []
	var v := 0.0
	while v <= p.max_speed + 1e-6:
		var lat: float = limit * (p.get("lateral_authority_curve").sample(v / p.max_speed) if has_curve else 1.0)
		var drag := keel * v * v
		if cross < 0.0 and drag >= lat:
			cross = v
		if is_equal_approx(fmod(v, 1.0), 0.0) or fmod(v, 1.0) < 0.005:
			table.append([snappedf(v, 0.1), snappedf(lat, 0.001), snappedf(drag, 0.001)])
		v += 0.01
	write({scenario = scenario, label = label, crossover_speed = cross, table = table, keel_drag = keel,
		thruster_limit = limit, criterion = "lowest speed at which keel drag on a pure sideways velocity (keel_drag v^2) reaches the faded lateral thruster acceleration (thruster_limit x curve(v / max_speed))"})


func write(r: Dictionary) -> void:
	var dir := "res://Scratch/out/%s" % label
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var f := FileAccess.open("%s/%s.json" % [dir, scenario], FileAccess.WRITE)
	f.store_string(JSON.stringify(r, "  "))
	f.close()
	if not rows.is_empty():
		var c := FileAccess.open("%s/%s.csv" % [dir, scenario], FileAccess.WRITE)
		var keys: Array = rows[0].keys()
		c.store_line(",".join(keys))
		for k in rows.size():
			if k % SAMPLE_EVERY != 0 and k != rows.size() - 1:
				continue
			var vals := []
			for key in keys:
				var value = rows[k][key]
				vals.append(("%.3f" % value) if value is float else str(value))
			c.store_line(",".join(vals))
		c.close()
	print("RESULT ", JSON.stringify(r))
	quit()
