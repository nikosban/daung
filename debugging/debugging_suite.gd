extends Node3D
## Reusable scene composition for Daung's existing movement diagnostics and test controls.
## Main supplies world dependencies; Movement never depends on this suite.

const MARKER_SCENE := preload("res://debugging/debug_marker.tscn")

## The fleet whose current selection the diagnostics follow.
@export var fleet: FleetCommand
@export var collision_shapes: Array[CollisionShape3D] = []
## World-space positions of the optional amber reference rings, supplied by the host scene.
@export var reference_marker_positions := PackedVector3Array()

var _outlines: Array[CollisionShapeOutline] = []


func _ready() -> void:
	process_physics_priority = -10
	# One trail per roster ship, all from the suite's MovementTrail node.
	var trails := {}
	var template := $MovementTrail as MovementTrail
	for i in fleet.roster.size():
		var trail := template if i == 0 else template.duplicate() as MovementTrail
		trail.ship = fleet.roster[i]
		if i > 0:
			add_child(trail)
		trails[fleet.roster[i]] = trail
	$MovementDebugOverlay.fleet = fleet
	$MovementDebugOverlay.trails = trails
	for shape in collision_shapes:
		var outline := CollisionShapeOutline.new()
		outline.name = "CollisionOutline"
		shape.add_child(outline)
		_outlines.push_back(outline)
	$MovementDebugOverlay.collision_outlines = _outlines
	for position in reference_marker_positions:
		var marker := MARKER_SCENE.instantiate() as MeshInstance3D
		$ReferenceMarkers.add_child(marker)
		marker.top_level = true
		marker.global_transform = Transform3D(Basis.IDENTITY, position)


func _exit_tree() -> void:
	# These visuals are parented to external collision shapes, so own their lifetime explicitly.
	for outline in _outlines:
		if is_instance_valid(outline):
			outline.queue_free()
	_outlines.clear()


## Diagnostic propulsion keys (#102; not player controls): while held, Up = main engines, Down = retro thrusters,
## Left / Right = RCS rotation, sent to every selected ship each physics frame; every other roster ship gets none.
## Runs after Orders (-20) and before Movement (0).
func _physics_process(_delta: float) -> void:
	var main := 1.0 if Input.is_action_pressed("debug_main_thrust") else 0.0
	var retro := 1.0 if Input.is_action_pressed("debug_retro_thrust") else 0.0
	var rcs := Input.get_axis("debug_rcs_right", "debug_rcs_left")
	var selection := fleet.get_selection()
	for ship in fleet.roster:
		if selection.has(ship):
			ship.set_diagnostic_propulsion(main, retro, rcs)
		else:
			ship.set_diagnostic_propulsion(0.0, 0.0, 0.0)


## F7 (Task 38, #79): three crossing orders through Orders, one per roster slot (middle, left, right), all crossing
## near (0, -60). Valid only in a fresh run, from the ships' start positions (0, 0), (-30, 0) and (30, 0).
const CROSSING_ORDERS: Array[Vector3] = [Vector3(0, 0, -120), Vector3(30, 0, -120), Vector3(-30, 0, -120)]


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_F4:
		for ship in fleet.get_selection():
			(ship.get_node("%Orders") as ShipOrders).stop()
	elif key.keycode == KEY_F7:
		for i in mini(fleet.roster.size(), CROSSING_ORDERS.size()):
			(fleet.roster[i].get_node("%Orders") as ShipOrders).move(CROSSING_ORDERS[i])
		$MovementDebugOverlay.crossing_issued = true
