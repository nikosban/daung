# Handoff

Current state only. Replace outdated content; do not append history.

## Current state

Godot 4.7 project (Forward Plus, Jolt Physics). Ship movement works on the
XZ plane with planar collision (Tasks 1b–1c):

- One reusable ship (`Movement/ship.tscn`, owner placeholder model
  `Arrata_Frigate_001`) takes `move_to()` / `stop()` orders, accelerates and
  brakes per its `MovementProfile`, and slides sideways while yaw turns
  gradually.
- It moves through one `move_and_collide()` per tick. Ships and obstacles
  block it without sliding; a blocked ship keeps its order, waits and
  resumes on its own when the way clears.
- `order_completed` fires once on arrival.

Check scenes (F6 with the tab active, or Run Specific Scene; number keys
select a ship, right-click to move, `C` to stop):

- `Movement/Check/movement_check.tscn`: one ship in open space;
- `Movement/Check/collision_check.tscn`: Lane A ship vs obstacle, Lane B
  ship vs ship.

No obstacle routing or ship avoidance yet.

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

## Known limitations

- Until 1d, routes are a straight line to the destination, so a ship ordered
  through an obstacle stays `Blocked`, and `order_failed` never fires.
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

#5 — Task 1d: Add static navigation and route following.
