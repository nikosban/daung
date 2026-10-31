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

Status: Task 1b implemented — orders, direct route, locomotion, states
`Idle`/`Moving`/`Arrived` and events, with a single direct translation
writer. Collision and `Blocked` (1c), static navigation and `order_failed`
(1d) and avoidance (1e) are still planned; engine mechanisms named for them
are candidate choices, not verified behavior.

### Files

| File | Role |
|---|---|
| `Movement/movement_controller.gd` | `MovementController`: the controller, route seam, route follower and locomotion |
| `Movement/movement_profile.gd` | `MovementProfile` `Resource` class |
| `Movement/ship.tscn` | Reusable ship: `CharacterBody3D` root with the controller; replaceable `Visual` child holding the model |
| `Movement/Profiles/*.tres` | One `MovementProfile` per ship type |
| `Movement/Check/movement_check.tscn` | Permanent MovementCheck scene (right-click `move_to`, `C` `stop`) |

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
toward the desired direction at `yaw_rate`.

Before 1d, the route is the straight line to the destination. Before 1e,
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
  already at the destination. The detection tolerance is a 1c technical
  parameter.

### Routes and maps

- A route is valid only if its last waypoint is within the destination
  tolerance of the exact requested goal. Godot may end a path at the nearest
  reachable navmesh point; such a route is an unreachable failure, never a
  new destination. Empty or partial routes fail the same way.
- Static routing: `NavigationServer3D`, one route map per clearance class.
- Local avoidance: `NavigationAgent3D` native RVO in 2D avoidance mode, on
  one shared avoidance map so ships of different sizes perceive each other.
- Static route maps and the avoidance map are separate concerns.
- Avoidance is advisory: locomotion limits and actual physics are final.
  RVO output is never assumed achievable or collision-free.

### Footprint

- Collision uses a reusable, yaw-independent circular planar envelope
  (circle/cylinder shape), so rotating hulls cannot create overlap.
- Its radius relates to the `AvoidanceProfile` radius and the
  `NavigationClearance` class; the exact relationship is set with the
  owning tickets (1c–1e). The envelope may overestimate hull clearance.
- Fixed obstacles and other ships both block; a ship stops rather than
  overlaps.

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
- No global traffic scheduler, by design.

### Open

- UNKNOWN: native multi-body kinematic blocking (verify in 1c); 2D RVO
  callback behavior in 4.7 (verify in 1e).
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
| `MovementProfile` | Movement | Max forward speed (units/s), max lateral speed (units/s), acceleration (units/s²), braking (units/s²), yaw rate (°/s), arrival tolerance (units) |
| `AvoidanceProfile` | Movement | Radius, neighbor range, time horizon, neighbor limit |
| `NavigationClearance` | Movement | Clearance class, route map |

The collision footprint is a reusable body shape, not a profile field.
