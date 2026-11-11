class_name MovementProfile
extends Resource
## Shared movement tuning for a ship type (V4 propulsion, #102). Configuration only; never written at runtime.
## Three independent propulsion capabilities: main engines along the bow, retro thrusters toward the stern, and RCS
## rotation. None shares a budget with another; none pushes the ship sideways. All values are provisional.

## Main engines: acceleration along the bow at full thrust.
@export_range(0.1, 100.0, 0.01, "suffix:m/s²") var main_acceleration: float = 1.5
## Retro thrusters: acceleration toward the stern at full thrust (braking forward motion, then reverse travel).
@export_range(0.1, 100.0, 0.01, "suffix:m/s²") var retro_acceleration: float = 0.75
## Forward speed limit: the main engines add no speed along the bow beyond this. Velocity itself is never clamped, so
## existing drift plus new thrust can briefly take the total speed above it.
@export_range(1.0, 150.0, 0.1, "suffix:m/s") var max_speed: float = 15.0
## Reverse speed limit: the retro thrusters add no speed toward the stern beyond this (velocity is never clamped).
@export_range(0.1, 150.0, 0.1, "suffix:m/s") var max_reverse_speed: float = 5.0
## RCS: the angular acceleration (output, °/s²) against the actual planar speed in m/s (input; the curve's domain is
## m/s, speeds past its end points use those points' values). Rotation only. Required.
@export var turn_acceleration_curve: Curve
## RCS: the turn-rate limit (output, °/s) against the actual planar speed in m/s (input, as above). RCS adds no turn
## rate beyond it. Required.
@export var turn_rate_curve: Curve
## An order completes within this distance of its destination (and below arrival_speed_tolerance). In #102 orders do
## not complete by arrival; navigation still reads it for the endpoint reservation size.
@export_range(0.25, 10.0, 0.05, "suffix:m") var arrival_tolerance: float = 2.0
## An order completes only at or below this planar speed (and within arrival_tolerance). Read by navigation (#102).
@export_range(0.05, 5.0, 0.01, "suffix:m/s") var arrival_speed_tolerance: float = 0.5
## Route guidance (Task #46): the point this far ahead along the planned route. Read by navigation and traffic.
@export_range(2.0, 60.0, 0.1, "suffix:m") var detour_lookahead_distance: float = 10.0
## Planning clearance (Task #46): the hull counts as clear of obstacles at any yaw where a cylinder this much wider
## than its reach is empty.
@export_range(0.05, 5.0, 0.01, "suffix:m") var plan_clearance_buffer: float = 0.5
## Physical clearance repositioning (#60). Read by ship traffic.
@export_range(0.1, 2.0, 0.05, "suffix:s") var departure_step_time: float = 0.5
@export_range(0.5, 10.0, 0.1, "suffix:s") var departure_max_time: float = 4.0
## No-go tolerance (Task #48, provisional): how far beyond the navigation mesh edge a planned centre may go.
@export_range(0.0, 5.0, 0.01, "suffix:m") var no_go_tolerance: float = 0.5
