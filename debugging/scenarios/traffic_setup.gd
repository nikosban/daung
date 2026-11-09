class_name TrafficSetup
extends Resource
## One ship traffic test case (Task 38, #79) for the traffic scenario scene: start poses, optional test profiles,
## timed orders and asteroids. Debug data only; it never changes the production ship or its profile.

## What the case shows and what to look for.
@export_multiline var description := ""
## Start position (Y ignored), yaw in degrees (0 = bow toward -Z) and planar velocity (m/s) per roster slot
## (0 middle, 1 left, 2 right). A slot without a position is parked far away, out of the case.
@export var positions := PackedVector3Array()
@export var yaws := PackedFloat32Array()
@export var velocities := PackedVector3Array()
## Test profiles: per slot, a copy of the production profile with this main acceleration (m/s²); 0 = the production
## profile itself. Everything else, including the 15 m/s cap, stays as in the production profile.
@export var main_accelerations := PackedFloat32Array()
## Timed moves through each ship's Orders: seconds after the scene starts, roster slot, point.
@export var order_times := PackedFloat32Array()
@export var order_slots := PackedInt32Array()
@export var order_points := PackedVector3Array()
## Asteroid positions (instances of Main/asteroid.tscn).
@export var asteroids := PackedVector3Array()
## Initial camera floor focus and height (m).
@export var camera_focus := Vector3.ZERO
@export var camera_height := 140.0
