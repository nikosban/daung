# Handoff

Current state only. Replace outdated content; do not append history.

## Current state

Godot 4.7 project (Forward Plus, Jolt Physics). Ship movement works on the
XZ plane with planar collision and static routing (Tasks 1b–1d):

- One reusable ship (`Movement/ship.tscn`, owner placeholder model
  `Arrata_Frigate_001`) takes `move_to()` / `stop()` orders, accelerates and
  brakes per its `MovementProfile`, and slides sideways while yaw turns
  gradually.
- It moves through one `move_and_collide()` per tick. Ships and obstacles
  block it without sliding; a blocked ship keeps its order, waits and
  resumes on its own when the way clears.
- In scenes with a `StaticNavigation` node, ships route around fixed
  obstacles on a pre-baked navmesh for their clearance class (footprint +
  margin). An order whose exact goal is unreachable fires `order_failed`
  once and doesn't move.
- `order_completed` fires once on arrival.

Check scenes (F6 with the tab active, or Run Specific Scene; number keys
select a ship, right-click to move, `C` to stop; the route is drawn in blue):

- `Movement/Check/movement_check.tscn`: one ship in open space (direct route);
- `Movement/Check/collision_check.tscn`: Lane A ship vs obstacle, Lane B
  ship vs ship (direct route);
- `Movement/Check/routing_check.tscn`: Reachable marker behind a wall,
  Unreachable marker inside an enclosure.

No ship avoidance yet.

## Accepted decisions

- Movement module may use Core; Movement owns its data assets
  (`MovementProfile`, `AvoidanceProfile`, `NavigationClearance`) — Core
  holds only genuinely shared definitions (Task 1a).
- One movement controller per ship is the only transform writer; one
  `move_and_collide()` commit per physics tick, never reapplied; state and
  arrival from actual displacement (Tasks 1a, 1c).
- Order lifecycle: `move_to()` supersedes silently; `stop()` → `Idle` with
  no event; unreachable → `order_failed` once, `Idle`; arrival →
  `order_completed` once, `Arrived` (Task 1a).
- After `stop()` or arrival, the ship brakes at its `MovementProfile`
  braking limit through the same single commit until stationary; no snap to
  rest, no drift, no hidden order (Task 1a).
- Blocked retains the order and retries local movement every physics tick;
  no rerouting, cancelling or teleporting — owner: "Wait and retry".
- Collision takes precedence over arrival; a blocked tick never completes an
  order (Task 1c review).
- Lateral translation with gradual, controlled yaw — owner answer.
- Fixed obstacles and other ships both block — owner answer.
- Speeds conservative; tuning numbers set by the owner in play — owner
  answer.
- Starting `MovementProfile` for `Arrata_Frigate_001`: forward 5 units/s,
  lateral 1.5 units/s, acceleration 1.0 units/s², braking 1.5 units/s², yaw
  20°/s, arrival tolerance 1.0 units — owner: "I agree" (Task 1b).
- No commanded reverse; a target behind is reached by turning and sliding
  sideways — owner: "I agree" (Task 1b).
- Limits apply to the requested velocity; actual velocity changes only at
  the acceleration/braking rate (Task 1b).
- Frigate footprint `CylinderShape3D` radius 10.5 units, height 4 units —
  owner: "I accept" (Task 1c). It is the authoritative physical footprint
  for 1d/1e.
- No sliding; a grazing contact also blocks until the path clears — owner:
  "I accept" (Task 1c).
- Clearance margin 2 units beyond the footprint (frigate bake radius 12.5);
  waypoint tolerance 2.0 units — owner: "Approved" (Task 1d).
- Static navigation (Task 1d review):
  - scene-owned navigation maps per clearance class and pre-baked
    navmeshes;
  - direct route only by explicit `direct_route`;
  - route validation requires the exact goal on the clearance navmesh and
    the path ending at the goal itself;
  - readiness probes each region's interior;
  - planar (XZ) segment progress that never advances before a corner is
    passed or goes back;
  - corner speed from existing rates and margin.

## Known limitations

- A destination closer to an obstacle than footprint + margin is
  unreachable (`order_failed`), even if it looks open.
- **Owner decision pending:** the 2-unit berth holds beside straight
  obstacle sides (baked edge exactly 12.5). Around obstacle corners, Godot's
  erosion puts the route as close as 11.29 and the ship as close as 11.42,
  still 0.9 beyond the footprint and with no contact.
- Navmeshes are pre-baked: after moving an obstacle, re-bake the scene's
  region in the editor. No dynamic map changes.
- Only the frigate clearance class exists; other classes need owner-confirmed
- Navmeshes are pre-baked: after moving an obstacle, re-bake the scene's
  region in the editor. No dynamic map changes.
- Only the frigate clearance class exists; other classes need owner-confirmed
  ship sizes.
- Until 1e, ships do not avoid each other; two ships blocking each other
  head on wait indefinitely.
- The circular footprint overestimates hull clearance: the frigate blocks a
  21-unit circle around a 5.9-wide hull.
- A blocked ship's displayed speed flickers between 0.00 and about 0.03
  units/s from engine contact recovery.
- Native RVO predicts imperfectly for slow-turning ships.
- One static route map per clearance class.
- No global traffic scheduler.
- QA deferred: congestion deadlock resolution, hull-exact rotating contact,
  large formations, pre-overlapped spawns, high-speed tunnelling.
- UNDECIDED (owner): final movement feel (tuned in play), fleet scale,
  unit confirmation.

## Next task

#6 — Task 1e: Add predictive ship avoidance.
