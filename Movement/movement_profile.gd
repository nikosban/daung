class_name MovementProfile
extends Resource
## Shared movement tuning for a ship type (Movement v3). Configuration only; never written at runtime.
## All values are provisional placeholders.

## Gameplay mass divisor (dimensionless): thruster acceleration = thruster_strength / mass.
@export_range(1.0, 20.0, 0.1) var mass: float = 5.0
## Rated main-engine acceleration along the bow at full throttle. Not divided by mass.
@export_range(0.1, 100.0, 0.1, "suffix:m/s²") var main_acceleration: float = 12.0
## Directional thruster strength in thrust units (m/s² × mass). One budget for any planar direction.
@export_range(1.0, 600.0, 1.0) var thruster_strength: float = 60.0
## Hard cap on the planar speed.
@export_range(1.0, 150.0, 0.1, "suffix:m/s") var max_speed: float = 15.0
## Time the pilot takes to close the gap between desired and actual velocity.
@export_range(0.1, 3.0, 0.01, "suffix:s") var pilot_response_time: float = 0.25
## An order completes within this distance of its destination (and below arrival_speed_tolerance).
@export_range(0.25, 10.0, 0.05, "suffix:m") var arrival_tolerance: float = 2.0
## An order completes only at or below this planar speed (and within arrival_tolerance).
@export_range(0.05, 5.0, 0.01, "suffix:m/s") var arrival_speed_tolerance: float = 0.5
## Turning rating in turn-authority units (°/s² × mass): turn_authority / mass is the angular acceleration
## at a rudder multiplier of 1. Shared proportionally with planar thrust from the directional thrusters.
@export_range(1.0, 1000.0, 1.0) var turn_authority: float = 120.0
## Rudder multiplier (output, 0–2) against actual planar speed as a fraction of max_speed (input, 0–1).
## Zero at rest means no turning in place.
@export var rudder_curve: Curve
