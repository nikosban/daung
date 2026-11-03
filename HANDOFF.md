# Handoff

## Current state

Daung has open-space ship movement with moving turns, near-opposite reversals, model-only banking, player-defined routes, a hard stop on static obstacles and automatic detours around them for normal right-clicks (Tasks #3, #5, #7, #9, #11 and #13). Running the project opens `Main/main.tscn`: a fixed camera, one frigate at the origin facing −Z, 2 m ring markers at (100, 0, 0), at the start location (0, 0, 0) and at the route test points (60, 0, 0), (60, 0, −40) and (20, 0, −40), and a grey 6 m radius test sphere at (83, 0, 0) that blocks the straight path to (100, 0, 0). Right-clicking the Y = 0 plane orders the ship there, around the sphere if needed; Shift + right-click appends a manual waypoint.

- `Movement/`: the `MovementProfile` Resource (ten provisional tunables), the shared `frigate_movement_profile.tres`, and `ShipMovement` (`CharacterBody3D`), the single writer of planar position, velocity and yaw, with `move_to()`, `append_waypoint()` and `stop()`.
- **Each new order (`move_to`) is classified once, from the actual travel velocity:**
  - at rest: translate and turn together;
  - 150° or more from travel: brake to rest, then start from rest;
  - anything else: a moving turn limited by 1.7 m/s² of directional thrust (`lateral_acceleration`: about 12 °/s of travel direction at 8 m/s, tighter at lower speeds), slowing for near goals (pure-pursuit cap).
- **Routes:** each ship keeps its own route (the anchor, then the requested points; never empty).
  - A plain right-click replaces the whole route. Godot navigation is queried once: if the path bends and ends at the click, its points become a detour route to the original click; otherwise the click is aimed at directly, exactly as before.
  - Shift + right-click appends a manual point without navigating, re-classifying, restarting or braking. With no active order it starts a direct order (no detour).
  - On manual multi-point routes the ship steers at a point 25 m further along the route (`route_lookahead_distance`), so it rounds bends early and may cut corners. Detours use 20 m (`detour_lookahead_distance`), blending to 25 m over the last 20 m before the detour's final point when manual points follow. Progress never goes backward. Intermediate points are guidance, never arrival targets.
  - For a detour, the 150° reversal check uses the initial guidance point (20 m along the detour), not the first leg or the click.
  - When guidance crosses a bend, the turn deflection is reset from the actual travel direction to the new leg, so banking follows the current bend.
  - `stop()` clears the whole route.
- Entering the 2 m tolerance of the final point completes an order. The ship brakes to rest along its travel and may coast past without turning back. A click inside 2 m is an arrival, never a reversal.
- **Static obstacles:** moving into a `StaticBody3D` (not an `AnimatableBody3D`) ends the whole order, pending points included, with an immediate stop at the contact; it stays the safety fallback for direct orders and manual legs. A ship resting against an obstacle can be ordered away from it. Other body types keep the engine's default sliding; their behavior is undecided.
- **Navigation:** `Main/main.tscn` has a `NavigationRegion3D` with the baked `Main/navigation_mesh.tres` (10.75 m clearance, 7 m agent height), baked from the colliders in group `navigation_source`: `TestObstacle` and an invisible 400 × 400 m `NavigationFloor` on layer 2 that the ship never touches. Rebake (select `NavigationRegion3D`, Bake NavigationMesh) after changing them.
- **Startup readiness:** Godot's asynchronous navigation is usable from about physics frame 4–5 (≈ 70–83 ms). A normal click before then is held (only the latest), then planned on the first ready tick; a Shift-click drops it and starts a direct order; `stop()` drops it. If navigation settles with no usable data (no region, an empty or missing mesh), the click becomes a direct order.
- **Fallback:** a click off the navigation mesh, inside the obstacle's clearance, or with no usable navigation becomes a direct order and hard-stops on contact. No failure is reported.
- `get_destination()` returns the final point; `get_guidance_target()` returns the point currently steered at. Both are always defined, including at startup and after `stop()`, arrival or a blocked stop.
- `Ships/ship.tscn`: the reusable ship. It has the movement root, a provisional box collision shape with no collision rules, and the protected GLB as a `Visual` child at identity.
- **Banking:** `Visual` runs `ShipVisualBank`, which reads Movement's `get_turn_deflection()` and its course error to `get_guidance_target()`, and rolls only the visual wrapper.
  - A turn under 70° heels outward 4°; 70° or more banks inward 9°.
  - The class is fixed per order or route bend and mirrors left and right.
  - The roll changes at up to 7 °/s and returns to level when the course is within 3°, on stop or arrival, during reversal braking, and on starts from rest.
  - Values live in `Ships/Profiles/frigate_bank_profile.tres`.
- `Main/right_click_move_input.gd`: temporary scene input glue.
- `Main/main.tscn` `TestObstacle`: a temporary `StaticBody3D` collision and navigation test fixture (sphere shape and plain grey mesh, radius 6 m), not asteroid art.
- `project.godot` sets the main scene, opens the window maximized with `canvas_items`/`expand` stretch, and enables physics interpolation.

The protected model `Assets/Ships/Whitebox/Arrata_Frigate_001.glb` and its sidecar are unchanged. Do not edit, relocate, rename, rescale or repivot them.

`ARCHITECTURE.md` lists the exact inventory and tuning values.

## Accepted decisions

- 1 world unit = 1 metre; authoritative gameplay movement uses X/Z.
- Movement is the only top-level gameplay module and may use Godot APIs only. It alone owns authoritative movement; guidance (including route guidance) and locomotion stay internal.
- Translate and turn together from rest. Moving turns are continuous and broad: about 90° of travel direction in 7.4 s at cruise; the travel turn comes from bounded directional thrust, so slower ships turn tighter (owner-approved trial, Task #13). Orders 150°–180° from actual travel brake fully to rest before restarting. Arrival ends commanded rotation.
- Routes: Shift + right-click appends, a plain right-click replaces. The ship moves continuously through intermediate points and brakes only for the final one. A Shift-click after the final point's 2 m arrival trigger has completed the order starts a new order, which may brake to rest first if near-opposite.
- Model-only presentation heels outward in broad maneuvers and banks inward in sharper ones. Visual tilt never affects the authoritative root or collision.
- Ship differences use shared reusable definitions and Resource configuration, with per-instance runtime state. Work happens in the one developing game scene.
- Right-click to move, with the ship already controlled (no selection). No stop key. The fixed camera looks 45° down.
- Obstacles: the immediate hard stop on contact, including grazing contacts, and the grey 6 m test sphere at (83, 0, 0) are provisional. Normal right-clicks detour around static obstacles with Godot navigation (`NavigationRegion3D` + baked mesh, one `query_path` per order, original click kept as the destination); Shift-built legs stay manual until the next slice, which must reuse the same path query and clearance method.
- Navigation stays asynchronous (engine defaults); no `map_force_update()`.
- Provisional movement defaults:
  - 8 m/s max speed;
  - 6 m/s² acceleration and 10 m/s² braking;
  - 20 °/s hull yaw;
  - 1.7 m/s² lateral acceleration (directional thrust, range 0.1–20), replacing the former fixed 12 °/s travel turn rate; provisional trial value;
  - 150° near-opposite angle;
  - 2 m arrival tolerance;
  - 25 m route lookahead for manual routes (range 2–100 m);
  - 20 m detour lookahead (range 2–100 m), provisional;
  - 1 m detour corner tolerance (range 0.1–10 m), provisional trial value;
  - 0.1 m path simplify epsilon (range 0.01–1 m);
  - navigation clearance `agent_radius` 10.75 m and `agent_height` 7 m in `Main/navigation_mesh.tres`.

  Final balance comes from owner playtests.

## Known limitations

- **Short clicks at speed (accepted by the owner):** a click within 2 m of a ship at 8 m/s finishes where braking ends, up to about 3.2 m past the click (8² ÷ (2 × 10)). The 2 m tolerance triggers arrival braking; it does not guarantee the final rest distance.
- **Slow-speed turns are tight:** the travel direction turns at `lateral_acceleration / speed`, so below cruise it turns much faster than at 8 m/s (about 24 °/s at 4 m/s, 49 °/s at 2 m/s) and almost freely below 1 m/s. The hull still yaws at 20 °/s. A 90° order at about 4 m/s arrived 4.1 s sooner than with the former 12 °/s limit.
- **Hull yaw versus travel:** the hull turns toward the guidance point at 20 °/s, so during turns it leads the travel direction.
- **Route bends slow the ship:** at the current tunings a 90° bend drops the speed to about 5.2 m/s (measured on the test route; 3.4 m/s with the former 12 °/s limit) before it recovers. The route's path is unchanged within 0.06 m, and it finishes 3.2 s sooner. The second bend of the test route is rounded about 2 m outside the corner.
- **Cut corners:** progress can jump forward when the ship's nearest route point moves onto the next leg (about 11 m at the first test corner). Travel direction, yaw and roll stay rate-limited.
- **Bends right after a start from rest:** if the first leg is shorter than the lookahead, guidance can cross its bend while the ship is still at rest, so that bend keeps a 0 deflection and does not bank.
- **Abrupt stop:** a blocked ship goes from up to 8 m/s to 0 in one physics tick at the contact (head-on: root X ≈ 66.97, about 1 mm from the sphere). There is no pre-brake or impact feedback.
- **Grazing contacts stop the ship:** any motion into the obstacle's surface counts, however shallow. Within the impact tick the engine may slide the ship by at most one tick of motion (≈ 0.13 m at 8 m/s; 0 head-on) before the stop.
- **Pure sideways order from contact stays blocked:** when the ship rests against an obstacle and is ordered exactly sideways, the hull's yaw swings its corner into the surface, which counts as a grazing contact and stops it again. Orders with any away component (e.g. back to (0, 0, 0)) escape.
- **Detour clearance is measured, not guaranteed:** the test detour from (0, 0, 0) to (100, 0, 0) keeps the hull 6.77 m from the sphere at its closest, and the return journey from rest at (100, 0, 0) to (0, 0, 0) keeps 6.04 m (it previously hard-stopped). Other obstacle shapes, approach angles, speeds or hull sizes are not validated, and there is no universal collision-safe radius. Raising `agent_radius` above about 11 m makes the test ring unreachable (fallback).
- **Detour guidance pins and jumps at corners (trial result, under review):** with bounded directional thrust the ship runs about 1–1.8 m outside the detour. Once it is more than `detour_corner_tolerance` from the route, no chord past the next detour point fits, so guidance pins to that point and jumps forward when the ship passes it. On the return journey this jumped 14.9 m and 18.7 m in one tick, and the near-goal cap dipped the speed to 3.3–4.4 m/s; the forward detour dips to 4.7 m/s. The ship never stops, and travel direction, yaw and roll stay rate-limited.
- **Pending order is invisible:** while a click waits for navigation (≈ 70–83 ms after start), `has_destination()` and the other getters still show the previous state.
- **Single region:** readiness waits for every region on the map to sync and is ready once any region with data is merged; partial readiness across several regions is not handled.
- **Static navigation data:** one finite author-time surface; moving or editing obstacles needs a rebake. No live replanning.
- **Bank visibility:** at the fixed camera distance and current lighting, a 4–9° lean is subtle. Its readability is the owner's playtest call.
- **Deferred QA:** hairpin, U-turn and dense zigzag routes, rapid route editing during braking, complex chained retargets (including rapid retargets while banked), extreme movement or visual tunings, other hull proportions and multi-ship scale are not validated. Grazing-contact feel, dense obstacle fields, high-speed tunneling at extreme tunings, moving/dynamic obstacles and ship–ship contact are not validated. Multiple or overlapping obstacles, narrow passages and detours entered mid-motion or with sharp path entries are not validated. There are no Shift-leg detours, avoidance, route display, pitch, selection or UI.

## Remaining work

Final banking values, the route lookahead feel and the hard-stop feel await owner playtest. The next planned slice is automatic detours for Shift-built legs. Route-failure notifications, impact feedback, collisions with other body types and obstacle appearance remain undecided. There is no measured performance target.

**Refinement notes (owner, Task #13):**
- The 20 m detour / 25 m manual lookahead split is provisional. Revisit the detour's clearance, rounding, speed and turning feel with more obstacle shapes, approaches and hull sizes. Do not silently merge these tunings or declare a universal collision-safe radius.
- The pending-order startup handling is a provisional startup policy. Revisit it once navigation becomes larger or dynamic and more command types need coordination; measure readiness latency and verify latest-order replacement before any generalized orchestration.
- Reversal classification against the initial guidance point is the current technical rule. Verify it on mid-motion retargets and sharp path entries; refine only if later evidence or owner feel requires it.
