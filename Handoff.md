# Handoff

Current state only. Replace outdated content; do not append history.

## Current state

Godot 4.7 project (Forward Plus, Jolt Physics). Ship movement works on the XZ plane with planar collision and static routing (Tasks 1b–1d, 1d.1, 1d.3, 1c.1):

- One reusable ship (Movement/ship.tscn, owner placeholder model `Arrata_Frigate_001`) takes `move_to()` / `stop()` orders, accelerates and brakes per its `MovementProfile`, and backs up (bounded reverse) and slides sideways immediately. Moving orders redirect velocity and begin gradual yaw together; rest starts get a visible directional-distance lead first. A short move can arrive before facing; arrival needs no alignment.
- It moves through one `move_and_collide()` per tick. Ships and obstacles block it without sliding; a blocked ship keeps its order, waits and resumes on its own when the way clears. Safe-margin recovery is reported by that same commit: low actual speed plus contact opposing a nonzero feasible request gives `Blocked`, including after order replacement. The previous state alone never retains `Blocked`.
- In scenes with a `StaticNavigation` node, ships route around fixed obstacles on a pre-baked navmesh for their clearance class (footprint + margin). An order whose exact goal is unreachable fires `order_failed` once and doesn't move.
- `order_completed` fires once on arrival.

Check scenes (F6 with the tab active, or Run Specific Scene; number keys select a ship, right-click to move, `C` to stop; the route is drawn in blue):

- Movement/Check/movement_check.tscn: one ship in open space (direct route);
- Movement/Check/collision_check.tscn: Lane A ship vs obstacle, Lane B ship vs ship (direct route);
- Movement/Check/routing_check.tscn: Reachable marker behind a wall, Unreachable marker inside an enclosure.

In the open-space scene, restart F6 then press **B** for the fixed (0,+40) rest order, or restart then **M** for acceleration toward (0,-100) followed by an automatic full-speed retarget to (40,0). The lower HUD records total vs directional travel, first-yaw time and release reason; amber marks the order start and actual trail. The production movement API is unchanged.

In the collision scene, restart F6 then press **S**. This places Ship1 at (-40, 10.501), settles the near contact, then replaces its order with (-40, -30). Within two seconds the HUD shows 60 consecutive Blocked ticks at/below 0.05 units/s, no penetration and no completion. Press **U** to remove the obstacle: the same order resumes and completes once. The HUD distinguishes commit contact from pre-commit motion/recovery queries; the trace is builds/issue-16/live/live_contact.csv. Restart F6 to repeat.

No ship avoidance yet.

Movement regression runner: `godot --headless --path . --fixed-fps 60 --script Movement/Check/rotation_lead_check.gd`. It reuses the ship and check scenes, emitting full 60-Hz CSV traces and JSON results under ignored `builds/issue-16/after/`; `-- --output=res://builds/...` selects another evidence directory. Earlier `builds/issue-14/` evidence is preserved. Generated `.gdignore` markers keep CSV evidence out of Godot's translation importer. `-- --contact-only` runs the #16 checks. Rendered B/M captures are reproducible with the same runner, without `--headless`, plus `-- --visual=B` or `-- --visual=M`; `-- --visual=contact` drives the collision scene's S/U check and saves Blocked/Arrived captures. Visual feel remains for owner playtest.

Verification on Godot 4.7.2/Jolt: full runner **2,517 checks, 0 failures**; final focused run **1,837 checks, 0 failures**; rendered S/U **2 checks, 0 failures**; headless editor import/parse exits 0 with no reported errors or warnings after excluding evidence from imports. The full run emitted one Jolt job-system capacity warning; it completed successfully. No export preset exists, so no standalone export was built. Owner validation/merge of #16 remains pending.

## Accepted decisions

- Movement module may use Core; Movement owns its data assets (`MovementProfile`, `AvoidanceProfile`, `NavigationClearance`) — Core holds only genuinely shared definitions (Task 1a).
- One movement controller per ship is the only transform writer; one `move_and_collide()` commit per physics tick, never reapplied; state and arrival from actual displacement (Tasks 1a, 1c).
- Order lifecycle: `move_to()` supersedes silently; `stop()` → `Idle` with no event; unreachable → `order_failed` once, `Idle`; arrival → `order_completed` once, `Arrived` (Task 1a).
- After `stop()` or arrival, the ship brakes at its `MovementProfile` braking limit through the same single commit until stationary; no snap to rest, no drift, no hidden order (Task 1a).
- Blocked retains the order and retries local movement every physics tick; no rerouting, cancelling or teleporting — owner: "Wait and retry".
- Collision takes precedence over arrival; a blocked tick never completes an order (Task 1c review).
- Lateral translation with gradual, controlled yaw — owner answer.
- Fixed obstacles and other ships both block — owner answer.
- Speeds conservative; tuning numbers set by the owner in play — owner answer.
- Current `MovementProfile` for `Arrata_Frigate_001`: forward 5 units/s, lateral 2.0 units/s, acceleration 2.0 units/s², braking 1.5 units/s², yaw 20°/s, arrival tolerance 1.0 units. The owner committed lateral and acceleration tuning in `c563ae6`; other values retain Task 1b defaults.
- Bounded reverse while rotating: a target behind is reached by translating backward and sideways while the hull turns gradually, even if rotation isn't complete on arrival; no reverse mode or distance threshold — owner answers on PR #10, Task 1d.1 (#11). Replaces the 1b "no commanded reverse" decision.
- Frigate `max_reverse_speed` 1.5 units/s (backward hull component), chosen by the tech lead on the owner's delegation; reverse must stay below forward speed (Task 1d.1).
- Limits apply to the requested velocity; actual velocity changes only at the acceleration/braking rate (Task 1b).
- Frigate footprint `CylinderShape3D` radius 10.5 units, height 4 units — owner: "I accept" (Task 1c). It is the authoritative physical footprint for 1d/1e.
- No sliding; a grazing contact also blocks until the path clears — owner: "I accept" (Task 1c).
- Clearance margin 2 units beyond the footprint (frigate bake radius 12.5); waypoint tolerance 2.0 units — owner: "Approved" (Task 1d).
- Corner berth: keep the default bake and accept reduced berth at obstacle corners — owner: option A (Task 1d).
- Static navigation (Task 1d review):
    - scene-owned navigation maps per clearance class and pre-baked navmeshes;
    - direct route only by explicit `direct_route`;
    - route validation requires the exact goal on the clearance navmesh and the path ending at the goal itself;
    - readiness probes each region's interior;
    - planar (XZ) segment progress that never advances before a corner is passed or goes back.
- Route steering: pure pursuit 2.0 units ahead along the route, and a new `MovementProfile.corner_drift_limit` of 0.5 units (range 0.1–2.0); the observed minimum clearance falls below the former 11.42 (no contact) — owner approval on PR #10 (Task 1d).
- Route speed and facing (owner decisions after the PR #10 trace):
    - one speed plan per route; a physical turn made of several route points holds its speed throughout;
    - between nearby corners, a steady speed instead of a brief speed-up and brake; longer straights accelerate normally;
    - the hull faces the route's direction while translation corrects drift, so the ship slides instead of rotating for small corrections;
- Simplified onset (Task 1d.3 owner correction; rest distance provisional):
    - actual XZ speed at receipt above `blocked_speed_tolerance` (0.05 units/s) selects zero lead: translation redirects and bounded yaw begins on the first following tick, including coasting and directly opposing retargets;
    - at/below the tolerance, `rotation_lead_distance_from_rest` is **1.0 unit** (range 0-5 units, step 0.1). One float per controller; one shared profile field. No moving-distance field or timeout/stall counters;
    - rest credit is positive actual travel along the live local follower direction. Translation continues; distance completion permits yaw next tick. A zero hull-feasible request at negligible speed releases promptly;
    - collision retains Blocked wait/retry and has no timed yaw release. Pending routing consumes no lead; waypoints do not reset it. Stop, failure and arrival clear before signals; no finishing alignment.
    - Visual acceptance checks immediate request redirection, smooth actual velocity changes and bounded yaw during translation. A straight-line portion with concurrent yaw is valid; path curvature is not required.
- Owner selected the existing centred physical pivot for this correction: Ship root and Footprint share their origin; Visual stays at identity. Rear-pivot rotation is deferred. The owner committed the centred model reimport in `c563ae6`; #16 preserves it and the scene composition/footprint.
- Safe-margin state correction (Task 1c.1): report recovery contact in the existing commit, check its normal against the feasible request, and evaluate actual speed at/below the existing 0.05 units/s tolerance. Re-evaluate every tick rather than retaining Blocked solely from old state. No additional production query, state, tuning or public API.

## Known limitations

- A destination closer to an obstacle than footprint + margin is unreachable (`order_failed`), even if it looks open.
- Reduced berth at obstacle corners, accepted by the owner (option A; to reassess in real levels):
    - the 2-unit berth holds beside straight obstacle sides (baked edge exactly 12.5);
    - around obstacle corners, Godot's erosion puts the route as close as 11.29; the earlier forward-route check measured clearance ≥ 11.27. The current replacement sweep measured ≥ **11.239223** (0.739223 beyond the footprint; 21 timings, no contact or Blocked ticks). Accepted as tested, not a guaranteed floor.
- Steady speed through closely spaced corners makes those routes slower (Reachable: about 6 s longer than with speed-ups between corners).
- After an order replacement that leaves the ship far off its new route, it backs and slides back to it while turning; a turnaround past a wall corner can overshoot the new route's heading by about 17° and turn back.
- A ship type without reverse (`max_reverse_speed` 0, the pre-1d.1 behaviour) can touch the wall corner after an order replacement; #13 remains deferred. The current frigate sweep has no contact/Blocked ticks.
- Navmeshes are pre-baked: after moving an obstacle, re-bake the scene's region in the editor. No dynamic map changes.
- Only the frigate clearance class exists; other classes need owner-confirmed ship sizes.
- Until 1e, ships do not avoid each other; two ships blocking each other head on wait indefinitely.
- The circular footprint overestimates hull clearance: the frigate blocks a 21-unit circle around a 5.9-wide hull.
- A blocked ship's displayed speed flickers between 0.00 and about 0.03 units/s from engine contact recovery.
- Rest lead remains provisional for owner feel: B travels 1.0250 directional units before yaw at 1.0500 s. M yaws on its first following tick, with actual speed 4.9762 units/s from 4.9998 at receipt; first yaw step 0.3333 degrees. Old momentum redirects continuously while the hull turns.
- Zero-reverse directly-behind recovery: first yaw tick 2, first travel tick 3. Actual obstruction retains its stationary lead and Blocked order; removal permits progress/arrival through the same collision commit.
- Native RVO predicts imperfectly for slow-turning ships.
- One static route map per clearance class.
- No global traffic scheduler.
- When reverse is below lateral speed, hull limiting can trim a behind-hull request away from the follower's route direction. The frigate now has reverse 1.5 and lateral 2.0 units/s; the route speed plan does not model reverse. No route-speed redesign is part of #16.
- While the hull turns under a diagonal velocity, actual hull-relative speed can briefly exceed the axis limits; actual velocity is never clamped, to avoid snaps.
- QA deferred: congestion deadlock resolution, hull-exact rotating contact, large formations, pre-overlapped spawns, high-speed tunnelling.
- UNDECIDED (owner): final movement feel (tuned in play), fleet scale, unit confirmation.

## Next task

#16 — owner validation/review and merge of the safe-margin state correction. After merge: #6 — Task 1e, predictive ship avoidance, using the same locomotion limits including reverse. #13 remains deferred.