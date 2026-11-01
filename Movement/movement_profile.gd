class_name MovementProfile
extends Resource

## Per-ship-type movement tuning. Distances are in project units (see
## ARCHITECTURE.md). Values live in .tres assets, not in code.

## Top speed along the hull's forward axis.
@export_range(0.0, 30.0, 0.1, "suffix:units/s") var max_forward_speed: float
## Top sideways speed relative to the hull.
@export_range(0.0, 30.0, 0.1, "suffix:units/s") var max_lateral_speed: float
## Top speed backward along the hull's forward axis (the backward component,
## not the combined diagonal speed). 0 = cannot reverse. Must stay below
## max_forward_speed.
@export_range(0.0, 30.0, 0.1, "suffix:units/s") var max_reverse_speed: float
## Rate at which actual velocity grows toward the requested velocity.
@export_range(0.1, 20.0, 0.1, "suffix:units/s²") var acceleration: float
## Rate at which actual velocity shrinks; also used to stop after stop() or arrival.
@export_range(0.1, 20.0, 0.1, "suffix:units/s²") var braking: float
## Maximum hull turn rate.
@export_range(1.0, 180.0, 1.0, "suffix:°/s") var yaw_rate: float
## Distance from the destination at which an order counts as arrived.
@export_range(0.05, 10.0, 0.05, "suffix:units") var arrival_tolerance: float
## Look-ahead: how far ahead along the route (planar arc length) the route
## follower aims. The aim point continues past corners.
@export_range(0.1, 20.0, 0.1, "suffix:units") var waypoint_tolerance: float
## How far a ship may swing outward off its route at a corner. Corner speed is
## set so the velocity change fits within this distance at the acceleration
## and braking rates. Separate from NavigationClearance.margin.
@export_range(0.1, 2.0, 0.05, "suffix:units") var corner_drift_limit: float
## Actual speed below which a ship in contact counts as Blocked. Must stay
## above zero, or no speed is ever below it and Blocked is never entered.
@export_range(0.01, 1.0, 0.01, "suffix:units/s") var blocked_speed_tolerance: float
