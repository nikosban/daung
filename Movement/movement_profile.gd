class_name MovementProfile
extends Resource

## Per-ship-type movement tuning. Distances are in project units (see
## ARCHITECTURE.md). Values live in .tres assets, not in code.

## Top speed along the hull's forward axis.
@export_range(0.0, 30.0, 0.1, "suffix:units/s") var max_forward_speed: float
## Top sideways speed relative to the hull.
@export_range(0.0, 30.0, 0.1, "suffix:units/s") var max_lateral_speed: float
## Rate at which actual velocity grows toward the requested velocity.
@export_range(0.1, 20.0, 0.1, "suffix:units/s²") var acceleration: float
## Rate at which actual velocity shrinks; also used to stop after stop() or arrival.
@export_range(0.1, 20.0, 0.1, "suffix:units/s²") var braking: float
## Maximum hull turn rate.
@export_range(1.0, 180.0, 1.0, "suffix:°/s") var yaw_rate: float
## Distance from the destination at which an order counts as arrived.
@export_range(0.05, 10.0, 0.05, "suffix:units") var arrival_tolerance: float
## How far ahead along the current route segment the route follower aims
## (planar). It never aims past the segment's corner.
@export_range(0.1, 20.0, 0.1, "suffix:units") var waypoint_tolerance: float
## Actual speed below which a ship in contact counts as Blocked. Must stay
## above zero, or no speed is ever below it and Blocked is never entered.
@export_range(0.01, 1.0, 0.01, "suffix:units/s") var blocked_speed_tolerance: float
