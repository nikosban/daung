# Handoff

## Current state

Daung has open-space ship movement on **heading-and-throttle locomotion** (Task #25, the owner's Movement v2 proposal; it replaces the Task #19–#23 desired-velocity controller). It also has model-only banking, player-defined routes, a hard stop on static obstacles, automatic detours around them for normal right-clicks, and resolution of occupied or off-surface destinations (Tasks #3–#15).

Running the project opens `Main/main.tscn`:
- **Scene:** one frigate at the origin facing −Z; 2 m ring markers at (100, 0, 0), at the start location (0, 0, 0) and at the route test points (60, 0, 0), (60, 0, −40) and (20, 0, −40); a grey 6 m radius test sphere at (83, 0, 0) that blocks the straight path to (100, 0, 0).
- **Test area:** **800 × 800 m** (navigable X −339.25…439.25, Z ±389.25).
- **Camera:** starts at the old 45° view. **Middle-drag** pans and the **wheel** zooms; the camera never follows the ship.
- **Orders:** right-clicking the Y = 0 plane orders the ship there, around the sphere if needed. A click on the sphere or too close to it goes to about (75.4, 0, −15.2). Shift + right-click appends a manual waypoint.
- **F3** toggles a readout of the phase, heading and commanded heading, speed and commanded speed, and slip.

- `Movement/`:
  - the `MovementProfile` Resource (nineteen provisional tunables);
  - the shared `frigate_movement_profile.tres`;
  - `ManeuverPlan` (per-order corner plan, clearance gate and the shared motion step);
  - `ShipMovement` (`CharacterBody3D`), the single writer of planar position, velocity and yaw, with `move_to()`, `append_waypoint()` and `stop()`.
- **Motion:** each tick the velocity is `bow · speed + right · slip + thruster velocity`. Yaw never rotates the thruster velocity; it does carry `speed` (deliberately non-Newtonian).
  - **Yaw:** the hull turns toward a commanded heading at up to 10 °/s, with the rate changing at up to 10 °/s², so turns ease in and out without snapping at alignment.
  - **Main engine:** speed changes along the bow at 1.0 m/s² up and 0.75 m/s² down, up to 5 m/s.
  - **Slip:** each tick of yaw adds `0.5 · speed · sin(Δyaw)` of sideways slip, which fades at 0.25 m/s².
  - **Thrusters:** push in any direction at 0.35 m/s².
- **Phases:** IDLE, TURN, CRUISE, BRAKE, TRANSLATE.
- **Each new order (`move_to`) is classified once, from the actual travel velocity:**
  - **At rest:**
    - A single leg within 15 m whose thruster-only time is at most 1.2 × turn-and-burn's is a TRANSLATE: the thrusters move the ship while the hull yaws toward the click; short moves end before full alignment.
    - Otherwise a heading error above 5° is a **departure TURN**: the hull yaws and the thrusters push toward the aim point on the same physics tick. On reaching the heading, the forward part of that thrust becomes engine speed (world velocity unchanged) and the rest fades.
    - Otherwise CRUISE.
  - **150° or more from travel:** brake to rest, then start from rest.
  - **Anything else:** a continuous moving TURN at a latched reduced speed (`min(0.6 × speed, the speed whose turn circle passes through the aim point)`), then CRUISE. There is no stop.
- **CRUISE** aims at the current leg's end at up to 5 m/s, braking ahead with 0.75 m/s² for planned corners (to their corner speed at their turn-start point) and for the final point. **BRAKE** is that final braking (and reversal braking).
- **Routes:** each ship keeps its own route (the anchor, then the requested points; never empty).
  - A plain right-click replaces the whole route, starting in the next physics tick. The click is kept exactly when it is on the navigation surface, reachable, and the hull fits there; the route follows the navigation path (a detour if it bends).
  - Otherwise (on or near the sphere, off the navigation floor, unreachable) a **destination search** picks an approximately nearest reachable point where the hull fits: rings around the click every 1 m, at most 32 samples per ship per physics tick. The previous order continues until the new one starts. If the rings pass the navigation data without a result, the order is declined: the ship brakes to rest. There is no indicator for a moved or declined destination.
  - Shift + right-click appends a manual point without navigating; the previous final point becomes a planned corner. If it arrives while a normal click is still waiting (outside startup syncing), it is appended once that order starts. With no active order it starts a direct order (no detour).
  - **Corners:**
    - **Corner speed:** each route vertex bending by more than 5° gets a corner speed of up to 3 m/s (0.6 × 5), lower if its turn would not fit half of the adjacent legs.
    - **Turn start:** the ship starts that corner's TURN `(v / yaw_rate) · tan(φ / 2)` before the vertex, aiming at the outgoing leg's direction.
    - **Clearance gate:** before a corner is used, it must pass the gate, which replays the same motion step through the turn and sweeps the hull box against static obstacles (with an overlap check at every sample).
    - **Stop-and-turn:** a corner that fails at all four speeds rests at the vertex and starts the next leg from rest. So does a corner the ship reaches before its check has finished (owner-approved Option A).
  - Intermediate points are never arrival targets. `stop()` clears the whole route.
- **Arrival:** entering the 2 m tolerance of the final point completes an order. Rotation is wound down before arrival and the heading freezes on the arrival tick. The ship then brakes to rest at 0.75 m/s² and may coast past without turning back. `stop()` and declined orders also freeze the heading on the same tick.
- **Static obstacles:** moving into a `StaticBody3D` (not an `AnimatableBody3D`) ends the whole order, pending points included, with an immediate stop at the contact. It stays the safety fallback for direct orders, manual legs, moving TURNs and stop-and-turn rotations. A ship resting against an obstacle can be ordered away from it. Other body types keep the engine's default sliding; their behavior is undecided.
- **Navigation:** `Main/main.tscn` has a `NavigationRegion3D` with the baked `Main/navigation_mesh.tres` (10.75 m clearance, 7 m agent height). It is baked from the colliders in group `navigation_source`: `TestObstacle`, and an invisible **800 × 800 m** `NavigationFloor` on layer 2 that the ship never touches. Rebake (select `NavigationRegion3D`, Bake NavigationMesh) after changing them.
- **Startup readiness:** Godot's asynchronous navigation is usable from about physics frame 4–5 (≈ 70–83 ms). A normal click before then is held (only the latest), then resolved on the first ready tick; a Shift-click drops it and starts a direct order; `stop()` drops it. If navigation settles with no usable data (no region, an empty or missing mesh), a click where the hull fits becomes a direct order and an occupied one is declined.
- **Fallback:** there is no direct order toward an occupied click any more. Direct orders remain for free clicks without usable navigation data and for Shift-built legs; the hard stop stays their safeguard. No failure is reported.
- **Hull fit:** a vertical cylinder bounding the ship's collision box at any yaw (10.685 m radius for the frigate), derived from `Ships/ship.tscn`, checked against static obstacles only.
- `get_destination()` returns the final point (the resolved one when the click moved); `get_guidance_target()` returns the end of the current leg. Both are always defined, including at startup and after `stop()`, arrival or a blocked stop.
- `Ships/ship.tscn`: the reusable ship. It has the movement root, a provisional box collision shape with no collision rules, and the protected GLB as a `Visual` child at identity.
- **Banking:** `Visual` runs `ShipVisualBank`, which reads Movement's `get_turn_deflection()` and its course error to `get_guidance_target()`, and rolls only the visual wrapper.
  - A turn under 70° heels outward 4°; 70° or more banks inward 9°.
  - The class is fixed per order or planned corner and mirrors left and right.
  - The roll changes at up to 7 °/s and returns to level when the course is within 3°, on stop or arrival, during reversal braking, and on starts from rest.
  - Values live in `Ships/Profiles/frigate_bank_profile.tres`.
- `Main/main.tscn` `TestObstacle`: a temporary `StaticBody3D` collision and navigation test fixture (sphere shape and plain grey mesh, radius 6 m), not asteroid art.
- `Main/right_click_move_input.gd`: temporary scene input glue.
- `project.godot` sets the main scene, opens the window maximized with `canvas_items`/`expand` stretch, and enables physics interpolation.
- `Main/camera_pan_zoom.gd`: temporary camera glue (middle-drag pan, wheel zoom between 15 and 400 m height, 10 % of height per notch; exported values on the `Camera3D` node).
- `Main/movement_debug_overlay.gd`: the temporary F3 readout (`MovementDebugOverlay` node); it reads Movement's read-only getters only.

The protected model `Assets/Ships/Whitebox/Arrata_Frigate_001.glb` and its sidecar are unchanged. Do not edit, relocate, rename, rescale or repivot them.

`ARCHITECTURE.md` lists the exact inventory and tuning values.

## Accepted decisions

- 1 world unit = 1 metre; authoritative gameplay movement uses X/Z.
- Movement is the only top-level gameplay module and may use Godot APIs only. It alone owns authoritative movement; guidance (including route following and the maneuver plan) and locomotion stay internal.
- **Locomotion (Task #25, approved):** heading-and-throttle per the owner's Movement v2 proposal, replacing desired-velocity chasing.
  - **From rest:** translation and yaw start on the same tick (thruster departure, the approved correction to v2).
  - **Moving orders below 150°:** continuous, with no stop rule.
  - **150° or more from actual travel:** brake to rest first (kept provisionally; powered reverse deferred).
  - **Stop-and-turn:** only at a corner that fails the clearance gate, or one still unchecked when reached (owner-approved Option A).
  - **Arrival and `stop()`:** both end rotation on that tick.
- **Routes:** Shift + right-click appends, a plain right-click replaces. Intermediate points are never arrival targets. A Shift-click after the final point's 2 m arrival trigger has completed the order starts a new order, which may brake to rest first if near-opposite.
- **Banking:** model-only presentation heels outward in broad maneuvers and banks inward in sharper ones. Visual tilt never affects the authoritative root or collision. Banking keeps reading `get_turn_deflection()` (unchanged contract).
- Ship differences use shared reusable definitions and Resource configuration, with per-instance runtime state. Work happens in the one developing game scene.
- **Input:** right-click to move, with the ship already controlled (no selection). No stop key. The camera looks 45° down, pans with middle-drag and zooms with the wheel, and does not follow the ship (Task #25).
- **Obstacles:**
  - The immediate hard stop on contact, including grazing contacts, and the grey 6 m test sphere at (83, 0, 0) are provisional.
  - Normal right-clicks detour around static obstacles with Godot navigation (`NavigationRegion3D` + baked mesh, one `query_path` per order, original click kept as the destination).
  - Shift-built legs stay manual until the next slice, which must reuse the same path query and clearance method.
- Navigation stays asynchronous (engine defaults); no `map_force_update()`.
- **Static destination resolution (Task #15):** a normal click that is off the navigation surface, unreachable or occupied by a static obstacle moves to an approximately nearest reachable point where the hull fits, searching progressively farther with no relocation limit. If none is found, the click still replaces the previous order and the ship brakes to rest. Free clicks beyond the navigation floor resolve to its edge. During a search the previous order continues; the route is built from the ship's live position when the destination is accepted.
- **Provisional movement defaults** (Task #25, the owner's v2 values, literal):
  - **Main engine:** 5 m/s max speed; 1.0 m/s² accel; 0.75 m/s² decel.
  - **Yaw:** 10 °/s yaw rate; 10 °/s² yaw accel.
  - **TURN:** turn speed factor 0.6; heading tolerance 5° (re-entry beyond 10°).
  - **Slip:** gain 0.5; decay 0.25 m/s².
  - **Thrusters:** 0.35 m/s² thruster accel; 15 m thruster range; TRANSLATE preference 1.2.
  - **Kept:** 2 m arrival tolerance; 150° near-opposite angle; 0.1 m path simplify epsilon; 1 m destination search spacing; 32 destination search samples per tick.
  - **Clearance gate:** 64 queries and 240 simulated steps per ship per physics tick.
  - **Navigation:** `agent_radius` 10.75 m and `agent_height` 7 m in `Main/navigation_mesh.tres`.

  The previous (Task #21/#23) values are in Git history (`main` at 5573f98). Final balance comes from owner playtests.

## Known limitations

All values are measured with deterministic 60 Hz headless traces of the shipped profile (Task #25). Comparisons are with `main` at 5573f98, the previous controller.

- **Starts from rest (measured):** translation and yaw begin on the first active tick for every direction.
  - **Straight 100 m:** reaches 5 m/s on active tick 300 (5.00 s). It shows BRAKE for 4.33 s, arrives 23.5 s after starting (15.4 s before) and rests 0.04 m from the click.
  - **30 m sideways:** a departure TURN for 9.0 s with thrusters, then CRUISE. It arrives after 13.5 s (6.4 s before).
  - **10 m sideways:** a TRANSLATE. It arrives after 7.3 s with the hull at −60.8° (not aligned), resting 0.02 m from the click.
  - **60 m rearward:** the hull swings 180° over 18 s while the thrusters carry it about 41 m stern-first, then it cruises. It arrives after 23.1 s (11.3 s before).
- **Hand-off from departure thrust (measured):** on the TURN → CRUISE tick, world velocity changes by 0.0169 m/s, within one tick's limits (accel + thruster + slip ≈ 0.0267 m/s).
  - **30 m sideways:** speed goes 3.000 → 3.017 m/s and the travel direction moves by 0.02°.
  - **Afterwards:** a 0.25 m/s sideways thruster remainder fades at 0.35 m/s².
- **Moving turns are slower and tighter-tracking (measured):** while cruising at 5 m/s toward −Z, a 90° order to a point 100 m to the side turns for 10.6 s, peaking at 0.23 m/s of slip. The hull stays within 4.4° of the travel direction (75° before). The ship arrives 28.6 s after the order (22.5 s before).
  - **Decisive test:** (0, 0, −100), then (60, 0, −60) at z ≈ −30. It turns for 8.0 s with no snap, slips at most 0.20 m/s, stays within 3.8° of travel, brakes for 4.35 s and arrives 19.1 s after the second order, resting 0.04 m from the click.
- **Close-range moving turns loop back once (measured; owner F5 call):**
  - **The cases:** at 5 m/s, 90° orders to points 10, 20 and 40 m to the side overshoot by up to 16.7 / 22.0 / 40.2 m from the click. The ship comes round in one continuous turn (192° / 187° / 154° of total yaw) and arrives after 23.3 / 21.2 / 20.1 s, resting 0.02–0.04 m from the click.
  - **Why:** the latched TURN speed needs about 2.7 s at 0.75 m/s² to be reached.
  - **What it isn't:** there is no stop, no repeated orbit and no failed arrival.
- **Reversals stop:** a 180° or 155° order at 5 m/s brakes to rest for 6.7 s (about 16.7 m) before the start from rest (the existing rule). The ship arrives after 33.2 / 28.2 s.
- **Stopping is long:** `stop()`, declined orders and arrival brake at 0.75 m/s². From 5 m/s that is about 16.7 m and 6.7 s (measured: 16.6 m for a declined order; 5.3 m before). The heading freezes on the same tick, even at the full 10 °/s turn rate: this is the owner's `stop()` contract, a visible abrupt end of rotation.
- **End of a turn:** on the last tick of a turn, a remaining yaw rate of at most 0.36 °/s is dropped to zero (one-tick discretization). Otherwise yaw acceleration stays within 10 °/s².
- **Routes slow down for corners:**
  - **Test route:** the manual route turns its two 90° corners at 3.0 m/s, starting each turn 17.2 m before the vertex. There are no waypoint stops. It arrives 41.9 s after the order (30.2 s before), resting 0.04 m from the final ring (1.21 before).
  - **Detours:**
    - **Forward (0, 0, 0) → (100, 0, 0):** arrives after 37.7 s (24.4 before). Arrival triggered during a corner TURN, so there was no visible BRAKE; it rests 0.50 m from the click.
    - **Return:** arrives after 33.9 s (21.7 before).
    - **Both:** zero contacts, and the minimum hull clearance to the sphere is 7.16 m (6.22 / 6.10 before).
    - **No pins or jumps:** the old detour guidance pins and jumps no longer exist; the ship follows legs with planned corners.
- **Clearance gate cost (measured):**
  - **Detours:** each detour has 6 corners, all passing on the first attempt (1.28–3.0 m/s), checked within 3 ticks: 147 queries and 542 simulated steps, at most 0.60–0.71 ms per tick.
  - **Manual route:** 2 corners checked within 6 ticks (350 queries, 1,080 steps).
  - **Extra stops from unchecked corners:** none, on either detour.
  - **Forced failure:** a corner whose turn sweeps the sphere (vertex (72, 0, −8)) failed all 4 attempts in 9 ticks (532 queries, 1,687 steps).
  - **Fleet:** 10 plans of the forward detour at once: 3 ticks, at most 5.9 ms per tick. There is no shared budget across ships; this is not a fleet solution.
- **The gate is measured, not guaranteed:**
  - **What it covers:** it checks the replayed TURN at the planned speed against static bodies only. The executed path differs slightly (per-tick re-aiming, actual speed at the turn start).
  - **What it doesn't cover:** the rotation of a stop-and-turn from rest at the vertex, and the first TURN of a moving order.
  - **Measured:** at the forced-failure corner the ship rested at the vertex, then its hull hit the sphere while turning from rest, and the hard stop ended the order. A corner the gate passed with the sphere inside the turn (vertex (70, 0, −10)) was flown with 1.25 m minimum clearance and no contact.
  - **Not implemented:** the rest-pose cylinder check mentioned in the plan, since it would have no further fallback.
- **Filter proof (measured):** a 30 m sweep through a thin plate blocks only for a `StaticBody3D`; an `AnimatableBody3D` and a `CharacterBody3D` are excluded and pass. A full overlap result (32 hits) fails closed.
- **Abrupt stop:** a blocked ship goes from up to 5 m/s to 0 in one physics tick at the contact (head-on: root X ≈ 66.97, as before). There is no pre-brake or impact feedback.
- **Grazing contacts stop the ship:** any motion into the obstacle's surface counts, however shallow.
- **Pure sideways order from contact stays blocked:** when the ship rests against an obstacle and is ordered exactly sideways, the hull's yaw can swing its corner into the surface, which counts as a grazing contact. Not re-measured in Task #25.
- **Orders start one tick later:** every normal click starts in the next physics tick (≈ 17 ms), or later while navigation syncs (≈ 70–83 ms after start) or a search runs. Until then the getters show the previous order.
- **Destination search is approximate:** samples are about 1 m apart, so the destination is approximately nearest and free pockets narrower than the spacing can be missed. A declined order does not prove that no free space exists.
- **Long searches stay pending, longer since the area grew:** the work grows with the square of the search radius (≈ 16 s pending at 100 m and ≈ 2.5 min at 300 m at 32 samples per tick). A whole-area decline now scans about twice the radius (about 4× the work) of the 400 m area; not re-measured.
- **Search cost adds up across ships:** each searching ship spends up to 32 samples per tick; there is no shared budget.
- **Single region:** readiness waits for every region on the map to sync and is ready once any region with data is merged; partial readiness across several regions is not handled.
- **Static navigation data:** one finite author-time surface; moving or editing obstacles needs a rebake. No live replanning.
- **Bank visibility:** at the camera distance and current lighting, a 4–9° lean is subtle. With slow, tightly tracked turns the course-error condition is met less often; not re-measured.
- **Camera far plane:** 1000 m. At maximum zoom (400 m height) the farthest part of the area can fall beyond it; not checked in F5.
- **Deferred QA:**
  - **Routes and retargets:** hairpin, U-turn and dense zigzag routes, rapid route editing during braking, and complex chained retargets (including rapid retargets while banked).
  - **Obstacles:** multiple or overlapping obstacles, narrow passages, dense obstacle fields, moving/dynamic obstacles and ship–ship contact.
  - **Tunings and hulls:** extreme movement or visual tunings, other hull proportions and multi-ship scale.
  - **Close range:** close-range stress, and the six moved-destination approach directions with the new controller.
  - **Not built:** Shift-leg detours or destination resolution, powered reverse, HOLD, avoidance, route display, pitch, selection and UI beyond F3.

## Remaining work

Owner F5 playtest of the Task #25 trial. The open questions it should answer:
- **Feel:** slip, turn speed and corner speed.
- **Close turns:** whether the single loop-back of close-range moving turns is acceptable.
- **Stopping:** the 16.7 m stop distance.
- **Departures:** the stern-first rearward departures.
- **Camera:** the camera limits.

Deferred original-v2 features:
- powered REVERSE (`max_reverse` 1.5 m/s, `reverse_range` 40 m), which would replace the 150° brake-to-rest;
- HOLD / station keeping;
- a public heading/speed/fleet API and `order_ended` notifications;
- timed and dynamic replanning;
- the original banking rewrite.

Other planned follow-up slices: dynamic occupancy and contact handling, and automatic detours for Shift-built legs. Route-failure notifications, impact feedback, collisions with other body types and obstacle appearance remain undecided. There is no measured performance target.

**Refinement notes (owner, Task #13, still open):**
- **Navigation clearance:** revisit it with more obstacle shapes, approaches and hull sizes. Do not declare a universal collision-safe radius.
- **Startup policy:** the pending-order startup handling is a provisional startup policy. Revisit it once navigation becomes larger or dynamic and more command types need coordination.
- **Reversal check:** reversal classification against the first aim point is the current technical rule. Verify it on mid-motion retargets and sharp path entries.
