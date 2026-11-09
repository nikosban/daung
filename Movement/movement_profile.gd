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
## Directional-thruster effectiveness (output, 0–1) against the actual planar speed in m/s (input; the curve's domain
## is in m/s, and speeds beyond its first and last points use those points' values). It scales the directional
## thrusters' sideways acceleration (thruster_strength / mass) and their bow-forward acceleration
## (forward_directional_acceleration); sternward thrust keeps the full thruster_strength / mass (then the retro rule).
## Required.
@export var directional_thrust_curve: Curve
## Directional thrusters' bow-forward acceleration at rest, scaled by directional_thrust_curve at the actual speed. Not
## divided by mass. It adds to the main engine and shares the directional thrusters' capacity; 0 = no forward thrust.
@export_range(0.0, 100.0, 0.0001, "suffix:m/s²") var forward_directional_acceleration: float = 0.25
## Hard cap on the planar speed.
@export_range(1.0, 150.0, 0.1, "suffix:m/s") var max_speed: float = 15.0
## Time the pilot takes to close the gap between desired and actual velocity.
@export_range(0.1, 3.0, 0.01, "suffix:s") var pilot_response_time: float = 0.25
## An order completes within this distance of its destination (and below arrival_speed_tolerance).
@export_range(0.25, 10.0, 0.05, "suffix:m") var arrival_tolerance: float = 2.0
## An order completes only at or below this planar speed (and within arrival_tolerance).
@export_range(0.05, 5.0, 0.01, "suffix:m/s") var arrival_speed_tolerance: float = 0.5
## Powered turning: the largest angular acceleration (output, °/s², not divided by mass) against the actual planar
## speed in m/s (input; the curve's domain is m/s, speeds past its end points use those points' values). Shared
## proportionally with planar thrust from the directional thrusters. Required.
@export var turn_acceleration_curve: Curve
## Powered turning: the turn-rate limit (output, °/s) against the actual planar speed in m/s (input, as above). When it
## contracts faster than the turn can be braked, the rate is clamped to it (never the heading). Required.
@export var turn_rate_curve: Curve
## Bow alignment: the largest angle (output, degrees 0–180; 180 = unrestricted) the pilot may command between the bow
## and the actual travel direction, against the actual planar speed in m/s (input; the curve's domain is m/s, speeds
## past its end points use those points' values). While the ship moves bow-first, the steering target is the course
## heading limited to this angle either side of the travel direction, recalculated every tick. It limits the target only,
## never the hull or the velocity. Required.
@export var bow_alignment_curve: Curve
## Equipment: does this hull have thrusters pointing forward, so it can brake along its own axis? If not, the
## directional thrusters' acceleration toward the stern is limited (see no_retro_braking_effectiveness).
@export var retro_thrusters: bool = true
## Without retro thrusters: the largest sternward thruster acceleration, as a fraction of
## thruster_strength / mass. Lateral and bow-forward thrust are not limited by it.
@export_range(0.1, 1.0, 0.01) var no_retro_braking_effectiveness: float = 0.45
## Reversal rule (provisional): an order whose direction from the ship is at least this far from the actual planar
## travel direction when it activates (the ship faster than arrival_speed_tolerance) first brakes to near rest
## (arrival_speed_tolerance) with no commanded turn, then continues as an order from rest. Judged by the velocity, not
## the bow.
@export_range(90.0, 180.0, 0.1, "suffix:°") var near_opposite_angle: float = 150.0
## Route guidance (Task #46): the pilot aims at the point this far ahead along the planned route, so it rounds bends
## instead of chasing each route vertex. Only used for orders the navigator routes around obstacles.
@export_range(2.0, 60.0, 0.1, "suffix:m") var detour_lookahead_distance: float = 10.0
## Planning clearance (Task #46): the hull counts as clear of obstacles at any yaw where a cylinder this much wider
## than its reach is empty (a cheap shortcut used to find the route sections that need a full hull check). Never
## blocks a ship that is touching an obstacle from moving away.
@export_range(0.05, 5.0, 0.01, "suffix:m") var plan_clearance_buffer: float = 0.5
## Physical clearance repositioning (#60): held-heading requests last this long before route guidance is tried
## again, up to departure_max_time total commanded repositioning per order. The pilot and hull checks still apply.
@export_range(0.1, 2.0, 0.05, "suffix:s") var departure_step_time: float = 0.5
@export_range(0.5, 10.0, 0.1, "suffix:s") var departure_max_time: float = 4.0
## No-go tolerance (Task #48, provisional): a predicted maneuver is rejected when the predicted ship centre, once on
## the navigation mesh, goes more than this far beyond the mesh edge (the static no-go zone around obstacles). Only
## for maneuvers the navigator predicts; it is not a physical boundary, and the rotating hull may cross the edge.
@export_range(0.0, 5.0, 0.01, "suffix:m") var no_go_tolerance: float = 0.5
