class_name MovementProfile
extends Resource
## Shared movement tuning for a ship type (heading-and-throttle locomotion). Configuration only; never
## written at runtime. All values are provisional.

## Highest commanded main-engine speed along the bow.
@export_range(1.0, 20.0, 0.1, "suffix:m/s") var max_speed: float = 5.0
## Main-engine speed gain along the bow.
@export_range(0.1, 10.0, 0.01, "suffix:m/s²") var accel: float = 1.0
## Main-engine speed loss (braking) along the bow; also the rate used to anticipate braking.
@export_range(0.1, 10.0, 0.01, "suffix:m/s²") var decel: float = 0.75
## Highest hull yaw rate.
@export_range(1.0, 90.0, 0.1, "suffix:°/s") var yaw_rate: float = 10.0
## Yaw rate gain and loss, so turns ease in and out instead of snapping.
@export_range(1.0, 180.0, 0.1, "suffix:°/s²") var yaw_accel: float = 10.0
## TURN commands this fraction of the speed it was entered with; also caps planned corner speeds as a
## fraction of max_speed and the thruster speed of a departure from rest.
@export_range(0.1, 1.0, 0.01) var turn_speed_factor: float = 0.6
## Sideways slip loss toward zero.
@export_range(0.0, 5.0, 0.01, "suffix:m/s²") var slip_decay: float = 0.25
## Fraction of the old velocity's sideways part, after the hull yaws, kept as slip.
@export_range(0.0, 1.0, 0.01) var slip_gain: float = 0.5
## Directional thruster acceleration, in any direction (TRANSLATE, departures from rest).
@export_range(0.05, 5.0, 0.01, "suffix:m/s²") var thruster_accel: float = 0.35
## Longest move from rest that may use TRANSLATE (thrusters only).
@export_range(0.0, 100.0, 0.1, "suffix:m") var thruster_range: float = 15.0
## TURN ends within this heading error; CRUISE re-enters TURN beyond twice this error.
@export_range(1.0, 30.0, 0.1, "suffix:°") var heading_tolerance: float = 5.0
## From rest, TRANSLATE is chosen when its estimated time is at most this multiple of turn-and-burn's.
@export_range(1.0, 2.0, 0.01) var translate_preference: float = 1.2
## Entering this distance of the final point completes an order.
@export_range(0.1, 10.0, 0.1, "suffix:m") var arrival_tolerance: float = 2.0
## Orders at least this far from the actual travel direction brake to rest before starting.
@export_range(90.0, 180.0, 0.1, "suffix:°") var near_opposite_angle: float = 150.0
## Tolerance when simplifying navigation paths into route points; unobstructed paths reduce to the click.
## Also how close a path's end must be to a destination for the destination to count as reachable.
@export_range(0.01, 1.0, 0.01, "suffix:m") var path_simplify_epsilon: float = 0.1
## Destination search around an occupied or off-surface click: the distance between search rings and
## between samples along a ring. The chosen destination is approximately the nearest valid one.
@export_range(0.25, 5.0, 0.05, "suffix:m") var destination_search_spacing: float = 1.0
## Destination search work per ship per physics tick, in samples.
@export_range(8, 512, 1) var destination_search_budget: int = 32
## Corner clearance gate work per ship per physics tick, in physics queries (overlap, candidate or sweep).
@export_range(16, 1024, 1) var clearance_check_budget: int = 64
## Corner clearance gate rollout work per ship per physics tick, in simulated motion steps.
@export_range(60, 6000, 1) var rollout_step_budget: int = 240
