extends Node3D
## Ship traffic scenario scene (Task 38, #79): the production ship, camera, Fleet and debugging suite, set up from one
## TrafficSetup. Select the setup on this root and run the scene with F6. There is no navigation mesh, so orders run
## in direct mode (path = straight line). The same scene is run headless by Tests/traffic_scenarios_test.gd.

const ASTEROID_SCENE := preload("res://Main/asteroid.tscn")
## Where a ship that the setup does not use is parked (one 60 m step apart per slot).
const PARKED_AWAY := Vector3(-400, 0, 400)

@export var setup: TrafficSetup

var _time := 0.0
var _next_order := 0

@onready var _fleet: FleetCommand = $FleetCommand


func _enter_tree() -> void:
	if setup == null:
		push_error("Traffic scenario needs a TrafficSetup.")
		return
	var ships := get_ships()
	for slot in ships.size():
		var ship := ships[slot]
		if slot < setup.positions.size():
			ship.position = Vector3(setup.positions[slot].x, 0.0, setup.positions[slot].z)
			ship.rotation.y = deg_to_rad(setup.yaws[slot]) if slot < setup.yaws.size() else 0.0
			ship.velocity = setup.velocities[slot] if slot < setup.velocities.size() else Vector3.ZERO
		else:
			ship.position = PARKED_AWAY + Vector3(60.0 * slot, 0.0, 0.0)
		if slot < setup.main_accelerations.size() and setup.main_accelerations[slot] > 0.0:
			# A per-instance test copy: the shared production profile is never modified.
			var profile := ship.profile.duplicate() as MovementProfile
			profile.main_acceleration = setup.main_accelerations[slot]
			ship.profile = profile
	var shapes: Array[CollisionShape3D] = []
	for ship in ships:
		shapes.push_back(ship.get_node("CollisionShape3D"))
	for i in setup.asteroids.size():
		var asteroid := ASTEROID_SCENE.instantiate() as Node3D
		asteroid.name = "Asteroid%d" % (i + 1)
		asteroid.position = setup.asteroids[i]
		$Asteroids.add_child(asteroid)
		shapes.push_back(asteroid.get_node("CollisionShape3D"))
	$DebuggingSuite.collision_shapes = shapes
	$CameraRig.position = setup.camera_focus


func _ready() -> void:
	if setup != null:
		$CameraRig.set_view(setup.camera_focus, setup.camera_height, 0.0)


## The scenario's ships in roster order (slot 0 middle, 1 left, 2 right).
func get_ships() -> Array[ShipMovement]:
	var ships: Array[ShipMovement] = [$Ship0, $Ship1, $Ship2]
	return ships


## Seconds since the scenario started (physics time).
func get_elapsed() -> float:
	return _time


func _physics_process(delta: float) -> void:
	if setup == null:
		return
	while _next_order < setup.order_times.size() and setup.order_times[_next_order] <= _time + 1e-6:
		var ship := get_ships()[setup.order_slots[_next_order]]
		(ship.get_node("%Orders") as ShipOrders).move(setup.order_points[_next_order])
		_next_order += 1
	_time += delta
