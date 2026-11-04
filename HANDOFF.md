# Handoff

## Current state

Daung has open-space ship movement on **Movement v3, slices 1–4** (Task #27 propulsion, Task #28 powered turning, Task #29 retro thrusters and Task #30 reaction delay; all four tasks of the Movement v3 rewrite). It replaces the earlier heading-and-throttle locomotion, routes, navigation, destination resolution, the obstacle hard stop and banking entirely.

Running the project opens `Main/main.tscn`:
- **Scene:** one frigate at the origin facing −Z; 2 m ring markers at (100, 0, 0), (0, 0, 0), (60, 0, 0), (60, 0, −40) and (20, 0, −40); the grey 6 m test sphere at (83, 0, 0).
- **Collision isolation:** the ship's collision mask is 0 in this scene, so it passes through the sphere.
- **Test area:** the inert 800 × 800 m navigation floor; nothing bounds the ship.
- **Camera:** starts at the 45° view. **Middle-drag** pans and the **wheel** zooms; the camera never follows the ship.
- **Orders:** right-clicking the Y = 0 plane orders the ship straight there. Each order acts after the crew reaction delay (0.3 s) counted from its own click; until then the current order stands. A second click inside the delay does not cancel the first: both act at their own times, in click order. Shift + right-click does nothing.
- **F4 (temporary, test-only):** calls `stop()` for the stopping comparison; it waits the same reaction delay. It is diagnostic debt, not a game control; remove it when a better test method is approved.
- **F3** toggles a readout of speed, velocity, heading, course heading, turn rate and its limit, applied angular acceleration, rudder multiplier, shared-capacity scale, desired speed, planned braking, main-engine command, thruster command (magnitude and XZ), active destination or no active order, and the command queue (physics clock, pending count, next pending command and its due time, last receipt and activation times). The Output panel logs every receipt and activation with its time.
- **F3 trail (Task #37):** the same F3 press also shows a thin cyan line through the ship's actual recorded positions (sampled after each physics move, a point every 0.1 m or more, drawn 0.05 m above Y = 0): turns, drift, overshoot and corrections. It never draws to the click and predicts nothing. It stays when the ship rests; F3 off erases it; F3 on starts a fresh trail at the ship. At 4096 points (about 410 m of path) the oldest points are dropped and tracing continues. Nothing is recorded before the first F3 press.
- **F3 destination marker (Task #38):** with F3 on, a magenta ring (slightly larger than the amber rings, drawn 0.1 m above the plane) appears at the latest right-click **the moment it is received**, while the order still waits its reaction delay. A newer right-click moves it at once; the queued orders still activate in click order. It disappears once the ship has no active order and nothing pending (last move completed, or a stop has taken effect). F3 off hides it without forgetting a still-relevant click; F3 on shows it again. Shift-click and F4 never create one.

**How it moves** (`Movement/ship_movement.gd`, `ShipMovement`):
- **Reaction delay:** `move_to()` and `stop()` only receive a command into one first-in-first-out queue, due `reaction_delay` (0.3 s) later on Movement's physics clock. At the start of each physics tick every due command activates in receipt order: a move sets the destination and the course from where the ship is then; a stop ends the order (ordinary braking). Nothing is cancelled or skipped, and stop has no bypass. Delay 0 acts on the next tick.
- **One velocity:** one world planar velocity and one heading.
- **Pilot:** each physics tick it wants to move toward the destination at `min(15, sqrt(2 · a_plan · distance))` m/s, where `a_plan = 12 / (1 + turning demand fraction)`: 12 m/s² with no turn, 6 m/s² while turning takes its full share. Without retro thrusters it is further limited to `5.4 / s`, where `s` is the actual travel direction's share along the bow (when positive): 5.4 m/s² moving bow-first, 12 sideways or stern-first. It requests the acceleration that closes the gap to the actual velocity in 0.25 s.
- **Main engine:** supplies the forward part along the bow, up to 12 m/s². It never fires while the ship has any stern-first motion, so it never brakes.
- **Thrusters:** supply the rest in any direction from one 60 / 5 = 12 m/s² rating, shared with turning (below).
- **Forward together:** forward, engine and thrusters add up to 24 m/s² (owner-approved Option A).
- **Integration:** only applied acceleration is integrated, and the speed is hard-capped at 15 m/s.
- **Turning:** the pilot steers the bow toward the order's **course heading**, set once when the move activates, toward the click; overshoot corrections never change it, a new order replaces it. Authority is `120 / 5 = 24°/s²` × the rudder curve of **actual** speed: 0 at rest, 1× at 7.5 m/s, 1.5× at 15 m/s (linear). It winds up and counter-turns with bounded angular acceleration (braking-distance rule), planning the counter-turn on the share it gets beside last tick's thruster demand: `authority / (1 + last planar fraction)`. The turn rate is limited to 60°/s at 15 m/s, scaled down by the same curve (40°/s at 7.5 m/s, 0 at rest). Yaw never rotates the velocity. Without an order or at zero speed the turn rate is 0, so rotation never persists without powered turning, and a ship at rest never turns in place.
- **Shared capacity:** thruster and turning demand are fractions of their ratings; when they sum above 1, both are scaled proportionally. At full demand on both, crabbing/braking gets 6 m/s² and turning half its authority. The main engine is outside this.
- **Retro thrusters** (`retro_thrusters`, default true): without them, the thrusters' acceleration toward the stern is capped at `0.45 × 12 = 5.4 m/s²` after sharing; only the excess sternward part is removed (lateral and bow-forward thrust are unchanged, nothing is scaled up). This weakens braking from bow-first travel **and** stern-first acceleration (owner-provisional: "Yes I agree until I see it"). The pilot plans its approach with the same limit, so it starts braking earlier.
- **Arrival:** within 2 m **and** at most 0.5 m/s. Afterwards, and after `stop()`, the thrusters brake toward zero velocity. There is no snap and no position hold, and overshoot can happen.
- **Bad profile:** a missing profile, a missing rudder curve, any numeric value ≤ 0 or a negative `reaction_delay` logs an error and the ship does not move.

**Files:**
- `Movement/movement_profile.gd` (`MovementProfile`, twelve provisional values; script defaults now equal the frigate profile, the rudder curve lives in the `.tres`) and `Movement/Profiles/frigate_movement_profile.tres`. `ARCHITECTURE.md` lists the values, units and ranges.
- `Ships/ship.tscn`: movement root, provisional box collision shape, `Visual` (plain `Node3D`) with the protected GLB at identity.
- `Main/right_click_move_input.gd` (right-click, its `move_requested` signal and the test-only F4), `Main/camera_pan_zoom.gd`, `Main/movement_debug_overlay.gd` (F3, also toggles the trail and drives the `DebugDestinationMarker` node in `Main/main.tscn`) and `Main/movement_trail.gd` with `Main/movement_trail_settings.gd` / `.tres` (trail cap 4096 points, sample spacing 0.1 m): temporary scene glue.
- **Inert:** `TestObstacle`, `NavigationFloor`, `NavigationRegion3D` and `Main/navigation_mesh.tres` remain in the scene but nothing uses them.
- **Deleted in Task #27** (Git history, `main` at a174d22): `Movement/maneuver_plan.gd`, `Ships/ship_visual_bank.gd`, `Ships/ship_bank_profile.gd` and `Ships/Profiles/frigate_bank_profile.tres`.

The protected model `Assets/Ships/Whitebox/Arrata_Frigate_001.glb` and its sidecar are unchanged. Do not edit, relocate, rename, rescale or repivot them.

## Accepted decisions

- 1 world unit = 1 metre; authoritative gameplay movement uses X/Z.
- Movement is the only top-level gameplay module and may use Godot APIs only. It owns open-space position, world planar velocity and yaw; pilot guidance and propulsion are internal. Since Task #27 it does not own path queries, route corners or destination resolution.
- **Movement v3 rewrite (Task #27, approved ticket and plan revision 1):**
  - **No adaptations:** a rewrite, not an adaptation of the old locomotion.
  - **No mass-derived extras:** no mass-derived throttle ramp and no mass-derived braking optimism.
  - **Main engine:** pushes along the bow only and never brakes.
  - **Thrusters:** one vector budget `thruster_strength / mass` shared by braking and crabbing.
  - **Forward:** forward thrust stacks with the engine (Option A).
  - **Braking:** only the thrusters stop the ship in this slice.
  - **After arrival or `stop()`:** no position hold.
  - **Invalid profiles:** fail closed.
  - **Collision isolation:** the scene's collision mask 0 is test isolation, not a collision design.
- **Powered turning (Task #28, approved ticket and plan revision 2):**
  - **Heading target:** the intended travel of the order (owner D1), held as one **course heading per order** set by `move_to()` (owner choice in PR #32, replacing the per-tick desired-velocity target that caused the late arrival spin). The A1 trial (no turning while braking against motion) was not implemented.
  - **Sharing:** turning and planar thrust share the directional-thruster capacity proportionally; no independent turning, no translation-priority leftovers, no budget coefficient (owner D4).
  - **Shared-capacity planning (owner-approved trial, PR #32):** the approach speed plans braking at `a_t / (1 + f_r)` and the yaw counter-turn plans at `α_max / (1 + f_t_prev)`. One extra float per ship (last tick's planar fraction); no phase, threshold or smoothing.
  - **No unpowered spin:** "Rotation should not persist without thrust." The turn rate drops to 0 in one tick when powered turning ends (heading continuous); no angular drag.
  - **Authority:** from actual speed through the rudder curve; zero at rest. One speed-linked turn-rate limit (owner-approved trial, PR #32); no phases, angle classes or reversal threshold. No final alignment.
- **Banking:** deferred; the old bank files were deleted with owner approval (Task #27). Visual tilt must never affect the authoritative root or collision.
- **Reaction delay (Task #30, approved ticket as corrected by the tech lead's audit, plan revision 1):**
  - **Rule:** every command, move and stop, waits its own `reaction_delay` from receipt; the old order stands until then; a later command never cancels an earlier pending one; due commands apply in receipt order.
  - **Stop:** delayed like moves, no emergency bypass (owner: "Yes").
  - **Activation:** a move takes its course from the ship's position at activation; the pilot and propulsion are unchanged.
  - **Default:** 0.3 s (owner's veteran-crew example) is a provisional trial; 3.0 s (green crew) is only the decisive-check override.
- **F3 trail (Task #37, approved ticket and plan revision 1):** debug-only; draws past observed positions only, never a destination line or prediction; one F3 toggle with the readout; starts hidden and inactive. **At capacity, discard the oldest points and continue tracing** (tech lead decision, issue #37). The cyan 1 px line is a provisional debug appearance, not an owner visual decision.
- **F3 destination marker (Task #38, approved ticket as corrected, plan revision 2):** the marker shows the latest **received** right-click immediately, without bypassing the reaction delay (owner chose A). It must be visibly distinct from the fixture rings at the same point (tech lead decision, issue #38): shared torus geometry, its own magenta material, node scale 1.25. Magenta and the scale are a provisional debug appearance. Debug scene glue only; it is not a gameplay command-feedback system.
- **Retro thrusters (Task #29, approved ticket as corrected, plan revision 2):**
  - **Capability:** one yes/no per hull. Without retro thrusters the sternward thruster component is capped at 45% of the thruster rating; same budget, no second braking strength, no braking optimism.
  - **Order:** shared capacity first, then the sternward cap; removed capacity is not reallocated.
  - **Planning:** the approach plans with the same cap, projected on the actual travel direction (the click direction only at zero speed).
  - **Stern-first:** the cap also weakens stern-first acceleration (owner-provisional, subject to playtest).
  - **Default:** `retro_thrusters = true` is a provisional test setting, not final Arrata equipment.
- **Earlier movement decisions** (`ARCHITECTURE.md`): Task #28 superseded the near-opposite rule; arrival ends commanded rotation. Routes are not implemented; later tickets state whether they carry over.
- Ship differences use shared reusable definitions and Resource configuration, with per-instance runtime state. Work happens in the one developing game scene.
- **Input:** right-click to move, with the ship already controlled (no selection). No stop key. The camera looks 45° down, pans with middle-drag and zooms with the wheel, and does not follow the ship.
- **Provisional movement values** (Tasks #27–#29, placeholders):
  - mass 5;
  - main acceleration 12 m/s²;
  - thrusters 60 (12 m/s²);
  - max speed 15 m/s (owner tuning trial 2; was 50, then 20 in trial 1);
  - pilot response 0.25 s (owner tuning trial 1, was 0.5);
  - arrival 2 m and 0.5 m/s;
  - turn authority 120 (24°/s² at 7.5 m/s, 36°/s² at 15 m/s before sharing) and the linear rudder curve (0,0), (0.5,1), (1,1.5) (owner-approved trial, Task #28);
  - turn-rate limit 60°/s at max speed (owner-approved trial, PR #32);
  - retro thrusters on, no-retro effectiveness 0.45 (Task #29);
  - reaction delay 0.3 s (Task #30).

  The owner rejected the first feel (too fast, too much overshoot). After playtesting trial 1 (20 m/s, 0.25 s), the owner asked for 15 m/s. These values are approved as trials only, not as final balance. If the pickup is still too sharp afterwards, the tech lead's next proposal is weaker main acceleration and thrusters together (for example 6 m/s² and 30). That is not applied.

## Known limitations

Values were measured with deterministic 60 Hz headless traces of the shipped profile in `Main/main.tscn` (Tasks #28 and #29). The movement numbers below are from the click with no reaction delay; with the 0.3 s default every order starts 0.3 s later (forward 100 m arrives 9.13 s after the click). With `reaction_delay = 0` the Task #30 traces reproduce them exactly (forward 100 m 8.85 s, sideways 10 m 2.75 s, sideways 100 m 9.75 s). With retro thrusters on, all seven Task #29 traces are identical to `main` before Task #29. Task #28's numbers are in PR #32; Task #27's fixed-heading numbers are in PR #31. Owner F5 playtest after Task #28: "Playtested, none of the issues are there." Task #30's traces are in PR #35. Owner F5 playtest of PR #35 (3.0 s two-click check): "Done, again after playtest it behaces as intended."

- **Reaction-delay decisive check (Task #30, 3.0 s, headless):** A to (100, 0, 0) received at 0.000 s activates at 3.017 s; B to (0, 0, −100) received at 1.000 s activates at 4.017 s. A is active for 1.0 s in between (ship 3.15 m toward A, 6.1 m/s), then B takes over and arrives at 13.00 s. Before 3.017 s the ship stays at rest with two pending.
- **Reaction-delay edge cases (headless):** stop then move received at 8.0 / 8.5 s while cruising at 15 m/s activate at 11.0 / 11.5 s; the stop brakes from 14.8 m/s (no speed reset). Move then stop: both act, 0.5 s apart. Two moves on the same tick both activate on one tick in order (the second decides). Delay 0: activation on the next tick. An order that arrives while the next command waits ends normally (4.97 s), and the waiting command activates on time (7.02 s).
- **Tick quantization:** activation lands 0 or 1 physics tick (≤ 16.7 ms) after the due time, depending on float summation of the clock (3.017 s or 3.000 s for 3.0 s). Not smoothed.

- **Retro decisive check (F4 at ≥ 14.5 m/s, moving forward):** with retro 9.01 m to rest (8.90 m to 0.5 m/s, 1.40 s); without retro 19.55 m (19.43 m, 2.68 s), about 2.2×; peak sternward thrust 12 vs 5.40 m/s². Ideal references 8.76 m and 19.47 m from 14.5 m/s.
- **Without retro, ordinary orders (arrival, overshoot):** forward 100 m: braking starts 20.5 m before the click instead of 9.0 m, 2.94 m overshoot and one return as with retro (2.52 m), arrival 9.97 s instead of 8.85 s. Sideways 100 m 10.87 s, rearward 100 m 11.02 s (weaker stern-first pickup), diagonal 45° 10.28 s, all 2.9 m and one return. 10 m sideways is unchanged (2.75 s), because the hull only reaches −24.8° and the sternward share stays under the cap. Moving 180° retarget from 15 m/s: planned 5.40 m/s² and applied sternward 5.40 m/s² while the forward motion is slowed; arrival 14.87 s instead of 13.53 s, two crossings and the same number of slow-downs as with retro (no added settle–move–settle).

- **Owner decisive check, 10 m sideways from rest:** one crossing of the click, no return. Braking is planned at 6 m/s² while the turn holds its share; the ship passes the click at 2.05 s, stops 1.77 m past it and completes at 2.75 s (heading −24.8°; the turn continues toward the course while braking, 9.1° after the crossing, and stops at arrival from 3°/s). Before shared planning: 3.95 m overshoot, back through the click, 4.92 s, 26° of yaw after the crossing.
- **Sideways 100 m:** unchanged. Tick 1 yaw 0.000° and thrusters 12 m/s²; aligned at −90° after 4.63 s (0.28° past); peak 52°/s; 2.52 m overshoot; arrival 9.75 s facing −90.0°; no yaw after the first crossing.
- **Other orders (arrival, overshoot):** forward 100 m 8.85 s, 2.52 m; rearward 100 m 9.77 s, 2.53 m (stern-first, 60°/s limit); short 5 m 1.97 s (stops 1.1 m past); short 15 m 4.75 s, 2.25 m and one return; turn + brake from 15 m/s 5.75 s, 2.71 m (was 9.63 s, three crossings); cruising −Z at 15 m/s with an order 45°/90°/135° right: 8.85 / 10.65 / 12.50 s, about 2.5 m, heading crossing ≤ 0.13°; straight behind 11.02 s, 2.41 m; reverse retarget to the origin at 5 s 16.83 s, 4.36 m (was 16.53 s, 6.62 m; heading crosses 3.3°). Every order completes, with no orbit; yaw never moves after completion.
- **Shared-planning costs:** when the turn's share ends at alignment, the planned braking returns from 6 to 12 m/s², and the desired speed steps up by as much as 3.8 m/s in one tick (moving 180°). Actual speed still never rises faster than one normal step (0.2 m/s per tick); the step shows as thrust. The reverse retarget arrives 0.3 s later. Short orders stop up to 1.8 m past the click rather than returning.
- **Rate limit (game rule):** the speed-linked 60°/s clamp also removes up to 0.9°/s per tick that the thrusters did not brake, on short orders and reversals; zero on 45°/90° moving turns and long sideways orders.
- **Path shape while moving at 15 m/s:** tightest radius 31 m at 45°, 12 m at 90°, 2 m at 135°; a 180° order stops and comes back.
- **Turning stops without power:** `stop()` mid-swing drops the rate from 18°/s to 0 in one tick (heading continuous). Arrival likewise ends rotation.
- **Small cases:** a click at the ship's own position has no course; it completes on the next tick, with no motion or yaw.
- **Turn-rate sign flips near ±180°:** on rearward and 180° orders the turn rate changes sign many times per second around the course (196–379 sign changes per order); the same counts with retro happen on `main` before Task #29. Not investigated.
- **Not re-measured in Task #28 or #29:** the stern-first stop, passing within 2 m above 0.5 m/s, and the mass-0 profile (the code paths are unchanged from Task #27).
- **Overshoot is expected:** there is no arrival snap and no final alignment; the ship rests up to about 1.8 m from the click; on short orders it can stop before the hull reaches its course.
- **Gone for now:** routes, Shift-click waypoints, navigation, detours, destination resolution, obstacle stop, collision response and banking. The ship flies through the test sphere.
- **No world bounds:** the ship can be ordered anywhere on the Y = 0 plane.
- **Camera far plane:** 1000 m; at maximum zoom the far part of the area can fall beyond it. Not checked in F5.
- **No player-facing pending-order indicator:** outside F3 a pending command shows only in the Output log.
- **F3 destination marker (Task #38, headless and windowed trace, reaction delay 3.0 s in memory):** clicks on (100, 0, 0) at 0.117 s and (60, 0, −40) at 1.133 s: the marker appears on receipt and jumps to the second click in the same input handling; the orders activate at 3.133 s and 4.150 s in click order, and the marker never leaves the latest click; it clears at 10.90 s when the last move completes. Move then F4: the marker stays while the stop is pending and clears on the frame after the stop activates. Not checked: the look in F5. Edge behavior by design: if a move completes while a later stop is pending, the marker stays until the stop activates; a click on the ship's own position shows it for about one frame. Headless runs print one dummy-renderer error (`material_get_instance_shader_parameters`, null material) for the new material; the Vulkan renderer prints none.
- **F3 trail (headless, Task #37):** sideways 100 m order: 636 points, every segment ≤ 0.25 m (one tick at 15 m/s, no jump to the click), every sample within 0.1 m of the ship's post-move position, no growth at rest, nothing recorded before F3 or while off. A cap lowered to 256 held at 256 with no long segment. Not checked: legibility in F5 and at maximum zoom; the newest point can lead the interpolated drawn ship by up to one tick (≤ 0.25 m), inside the hull.
- **Not verified:** the profile guard for a 0 effectiveness value (range 0.1–1.0 prevents it in the inspector).
- **Deferred QA:** unusual yaw while braking without retro, close overshoot recoveries, future hull profiles, equipment failure or damage, high-speed tight loops, corners, obstacles, routes, negative or inverted tuning, pathological fast retargets, extreme rudder-curve shapes and multi-ship performance.

## Remaining work

**Next:** none queued after Task #38 (F3 destination marker); the next task arrives as a new ticket.

**Open owner decisions:** long-term command feedback and whether crew changes may modify the reaction delay; whether the no-retro stern-first weakening feels right (provisional); keep the speed-linked turn-rate clamp as a game rule or replace it with powered counter-turn braking; later, a weaker-directional-thrust trial.

Later: routes and navigation, destination resolution, collision response and banking, each through its own ticket. Route-failure notifications, impact feedback, collisions with other body types and obstacle appearance remain undecided. There is no measured performance target.
