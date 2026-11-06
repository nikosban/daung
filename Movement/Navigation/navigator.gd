class_name Navigator
extends RefCounted
## Navigation for ShipMovement (Tasks #46, #56): one Job per activated move, served from one queue shared by all ships
## within a wall-clock allowance per physics tick (NavigationBudget). Nothing here writes a transform or velocity or
## commands thrust: a Job only says, each tick, which guidance the ship's pilot follows (Guidance), and ShipMovement
## turns that into pilot targets. ShipMovement stays the single writer of position, velocity and yaw.
##
## Route phase: the job's RoutePlanner checks readiness, resolves a blocked click (Task #54) and asks Godot for one
## ordinary path. When the hull cannot touch anything along that route and the ship's drift corridor is clear (the
## open-space fast path), the plan is DONE and flown unchecked, as before Task #56.
##
## Checked flight (status GUIDING): otherwise the job stays with the order and decides every interval of
## pilot_response_time (I ticks) what the ship does in the next one: COAST, FOLLOW a route or BRAKE. Each decision is
## computed during the interval before it, from the predicted state at its start (the boundary), and adopted at the
## boundary only if the ship's actual state then equals the prediction (HANDOFF_TOLERANCE); otherwise, or when the
## decision is not ready (late), the ship brakes for that interval and the next decision starts from its actual state.
## Decision order, all from the boundary state (ManeuverCheck predictions with the real pilot, hull and no-go rule):
##  1. Safety: follow the route for I, then brake to rest, must be clear. Progress: follow the route freely for the
##     window W = speed / a_b + pilot_response_time (a_b the weakest planned braking) without contact or no-go breach.
##     Both pass: FOLLOW.
##  2. Slowing on the same route (not at activation): BRAKE when braking 1, 2, 4, ... intervals, with the ship still
##     above arrival_speed_tolerance, makes the progress window pass.
##  3. Alternative passage: while queries remain (NavigationBudget.path_recoveries_per_order), a PassageGraph query from
##     the boundary position to the same destination; the first distinct route (corners offset) whose safety and
##     progress checks pass is followed. Each query counts; a rejected route is never tried again.
##  4. FOLLOW the route if its safety check passed (safe for the interval; re-checked next interval).
##  5. BRAKE. When the ship is (nearly) at rest, nothing passes and no query is left, the order is BLOCKED: the ship
##     rests, the destination and order are kept, and nothing more is searched until another command activates.
## Activation: the ship coasts (no thrust, no turning) from the activation tick. The first work checks that coast for
## one interval followed by braking to rest from the live state; if the coast itself would touch something or breach
## the no-go rule, the ship brakes at once. The first decision is taken for the end of that coast interval.
## A route's corners are rounded outward by MovementProfile.path_corner_clearance (PassageGraph.CornerShaper) before
## it is checked or flown.
## The outcome depends only on states and the world, never on wall-clock time, except that a late decision brakes.

const BUDGET: NavigationBudget = preload("res://Movement/Navigation/navigation_budget.tres")

enum Status { PENDING, DONE, DECLINED, CANCELLED, GUIDING, BLOCKED }
enum Guidance { COAST, FOLLOW, BRAKE }

## Largest summed difference (position m + velocity m/s + yaw rad + turn rate rad/s) between the ship's state and a
## predicted boundary state for which the decision made from that prediction is adopted (float noise only). Task #50
## measured 0 to 1e-7 while braking; the arrival approach's speed law (sqrt of the remaining distance) amplifies the
## float noise of the real tick (yaw read back from the basis) to 2e-4 to 4e-4 (Task #56 A2 runs).
const HANDOFF_TOLERANCE := 1.0e-3
## Intervals the ship coasts after activation before its first checked decision applies (the coast and the braking
## after it are checked from the live state first). Two intervals leave room for the route, its corners and an
## alternative-passage query within the shared allowance (Task #56 measurement).
const ACTIVATION_INTERVALS := 2

static var _jobs: Array[Job] = []
static var _frame := -1
static var _frame_used := 0


## Starts the navigation job for an activated move. The caller keeps the job and cancels it when the order ends or a
## later command activates.
static func start_job(ship: ShipMovement, probe: HullProbe, click: Vector3) -> Job:
	var job := Job.new(ship, probe, click)
	_jobs.push_back(job)
	return job


## Advances queued jobs, oldest first, within this physics tick's shared allowance. Every ship calls it each tick before
## its own move. On the first call of a frame, before any ship has moved in it, every guiding job reaches its interval
## boundary (adopt or brake) outside the allowance. A job only waiting (for navigation to sync, or for its boundary
## with its decision ready) does not hold up the jobs behind it.
static func service() -> void:
	var frame := Engine.get_physics_frames()
	if frame != _frame:
		_frame = frame
		_frame_used = 0
		for job in _jobs:
			if job.status == Status.PENDING or job.status == Status.GUIDING:
				job.on_frame(frame)
	var i := 0
	while i < _jobs.size():
		var job := _jobs[i]
		if job.status != Status.PENDING and job.status != Status.GUIDING:
			_jobs.remove_at(i)
			continue
		if job.is_idle():
			i += 1
			continue
		var allowance := BUDGET.plan_time_per_tick - _frame_used
		if allowance <= 0:
			return
		var start := Time.get_ticks_usec()
		job.advance(PlanClock.new(start + allowance, BUDGET.plan_time_per_tick))
		_frame_used += Time.get_ticks_usec() - start
		if job.status != Status.PENDING and job.status != Status.GUIDING:
			_jobs.remove_at(i)
		elif job.is_waiting():
			i += 1
		else:
			return


## Used time this physics frame by all navigation jobs (µs; debug and traces).
static func get_frame_used() -> int:
	return _frame_used


## The weakest planned braking (m/s²): half the thruster rating at full turning share, or the no-retro sternward cap.
static func weakest_braking_of(profile: MovementProfile) -> float:
	var thrusters := profile.thruster_strength / profile.mass
	var braking := thrusters * 0.5
	if not profile.retro_thrusters:
		braking = minf(braking, profile.no_retro_braking_effectiveness * thrusters)
	return braking


## One navigation job for one activated move.
class Job:
	var status := Status.PENDING
	## DONE: the plan the pilot follows unchecked (kind DIRECT for the unchanged direct order).
	var plan: RouteGuidance.Plan
	## GUIDING / BLOCKED: what the ship does this tick, and for FOLLOW the route plan and its live progress.
	var control := Guidance.COAST
	var guided_plan: RouteGuidance.Plan
	var guided_follow: RouteGuidance.Follow
	var reason := ""
	var summary := ""
	## Short phase text for F3 ("following route 68 m", "slowing for clearance", "alternative passage 195 m", ...).
	var phase := "planning"
	## Lines for the Output, drained by ShipMovement.
	var events := PackedStringArray()
	var used_usec := 0
	var ticks := 0
	var click := Vector3.ZERO
	var destination := Vector3.ZERO
	var resolution := ""
	var resolution_log := PackedStringArray()
	var worst_tick_usec := 0
	## Evidence counters (checked flight).
	var decisions := 0
	var late := 0
	var mismatches := 0
	var queries := 0
	var predicted_ticks := 0
	var worst_decision_usec := 0
	var _ship: ShipMovement
	var _probe: HullProbe
	## Shared with Decision (same file).
	var _profile: MovementProfile
	var _map: RID
	var _delta := 1.0 / 60.0
	var _interval := 15
	var _route: RoutePlanner
	var _last_frame := -1
	var _tick_usec := 0
	# Checked flight.
	var _route_raw := PackedVector3Array()
	var _rejected: Array[PackedVector3Array] = []
	var _boundary_frame := -1
	var _activation_frame := -1
	var _boundary_state: ShipPilot.State
	var _boundary_follow: RouteGuidance.Follow
	var _activation := true
	var _coast_check: ManeuverCheck
	var _coast_proven := false
	var _shaper: PassageGraph.CornerShaper
	var _task: Decision
	var _ready: Decision

	func _init(ship: ShipMovement, probe: HullProbe, p_click: Vector3) -> void:
		_ship = ship
		_probe = probe
		_profile = ship.profile
		_map = ship.get_world_3d().navigation_map
		_delta = ship.get_physics_process_delta_time()
		_interval = maxi(1, roundi(_profile.pilot_response_time / _delta))
		click = Vector3(p_click.x, ship.global_position.y, p_click.z)
		destination = click
		probe.queries = 0
		var now := ship.get_pilot_state()
		_activation_frame = Engine.get_physics_frames()
		_boundary_frame = _activation_frame + _interval * ACTIVATION_INTERVALS
		_coast_check = _check(now, null, null, [Vector2i(ManeuverCheck.Mode.COAST, _interval * ACTIVATION_INTERVALS)], ManeuverCheck.Tail.REST)
		_route = RoutePlanner.new(_map, probe, _profile, click, ship.get_pilot_state, Navigator.BUDGET.destination_candidates_per_order)

	func cancel() -> void:
		if status == Status.PENDING or status == Status.GUIDING:
			status = Status.CANCELLED

	## Whether a guiding job has nothing to compute until its next boundary (it is not advanced).
	func is_idle() -> bool:
		return status == Status.GUIDING and _task == null and _coast_check == null and _shaper == null

	## Whether the job, after advancing, only waits: for navigation to sync, or for its next boundary. It then does not
	## hold up the jobs behind it.
	func is_waiting() -> bool:
		if status == Status.PENDING:
			return _route.result == RoutePlanner.RUNNING and _route.waiting and _coast_check == null
		return is_idle()

	## Interval boundaries, once per frame before any ship has moved (Navigator.service()).
	func on_frame(frame: int) -> void:
		if not is_instance_valid(_ship):
			status = Status.CANCELLED
			return
		if frame != _boundary_frame:
			return
		if status == Status.PENDING:
			# The route is not ready by the end of the activation coast: brake (late), then decide from the actual state.
			late += 1
			_brake_and_restart(frame, "route not ready by the end of the activation coast")
			return
		var now := _ship.get_pilot_state()
		var decision := _ready
		_ready = null
		if decision == null:
			late += 1
			_brake_and_restart(frame, "decision late")
			return
		var difference := _difference(now, _boundary_state)
		if difference > HANDOFF_TOLERANCE:
			mismatches += 1
			_brake_and_restart(frame, "state differs from the prediction by %.6f (position %.6f m, velocity %.6f m/s)" % [difference, (now.position - _boundary_state.position).length(), (now.velocity - _boundary_state.velocity).length()])
			return
		_adopt(decision)
		if status == Status.BLOCKED:
			return
		_start_next(frame, now)

	func advance(clock: PlanClock) -> void:
		if not is_instance_valid(_ship):
			status = Status.CANCELLED
			return
		var start := Time.get_ticks_usec()
		var frame := Engine.get_physics_frames()
		if frame != _last_frame:
			_last_frame = frame
			ticks += 1
			_tick_usec = 0
		if status == Status.PENDING and _route.result == RoutePlanner.RUNNING:
			_route.run(clock)
			if _route.result != RoutePlanner.RUNNING:
				_route_done()
		if _coast_check != null and (status == Status.PENDING or status == Status.GUIDING):
			_run_coast_check(clock)
		if _shaper != null:
			while clock.has_time():
				var finished := _shaper.step()
				clock.item_done()
				if finished:
					_route_shaped()
					break
		if status == Status.GUIDING and _task != null and _coast_check == null:
			var task := _task
			var task_start := Time.get_ticks_usec()
			var result := task.run(clock)
			task.used_usec += Time.get_ticks_usec() - task_start
			if result != Decision.RUNNING:
				worst_decision_usec = maxi(worst_decision_usec, task.used_usec)
				predicted_ticks += task.predicted_ticks
				if task._activation:
					events.push_back("first decision ready %d of %d ticks after activation (%d µs of work, %d predicted ticks)" % [frame - _activation_frame, _boundary_frame - _activation_frame, task.used_usec, task.predicted_ticks])
				_ready = task
				_task = null
		_add_time(start)

	func _add_time(start: int) -> void:
		var used := Time.get_ticks_usec() - start
		used_usec += used
		_tick_usec += used
		worst_tick_usec = maxi(worst_tick_usec, _tick_usec)

	## The physics frame whose start the ship's current state belongs to: this frame before the ship has moved in it,
	## the next one after.
	func _state_frame() -> int:
		var frame := Engine.get_physics_frames()
		return frame + 1 if _ship.get_moved_frame() == frame else frame

	func _route_done() -> void:
		resolution = _route.resolution
		resolution_log = _route.resolution_log
		match _route.result:
			RoutePlanner.BASELINE:
				var direct := RouteGuidance.Plan.new()
				direct.destination = click
				_finish(direct, _route.note)
			RoutePlanner.DECLINED:
				status = Status.DECLINED
				reason = _route.note
			RoutePlanner.ROUTE:
				if not _route.needs_prediction:
					_finish(_route.primary_plan, "open space (no hull contact possible along the route)")
					return
				destination = _route.destination
				_route_raw = _route.route_plan.route
				status = Status.GUIDING
				phase = "checking route"
				_shaper = shaper_for(_route_raw)

	## The initial route's corners are rounded: the plan exists, and decisions can start.
	func _route_shaped() -> void:
		guided_plan = plan_for(_shaper.route)
		guided_follow = RouteGuidance.Follow.new()
		phase = "checking route %.0f m" % guided_plan.total_length()
		events.push_back("checked flight: route %.1f m (%s); %d corners moved for clearance, %d of them reduced to keep the legs on the mesh (%d samples)" % [guided_plan.total_length(), _route.hazard_text, _shaper.rounded, _shaper.reduced, _shaper.samples_tested])
		_shaper = null
		if control == Guidance.BRAKE:
			# The activation coast ended (late route, or a coast that was not clear): decide from the actual state.
			_start_next(_state_frame(), _ship.get_pilot_state())
		elif _coast_check == null and _boundary_state != null:
			_task = Decision.new(self, _boundary_state, _boundary_follow, guided_plan, _activation)

	func _finish(p_plan: RouteGuidance.Plan, note: String) -> void:
		plan = p_plan
		status = Status.DONE
		summary = note
		destination = p_plan.destination
		_coast_check = null

	func _run_coast_check(clock: PlanClock) -> void:
		var result := _coast_check.run(clock)
		if result == ManeuverCheck.RUNNING:
			return
		var check := _coast_check
		_coast_check = null
		predicted_ticks += check.predicted_ticks
		if result == ManeuverCheck.FAIL and check.failed_segment == 0:
			events.push_back("activation coast not clear (%s): braking" % check.failure)
			_brake_and_restart(_state_frame(), "activation coast not clear")
			return
		_coast_proven = result == ManeuverCheck.PASS
		if not _coast_proven:
			events.push_back("activation: braking to rest after the coast is not proven (%s)" % check.failure)
		_boundary_state = check.segment_states[0]
		_boundary_follow = RouteGuidance.Follow.new()
		if status == Status.GUIDING and guided_plan != null:
			_task = Decision.new(self, _boundary_state, _boundary_follow, guided_plan, _activation)

	## Brake from now: the next boundary is one interval ahead, predicted from the actual state under braking.
	func _brake_and_restart(frame: int, why: String) -> void:
		if why != "" and control != Guidance.BRAKE:
			events.push_back("braking: %s" % why)
		control = Guidance.BRAKE
		_coast_check = null
		_task = null
		_ready = null
		_activation = false
		if status == Status.PENDING:
			phase = "planning (braking)"
			_boundary_state = null
			_boundary_frame = -1
			return
		phase = "braking (%s)" % why if why != "" else "braking"
		_start_next(frame, _ship.get_pilot_state())

	## Starts the decision for the interval after the current one, from the predicted state at its start.
	func _start_next(frame: int, now: ShipPilot.State) -> void:
		_boundary_frame = frame + _interval
		var boundary := _check(now, guided_follow, guided_plan, [Vector2i(_mode_of(control), _interval)], ManeuverCheck.Tail.NONE)
		boundary.run_all()
		predicted_ticks += boundary.predicted_ticks
		if boundary.segment_states.is_empty():
			_boundary_state = boundary.state
			_boundary_follow = boundary.follow
		else:
			_boundary_state = boundary.segment_states[0]
			_boundary_follow = boundary.segment_follows[0]
		_task = Decision.new(self, _boundary_state, _boundary_follow, guided_plan, false)

	func _adopt(decision: Decision) -> void:
		decisions += 1
		if decision.queried:
			queries += 1
		_activation = false
		var previous := control
		var previous_phase := phase
		control = decision.control
		if decision.new_route.size() > 0:
			_rejected.push_back(_route_raw)
			_route_raw = decision.new_route
			guided_plan = decision.plan
			guided_follow = RouteGuidance.Follow.new()
			RouteGuidance.track(guided_plan, guided_follow, _ship.global_position)
		elif control == Guidance.FOLLOW and previous != Guidance.FOLLOW:
			# Progress resumes from the predicted progress at the boundary (equal to tracking the actual position).
			guided_follow = ManeuverCheck.copy_follow(_boundary_follow)
		for line in decision.events:
			events.push_back(line)
		phase = decision.phase
		if decision.blocked:
			status = Status.BLOCKED
			control = Guidance.BRAKE
			reason = decision.blocked_reason
			events.push_back("blocked (unresolved): %s" % reason)
		elif phase != previous_phase:
			events.push_back(phase)

	func _difference(a: ShipPilot.State, b: ShipPilot.State) -> float:
		return (a.position - b.position).length() + (a.velocity - b.velocity).length() + absf(wrapf(a.yaw - b.yaw, -PI, PI)) + absf(a.turn_rate - b.turn_rate)

	func _mode_of(p_control: int) -> int:
		match p_control:
			Guidance.COAST:
				return ManeuverCheck.Mode.COAST
			Guidance.FOLLOW:
				return ManeuverCheck.Mode.FOLLOW
		return ManeuverCheck.Mode.BRAKE

	func _check(start: ShipPilot.State, follow: RouteGuidance.Follow, p_plan: RouteGuidance.Plan, segments: Array[Vector2i], tail: int) -> ManeuverCheck:
		return ManeuverCheck.new(start, follow, p_plan, segments, tail, _profile, _probe, _delta, _map)

	func shaper_for(raw: PackedVector3Array) -> PassageGraph.CornerShaper:
		return PassageGraph.CornerShaper.new(_map, raw, _profile.path_corner_clearance)

	func plan_for(route: PackedVector3Array) -> RouteGuidance.Plan:
		return RouteGuidance.make_plan(RouteGuidance.Kind.ROUTE, route, destination, _profile.detour_lookahead_distance)

	## Destination-resolution query counts (Task #54): closest-point, path and physics (hull) queries of this job.
	func query_text() -> String:
		return "%d closest-point, %d path, %d physics queries" % [_route.closest_queries, _route.path_queries, _probe.queries]

	## Checked-flight evidence for the Output.
	func evidence_text() -> String:
		return "%d decisions, %d late, %d state mismatches, %d alternative queries, %d predicted ticks; %d µs over %d ticks, worst tick %d µs, worst decision %d µs" % [decisions, late, mismatches, queries, predicted_ticks, used_usec, ticks, worst_tick_usec, worst_decision_usec]


## One interval decision (see the Navigator description), resumable: run() advances its current prediction or
## passage query one work item at a time while the clock allows.
class Decision:
	enum { RUNNING, READY }

	var control := Guidance.BRAKE
	var plan: RouteGuidance.Plan
	var new_route := PackedVector3Array()
	var phase := ""
	var blocked := false
	var blocked_reason := ""
	## Whether this decision ran an alternative-passage query (counted against the order when adopted).
	var queried := false
	var events := PackedStringArray()
	var used_usec := 0
	var predicted_ticks := 0
	var _job: Job
	var _start: ShipPilot.State
	var _follow: RouteGuidance.Follow
	var _activation := false
	var _step := 0
	var _check: ManeuverCheck
	var _safe := false
	var _slow := 1
	var _query: PassageGraph.Query
	var _shaper: PassageGraph.CornerShaper
	var _candidate := PackedVector3Array()
	var _candidate_plan: RouteGuidance.Plan
	var _candidate_safe := false
	var _tried := PackedStringArray()

	func _init(job: Job, start: ShipPilot.State, follow: RouteGuidance.Follow, p_plan: RouteGuidance.Plan, activation: bool) -> void:
		_job = job
		_start = start.copy()
		_follow = ManeuverCheck.copy_follow(follow)
		plan = p_plan
		_activation = activation

	func _speed() -> float:
		return RouteGuidance.planar(_start.velocity).length()

	func _window_ticks(speed: float) -> int:
		var profile := _job._profile
		return ceili((speed / Navigator.weakest_braking_of(profile) + profile.pilot_response_time) / _job._delta)

	func _safety(p_plan: RouteGuidance.Plan, follow: RouteGuidance.Follow) -> ManeuverCheck:
		return _job._check(_start, follow, p_plan, [Vector2i(ManeuverCheck.Mode.FOLLOW, _job._interval)], ManeuverCheck.Tail.REST)

	func _progress(p_plan: RouteGuidance.Plan, follow: RouteGuidance.Follow, brake_ticks: int) -> ManeuverCheck:
		var segments: Array[Vector2i] = []
		if brake_ticks > 0:
			segments.push_back(Vector2i(ManeuverCheck.Mode.BRAKE, brake_ticks))
		segments.push_back(Vector2i(ManeuverCheck.Mode.FOLLOW, _window_ticks(_speed())))
		return _job._check(_start, follow, p_plan, segments, ManeuverCheck.Tail.NONE)

	func run(clock: PlanClock) -> int:
		while true:
			if _check != null:
				var result := _check.run(clock)
				if result == ManeuverCheck.RUNNING:
					return RUNNING
				predicted_ticks += _check.predicted_ticks
				var check := _check
				_check = null
				if _next(result == ManeuverCheck.PASS, check):
					return READY
				continue
			if _shaper != null:
				if not clock.has_time():
					return RUNNING
				var shaped := _shaper.step()
				clock.item_done()
				if shaped:
					_candidate_plan = _job.plan_for(_shaper.route)
					_shaper = null
					_step = 10
					_check = _safety(_candidate_plan, null)
				continue
			if _query != null:
				if not clock.has_time():
					return RUNNING
				var found := _query.step()
				clock.item_done()
				match found:
					PassageGraph.FOUND:
						_candidate = _query.route
						_shaper = _job.shaper_for(_candidate)
					PassageGraph.DONE, PassageGraph.UNAVAILABLE:
						var reason := "no distinct passage passed" if found == PassageGraph.DONE else "alternative passages unavailable (map has no single region)"
						events.push_back("alternative query from (%.1f, %.1f) at %.2f m/s: %s [%s]; %d searches, %d expansions" % [_start.position.x, _start.position.z, _speed(), reason, ", ".join(_tried), _query.searches, _query.expansions])
						_query = null
						if _after_query():
							return READY
				continue
			if not clock.has_time():
				return RUNNING
			clock.item_done()
			if _begin():
				return READY
		return RUNNING

	## First prediction: the current route's safety check.
	func _begin() -> bool:
		_step = 1
		_check = _safety(plan, _follow)
		return false

	## Advances the decision after a finished prediction; true when decided.
	func _next(passed: bool, check: ManeuverCheck) -> bool:
		match _step:
			1:
				_safe = passed
				_step = 2
				_check = _progress(plan, _follow, 0)
				return false
			2:
				if passed and _safe:
					return _decide(Guidance.FOLLOW, "following route %.0f m" % plan.total_length())
				return _try_slowing()
			3:
				if check.failed_segment == 0:
					return _try_query()
				var braked: ShipPilot.State = check.segment_states[0]
				if RouteGuidance.planar(braked.velocity).length() <= _job._profile.arrival_speed_tolerance:
					return _try_query()
				if passed:
					return _decide(Guidance.BRAKE, "slowing for clearance")
				_slow *= 2
				_check = _progress(plan, _follow, _slow * _job._interval)
				return false
			10:
				_candidate_safe = passed
				if not passed:
					_tried.push_back("%.0f m: %s" % [_candidate_plan.total_length(), check.failure])
					_step = 0
					return false
				_step = 11
				_check = _progress(_candidate_plan, null, 0)
				return false
			11:
				if passed:
					_tried.push_back("%.0f m: passes" % _candidate_plan.total_length())
					events.push_back("alternative query from (%.1f, %.1f) at %.2f m/s: switching to a distinct passage of %.1f m [%s]; %d searches, %d expansions" % [_start.position.x, _start.position.z, _speed(), _candidate_plan.total_length(), ", ".join(_tried), _query.searches, _query.expansions])
					_query = null
					new_route = _candidate
					plan = _candidate_plan
					return _decide(Guidance.FOLLOW, "alternative passage %.0f m" % plan.total_length())
				_tried.push_back("%.0f m: progress window fails (%s)" % [_candidate_plan.total_length(), check.failure])
				_step = 0
				return false
		return false

	func _try_slowing() -> bool:
		if _activation or _speed() <= _job._profile.arrival_speed_tolerance:
			return _try_query()
		_step = 3
		_slow = 1
		_check = _progress(plan, _follow, _job._interval)
		return false

	func _try_query() -> bool:
		if _job.queries >= Navigator.BUDGET.path_recoveries_per_order:
			return _after_query()
		# Counted when the decision is adopted (a late decision's query is redone, not lost from the budget).
		queried = true
		var rejected: Array[PackedVector3Array] = _job._rejected.duplicate()
		rejected.push_back(_job._route_raw)
		_query = PassageGraph.Query.new(_job._map, _start.position, _job.destination, rejected, Navigator.BUDGET.passage_searches_per_query, _job._profile.detour_lookahead_distance)
		return false

	## No alternative was taken: follow the route if its interval is safe, otherwise brake (or block at rest).
	func _after_query() -> bool:
		if _safe:
			return _decide(Guidance.FOLLOW, "following route %.0f m (no faster passage)" % plan.total_length())
		var used := _job.queries + (1 if queried else 0)
		if _speed() <= _job._profile.arrival_speed_tolerance and used >= Navigator.BUDGET.path_recoveries_per_order:
			blocked = true
			blocked_reason = "no safe approach found from (%.1f, %.1f) (%d alternative queries used)" % [_start.position.x, _start.position.z, used]
			return _decide(Guidance.BRAKE, "blocked (unresolved)")
		return _decide(Guidance.BRAKE, "braking (route not safe at this speed)")

	func _decide(p_control: int, p_phase: String) -> bool:
		control = p_control
		phase = p_phase
		return true
