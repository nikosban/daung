# Architecture

## Status and units

This is the target design approved in Task #1. Task #27 (Movement v3, Task 1 of 4) replaced the earlier Movement implementation with a rewrite; the actual inventory is listed below.

**1 world unit = 1 metre.** Gameplay movement is horizontal on Godot's X/Z plane. Ordinary movement does not chase Y; any later vertical animation belongs to the model only.

Data assets use m/s for speed, m/s² for acceleration, s for times, and metres for dimensions and distances. **Thrust units** are m/s² × the dimensionless gameplay mass divisor, so thrust / mass gives m/s². Rotation units are added with rotation (Task 15).

## Module map

| Module | Owns | May use | Status |
|---|---|---|---|
| Movement | Move/stop requests; authoritative open-space position, one world planar velocity and yaw; pilot guidance and propulsion (internal); movement-profile definitions | Godot engine APIs only | Implemented (Movement v3 slice 1: arrival-steering pilot, main engine and directional thrusters, fixed heading) |

Movement is the only top-level gameplay module. Pilot guidance and propulsion are internal responsibilities, not independently exposed global modules. Since Task #27 Movement no longer owns path queries, route corners or destination resolution; they return only through later approved tickets. Scene-level mouse/camera input is composition glue, not a module.

Dependencies follow the one-way May-use map. Changes require an approved ticket stating the map change. Enforcement is review-only; no dependency tooling is installed or planned here.

## Movement boundary and authority

The command flow is caller → move-to or stop request → Movement's pilot → propulsion → authoritative ship transform.

- Movement alone writes the ship's authoritative transform and owns its heading and velocity. External callers request movement rather than writing transforms.
- Callers may read velocity and the read-only debug getters. No per-tick cross-system notifications are specified.
- Exact replacement, cancellation, arrival and failure notification semantics are **UNDECIDED** beyond the current behavior below. API signatures, state names, notification contracts, queues and hidden states are not prescribed.
- Movement does not call visual, input, UI or future gameplay systems. Other gameplay systems enter the dependency map only through later approved tickets.

## Earlier confirmed movement behavior

These owner decisions predate Movement v3. The current slice does **not** implement them (heading fixed, no routes, no near-opposite rule). Whether each still applies is for the Movement v3 tickets (Tasks 15–17) and later ones to state:

- From rest, translation and turning begin together. Movement accommodates forward, backward, lateral and diagonal directions. Short journeys may end before the hull faces the destination.
- While moving, turns are relatively wide and momentum-aware; the ship follows a continuous trajectory.
- A near-opposite order (150°, relative to actual travel) brakes to rest before stationary movement begins.
- Arrival ends commanded rotation; there is no final alignment phase.
- Intermediate route vertices are not arrival targets; route following avoids stop/start, heading resets and jitter.

## Movement v3 (Task #27)

Movement uses `CharacterBody3D` in floating mode with one `move_and_slide()` per physics tick and built-in physics interpolation. There is one world-space planar velocity (the built-in `velocity`, Y = 0) and one heading. No velocity channels are combined, no existing velocity is rotated, and there is no mode or phase state.

Each physics tick:

1. **Arrival:** an active order completes when the ship is within `arrival_tolerance` of its destination **and** its planar speed is at most `arrival_speed_tolerance`. Being inside the tolerance at higher speed is not arrival.
2. **Desired velocity** (arrival steering, Reynolds): with an active order, toward the destination at `min(max_speed, sqrt(2 · a_t · d))`, where `d` is the planar distance and `a_t = thruster_strength / mass` (the thrusters are the only brake). Without an order (after arrival or `stop()`) it is zero. It is never assigned to `velocity`.
3. **Requested acceleration:** `(desired − velocity) / pilot_response_time`.
4. **Main engine:** along the current bow only, `clamp(requested · bow, 0, main_acceleration)`. It is 0 whenever `velocity · bow < 0`, so it never reduces the current speed (non-negative work).
5. **Thrusters:** the remainder `requested − bow · main`, limited to magnitude `a_t`. That one vector budget covers braking and lateral/forward crabbing together. With the frigate values, main and thrusters together give up to 24 m/s² forward (owner-approved Option A).
6. **Integration:** `velocity += (bow · main + thrusters) · delta`, planar magnitude hard-clamped to `max_speed`, then `move_and_slide()`.

The heading is held fixed in this slice (yaw is never written). There is no position hold, snap or speed reset: after arrival or `stop()` the ship brakes toward zero velocity wherever it is. Overshoot can occur. Collision behavior is not promised.

## Reusable ship composition

The reusable ship scene `Ships/ship.tscn` separates authoritative movement from a visual/model child `Visual` (a plain `Node3D` wrapper). Only that child may ever tilt visually; the authoritative root and collision never tilt.

Banking is **deferred**: Task #27 deleted the former `ShipVisualBank` script and `ShipBankProfile` resource, since they read Movement's removed API (Git history, `main` at a174d22).

Shared function and appearance use one authoritative scene/script/resource. Ship differences use configuration rather than duplicated implementations; check existing assets before creating another shared definition. Per-instance runtime state must not modify shared resources.

The owner's placeholder is `Assets/Ships/Whitebox/Arrata_Frigate_001.glb`. Preserve the source unchanged, including its scale and pivot; import metadata is asset metadata, not a movement design decision.

## Data and validation

Per-ship tuning belongs in Godot `Resource` data assets, not code constants. Shared assets hold configuration only; runtime state belongs to the individual ship. Each tunable requires a default, unit and owner-approved range. `MovementProfile` holds the provisional values (see the inventory). Start conservatively and adjust in play.

The first playable work uses one ship in open space in the developing game scene, rather than multiple test scenes. The intended battle scale is tens of units; assess it with real combat later, without treating that intention as a measured performance target.

The rejected upfront alternative is a global command/orchestration framework, an independently deployable navigation system and custom simulation. They add coupling and complexity before confirmed users require them.

## Actually implemented inventory

- `project.godot`: Daung, main scene `res://Main/main.tscn`; the window opens maximized with `canvas_items`/`expand` stretch; `physics/common/physics_interpolation=true`; otherwise engine defaults.
- **Movement** (`Movement/`):
  - `movement_profile.gd`: `MovementProfile` Resource (Task #27; all values provisional placeholders):

    | Value | Default | Unit | Range |
    |---|---|---|---|
    | `mass` | 5 | gameplay mass divisor | 1–20 |
    | `main_acceleration` | 12 | m/s² (not divided by mass) | 0.1–100 |
    | `thruster_strength` | 60 | thrust units (÷ mass = 12 m/s²) | 1–600 |
    | `max_speed` | 20 (owner trial, was 50) | m/s | 1–150 |
    | `pilot_response_time` | 0.25 (owner trial, was 0.5) | s | 0.1–3 |
    | `arrival_tolerance` | 2 | m | 0.25–10 |
    | `arrival_speed_tolerance` | 0.5 | m/s | 0.05–5 |

  - `Profiles/frigate_movement_profile.tres`: the shared frigate profile (the defaults above).
  - `ship_movement.gd`: `ShipMovement` (`CharacterBody3D`, floating mode), the single writer of planar position, velocity and yaw.
    - **Public:** `move_to(world_position)` (replaces any order; Y ignored; velocity carries over), `stop()` and the built-in `velocity`.
    - **Read-only getters (F3):** `has_order()`, `get_destination()`, `get_heading()` (degrees of yaw), `get_main_command()` (m/s²) and `get_thruster_command()` (world vector, m/s²).
    - **State (per ship):** destination, order flag and the last main/thruster commands. No signals.
    - **Profile guard:** a missing profile or any value ≤ 0 logs an error in `_ready()` and disables physics processing, so the ship does not move.
- **Ship** (`Ships/ship.tscn`): `ShipMovement` root with the frigate profile; a provisional `BoxShape3D` (5.9 × 3.2 × 20.3 m) on the default collision layer/mask; `Visual` (plain `Node3D`) → the protected GLB instanced at identity (its bow faces −Z).
- **Main scene** (`Main/main.tscn`):
  - **Camera:** starting at (50, 55, 60), pitched 45° down, with `camera_pan_zoom.gd` (scene glue: middle-drag pans over XZ; the wheel zooms between heights `min_height` 15 m and `max_height` 400 m, `zoom_step` 0.1 of the height per notch; never follows the ship).
  - Light and environment.
  - **Ship:** one at the origin, with the instance override **`collision_mask = 0`** (Task #27 test isolation; `ship.tscn` keeps its default).
  - **Markers:** 2 m rings sharing one mesh and material at (100, 0, 0), (0, 0, 0), (60, 0, 0), (60, 0, −40) and (20, 0, −40).
  - **Inert fixtures:** `TestObstacle` (a 6 m `StaticBody3D` sphere at (83, 0, 0); the ship passes through it), `NavigationFloor` (800 × 800 m, layer 2, mask 0) and `NavigationRegion3D` with `Main/navigation_mesh.tres`. Movement no longer queries them; they are unreferenced fixtures kept for later tickets.
  - **Scene glue:** `right_click_move_input.gd` (projects right-clicks onto the Y = 0 plane and calls `move_to`; Shift + right-click does nothing) and `MovementDebugOverlay` (`movement_debug_overlay.gd`, a `CanvasLayer` toggled by F3 that reads Movement only: speed, velocity, heading, main command, thruster command, destination and order state).
- Protected ship source and its import sidecar, unchanged.
- Not implemented: rotation, retro availability, reaction delay, routes and waypoints, navigation and detours, destination resolution, avoidance, collision response, banking, group orders, selection, UI beyond F3, tests and export presets. No added dependencies.

## Undecided and deferred

**UNDECIDED (owner, later tickets):** exact order lifecycle and notifications; final speed, acceleration and thrust balance and arrival feel; whether the earlier confirmed behaviors (above) carry into Movement v3; routes, navigation, avoidance and their feedback; collision behavior with any body; banking; final camera bindings; and a performance target beyond the intended scale.

**DEFERRED:** rotation through the same force model (Task 15), retro-thruster availability (Task 16), reaction delays (Task 17), routes, navigation and detours, collision response, banking, HOLD/station keeping, a public heading/speed/fleet API, order notifications, and QA of high-speed tight loops, corners, obstacles, routes, negative or inverted tuning, and multi-ship scale.
