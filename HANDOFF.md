# Handoff

## Current state

Daung has open-space ship movement with moving turns, near-opposite reversals, model-only banking and player-defined routes (Tasks #3, #5, #7 and #9). Running the project opens `Main/main.tscn`: a fixed camera, one frigate at the origin facing −Z, and 2 m ring markers at (100, 0, 0), at the start location (0, 0, 0) and at the route test points (60, 0, 0), (60, 0, −40) and (20, 0, −40). Right-clicking the Y = 0 plane orders the ship there; Shift + right-click appends a waypoint.

- `Movement/`: the `MovementProfile` Resource (eight provisional tunables), the shared `frigate_movement_profile.tres`, and `ShipMovement` (`CharacterBody3D`), the single writer of planar position, velocity and yaw, with `move_to()`, `append_waypoint()` and `stop()`.
- **Each new order (`move_to`) is classified once, from the actual travel velocity:**
  - at rest: translate and turn together;
  - 150° or more from travel: brake to rest, then start from rest;
  - anything else: a moving turn at up to 12 °/s of travel direction, slowing for near goals (pure-pursuit cap).
- **Routes:** each ship keeps its own route (the anchor, then the requested points; never empty).
  - A plain right-click replaces the whole route with one destination, aimed at directly, exactly as before routes existed.
  - Shift + right-click appends a point without re-classifying, restarting or braking. With no active order it starts one like a plain right-click.
  - On multi-point routes the ship steers at a point 25 m further along the route (`route_lookahead_distance`), so it rounds bends early and may cut corners. Progress never goes backward. Intermediate points are guidance, never arrival targets.
  - When guidance crosses a bend, the turn deflection is reset from the actual travel direction to the new leg, so banking follows the current bend.
  - `stop()` clears the whole route.
- Entering the 2 m tolerance of the final point completes an order. The ship brakes to rest along its travel and may coast past without turning back. A click inside 2 m is an arrival, never a reversal.
- `get_destination()` returns the final point; `get_guidance_target()` returns the point currently steered at. Both are always defined, including at startup and after `stop()` or arrival.
- `Ships/ship.tscn`: the reusable ship. It has the movement root, a provisional box collision shape with no collision rules, and the protected GLB as a `Visual` child at identity.
- **Banking:** `Visual` runs `ShipVisualBank`, which reads Movement's `get_turn_deflection()` and its course error to `get_guidance_target()`, and rolls only the visual wrapper.
  - A turn under 70° heels outward 4°; 70° or more banks inward 9°.
  - The class is fixed per order or route bend and mirrors left and right.
  - The roll changes at up to 7 °/s and returns to level when the course is within 3°, on stop or arrival, during reversal braking, and on starts from rest.
  - Values live in `Ships/Profiles/frigate_bank_profile.tres`.
- `Main/right_click_move_input.gd`: temporary scene input glue.
- `project.godot` sets the main scene, opens the window maximized with `canvas_items`/`expand` stretch, and enables physics interpolation.

The protected model `Assets/Ships/Whitebox/Arrata_Frigate_001.glb` and its sidecar are unchanged. Do not edit, relocate, rename, rescale or repivot them.

`ARCHITECTURE.md` lists the exact inventory and tuning values.

## Accepted decisions

- 1 world unit = 1 metre; authoritative gameplay movement uses X/Z.
- Movement is the only top-level gameplay module and may use Godot APIs only. It alone owns authoritative movement; guidance (including route guidance) and locomotion stay internal.
- Translate and turn together from rest. Moving turns are continuous and broad: about 90° of travel direction in 7.5 s at cruise. Orders 150°–180° from actual travel brake fully to rest before restarting. Arrival ends commanded rotation.
- Routes: Shift + right-click appends, a plain right-click replaces. The ship moves continuously through intermediate points and brakes only for the final one. A Shift-click after the final point's 2 m arrival trigger has completed the order starts a new order, which may brake to rest first if near-opposite.
- Model-only presentation heels outward in broad maneuvers and banks inward in sharper ones. Visual tilt never affects the authoritative root or collision.
- Ship differences use shared reusable definitions and Resource configuration, with per-instance runtime state. Work happens in the one developing game scene.
- Right-click to move, with the ship already controlled (no selection). No stop key. The fixed camera looks 45° down.
- Provisional movement defaults:
  - 8 m/s max speed;
  - 6 m/s² acceleration and 10 m/s² braking;
  - 20 °/s hull yaw and 12 °/s travel turn rate (slowed by the owner after playtest);
  - 150° near-opposite angle;
  - 2 m arrival tolerance;
  - 25 m route lookahead (range 2–100 m).

  Final balance comes from owner playtests.

## Known limitations

- **Short clicks at speed (accepted by the owner):** a click within 2 m of a ship at 8 m/s finishes where braking ends, up to about 3.2 m past the click (8² ÷ (2 × 10)). The 2 m tolerance triggers arrival braking; it does not guarantee the final rest distance.
- **Slow-but-moving ships:** a ship that is moving slowly but not stopped, given an order 90°–149° away, swings wider as it speeds up during the turn, because the travel turn rate is fixed in °/s.
- **Hull yaw versus travel:** the hull turns toward the guidance point at 20 °/s, so during turns it leads the travel direction.
- **Route bends slow the ship:** at the current tunings a 90° bend drops the speed to about 3.4 m/s (measured on the test route) before it recovers. The second bend of the test route is rounded about 2 m outside the corner.
- **Cut corners:** progress can jump forward when the ship's nearest route point moves onto the next leg (about 11 m at the first test corner). Travel direction, yaw and roll stay rate-limited.
- **Bends right after a start from rest:** if the first leg is shorter than the lookahead, guidance can cross its bend while the ship is still at rest, so that bend keeps a 0 deflection and does not bank.
- **Bank visibility:** at the fixed camera distance and current lighting, a 4–9° lean is subtle. Its readability is the owner's playtest call.
- **Deferred QA:** hairpin, U-turn and dense zigzag routes, rapid route editing during braking, complex chained retargets (including rapid retargets while banked), extreme movement or visual tunings, other hull proportions and multi-ship scale are not validated. There is no obstacle routing, obstacles, collision response, route display, pitch, selection or UI.

## Remaining work

Final banking values and the route lookahead feel await owner playtest. Obstacle/collision/avoidance behavior remains undecided. There is no measured performance target.
