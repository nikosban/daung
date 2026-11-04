# Architecture

## Status and units

This is the target design approved in Task #1. Task #27 (Movement v3, Task 1 of 4) replaced the earlier Movement implementation with a rewrite, and Task #28 (Task 2 of 4) added speed-dependent powered turning; the actual inventory is listed below.

**1 world unit = 1 metre.** Gameplay movement is horizontal on Godot's X/Z plane. Ordinary movement does not chase Y; any later vertical animation belongs to the model only.

Data assets use m/s for speed, m/s² for acceleration, s for times, and metres for dimensions and distances. **Thrust units** are m/s² × the dimensionless gameplay mass divisor, so thrust / mass gives m/s². Angles are in degrees in data and debug output (radians internally). **Turn-authority units** are °/s² × the mass divisor, so turn_authority / mass gives °/s².

## Module map

| Module | Owns | May use | Status |
|---|---|---|---|
| Movement | Move/stop requests; authoritative open-space position, one world planar velocity and yaw; pilot guidance and propulsion (internal); movement-profile definitions | Godot engine APIs only | Implemented (Movement v3 slices 1–2: arrival-steering pilot, main engine, directional thrusters, speed-dependent powered turning sharing the thruster capacity) |

Movement is the only top-level gameplay module. Pilot guidance and propulsion are internal responsibilities, not independently exposed global modules. Since Task #27 Movement no longer owns path queries, route corners or destination resolution; they return only through later approved tickets. Scene-level mouse/camera input is composition glue, not a module.

Dependencies follow the one-way May-use map. Changes require an approved ticket stating the map change. Enforcement is review-only; no dependency tooling is installed or planned here.

## Movement boundary and authority

The command flow is caller → move-to or stop request → Movement's pilot → propulsion → authoritative ship transform.

- Movement alone writes the ship's authoritative transform and owns its heading and velocity. External callers request movement rather than writing transforms.
- Callers may read velocity and the read-only debug getters. No per-tick cross-system notifications are specified.
- Exact replacement, cancellation, arrival and failure notification semantics are **UNDECIDED** beyond the current behavior below. API signatures, state names, notification contracts, queues and hidden states are not prescribed.
- Movement does not call visual, input, UI or future gameplay systems. Other gameplay systems enter the dependency map only through later approved tickets.

## Earlier confirmed movement behavior

These owner decisions predate Movement v3. Task #28 superseded the near-opposite rule (no reversal threshold) and implements turning from rest only through speed (no turning at exactly zero speed); arrival ends commanded rotation. Routes are not implemented. Whether each still applies is for the Movement v3 tickets (Tasks 15–17) and later ones to state:

- From rest, translation and turning begin together. Movement accommodates forward, backward, lateral and diagonal directions. Short journeys may end before the hull faces the destination.
- While moving, turns are relatively wide and momentum-aware; the ship follows a continuous trajectory.
- A near-opposite order (150°, relative to actual travel) brakes to rest before stationary movement begins.
- Arrival ends commanded rotation; there is no final alignment phase.
- Intermediate route vertices are not arrival targets; route following avoids stop/start, heading resets and jitter.

## Movement v3 (Tasks #27 and #28)

Movement uses `CharacterBody3D` in floating mode with one `move_and_slide()` per physics tick and built-in physics interpolation. There is one world-space planar velocity (the built-in `velocity`, Y = 0) and one heading. No velocity channels are combined, no existing velocity is rotated, and there is no mode or phase state. The only rotational state is one per-ship turn rate and the current order's course heading.

Each physics tick (everything read at the start of the tick, including the bow):

1. **Arrival:** an active order completes when the ship is within `arrival_tolerance` of its destination **and** its planar speed is at most `arrival_speed_tolerance`. Being inside the tolerance at higher speed is not arrival.
2. **Desired velocity** (arrival steering, Reynolds): with an active order, toward the destination at `min(max_speed, sqrt(2 · a_t · d))`, where `d` is the planar distance and `a_t = thruster_strength / mass` (the thrusters are the only brake). Without an order (after arrival or `stop()`) it is zero. It is never assigned to `velocity`.
3. **Requested acceleration:** `(desired − velocity) / pilot_response_time`.
4. **Main engine:** along the current bow only, `clamp(requested · bow, 0, main_acceleration)`. It is 0 whenever `velocity · bow < 0`, so it never reduces the current speed (non-negative work).
5. **Planar demand:** `t_req = requested − bow · main`, as a fraction `f_t = min(|t_req| / a_t, 1)`.
6. **Turning demand:** rated authority `α_max = (turn_authority / mass) × rudder_curve(speed / max_speed)` and turn-rate limit `ω_max = max_turn_rate_at_max_speed × rudder_curve(speed / max_speed) / rudder_curve(1)`, both from the **actual** start-of-tick speed (both 0 at rest). The target is the order's **course heading**, set once by `move_to()` from the ship toward the destination (none for a zero-length order); positional correction after an overshoot never changes it, and a new order replaces it. With an active order, a course and `α_max > 0`, with the shortest error `e`, the wanted rate is `sign(e) · min(sqrt(2 · α_max · |e|), |e| / delta, ω_max)` (braking-distance rule; the `|e| / delta` term is only a numerical aid, and the heading can still cross the target). The request `α_req = (wanted − rate) / delta` gives `f_r = min(|α_req| / α_max, 1)`. Otherwise `f_r = 0` and the turn rate is set to 0: rotation does not persist without powered turning (intentional non-Newtonian rule).
7. **Shared capacity:** if `f_t + f_r > 1`, both are scaled by `1 / (f_t + f_r)` (owner-approved proportional sharing). At full demand on both, the thrusters give 6 m/s² and turning half its rated authority. The main engine is outside this capacity.
8. **Integration:** `rate = clamp(rate + α · delta, −ω_max, ω_max)` (when the limit contracts faster than the authority can slow the turn, the rate is clamped, never the heading); `velocity += (bow · main + thrusters) · delta`, planar magnitude hard-clamped to `max_speed`; `yaw += rate · delta`; then `move_and_slide()`.

Yaw never rotates the velocity. The speed-linked rate limit is the only yaw-rate cap (owner-approved trial, PR #32); there is no heading snap or final alignment. There is no position hold, snap or speed reset: after arrival or `stop()` the ship brakes toward zero velocity wherever it is. Overshoot can occur. Collision behavior is not promised.

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
  - `movement_profile.gd`: `MovementProfile` Resource (Tasks #27 and #28; all values provisional placeholders; script defaults equal the frigate profile, the curve lives only in the `.tres`):

    | Value | Default | Unit | Range |
    |---|---|---|---|
    | `mass` | 5 | gameplay mass divisor | 1–20 |
    | `main_acceleration` | 12 | m/s² (not divided by mass) | 0.1–100 |
    | `thruster_strength` | 60 | thrust units (÷ mass = 12 m/s²) | 1–600 |
    | `max_speed` | 15 (owner trial 2) | m/s | 1–150 |
    | `pilot_response_time` | 0.25 (owner trial) | s | 0.1–3 |
    | `arrival_tolerance` | 2 | m | 0.25–10 |
    | `arrival_speed_tolerance` | 0.5 | m/s | 0.05–5 |
    | `turn_authority` | 120 (Task #28) | turn-authority units (÷ mass = 24°/s² at multiplier 1) | 1–1000 |
    | `max_turn_rate_at_max_speed` | 60 (PR #32 trial) | °/s (scaled by the normalized rudder curve: 0 at rest, 40 at half speed) | 1–180 |
    | `rudder_curve` | Godot `Curve`, linear (0,0), (0.5,1), (1,1.5) (Task #28) | x: speed / max_speed; y: multiplier | x 0–1, y 0–2 |

  - `Profiles/frigate_movement_profile.tres`: the shared frigate profile (the defaults above).
  - `ship_movement.gd`: `ShipMovement` (`CharacterBody3D`, floating mode), the single writer of planar position, velocity and yaw.
    - **Public:** `move_to(world_position)` (replaces any order; Y ignored; velocity carries over), `stop()` and the built-in `velocity`.
    - **Read-only getters (F3):** `has_order()`, `get_destination()`, `get_heading()` (degrees of yaw), `get_target_heading()` (the order's course), `get_turn_rate()` (°/s), `get_turn_rate_limit()` (°/s), `get_turn_acceleration()` (applied, °/s²), `get_rudder_multiplier()`, `get_shared_scale()`, `get_main_command()` (m/s²) and `get_thruster_command()` (world vector, m/s²).
    - **State (per ship):** destination, order flag, course heading, turn rate and the last tick's commands and turning values. No signals.
    - **Profile guard:** a missing profile, a missing rudder curve, a rudder curve ≤ 0 at full speed or any value ≤ 0 logs an error in `_ready()` and disables physics processing, so the ship does not move.
- **Ship** (`Ships/ship.tscn`): `ShipMovement` root with the frigate profile; a provisional `BoxShape3D` (5.9 × 3.2 × 20.3 m) on the default collision layer/mask; `Visual` (plain `Node3D`) → the protected GLB instanced at identity (its bow faces −Z).
- **Main scene** (`Main/main.tscn`):
  - **Camera:** starting at (50, 55, 60), pitched 45° down, with `camera_pan_zoom.gd` (scene glue: middle-drag pans over XZ; the wheel zooms between heights `min_height` 15 m and `max_height` 400 m, `zoom_step` 0.1 of the height per notch; never follows the ship).
  - Light and environment.
  - **Ship:** one at the origin, with the instance override **`collision_mask = 0`** (Task #27 test isolation; `ship.tscn` keeps its default).
  - **Markers:** 2 m rings sharing one mesh and material at (100, 0, 0), (0, 0, 0), (60, 0, 0), (60, 0, −40) and (20, 0, −40).
  - **Inert fixtures:** `TestObstacle` (a 6 m `StaticBody3D` sphere at (83, 0, 0); the ship passes through it), `NavigationFloor` (800 × 800 m, layer 2, mask 0) and `NavigationRegion3D` with `Main/navigation_mesh.tres`. Movement no longer queries them; they are unreferenced fixtures kept for later tickets.
  - **Scene glue:** `right_click_move_input.gd` (projects right-clicks onto the Y = 0 plane and calls `move_to`; Shift + right-click does nothing) and `MovementDebugOverlay` (`movement_debug_overlay.gd`, a `CanvasLayer` toggled by F3 that reads Movement only: speed, velocity, heading, course heading, turn rate and its limit, applied angular acceleration, rudder multiplier, shared-capacity scale, main command, thruster command, destination and order state).
- Protected ship source and its import sidecar, unchanged.
- Not implemented: retro availability, reaction delay, routes and waypoints, navigation and detours, destination resolution, avoidance, collision response, banking, group orders, selection, UI beyond F3, tests and export presets. No added dependencies.

## Undecided and deferred

**UNDECIDED (owner, later tickets):** exact order lifecycle and notifications; final speed, acceleration and thrust balance and arrival feel; whether the earlier confirmed behaviors (above) carry into Movement v3; routes, navigation, avoidance and their feedback; collision behavior with any body; banking; final camera bindings; and a performance target beyond the intended scale.

**DEFERRED:** retro-thruster availability (Task 16), reaction delays (Task 17), routes, navigation and detours, collision response, banking, HOLD/station keeping, a public heading/speed/fleet API, order notifications, and QA of high-speed tight loops, corners, obstacles, routes, negative or inverted tuning, pathological fast retargets, extreme rudder-curve shapes, and multi-ship scale.
