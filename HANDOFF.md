# Handoff

Current state only. Replace outdated content; do not append history.

## Current state

Godot 4.7 project (Forward Plus, Jolt Physics). Task 1b movement works in
open space: one reusable ship (`Movement/ship.tscn`, owner placeholder
model `Arrata_Frigate_001`) takes `move_to()` / `stop()` orders, accelerates
and brakes per its `MovementProfile`, slides sideways while yaw turns
gradually, and emits `order_completed` once on arrival. Try it in
`Movement/Check/movement_check.tscn` (F6; right-click to move, `C` to stop).
No collision, obstacle routing or ship avoidance yet.

## Accepted decisions

- Movement module may use Core; Movement owns its data assets
  (`MovementProfile`, `AvoidanceProfile`, `NavigationClearance`) — Core
  holds only genuinely shared definitions (Task 1a).
- One movement controller per ship is the only transform writer; one
  translation per physics tick; state and arrival from actual displacement
  (Task 1a).
- 1b uses a direct translation writer; 1c replaces it with one native
  `move_and_collide()` call whose displacement is never reapplied (Task 1a).
- Order lifecycle: `move_to()` supersedes silently; `stop()` → `Idle` with
  no event; unreachable → `order_failed` once, `Idle`; arrival →
  `order_completed` once, `Arrived` (Task 1a).
- After `stop()` or arrival, the ship brakes at its `MovementProfile`
  braking limit through the same single movement commit until stationary;
  no snap to rest, no drift, no hidden order (Task 1a).
- Blocked retains the order and retries local movement every physics tick;
  no rerouting, cancelling or teleporting — owner: "Wait and retry".
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
- Arrival requires actual position and predicted rest point within
  tolerance (Task 1b).

## Known limitations

- Until 1c, ships pass through everything, the ship body has no collision
  shape (Godot shows a "no shape" configuration warning on it), and
  `Blocked` is never entered.
- Until 1d, routes are a straight line to the destination and `order_failed`
  never fires.
- Circular collision footprint overestimates hull clearance.
- Native RVO predicts imperfectly for slow-turning ships.
- One static route map per clearance class.
- No global traffic scheduler.
- QA deferred: congestion deadlock resolution, hull-exact rotating contact,
  large formations.
- UNDECIDED (owner): final movement feel (tuned in play), fleet scale,
  unit confirmation.

## Next task

#4 — Task 1c: Add planar collisions and blocked-order retry.
