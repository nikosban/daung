# Handoff

Current state only. Replace outdated content; do not append history.

## Current state

Godot 4.7 project (Forward Plus, Jolt Physics). Ship movement works on the
XZ plane with planar collision and static routing (Tasks 1b–1d, 1d.1, 1d.3):

- One reusable ship (`Movement/ship.tscn`, owner placeholder model
  `Arrata_Frigate_001`) takes `move_to()` / `stop()` orders, accelerates and
  brakes per its `MovementProfile`, and backs up (bounded reverse) and
  slides sideways immediately. Yaw starts after an order-onset lead, then
  turns gradually during travel. A short move behind can arrive before the
  hull has turned to face it; arrival never requires alignment.
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

Task 1d.3 regression runner:
`godot --headless --path . --fixed-fps 60 --script Movement/Check/rotation_lead_check.gd`.
It reuses the ship and check scenes, emitting full 60-Hz CSV traces and JSON
results under ignored `builds/issue-14/`. Visual feel remains for owner playtest.

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
- Bounded reverse while rotating: a target behind is reached by translating
  backward and sideways while the hull turns gradually, even if rotation
  isn't complete on arrival; no reverse mode or distance threshold — owner
  answers on PR #10, Task 1d.1 (#11). Replaces the 1b "no commanded reverse"
  decision.
- Frigate `max_reverse_speed` 1.5 units/s (backward hull component), chosen
  by the tech lead on the owner's delegation; reverse must stay below forward
  speed (Task 1d.1).
- Limits apply to the requested velocity; actual velocity changes only at
  the acceleration/braking rate (Task 1b).
- Frigate footprint `CylinderShape3D` radius 10.5 units, height 4 units —
  owner: "I accept" (Task 1c). It is the authoritative physical footprint
  for 1d/1e.
- No sliding; a grazing contact also blocks until the path clears — owner:
  "I accept" (Task 1c).
- Clearance margin 2 units beyond the footprint (frigate bake radius 12.5);
  waypoint tolerance 2.0 units — owner: "Approved" (Task 1d).
- Corner berth: keep the default bake and accept reduced berth at obstacle
  corners — owner: option A (Task 1d).
- Static navigation (Task 1d review):
  - scene-owned navigation maps per clearance class and pre-baked
    navmeshes;
  - direct route only by explicit `direct_route`;
  - route validation requires the exact goal on the clearance navmesh and
    the path ending at the goal itself;
  - readiness probes each region's interior;
  - planar (XZ) segment progress that never advances before a corner is
    passed or goes back.
- Route steering: pure pursuit 2.0 units ahead along the route, and a new
  `MovementProfile.corner_drift_limit` of 0.5 units (range 0.1–2.0); the
  observed minimum clearance falls below the former 11.42 (no contact) —
  owner approval on PR #10 (Task 1d).
- Route speed and facing (owner decisions after the PR #10 trace):
  - one speed plan per route; a physical turn made of several route points
    holds its speed throughout;
  - between nearby corners, a steady speed instead of a brief speed-up and
    brake; longer straights accelerate normally;
  - the hull faces the route's direction while translation corrects drift,
    so the ship slides instead of rotating for small corrections;
- Translation-first order onset (Task 1d.3, approved for provisional playtest):
  - actual XZ speed at receipt ≤ `blocked_speed_tolerance` (0.05 units/s)
    selects `rotation_lead_from_rest` **0.35 s**; higher speed selects
    `rotation_lead_while_moving` **0.10 s**, including no-order coasting;
  - both values live in the shared frigate MovementProfile, editor range
    0–1 s, step 0.01 s; one remaining-time float lives on each controller;
  - only following ticks consume time; pending navigation does not;
    Blocked/no-progress ticks do, and waypoints never restart the lead;
  - translation keeps running; expiry permits the normal bounded yaw;
    stop, failure and arrival clear the lead before events.

## Known limitations

- A destination closer to an obstacle than footprint + margin is
  unreachable (`order_failed`), even if it looks open.
- Reduced berth at obstacle corners, accepted by the owner (option A; to
  reassess in real levels):
  - the 2-unit berth holds beside straight obstacle sides (baked edge exactly
    12.5);
  - around obstacle corners, Godot's erosion puts the route as close as
    11.29; the earlier forward-route check measured clearance ≥ 11.27.
    The 1d.3 replacement sweep measured ≥ **11.207** (0.707 beyond the
    footprint; 21 timings, no contact or Blocked ticks; 1d.1 baseline 11.198).
    Accepted as tested, not a guaranteed floor.
- Steady speed through closely spaced corners makes those routes slower
  (Reachable: about 6 s longer than with speed-ups between corners).
- After an order replacement that leaves the ship far off its new route,
  it backs and slides back to it while turning; a turnaround past a wall
  corner can overshoot the new route's heading by about 17° and turn back.
- A ship type without reverse (`max_reverse_speed` 0, the pre-1d.1
  behaviour) can touch the wall corner after an order replacement (6 of 21
  timings measured: 10.48, up to 12 `Blocked` ticks, then one completion).
  The frigate doesn't.
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
- Replacing an order at resting safe-margin contact can report `Moving`
  while making negligible travel (collision-check centre (-40, 10.501),
  goal (-40, -30), same result with zero or 0.35 s lead). Collision still
  prevents passage. This existing contact-state edge case was not changed.
- Provisional onset timing is technically verified, not visually approved:
  from rest, 0.0703 units travelled before first yaw (22 held 60-Hz ticks);
  a ~5 units/s retarget travelled 0.5719 units (7 held ticks). Each timing
  is within one tick of its configured interval. The rest cue may be hard
  to see; final timing/feel remains the owner's decision.
- Native RVO predicts imperfectly for slow-turning ships.
- One static route map per clearance class.
- No global traffic scheduler.
- Ship types with reverse below lateral drift off the route direction when
  the route lies behind the hull (17.6° measured with reverse 0.5); the
  frigate (reverse = lateral) does not.
- While the hull turns under a diagonal velocity, actual hull-relative speed
  can briefly exceed the axis limits (lateral up to 1.58 of 1.5 measured);
  actual velocity is never clamped, to avoid snaps.
- QA deferred: congestion deadlock resolution, hull-exact rotating contact,
  large formations, pre-overlapped spawns, high-speed tunnelling.
- UNDECIDED (owner): final movement feel (tuned in play), fleet scale,
  unit confirmation.

## Next task

#14 — owner playtest/review and merge of the translation-first onset change.
After merge: #6 — Task 1e, predictive ship avoidance, using the same
locomotion limits including reverse. #13 remains deferred.
