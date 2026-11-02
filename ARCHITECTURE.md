# Architecture

## Status and units

This is the target design approved in Task #1. Task #3 implemented the first open-space Movement slice; the actual inventory is listed below.

**1 world unit = 1 metre.** Gameplay movement is horizontal on Godot's X/Z plane. Ordinary movement does not chase Y; any later vertical animation belongs to the model only.

Data assets use m/s for speed, m/s² for acceleration and braking, degrees/s for rotation, and metres for dimensions and distances.

## Module map

| Module | Owns | May use | Status |
|---|---|---|---|
| Movement | Move/append/stop requests; authoritative planar translation, heading, velocity and movement state; open-space route guidance; movement-profile definitions | Godot engine APIs only | Implemented (open-space single-destination and player-route guidance) |

Movement is the only top-level gameplay module. Navigation guidance/route following and locomotion are distinct internal responsibilities, not independently exposed global modules. Scene-level mouse/camera input is composition glue, not a module.

Dependencies follow the one-way May-use map. Changes require an approved ticket stating the map change. Enforcement is review-only; no dependency tooling is installed or planned here.

## Movement boundary and authority

The command flow is caller → move-to or stop request → Movement's internal navigation guidance → locomotion → authoritative ship transform.

- Movement alone writes the ship's authoritative transform and owns its heading, velocity and movement state. External callers request movement rather than writing transforms.
- Navigation supplies path or heading guidance. Locomotion determines feasible continuous motion from that guidance and the ship's motion limits. Navigation does not issue separate stop, accelerate or rotate orders at intermediate vertices.
- Callers may read movement state/velocity and subscribe to significant notifications. No per-tick cross-system notifications are specified.
- Exact replacement, cancellation, arrival and failure notification semantics are **UNDECIDED**, except for the confirmed behavior below. API signatures, state names, notification contracts, queues and hidden states are not prescribed.
- Movement does not call visual, input, UI or future gameplay systems. Scene-level input/order adaptation is future composition glue, not a global orchestration module. Other gameplay systems enter the dependency map only through later approved tickets.

## Confirmed movement behavior

- From rest, translation and turning begin together. Movement accommodates forward, backward, lateral and diagonal directions. Short journeys may end before the hull faces the destination.
- While moving, turns are relatively wide and momentum-aware. Very sharp corners need not be followed exactly; the ship follows a continuous trajectory toward its destination.
- A near-opposite order, measured relative to **actual travel direction**, brakes the ship to rest before stationary movement begins. The threshold is 150° (provisional, `near_opposite_angle`).
- Acceleration and braking are gradual, with straightforward tunable rates. Heavy, momentous movement remains controlled; special stopping curves and a generic state-machine framework are not required.
- Arrival ends commanded rotation. There is no final alignment phase or requirement to finish yaw before arrival.
- Intermediate route vertices are not arrival targets. Route following must avoid waypoint-induced stop/start, heading resets and jitter, producing one continuous journey.

Movement uses `CharacterBody3D` in floating mode with one `move_and_slide()` per physics tick, separate bounded travel-direction and speed changes, stopping-distance braking, a pure-pursuit speed cap (`R = d / (2 sin θ)`) for near goals, polyline lookahead guidance for multi-point routes, and built-in physics interpolation. Obstacle pathfinding and collision response remain open.

## Reusable ship composition

The reusable ship scene `Ships/ship.tscn` separates authoritative movement from a visual/model child:

- The child consumes Movement's read-only motion/turn output; Movement never calls it.
- Only the child tilts visually. The authoritative root and collision never tilt; visual roll does not affect physical movement or navigation coordinates.
- Broad gradual maneuvers heel outward; sharper maneuvers bank inward. These are different maneuvers, not phases of one turn. The model straightens on straight travel.
- `Ships/ship_visual_bank.gd` on `Visual` implements this (Task #7): the class is fixed per order from Movement's initial turn deflection, and the roll is bounded-rate about the wrapper's local Z. Its values are provisional, in `ShipBankProfile`. No separate top-level visual module is introduced.

Shared function and appearance use one authoritative scene/script/resource. Ship differences use configuration rather than duplicated implementations; check existing assets before creating another shared definition. Per-instance runtime state must not modify shared resources.

The owner's placeholder is `Assets/Ships/Whitebox/Arrata_Frigate_001.glb`. Preserve the source unchanged, including its scale and pivot; import metadata is asset metadata, not a movement design decision.

## Data and validation

Per-ship tuning belongs in Godot `Resource` data assets, not code constants. Shared assets hold configuration only; runtime state belongs to the individual ship. Each tunable requires a default, unit and owner-approved range, including the future near-opposite angle and banking parameters. `MovementProfile` and `ShipBankProfile` hold the provisional values (see the inventory). Start conservatively and adjust in play.

The first playable work uses one ship in open space in the developing game scene, rather than multiple test scenes. The intended battle scale is tens of units; assess it with real combat later, without treating that intention as a measured performance target.

The rejected upfront alternative is a global command/orchestration framework, an independently deployable navigation system and custom simulation. They add coupling and complexity before confirmed users require them.

## Actually implemented inventory

- `project.godot`: Daung, main scene `res://Main/main.tscn`; the window opens maximized with `canvas_items`/`expand` stretch, so the view fills any window size or aspect; `physics/common/physics_interpolation=true`; otherwise engine defaults.
- **Movement** (`Movement/`):
  - `movement_profile.gd`: `MovementProfile` Resource with `max_speed` (8 m/s, 0–60), `acceleration` (6 m/s², 0.1–30), `braking` (10 m/s², 0.1–40), hull `turn_rate` (20 °/s, 1–120), `arrival_tolerance` (2 m, 0.1–10), `travel_turn_rate` (12 °/s, 1–90; about 90° in 7.5 s), `near_opposite_angle` (150°, 90–180) and `route_lookahead_distance` (25 m, 2–100). All values are provisional.
  - `Profiles/frigate_movement_profile.tres`: the shared frigate profile.
  - `ship_movement.gd`: `ShipMovement` (`CharacterBody3D`, floating mode), the single writer of planar position, velocity and yaw. Public: `move_to(world_position)`, `append_waypoint(world_position)`, `stop()`, `has_destination()`, `get_destination()`, `get_guidance_target()`, `get_turn_deflection()` and the built-in `velocity`. No signals.
  - **Route state (per ship):** `_route` holds the anchor (the ship position when the route was set) followed by the requested points; the last entry is the final destination. It is never empty: while idle it holds only the last final point. Multi-point routes also keep a monotonic `_route_progress` (arc length) and `_route_segment`, plus the derived `_guidance_target` and `_guidance_segment`.
  - `get_destination()` is the final point (the last one once idle; the origin at startup). `get_guidance_target()` is the point currently steered at; it equals `get_destination()` for single destinations and while idle.
  - `get_turn_deflection()` is read-only: the signed degrees from the actual travel direction to the goal, fixed when a moving-turn order is received, or to the next leg when route guidance crosses a vertex (positive = left turn). It is 0 for orders from rest, near-opposite orders, orders inside tolerance, and after arrival or `stop()`.
  - `move_to()` always replaces the whole route with `[ship position, point]` and classifies it once, against the actual planar velocity: at rest, a stationary start; at or above `near_opposite_angle`, brake to rest first; otherwise a moving turn.
  - `append_waypoint()` adds a point to the end of the active route and never re-classifies, restarts or brakes. A single-destination route is first re-anchored at the ship, so the aim stays continuous. With no active order (including after the 2 m arrival trigger) it acts as `move_to()`.
  - `stop()` clears the whole route, including pending points.
  - Each physics tick:
    - **Guidance:** a single destination is aimed at directly. A multi-point route projects the ship onto the segments that start within lookahead of its progress (progress never goes backward) and aims at the point `route_lookahead_distance` further along the route, clamped to the final destination. Intermediate points are never arrival targets.
    - **Travel direction:** set straight at the guidance point from rest; otherwise it rotates toward it by at most `travel_turn_rate`.
    - **Speed:** moves toward `min(max_speed, sqrt(2 · braking · (d + r)), ω · d / (2 sin θ))` at the acceleration or braking rate, where `d` is the distance to the guidance point and `r` the route length beyond it (0 for single destinations).
    - **Hull yaw:** turns toward the guidance point at `turn_rate`, independently of travel.
  - **Near-opposite pending:** one private flag, set at order receipt. The ship brakes along its current direction with no steering or yaw. At rest, the same order starts from rest, or completes if the ship is already within tolerance.
  - **Arrival:** once guidance has reached the final destination, entering `arrival_tolerance` completes the order and collapses the route to its final point. The ship then brakes to rest along its current travel with no yaw, and may coast past the destination without turning back (owner-accepted). An order issued inside tolerance is an arrival, never a reversal.
- **Ship** (`Ships/ship.tscn`): `ShipMovement` root with the frigate profile; a provisional `BoxShape3D` (5.9 × 3.2 × 20.3 m, derived from the model bounds) with no collision rules; `Visual` → the protected GLB instanced at identity (its bow already faces −Z).
  - `Visual` carries `ship_visual_bank.gd` (`ShipVisualBank`), which reads Movement only and writes only its own local Z rotation.
  - **Target roll:** level unless there is an order with a non-zero deflection, the ship is moving, and the course error to Movement's guidance target is at least `settle_angle`.
    - |deflection| below `sharp_turn_angle`: heel **outward** by `outward_heel`.
    - |deflection| at or above `sharp_turn_angle`: bank **inward** by `inward_bank`.
    - Mirrored by the turn's sign.
  - The roll moves toward the target at up to `roll_rate`.
  - `Ships/ship_bank_profile.gd` (`ShipBankProfile` Resource, all provisional): `outward_heel` (4°, 0–12), `inward_bank` (9°, 0–20), `sharp_turn_angle` (70°, 10–149), `roll_rate` (7 °/s, 0.5–30) and `settle_angle` (3°, 0.1–10).
  - `Ships/Profiles/frigate_bank_profile.tres` is the shared frigate bank profile.
- **Main scene** (`Main/main.tscn`): fixed camera at (50, 55, 60) pitched 45° down, light and environment, one ship at the origin, 2 m ring markers sharing one mesh and material at (100, 0, 0), the start location (0, 0, 0) and the route test points (60, 0, 0), (60, 0, −40) and (20, 0, −40), and `right_click_move_input.gd` (scene glue that projects right-clicks onto the Y = 0 plane and calls `move_to`, or `append_waypoint` with Shift held).
- Protected ship source and its import sidecar, unchanged.
- Not implemented: obstacle routing, route display, obstacles, collision or avoidance behavior, pitch or other visual motion, selection, UI, tests and export presets. No added dependencies.

## Undecided and deferred

**UNDECIDED (owner, later tickets):** exact order lifecycle and notifications; final route lookahead feel; route display/selection UI and route editing beyond append/replace; final speed/acceleration/braking/yaw balance; final near-opposite angle, travel turn rate and arrival/braking feel; final banking amplitude, threshold and response; obstacle/pathfinding and collision/avoidance behavior; and a performance target beyond the intended scale.

**DEFERRED:** hairpin, U-turn and dense zigzag routes, rapid route editing during braking, rapid chained retargets with banking, extreme visual tuning, other hull proportions, complex chained retargets, extreme tunings, obstacle routing, collision/avoidance, dense fleets, unusual maneuvers and vertical animation.
