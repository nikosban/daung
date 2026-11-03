# Architecture

## Status and units

This is the target design approved in Task #1. Task #3 implemented the first open-space Movement slice; the actual inventory is listed below.

**1 world unit = 1 metre.** Gameplay movement is horizontal on Godot's X/Z plane. Ordinary movement does not chase Y; any later vertical animation belongs to the model only.

Data assets use m/s for speed, m/s² for acceleration and braking, degrees/s for rotation, and metres for dimensions and distances.

## Module map

| Module | Owns | May use | Status |
|---|---|---|---|
| Movement | Move/append/stop requests; authoritative planar translation, heading, velocity and movement state; open-space route guidance; movement-profile definitions | Godot engine APIs only | Implemented (heading-and-throttle locomotion with planned maneuvers; player routes and static-obstacle detours; static destination resolution) |

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

Movement uses `CharacterBody3D` in floating mode with one `move_and_slide()` per physics tick and built-in physics interpolation. Since Task #25, locomotion is heading-and-throttle (replacing the Task #19–#23 desired-velocity chasing, thrust ellipse, pure-pursuit and bend caps and lookahead guidance): the hull turns toward a commanded heading with bounded yaw rate and yaw acceleration, the main engine changes speed along the bow, a small sideways slip fades, and directional thrusters perform short TRANSLATE moves and departures from rest. Each order gets one maneuver plan (corner speeds and turn-start points) whose corners pass a measured clearance gate, executed per tick by phases IDLE, TURN, CRUISE, BRAKE and TRANSLATE. Moving into a static obstacle ends the order with a hard stop (Task #11). Normal orders route around static obstacles through a Godot navigation path query (Task #13). A normal order whose point is off the navigation surface, unreachable or occupied by a static obstacle is resolved first to an approximately nearest reachable point where the hull fits (Task #15). Collision response to other bodies remains open.

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
  - `movement_profile.gd`: `MovementProfile` Resource (heading-and-throttle, Task #25; all values provisional, the owner's v2 proposal unless noted):
    - **Main engine:** `max_speed` (5 m/s, 1–20), `accel` (1.0 m/s², 0.1–10), `decel` (0.75 m/s², 0.1–10; also the rate used to anticipate braking).
    - **Yaw:** `yaw_rate` (10 °/s, 1–90), `yaw_accel` (10 °/s², 1–180).
    - **TURN:** `turn_speed_factor` (0.6, 0.1–1.0), `heading_tolerance` (5°, 1–30; TURN re-entry beyond 2×).
    - **Slip:** `slip_gain` (0.5, 0–1), `slip_decay` (0.25 m/s², 0–5).
    - **Thrusters:** `thruster_accel` (0.35 m/s², 0.05–5), `thruster_range` (15 m, 0–100), `translate_preference` (1.2, 1.0–2.0; new tunable, Task #25).
    - **Kept:** `arrival_tolerance` (2 m, 0.1–10), `near_opposite_angle` (150°, 90–180; kept provisionally while powered reverse is deferred), `path_simplify_epsilon` (0.1 m, 0.01–1; also the reachability tolerance of a path's end), `destination_search_spacing` (1 m, 0.25–5), `destination_search_budget` (32 samples per physics tick, 8–512).
    - **Clearance gate budgets (new, Task #25):** `clearance_check_budget` (64 queries per ship per physics tick, 16–1024), `rollout_step_budget` (240 simulated steps per ship per physics tick, 60–6000).
    - **Removed in Task #25** (their mechanisms are gone): `acceleration`, `braking`, `turn_rate`, `lateral_acceleration`, `precision_lateral_acceleration`, `precision_fade_speed`, `route_lookahead_distance`, `detour_lookahead_distance`, `detour_corner_tolerance`. `max_reverse` and `reverse_range` are not added (powered reverse deferred).
  - `Profiles/frigate_movement_profile.tres`: the shared frigate profile.
  - `maneuver_plan.gd`: `ManeuverPlan` (`RefCounted`, Movement-internal, not a module).
    - **`ManeuverPlan.Motion`:** the per-ship motion state (position, yaw, yaw velocity, `speed` ≥ 0 along the bow, `slip` toward the hull's right with |slip| ≤ speed, world `thrust_velocity`) and its one-tick `step()`. This is the only integrator. Velocity = bow · speed + right · slip + thrust_velocity.
      - **Yaw:** the yaw velocity approaches the fastest rate that can still stop at the commanded heading when slowed by `yaw_accel` per tick (the discrete form of `sqrt(2 · yaw_accel · error)`). It is bounded by `yaw_rate` and a per-tick yaw limit, and changes by at most `yaw_accel · dt`. With no commanded heading it eases to 0.
      - **Slip:** gains `slip_gain · speed · sin(Δyaw)` (the old velocity seen in the new hull frame), then decays at `slip_decay`.
      - **Speed and thrust:** speed moves toward its command at `accel` / `decel`; thrust_velocity moves toward its command at `thruster_accel`.
    - **Plan:** built per order (and per re-anchoring append). `append()` adds a point; the previous final point becomes a corner.
      - **Corner speed:** for each interior vertex with deflection φ above `heading_tolerance`, `min(turn_speed_factor · max_speed, yaw_rate · half the shorter adjacent leg / tan(φ / 2))`. Its turn-start trim is `(v / yaw_rate) · tan(φ / 2)` before the vertex. Smaller deflections are `NO_TURN`.
    - **Clearance gate:** each corner starts unchecked. Up to 4 attempts (the corner speed, then halved three times); each rolls out the same `Motion.step()` TURN from the turn-start point at that speed until the heading is within tolerance of the outgoing leg.
      - **Samples:** after 0.25 m of hull-corner rotation (at the hull bound radius), 1 m of travel or 60 steps, at most 200 per attempt.
      - **Queries per sample interval,** with the hull box enlarged by 0.25 m on X and Z, the ship's mask and the ship excluded:
        1. `intersect_shape` at the start pose: a static obstacle fails the attempt.
        2. `intersect_shape` of the axis-aligned box around both poses: every non-static body becomes a sweep exclusion; a full (32) result or a non-`CollisionObject3D` collider fails closed.
        3. `cast_motion` to the next pose with those exclusions: a safe fraction < 1 fails.
        
        The final pose gets an overlap query too.
      - **Outcome:** a passing attempt sets the corner speed and trim; if every attempt fails, the corner is `STOP` (stop-and-turn).
      - **Budgets:** work is spread over ticks within `clearance_check_budget` queries and `rollout_step_budget` steps, nearest corner first, resuming from the exact state.
      - **What it is:** a measured clearance gate for static bodies, not a guarantee. It checks only moving turns, not the rotation of a stop-and-turn from rest at the vertex.
  - `ship_movement.gd`: `ShipMovement` (`CharacterBody3D`, floating mode), the single writer of planar position, velocity and yaw.
    - **Public:** `move_to(world_position)`, `append_waypoint(world_position)`, `stop()`, `has_destination()`, `get_destination()`, `get_guidance_target()`, `get_turn_deflection()` and the built-in `velocity`.
    - **Read-only debug getters (Task #25, F3):** `get_phase_name()`, `get_commanded_heading()` (degrees of yaw, NAN when none), `get_heading()`, `get_commanded_speed()` (main engine, or the thruster target in TRANSLATE and departure TURNs), `get_speed()` (actual planar) and `get_slip()`.
    - No signals.
  - **Route state (per ship):** `_route` holds the anchor (the ship position when the route was set) followed by the route points; the last entry is the final destination. It is never empty: while idle it holds only the last final point.
    - `_leg` is the current leg (`_route[_leg]` → `_route[_leg + 1]`, the aim point), and `_plan` is the route's `ManeuverPlan`.
    - `_pending_order` / `_has_pending_order` hold the latest normal order until it starts; `_pending_waypoints` holds points appended meanwhile (outside navigation syncing). The destination search keeps its ring-0 point, start angle, limit and ring/sample position (`_search_*`).
    - `_hull_bound` is a vertical `CylinderShape3D` bounding the collision box at any yaw (radius 10.685 m, height 3.2 m for the frigate), derived in `_ready()` from the ship's `BoxShape3D` child. The box and its local transform are kept for the clearance gate.
  - `get_destination()` is the final point (the last one once idle; the origin at startup). `get_guidance_target()` is the current aim point (the end of the current leg), or the final point while idle.
  - `get_turn_deflection()` is read-only: the signed degrees from the actual travel direction to the first aim point, fixed when a moving order starts, or to the next leg at a planned corner's turn start (positive = left turn). It is 0 for orders from rest and near-opposite orders, and after arrival or `stop()`.
  - **Navigation readiness** (`_navigation_state`, through `NavigationServer3D` only, on the ship's world map): **syncing** while the map iteration is 0, any region on the map has iteration 0, or a synced enabled region with non-empty bounds is not yet merged (`map_get_closest_point_owner` invalid); **unavailable** once synced with no enabled region holding data (no region, an empty or missing mesh, or a disabled region); otherwise **ready**. No global async change and no `map_force_update()`.
  - `move_to()` is a normal order. It records the point as the pending order, replacing any earlier one together with its search and queued points. Nothing starts inside `move_to()`: the order is resolved at the start of a physics tick (hull checks query the physics space), from the first tick navigation is not syncing. Until the order starts or is declined, the previous order continues and the getters are unchanged (owner-approved). Resolution:
    - **Valid point:** with navigation ready, one `NavigationServer3D.query_path` from the ship to the point (`simplify_path`, `simplify_epsilon = path_simplify_epsilon`). The point is kept exactly when it is **on the navigation surface** (`map_get_closest_point` has the same XZ), the path **reaches** it (its end within `path_simplify_epsilon`, XZ) and the **hull fits** there. `arrival_tolerance` plays no part.
    - **Destination search** otherwise (off the surface, unreachable, occupied, or an empty path while ready). Ring 0 is the path's end (the nearest reachable navigation point), or `map_get_closest_point` when the path is empty. Ring k has radius `r0 + k · destination_search_spacing` around the point and `ceil(2π r / spacing)` samples; they start at ring 0's direction from the point (toward the ship if ring 0 is the point), alternate sides, and are snapped with `map_get_closest_point`. A sample is accepted when its distance from the point is within its ring radius, the hull fits there and a path from the ship's current position reaches it; the first accepted sample becomes the destination. At most `destination_search_budget` samples run per ship per tick; the rest continue in later ticks from the same position in the sequence, so the result does not depend on the budget. The search ends once a ring's radius exceeds the farthest XZ corner of the enabled navigation regions' bounds (`region_get_bounds`), and the order is declined. Placement is approximately nearest; pockets narrower than the spacing can be missed, so a declined order does not prove that no free space exists.
    - **Hull fit:** `intersect_shape` with `_hull_bound` at the point (the ship's collision mask, the ship excluded); only a `StaticBody3D` that is not an `AnimatableBody3D` counts, as for the hard stop. It is yaw-independent.
    - **Navigation unavailable:** no search. A point where the hull fits becomes the direct route `[ship, point]`, as before; an occupied point is declined.
    - **Route:** built from the path computed in the tick the destination is accepted, anchored at the ship's position in that tick. If the path has more than 2 points, the route is `[ship, interior path points flattened to the ship's Y, destination]` with zero-length points dropped; otherwise `[ship, destination]`. `get_destination()` returns the destination (the resolved point when the request moved).
    - **Declined:** the route ends as on `stop()` (the ship brakes to rest, replacing the previous order; owner-approved). No notification.
    - Points queued in `_pending_waypoints` are then appended through `append_waypoint()`, in order.
  - **Order start** (shared): replaces the whole route, builds its plan and classifies the order once against the actual velocity, with the first aim point as the goal:
    - **At rest:** a start from rest.
    - **At or above `near_opposite_angle` from travel:** BRAKE to rest, then a start from rest (no steering; the yaw velocity eases to 0).
    - **Otherwise a continuous moving order:** TURN when the heading error exceeds `heading_tolerance`, with a commanded speed latched once as `min(turn_speed_factor · speed, v_fit)`, where `v_fit = yaw_rate · d / (2 sin θ)` fits the circle through the aim point. Otherwise CRUISE.
    - **Inside tolerance:** an order issued inside `arrival_tolerance` is an arrival, never a reversal.
  - **Start from rest:**
    - **TRANSLATE:** a single-leg route within `thruster_range`, when `2 · sqrt(d / thruster_accel) ≤ translate_preference ×` the estimated turn-and-burn time (yaw profile plus accel/cruise/decel).
    - **Departure TURN:** when the heading error exceeds tolerance. The hull yaws and the thrusters push toward the aim point **on the same tick**, up to `turn_speed_factor · max_speed`, limited by thruster stopping distance. This is the Task #25 correction to v2, which would have rotated in place.
    - **CRUISE** otherwise.
  - **TURN → CRUISE** at `heading_tolerance`. After a departure the thrusters' forward component along the bow moves into `speed` (world velocity unchanged); any sideways or sternward component stays and fades at `thruster_accel`.
  - `append_waypoint()` never navigates. It adds a manual point to the end of the active route (the old final point becomes a planned and gated corner) and never re-classifies or restarts. A single-destination route is first re-anchored at the ship, with a new plan. While a normal order is pending and navigation is not syncing, the point is queued and appended once that order starts or is declined. With no active order (including after the 2 m arrival trigger), or while a normal order is pending during navigation syncing, it drops the pending order and starts a direct order to the point.
  - `stop()` clears the whole route, including pending points, a pending normal order, its destination search and queued points.
  - Each physics tick:
    - **Clearance gate:** the plan's gate advances within its budgets. A corner that passes after the ship is already past its turn-start point stays stop-and-turn.
    - **Legs:** a `NO_TURN` vertex is passed once within `arrival_tolerance` along the leg. A passed corner starts its TURN at its turn-start point, with commanded heading = the outgoing leg and commanded speed = the corner speed. A stop-and-turn or still-unchecked corner brakes to rest within `arrival_tolerance` of the vertex and then starts the next leg from rest (owner-approved Option A: an unchecked corner reached is executed as stop-and-turn).
    - **Phases:**
      - **TRANSLATE:** thrust toward the destination at `min(max_speed, sqrt(2 · thruster_accel · d))`, hull yawing toward it.
      - **TURN:** as above.
      - **CRUISE:** heading = bearing to the aim point; speed = `max_speed` limited by `sqrt(v_c² + 2 · decel · (distance to turn start))` for each planned corner and `sqrt(2 · decel · d)` for the final point or the next stop/unchecked corner. It re-enters TURN beyond `2 · heading_tolerance` with a freshly latched speed.
      - **BRAKE:** the label when a rest point is the binding limit and the ship is slowing; also near-opposite braking and resting at a stop corner.
    - **Yaw run-out:** while an order is active, |yaw velocity| ≤ `yaw_accel ·` the shortest time to the arrival trigger (`(sqrt(2aD) − sqrt(2a · arrival_tolerance)) / a`, `a = max(decel, thruster_accel)`, `D` = the remaining route length), so the rotation winds down before arrival.
    - **Step and move:** one `Motion.step()`, then `velocity` is set and `move_and_slide()` runs once.
  - **Arrival:** on the final leg, entering `arrival_tolerance` completes the order and collapses the route to its final point. The heading freezes on that tick (the yaw velocity is zeroed). The ship then brakes to rest at `decel`, slip and thrust fade, and it may coast past without turning back. `stop()` and declined orders end the same way, so the heading freezes immediately (owner contract).
  - **Blocked (static contact):** after the single `move_and_slide()`, if there is an active order and a slide collision's collider is a `StaticBody3D` (not an `AnimatableBody3D`) with the tick's commanded velocity pointing into its normal, the order ends through the same route-end path as arrival and the whole motion state (speed, slip, thrust) is zeroed: an immediate hard stop at the contact. A resting contact does not block an order away from it. Contacts with other body types keep the engine's default sliding; their behavior is undecided. No notification is emitted.
- **Ship** (`Ships/ship.tscn`): `ShipMovement` root with the frigate profile; a provisional `BoxShape3D` (5.9 × 3.2 × 20.3 m, derived from the model bounds) with no collision rules; `Visual` → the protected GLB instanced at identity (its bow already faces −Z).
  - `Visual` carries `ship_visual_bank.gd` (`ShipVisualBank`), which reads Movement only and writes only its own local Z rotation.
  - **Target roll:** level unless there is an order with a non-zero deflection, the ship is moving, and the course error to Movement's guidance target is at least `settle_angle`.
    - |deflection| below `sharp_turn_angle`: heel **outward** by `outward_heel`.
    - |deflection| at or above `sharp_turn_angle`: bank **inward** by `inward_bank`.
    - Mirrored by the turn's sign.
  - The roll moves toward the target at up to `roll_rate`.
  - `Ships/ship_bank_profile.gd` (`ShipBankProfile` Resource, all provisional): `outward_heel` (4°, 0–12), `inward_bank` (9°, 0–20), `sharp_turn_angle` (70°, 10–149), `roll_rate` (7 °/s, 0.5–30) and `settle_angle` (3°, 0.1–10).
  - `Ships/Profiles/frigate_bank_profile.tres` is the shared frigate bank profile.
- **Main scene** (`Main/main.tscn`): camera starting at (50, 55, 60) pitched 45° down with `camera_pan_zoom.gd` (Task #25 scene glue: middle-drag pans over XZ, the wheel zooms along the view axis at constant pitch between heights `min_height` 15 m and `max_height` 400 m, `zoom_step` 0.1 of the height per notch; exported on the node; never follows the ship), light and environment, one ship at the origin, 2 m ring markers sharing one mesh and material at (100, 0, 0), the start location (0, 0, 0) and the route test points (60, 0, 0), (60, 0, −40) and (20, 0, −40), `TestObstacle` (a temporary `StaticBody3D` collision test: a 6 m radius sphere shape and matching plain grey sphere mesh at (83, 0, 0), scene-owned resources, default layer/mask, group `navigation_source`; not asteroid art), `NavigationFloor` (an invisible `StaticBody3D` navigation source: `BoxShape3D` 800 × 1 × 800 m at (50, −0.5, 0) (Task #25; the navigable area is X −339.25…439.25, Z ±389.25), top at Y = 0, layer 2, mask 0, so it never touches the ship; group `navigation_source`), `NavigationRegion3D` (its navigation mesh is `Main/navigation_mesh.tres`, baked with Bake NavigationMesh (Task #25: rebaked for the 800 m floor with unchanged settings) from the static colliders in group `navigation_source` with collision mask 3: `agent_radius` 10.75 m, which covers the hull's 10.68 m corner radius; `agent_height` 7 m, above the sphere's 6 m, since the baker treats the sphere as hollow; `cell_size`/`cell_height` 0.25 m, engine defaults matching the map. Rebake after changing the obstacle, floor or these values), and `right_click_move_input.gd` (scene glue that projects right-clicks onto the Y = 0 plane and calls `move_to`, or `append_waypoint` with Shift held), and `MovementDebugOverlay` (`movement_debug_overlay.gd`, a `CanvasLayer` toggled by F3 that reads Movement only: phase, heading and commanded heading, speed and commanded speed, slip).
- Protected ship source and its import sidecar, unchanged.
- Not implemented: destination resolution or detours for Shift-appended legs, a player-facing indicator for a moved or declined destination, group orders, live replanning, dynamic obstacle navigation, route display, collision behavior beyond the static-contact stop, powered reverse, station keeping (HOLD), avoidance, pitch or other visual motion, selection, UI beyond the F3 debug readout, tests and export presets. No added dependencies.

## Undecided and deferred

**UNDECIDED (owner, later tickets):** exact order lifecycle and notifications; final slip, corner-speed and turn feel (including the single loop-back of close-range moving turns) and final camera bindings; route display/selection UI and route editing beyond append/replace; final speed/acceleration/braking/yaw balance; final near-opposite angle, travel turn rate and arrival/braking feel; final banking amplitude, threshold and response; automatic routing for Shift-defined legs, live replanning, final navigation clearance, avoidance, route-failure notifications and feedback for moved or declined destinations, impact feedback/damage, glancing-hit behavior beyond the provisional hard stop, collisions with ships and moving or dynamic bodies, and obstacle appearance; and a performance target beyond the intended scale.

**DEFERRED:** powered REVERSE (`max_reverse`, `reverse_range`), HOLD/station keeping, a public heading/speed/fleet API, order notifications, timed or dynamic replanning, fleet pacing, clearance checks for stop-and-turn rotation at a vertex, hairpin, U-turn and dense zigzag routes, rapid route editing during braking, rapid chained retargets with banking, extreme visual tuning, other hull proportions, complex chained retargets, extreme tunings, multiple or overlapping obstacles, narrow passages, multi-region navigation readiness and destination search across disconnected regions, path updates after geometry changes, destination resolution for dynamic occupancy and for group orders, avoidance, grazing-contact feel, dense obstacle fields, high-speed tunneling, dense fleets, unusual maneuvers and vertical animation.
