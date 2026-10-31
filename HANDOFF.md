# Handoff

Current state only. Replace outdated content; do not append history.

## Current state

Empty Godot 4.7 project (Forward Plus, Jolt Physics). No gameplay code or
scenes. Ship movement is documented in `ARCHITECTURE.md` (Movement) but
**not implemented**.

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

## Known limitations

- Circular collision footprint overestimates hull clearance.
- Native RVO predicts imperfectly for slow-turning ships.
- One static route map per clearance class.
- No global traffic scheduler.
- QA deferred: congestion deadlock resolution, hull-exact rotating contact,
  large formations.
- UNDECIDED (owner): movement tuning numbers, fleet scale, unit
  confirmation.

## Next task

#3 — Task 1b: Implement reusable ship movement and orders.
