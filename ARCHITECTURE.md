# Architecture

## Status and units

This is the target design approved in Task #1. Task #3 implemented the first open-space Movement slice; the actual inventory is listed below.

**1 world unit = 1 metre.** Gameplay movement is horizontal on Godot's X/Z plane. Ordinary movement does not chase Y; any later vertical animation belongs to the model only.

Data assets use m/s for speed, m/s² for acceleration and braking, degrees/s for rotation, and metres for dimensions and distances.

## Module map

| Module | Owns | May use | Status |
|---|---|---|---|
| Movement | Move/stop requests; authoritative planar translation, heading, velocity and movement state; movement-profile definitions | Godot engine APIs only | Implemented (direct open-space guidance only) |

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
- A near-opposite order, measured relative to **actual travel direction**, brakes the ship to rest before stationary movement begins. The near-opposite angle threshold is a future owner tuning decision.
- Acceleration and braking are gradual, with straightforward tunable rates. Heavy, momentous movement remains controlled; special stopping curves and a generic state-machine framework are not required.
- Arrival ends commanded rotation. There is no final alignment phase or requirement to finish yaw before arrival.
- Intermediate route vertices are not arrival targets. Route following must avoid waypoint-induced stop/start, heading resets and jitter, producing one continuous journey.

Task #3 uses `CharacterBody3D` in floating mode, bounded `move_toward` velocity changes with stopping-distance braking, and built-in physics interpolation. Obstacle pathfinding, collision response and moving-retarget techniques remain open.

## Reusable ship composition

The reusable ship scene `Ships/ship.tscn` separates authoritative movement from a visual/model child:

- The child consumes Movement's read-only motion/turn output; Movement never calls it.
- Only the child tilts visually. The authoritative root and collision never tilt; visual roll does not affect physical movement or navigation coordinates.
- Broad gradual maneuvers heel outward; sharper maneuvers bank inward. These are different maneuvers, not phases of one turn. The model straightens on straight travel.
- Banking thresholds, angles, intensity and response curves are **UNDECIDED**. No separate top-level visual module is introduced.

Shared function and appearance use one authoritative scene/script/resource. Ship differences use configuration rather than duplicated implementations; check existing assets before creating another shared definition. Per-instance runtime state must not modify shared resources.

The owner's placeholder is `Assets/Ships/Whitebox/Arrata_Frigate_001.glb`. Preserve the source unchanged, including its scale and pivot; import metadata is asset metadata, not a movement design decision.

## Data and validation

Per-ship tuning belongs in Godot `Resource` data assets, not code constants. Shared assets hold configuration only; runtime state belongs to the individual ship. Each tunable requires a default, unit and owner-approved range, including the future near-opposite angle and banking parameters. `MovementProfile` holds the five provisional Task #3 values (see the inventory). Start conservatively and adjust in play.

The first playable work uses one ship in open space in the developing game scene, rather than multiple test scenes. The intended battle scale is tens of units; assess it with real combat later, without treating that intention as a measured performance target.

The rejected upfront alternative is a global command/orchestration framework, an independently deployable navigation system and custom simulation. They add coupling and complexity before confirmed users require them.

## Actually implemented inventory

- `project.godot`: Daung, main scene `res://Main/main.tscn`; the window opens maximized with `canvas_items`/`expand` stretch, so the view fills any window size or aspect; `physics/common/physics_interpolation=true`; otherwise engine defaults.
- **Movement** (`Movement/`):
  - `movement_profile.gd`: `MovementProfile` Resource with `max_speed` (10 m/s, 0–60), `acceleration` (6 m/s², 0.1–30), `braking` (10 m/s², 0.1–40), `turn_rate` (35 °/s, 1–120) and `arrival_tolerance` (2 m, 0.1–10). All values are provisional.
  - `Profiles/frigate_movement_profile.tres`: the shared frigate profile.
  - `ship_movement.gd`: `ShipMovement` (`CharacterBody3D`, floating mode), the single writer of planar position, velocity and yaw. Public: `move_to(world_position)`, `stop()`, `has_destination()`, `get_destination()` and the built-in `velocity`. No signals.
  - Each physics tick, the planar velocity moves toward `direction × min(max_speed, sqrt(2 · braking · distance))` at the acceleration or braking rate. Yaw turns toward the destination at `turn_rate`, independently of translation. Entering arrival tolerance clears the destination; the ship then brakes to rest without further rotation. Orders inside tolerance are ignored.
- **Ship** (`Ships/ship.tscn`): `ShipMovement` root with the frigate profile; a provisional `BoxShape3D` (5.9 × 3.2 × 20.3 m, derived from the model bounds) with no collision rules; `Visual` → the protected GLB instanced at identity (its bow already faces −Z).
- **Main scene** (`Main/main.tscn`): fixed camera at (50, 55, 60) pitched 45° down, light and environment, one ship at the origin, a 2 m ring marker at (100, 0, 0), and `right_click_move_input.gd` (scene glue that projects right-clicks onto the Y = 0 plane and calls `move_to`).
- Protected ship source and its import sidecar, unchanged.
- Not implemented: designed moving retarget or reversal, routing, obstacles, collision or avoidance behavior, banking, selection, UI, tests and export presets. No added dependencies.

## Undecided and deferred

**UNDECIDED (owner, later tickets):** exact order lifecycle and notifications; final speed/acceleration/braking/yaw balance; near-opposite angle and low-speed travel-direction classification; arrival/braking feel; banking parameters; obstacle/pathfinding and collision/avoidance behavior; and a performance target beyond the intended scale.

**DEFERRED:** designed moving retarget and near-opposite reversal (Task 3), banking (Task 4), obstacle routing, collision/avoidance, dense fleets, unusual maneuvers and vertical animation.
