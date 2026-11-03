class_name MovementProfile
extends Resource
## Shared movement tuning for a ship type. Configuration only; never written at runtime.

@export_range(0.0, 60.0, 0.1, "suffix:m/s") var max_speed: float = 8.0
@export_range(0.1, 30.0, 0.1, "suffix:m/s²") var acceleration: float = 6.0
@export_range(0.1, 40.0, 0.1, "suffix:m/s²") var braking: float = 10.0
@export_range(1.0, 120.0, 0.1, "suffix:°/s") var turn_rate: float = 20.0
@export_range(0.1, 10.0, 0.1, "suffix:m") var arrival_tolerance: float = 2.0
## Directional (sideways) thrust: how strongly a moving ship can turn its travel direction (not its
## hull). The travel turn rate is this divided by speed, so slower ships turn tighter.
@export_range(0.1, 20.0, 0.1, "suffix:m/s²") var lateral_acceleration: float = 1.7
## Orders at least this far from the current travel direction brake to rest before starting.
@export_range(90.0, 180.0, 0.1, "suffix:°") var near_opposite_angle: float = 150.0
## How far ahead along a multi-point route the ship aims, so it anticipates bends.
## Not a stopping radius; intermediate points need not be passed exactly.
@export_range(2.0, 100.0, 0.1, "suffix:m") var route_lookahead_distance: float = 25.0
## Lookahead while following an automatically generated detour around static obstacles (provisional).
## Manual legs appended after the detour's final point return to route_lookahead_distance.
@export_range(2.0, 100.0, 0.1, "suffix:m") var detour_lookahead_distance: float = 20.0
## Corner tracking on detours: the straight line from the ship to its guidance point may pass at most
## this far from any detour point it skips, so guidance does not pull the ship far inside a curve.
@export_range(0.1, 10.0, 0.1, "suffix:m") var detour_corner_tolerance: float = 1.0
## Tolerance when simplifying navigation paths into route points; unobstructed paths reduce to the click.
@export_range(0.01, 1.0, 0.01, "suffix:m") var path_simplify_epsilon: float = 0.1
