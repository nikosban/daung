# Architecture

The current shape of the game's code. Changed only through tickets that
state a map change; the agent updates this file in the same pull request.

## Units

1 unit = [1 metre]. Owner numbers are in units unless stated otherwise.
Confirmation of the bracketed value is UNDECIDED (owner).

## Modules

| Module | Owns | May use |
|---|---|---|
| Core | Shared data types, events, data asset definitions | — |
| Movement | Ship orders, navigation, route following, avoidance, locomotion, collision and authoritative movement state | Core |

Movement's internal responsibilities (below) are not top-level modules.
Future modules (for example commands or fleets) may use Movement only after
an approved map change.

## Rules

- Dependencies point one way, exactly as "May use" lists. A new entry is a
  map change and needs an approved ticket.
- A module calls only the modules it may use; it notifies others through
  events.
- Tuning values live in data assets (Godot `Resource`), never as
  constants in code.
- Every shared definition has one authoritative source (see the reusability
  policy in `AGENTS.md`).

## Enforcement

Review only. Godot has no mechanism that rejects undeclared dependencies,
and the project has none installed.

## Movement

Status: Tasks 1b–1d implemented — orders, validated static routes per
clearance class, waypoint following, locomotion, planar collision through one
`move_and_collide()` commit, all four states and both events. Avoidance (1e)
is still planned; engine mechanisms named for it are candidate choices, not
verified behavior.

### Files

| File | Role |
|---|---|
| `Movement/movement_controller.gd` | `MovementController`: the controller, route request, route follower, locomotion and collision commit |
| `Movement/movement_profile.gd` | `MovementProfile` `Resource` class |
| `Movement/navigation_clearance.gd` | `NavigationClearance` `Resource` class: footprint reference and margin |
| `Movement/static_navigation.gd` | `StaticNavigation` node: scene-owned maps per clearance, readiness, validated `find_route()` |
| `Movement/clearance_region.gd` | `ClearanceRegion` (`NavigationRegion3D`): baked region for one clearance class; child of `StaticNavigation` |
| `Movement/Profiles/*_clearance.tres` | One `NavigationClearance` per ship type |
| `Movement/Check/routing_check.tscn` | Permanent routing check: wall + Reachable marker, enclosure + Unreachable marker |
| `Movement/Check/routing_check_frigate_navmesh.tres` | Baked frigate navmesh for the routing check (`agent_radius` 12.5) |
| `Movement/ship.tscn` | Reusable ship: `CharacterBody3D` root with the controller, `Footprint` collision shape and replaceable `Visual` child holding the model |
| `Movement/Profiles/*_movement.tres` | One `MovementProfile` per ship type |
| `Movement/Profiles/*_footprint.tres` | One `CylinderShape3D` footprint per ship type |
| `Movement/Check/movement_check.gd` | Shared check script: number keys select a ship, right-click `move_to`, `C` `stop` |
| `Movement/Check/movement_check.tscn` | Permanent MovementCheck scene: one ship in open space |
| `Movement/Check/collision_check.tscn` | Permanent collision check: Lane A (ship 1 → obstacle), Lane B (ship 2 → ship 3) |
| `Movement/Check/obstacle.tscn` | Check-scene obstacle fixture (`StaticBody3D` box); not a game obstacle system |

### Physics layers

Numbered layers, set in scenes; `project.godot` names none.

| Layer | Used by | Mask |
|---|---|---|
| 1 | Ships | 1 + 2 (ships and obstacles) |
| 2 | Static obstacles | none |

### Shape

- One reusable ship movement composition, used by every ship type. Ship
  differences are expressed only through `Resource` data assets; no
  duplicated movement scripts and no base-class hierarchy.
- The body is a kinematic `CharacterBody3D`. Motion is authoritative on the
  flat **XZ** plane; vertical motion is excluded. The 3D model is visual.
- Heading (yaw) and velocity direction may differ: a ship may translate
  sideways while its yaw turns gradually toward the controlled target.

### Public interface

Other systems use Movement only through this boundary:

| Member | Kind | Meaning |
|---|---|---|
| `move_to(world_position)` | order | Replaces any active order with a new destination. |
| `stop()` | order | Cancels the active order. |
| `get_state()`, `get_destination()`, `get_desired_direction()` | read-only | State is `Idle`, `Moving`, `Blocked` or `Arrived` (see States). |
| `get_route()`, `get_waypoint_index()` | read-only | Current route and waypoint progress (debug display). |
| `order_completed` | event | Emitted once when the active order arrives. |
| `order_failed` | event | Emitted once when the active order's route is unreachable. |

Events notify upward on significant changes only; no per-tick signals.
Movement does not depend on combat, UI or fleet code.

### Authority

- One movement controller per ship owns the order, actual position, yaw,
  velocity and state. No other system writes the ship's transform.
- Exactly one translation is applied per physics tick:
  - **1b:** the controller is the single direct translation writer, in
    unobstructed space (no collision yet).
  - **1c onward:** that writer is replaced by **one native
    `move_and_collide()` call**, which itself moves the body. The
    controller then reads the actual post-collision displacement (measured
    transform difference) and never applies that displacement again.
  - **1e onward:** with avoidance enabled, still only one movement update
    per physics tick (see Physics tick).
- State and arrival come from actual displacement, never from intended or
  preferred velocity.

### Responsibilities

Run in this order each tick. Each is introduced by the ticket shown.

| # | Responsibility | Owns | Input | Output | Ticket |
|---|---|---|---|---|---|
| 1 | Static Navigation | Nothing on the ship; uses shared route maps | Start, original requested goal, clearance class | Waypoint route, or explicit unreachable failure | 1d |
| 2 | Route Follower | Waypoint progress | Route, actual position, movement limits | Preferred direction and speed | 1d |
| 3 | Avoidance | Nothing; never writes position | Preferred movement, nearby-ship state, locomotion limits | Corrected desired movement (advisory) | 1e |
| 4 | Locomotion | Nothing persistent beyond the controller's state | Corrected request, actual velocity and yaw, `MovementProfile`, delta | Feasible translational velocity and controlled yaw | 1b |
| 5 | Planar Collision | Nothing; engine moves the body | Proposed displacement, footprint, world geometry | Body moved once; collision/contact and actual travel | 1c |
| 6 | Controller state/commit | Order, actual velocity, yaw, state, events | Actual travel and collision result | Reconciled velocity, state, events | 1b (extended in 1c–1e) |

Locomotion (1b): the requested velocity is limited to the hull's current
forward and lateral axes, with no commanded reverse (a target behind is
reached by turning and sliding sideways). Actual velocity then moves toward
that request at `acceleration` (speeding up) or `braking` (slowing down) and
is never clamped afterwards, so a yaw change cannot snap speed. Yaw turns
toward the facing reference at `yaw_rate`: the desired direction for direct
routes, the route's direction for routed ones (see Route Follower).

Route Follower (1d), all planar (XZ) from the actual position; Y is never
chased:

- **Progress:** owns the current segment index (`_waypoint`, the segment's end
  point). It advances only once the ship's projection along the segment has
  passed its end, and never goes back, so a passed corner is never chased.
- **Translation (pure pursuit):** moves toward the point `waypoint_tolerance`
  ahead **along the route's arc length** from the ship's projection on the
  current segment. The aim point slides continuously past corners, and this
  direction also corrects cross-track drift.
- **Facing:** the hull turns (at `yaw_rate`) toward the route's direction
  across that same look-ahead window (the chord from the ship's projection to
  the aim point), not toward the translation direction. It turns
  continuously as the window slides over a corner, and correcting a small
  drift slides the ship sideways instead of rotating it.
- **Speed plan,** built once per route (and discarded with it):
  - **Turns:** each route bend is a turn. Turns whose slow sections overlap
    are one physical turn and merge, with their angles added, so passing an
    intermediate route point never releases the speed.
  - **Turn speed:** the lower of two limits:
    - outward swing: `sqrt(2 × min(acceleration, braking) ×
      corner_drift_limit) / (2 sin(angle / 2))`;
    - hull: the facing turns through the angle over look-ahead + the turn's
      span, the hull lags it at `yaw_rate`, and `v × sin(lag)` must stay
      within `max_lateral_speed`.
  - **Slow section:** starts one look-ahead before the first bend and lasts
    until the hull has turned through the whole angle at that speed (at
    least past the last bend).
  - **Gaps:** between slow sections, and before the goal, a gap counts as
    short when a speed-up there could not reach `max_forward_speed` while
    also slowing back down at the gentler of `acceleration` and `braking`.
    A short gap holds the higher of its two neighbouring speeds instead of
    speeding up and braking again.
  - **At run time:** the requested speed at the ship's arc progress is the
    lowest of `max_forward_speed`, braking to rest at the goal, and, for each
    slow section, braking into it, its held speed inside it, and
    accelerating out of it (a forward–backward pass evaluated in place). It
    is a ceiling, not a schedule: a ship slowed by contact simply accelerates
    back up to it.
- **Hull cap,** only on routes that bend: speed never exceeds what the hull,
  as currently turned, can thrust along the translation direction
  (`max_lateral_speed / sin(angle)`; sideways only if the direction is
  behind the hull). Direct and single-segment orders aren't capped, so
  open-space movement is unchanged.

Before 1e,
avoidance passes preferred movement through unchanged.

### Physics tick

1. Read the active order and actual state.
2. Reuse the current route or request one (1d). No repathing every tick.
3. Route Follower → preferred movement.
4. Optional avoidance request (1e).
5. Locomotion → feasible translation and gradual yaw.
6. One translation commit (direct in 1b; `move_and_collide()` from 1c).
7. Measure actual displacement; reconcile velocity; update state and
   events.

No-active-order braking: after `stop()` or arrival there is no active
order, but the tick keeps running while actual velocity is non-zero. Steps
2–4 are skipped; locomotion receives zero desired translation and reduces
velocity at the `MovementProfile` braking limit until stationary. Steps 6–7
run as usual, through the same single commit (direct in 1b;
`move_and_collide()` from 1c, so braking motion cannot bypass collision).
State stays `Idle` or `Arrived` and no event is emitted. No order queue,
new state, separate deceleration algorithm or new values.

Scheduling:

- **Avoidance disabled:** steps 5–7 run in `_physics_process`.
- **Avoidance enabled (1e):** Godot emits `velocity_computed` after
  `_physics_process` and before physics-server sync. Steps 5–7 run once,
  in that callback, and not also in `_physics_process`. A callback result is
  used only for the order and tick it was requested for.

### States

| State | Meaning | Leaves when |
|---|---|---|
| `Idle` | No active order. | `move_to()` → `Moving`. |
| `Moving` | Active order, making physical progress. | Arrives → `Arrived`; obstructed → `Blocked`; unreachable → `Idle`; `stop()` → `Idle`. |
| `Blocked` | Active order genuinely obstructed by collision, no physical progress. | Progress resumes → `Moving`; `stop()` / `move_to()`. |
| `Arrived` | Order reached its destination within arrival tolerance. | Next `move_to()` or `stop()`. |

Order lifecycle:

- `move_to()` silently supersedes the previous order and invalidates its
  pending results (routes, avoidance callbacks). No order queue.
- `stop()` cancels the order → `Idle`. No completion or failure event.
- Unreachable static route → `order_failed` once, order cleared, `Idle`.
- Arrival → `order_completed` once, `Arrived`. Arrival requires the actual
  position and the predicted rest point under `braking` (position +
  velocity × |velocity| / (2 × braking)) to both be within
  `arrival_tolerance` of the goal.
- These are order-state semantics. Neither `stop()` nor arrival instantly
  zeroes actual velocity; remaining velocity is removed by the
  no-active-order braking path (see Physics tick) using `MovementProfile`
  braking (1b).

Blocked (1c):

- Blocked is neither Arrived nor failed. The ship retains its order, waits,
  and retries its local, collision-constrained movement every physics tick.
- No automatic rerouting, cancelling or teleporting; no global repathing per
  tick; no extra scheduler.
- Blocked only when an active movement request is obstructed by collision
  and lacks physical progress — not while turning, slowly accelerating, or
  already at the destination.
- Rule (1c), evaluated after the commit and before arrival:
  - **Enter** `Blocked`: `move_and_collide()` reported a collision and
    actual speed < `blocked_speed_tolerance`.
  - **Stay** `Blocked` while actual speed < `blocked_speed_tolerance`, with
    or without a reported collision. Engine contact recovery pushes a
    pressed ship back by about the safe margin, so it creeps a few ticks
    without a reported contact.
  - **Leave** `Blocked` → `Moving` once actual speed reaches the tolerance.
  - On a `Blocked` tick, arrival is not evaluated.
  - Within `arrival_tolerance`, a `test_move()` query (moves nothing) toward
    the goal also gives `Blocked` instead of `Arrived` if a contact lies
    short of the goal.
- A blocked ship's reconciled velocity is near zero (observed below
  0.04 units/s from contact recovery), never its intended velocity.

### Routes and maps

- Static routing: `NavigationServer3D` `map_get_path`, one route map per
  clearance class **per scene**.
- **Map ownership (1d):**
  - A `StaticNavigation` node in the scene owns the maps. When the first
    `ClearanceRegion` child of a clearance registers, it creates that
    clearance's map, sets cell size and height from the region's baked
    navmesh, and activates it.
  - All ships of that clearance in the scene share the map; a ship
    references the node through its `navigation` export.
  - In `_exit_tree` it frees every map, after its child regions have left the
    tree. No autoload and no global registry.
- **Baked navmeshes:**
  - Pre-baked per scene and clearance, with `agent_radius ≥ footprint.radius
    + margin` (`ClearanceRegion` reports an error otherwise).
  - Bake source is the `navigation_source` group (ground and obstacles, meshes
    and colliders; never ships).
  - Re-bake in the editor after moving obstacles.
- **Readiness:** a route request waits (order `Moving`, nothing requested,
  no failure) until the map holds every region's polygons. Godot 4.7 builds
  regions asynchronously, so the map's first sync can precede them. The check
  is that the map's closest-point owner at the **centre of one of each
  region's own polygons** is that region. An interior point is used because
  at a vertex or edge shared with an adjacent region the map reports only
  one owner. `stop()` or a new order cancels a pending request. No
  `map_force_update()`.
- **Validation** (`find_route`, all planar XZ). A route is returned only if:
  1. the exact goal lies **on** the clearance's navmesh: its closest mesh
     point is directly below it (within floating-point noise, 0.001), so a
     goal even 0.1 inside the berth fails;
  2. the path is not empty;
  3. the path ends at the goal itself (same 0.001), not at the nearest
     reachable point of another island.

  The last point then differs from the goal only in height and is replaced by
  it. Otherwise → `order_failed` once, `Idle`; never a partial route or a
  substitute destination. `arrival_tolerance` is used only for arrival.
- **Direct route:** only by explicit `direct_route = true` on ship instances
  in scenes that intentionally have no navigation (the 1b/1c checks). It is
  never inferred from an empty or unsynced map.
- **No rerouting when `Blocked`:** dynamic blocking keeps the route and the
  order. Routes are requested once per order, never per tick.
- Local avoidance: `NavigationAgent3D` native RVO in 2D avoidance mode, on
  one shared avoidance map so ships of different sizes perceive each other.
- Static route maps and the avoidance map are separate concerns.
- Avoidance is advisory: locomotion limits and actual physics are final.
  RVO output is never assumed achievable or collision-free.

### Footprint

- Collision uses a reusable, yaw-independent circular planar envelope
  (circle/cylinder shape), so rotating hulls cannot create overlap.
- The per-type `CylinderShape3D` (`Movement/Profiles/*_footprint.tres`) is
  the **authoritative physical footprint**. 1d navigation clearance derives
  from it (`NavigationClearance.footprint` + `margin`, checked against the
  baked `agent_radius`). 1e avoidance radius must derive from it or be
  reconciled with it explicitly; no independent conflicting radii. The envelope overestimates hull
  clearance (frigate: radius 10.5 around a 5.9-wide hull).
- Fixed obstacles and other ships both block; a ship stops rather than
  overlaps. No sliding: `move_and_collide()` discards motion past the
  contact, so a grazing contact also blocks. The body has
  `axis_lock_linear_y`, keeping contact recovery on the XZ plane.

### Edge cases

Critical (owning ticket):

- No extra position assignment after `move_and_collide()` (1c).
- No false route success when the path ends at the nearest reachable point
  (1d).
- No movement from stale avoidance callbacks after order replacement (1e).
- Order supersession invalidates old results (1b–1e).
- No false arrival on collision; arrival from actual position (1c).
- Blocked retains the order (1c).
- No snapping rotation; yaw always changes gradually (1b).
- Collision has precedence over route and avoidance requests (1c).
- Fixed physics-tick scheduling, one movement update per tick (1b, 1e).

QA (deferred): congestion deadlock resolution, hull-exact rotating contact,
large formations.

### Debt

- Circular footprint overestimates hull clearance.
- Native RVO predicts imperfectly for slow-turning ships.
- Multiple static route maps, one per clearance class.
- No global traffic scheduler, by design. Two ships blocking each other head
  on wait indefinitely (observed in 1c).
- Navmeshes are pre-baked; moving a static obstacle needs an editor re-bake.
  No dynamic map changes.

### Open

- Observed in 1c (Jolt, Godot 4.7.2), not a guarantee:
  - two ships moving head on both stop, with up to 0.006 units of
    interpenetration (within the engine margin);
  - contact recovery stays on the XZ plane.
- Observed in 1d (default bake settings), not a guarantee:
  - the baked edge is exactly `agent_radius` (12.5) beside straight obstacle
    sides;
  - Godot's erosion approximates obstacle **corners** closer: vertices at
    11.85, and straight route legs between them at 11.29;
  - the ship tracks the route closely (cross-track ≤ 0.34 on forward
    routes), so at corners it passes near that chord: ≥ 11.27 on forward
    routes and 11.21 on one reverse pass after an order replacement, with no
    contact.
  - The approved 2-unit berth is therefore held beside sides but not fully
    at corners. Reducing `edge_max_error` didn't help. The owner accepted
    this (option A) and the reduced observed minimum (smooth steering over
    the former 11.42 observation); see `HANDOFF.md`.
- UNKNOWN: 2D RVO callback behavior in 4.7 (verify in 1e).
- UNDECIDED (owner): target fleet scale; unit confirmation. `MovementProfile`
  starting values are owner-confirmed for play; turning feel is judged by
  the owner in play, not by tests.

## Data assets

All Movement assets are Godot `Resource`s. They hold configuration only;
runtime per-ship state is never stored in a shared profile. Defaults, units
and ranges are set in the implementation tickets and are UNDECIDED (owner)
until confirmed. Values live in the `.tres` assets; the script declares
fields, units and editor ranges only.

| Asset | Module | Values |
|---|---|---|
| `MovementProfile` | Movement | Max forward speed (units/s), max lateral speed (units/s), acceleration (units/s²), braking (units/s²), yaw rate (°/s), arrival tolerance (units), waypoint tolerance / look-ahead (units), corner drift limit (units), blocked speed tolerance (units/s) |
| Footprint (`CylinderShape3D`) | Movement | Radius (units), height (units) |
| `AvoidanceProfile` | Movement | Radius, neighbor range, time horizon, neighbor limit |
| `NavigationClearance` | Movement | Footprint (reference to the footprint shape), margin (units); the class is the resource itself, its map is owned by the scene's `StaticNavigation` |

The collision footprint is a reusable body shape resource, not a profile
field. Instances share the per-type resource and never edit it.
