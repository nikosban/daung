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
## Turn-rate limit at max_speed. At lower speeds it scales with the rudder curve (normalized to its
## full-speed value), so it is zero at rest.
@export_range(1.0, 180.0, 1.0, "suffix:°/s") var max_turn_rate_at_max_speed: float = 60.0
## Rudder multiplier (output, 0–2) against actual planar speed as a fraction of max_speed (input, 0–1).
## Zero at rest means no turning in place.
@export var rudder_curve: Curve
## Equipment: does this hull have thrusters pointing forward, so it can brake along its own axis? If not, the
## directional thrusters' acceleration toward the stern is limited (see no_retro_braking_effectiveness).
@export var retro_thrusters: bool = true
## Without retro thrusters: the largest sternward thruster acceleration, as a fraction of
## thruster_strength / mass. Lateral and bow-forward thrust are not limited by it.
@export_range(0.1, 1.0, 0.01) var no_retro_braking_effectiveness: float = 0.45
## Crew reaction delay: time between receiving a move or stop command and the pilot acting on it. Every
## command waits its own delay; the active order stands until then. 0 acts on the next physics tick.
@export_range(0.0, 5.0, 0.01, "suffix:s") var reaction_delay: float = 0.3
## Route guidance (Task #46): the pilot aims at the point this far ahead along the planned route, so it rounds bends
## instead of chasing each route vertex. Only used for orders the navigator routes around obstacles.
@export_range(2.0, 60.0, 0.1, "suffix:m") var detour_lookahead_distance: float = 10.0
## Planning clearance (Task #46): the hull counts as clear of obstacles at any yaw where a cylinder this much wider
## than its reach is empty (a cheap shortcut used to find the route sections that need a full hull check). Never
## blocks a ship that is touching an obstacle from moving away.
@export_range(0.05, 5.0, 0.01, "suffix:m") var plan_clearance_buffer: float = 0.5
## Departures (Task #46): when a ship must first brake or back off before following a route, the planner tries
## departures lasting one, two, … steps of this length, up to departure_max_time, shortest first.
@export_range(0.1, 2.0, 0.05, "suffix:s") var departure_step_time: float = 0.5
@export_range(0.5, 10.0, 0.1, "suffix:s") var departure_max_time: float = 4.0
