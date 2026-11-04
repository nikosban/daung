# Handoff

## Current state

Daung has open-space ship movement on **Movement v3, slices 1–2** (Task #27 propulsion and Task #28 powered turning; Tasks 1–2 of 4 in the Movement v3 rewrite). It replaces the earlier heading-and-throttle locomotion, routes, navigation, destination resolution, the obstacle hard stop and banking entirely.

Running the project opens `Main/main.tscn`:
- **Scene:** one frigate at the origin facing −Z; 2 m ring markers at (100, 0, 0), (0, 0, 0), (60, 0, 0), (60, 0, −40) and (20, 0, −40); the grey 6 m test sphere at (83, 0, 0).
- **Collision isolation:** the ship's collision mask is 0 in this scene, so it passes through the sphere.
- **Test area:** the inert 800 × 800 m navigation floor; nothing bounds the ship.
- **Camera:** starts at the 45° view. **Middle-drag** pans and the **wheel** zooms; the camera never follows the ship.
- **Orders:** right-clicking the Y = 0 plane orders the ship straight there; a new click replaces the order at once. Shift + right-click does nothing.
- **F3** toggles a readout of speed, velocity, heading, course heading, turn rate and its limit, applied angular acceleration, rudder multiplier, shared-capacity scale, main-engine command, thruster command (magnitude and XZ), destination and order state.

**How it moves** (`Movement/ship_movement.gd`, `ShipMovement`):
- **One velocity:** one world planar velocity and one heading.
- **Pilot:** each physics tick it wants to move toward the destination at `min(15, sqrt(2 · 12 · distance))` m/s. It requests the acceleration that closes the gap to the actual velocity in 0.25 s.
- **Main engine:** supplies the forward part along the bow, up to 12 m/s². It never fires while the ship has any stern-first motion, so it never brakes.
- **Thrusters:** supply the rest in any direction from one 60 / 5 = 12 m/s² rating, shared with turning (below).
- **Forward together:** forward, engine and thrusters add up to 24 m/s² (owner-approved Option A).
- **Integration:** only applied acceleration is integrated, and the speed is hard-capped at 15 m/s.
- **Turning:** the pilot steers the bow toward the order's **course heading**, set once by `move_to()` toward the click; overshoot corrections never change it, a new order replaces it. Authority is `120 / 5 = 24°/s²` × the rudder curve of **actual** speed: 0 at rest, 1× at 7.5 m/s, 1.5× at 15 m/s (linear). It winds up and counter-turns with bounded angular acceleration (braking-distance rule). The turn rate is limited to 60°/s at 15 m/s, scaled down by the same curve (40°/s at 7.5 m/s, 0 at rest). Yaw never rotates the velocity. Without an order or at zero speed the turn rate is 0, so rotation never persists without powered turning, and a ship at rest never turns in place.
- **Shared capacity:** thruster and turning demand are fractions of their ratings; when they sum above 1, both are scaled proportionally. At full demand on both, crabbing/braking gets 6 m/s² and turning half its authority. The main engine is outside this.
- **Arrival:** within 2 m **and** at most 0.5 m/s. Afterwards, and after `stop()`, the thrusters brake toward zero velocity. There is no snap and no position hold, and overshoot can happen.
- **Bad profile:** a missing profile, a missing rudder curve or any value ≤ 0 logs an error and the ship does not move.

**Files:**
- `Movement/movement_profile.gd` (`MovementProfile`, nine provisional values; script defaults now equal the frigate profile, the rudder curve lives in the `.tres`) and `Movement/Profiles/frigate_movement_profile.tres`. `ARCHITECTURE.md` lists the values, units and ranges.
- `Ships/ship.tscn`: movement root, provisional box collision shape, `Visual` (plain `Node3D`) with the protected GLB at identity.
- `Main/right_click_move_input.gd`, `Main/camera_pan_zoom.gd` and `Main/movement_debug_overlay.gd`: temporary scene glue.
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
  - **No unpowered spin:** "Rotation should not persist without thrust." The turn rate drops to 0 in one tick when powered turning ends (heading continuous); no angular drag.
  - **Authority:** from actual speed through the rudder curve; zero at rest. One speed-linked turn-rate limit (owner-approved trial, PR #32); no phases, angle classes or reversal threshold. No final alignment.
- **Banking:** deferred; the old bank files were deleted with owner approval (Task #27). Visual tilt must never affect the authoritative root or collision.
- **Earlier movement decisions** (`ARCHITECTURE.md`): Task #28 superseded the near-opposite rule; arrival ends commanded rotation. Routes are not implemented; later tickets state whether they carry over.
- Ship differences use shared reusable definitions and Resource configuration, with per-instance runtime state. Work happens in the one developing game scene.
- **Input:** right-click to move, with the ship already controlled (no selection). No stop key. The camera looks 45° down, pans with middle-drag and zooms with the wheel, and does not follow the ship.
- **Provisional movement values** (Tasks #27 and #28, placeholders):
  - mass 5;
  - main acceleration 12 m/s²;
  - thrusters 60 (12 m/s²);
  - max speed 15 m/s (owner tuning trial 2; was 50, then 20 in trial 1);
  - pilot response 0.25 s (owner tuning trial 1, was 0.5);
  - arrival 2 m and 0.5 m/s;
  - turn authority 120 (24°/s² at 7.5 m/s, 36°/s² at 15 m/s before sharing) and the linear rudder curve (0,0), (0.5,1), (1,1.5) (owner-approved trial, Task #28);
  - turn-rate limit 60°/s at max speed (owner-approved trial, PR #32).

  The owner rejected the first feel (too fast, too much overshoot). After playtesting trial 1 (20 m/s, 0.25 s), the owner asked for 15 m/s. These values are approved as trials only, not as final balance. If the pickup is still too sharp afterwards, the tech lead's next proposal is weaker main acceleration and thrusters together (for example 6 m/s² and 30). That is not applied.

## Known limitations

Values were measured with deterministic 60 Hz headless traces of the shipped profile in `Main/main.tscn` (Task #28). The numbers are in the Task #28 pull request; Task #27's fixed-heading numbers are in PR #31.

- **Decisive sideways check, (0, 0, 0) → (100, 0, 0):**
  - **Tick 1:** yaw 0.000°, rudder 0, thrusters +X at the full 12 m/s². Course −90.0° for the whole order.
  - **From tick 2:** the turn claims half the capacity, so the thrusters give 6 m/s². Yaw −1.7° at 1 s (6.1 m/s), −12.8° at 2 s, −42.8° at 3 s, −82.8° at 4 s, −90.000° by 5 s (at most 0.5° past). Peak turn rate 52°/s.
  - **Overshoot and arrival:** to X = 102.5 (2.5 m), arrival 9.75 s, resting at X 99.34 facing −90.0°. No yaw after first passing the click.
  - **No jumps:** largest per-tick change 0.20 m/s in velocity, 0.87° in heading and 0.6°/s in turn rate.
- **Other orders (arrival, final yaw):** forward 100 m 8.85 s, 0°; rearward 100 m 9.78 s, 180° (4.7 s moving stern-first, peak at the 60°/s limit); retarget to (0, 0, −100) at 3 s 14.65 s; reverse retarget to the origin at 5 s 16.53 s, 90.3°; cruising −Z at 15 m/s with an order 89° or 91° to the right: 10.63 s / 10.73 s, nearly identical (no boundary); with an order straight behind: 10.87 s; four retargets one second apart: 11.12 s. Every order completes, with no orbit and no course change within an order.
- **Sharing and limit costs:** turning while braking from 15 m/s to (30, 0, −30) takes 9.63 s; crab + turn to (300, 0, −50) takes 23.55 s. In hard moving turns the heading crosses the course by up to 10–15° before settling (shared authority is below what the steering assumes). Rearward and reversal turns are capped at 60°/s, so the ship moves stern-first for 4–5 s. While a reversal passes through zero speed the rate stays within the limit (at most 5.9°/s below 1 m/s) and reaches 0 at rest.
- **Turning stops without power:** `stop()` mid-swing drops the rate from 18°/s to 0 in one tick (heading continuous). Arrival likewise ends rotation.
- **Small cases:** a click at the ship's own position has no course; it completes on the next tick, with no motion or yaw.
- **Not re-measured in Task #28:** the stern-first stop, passing within 2 m above 0.5 m/s, and the mass-0 profile (the code paths are unchanged from Task #27).
- **Overshoot is expected:** there is no arrival snap and no final alignment; the ship rests up to about 1.3 m from the click, facing about its order's course.
- **Gone for now:** routes, Shift-click waypoints, navigation, detours, destination resolution, obstacle stop, collision response and banking. The ship flies through the test sphere.
- **No world bounds:** the ship can be ordered anywhere on the Y = 0 plane.
- **Camera far plane:** 1000 m; at maximum zoom the far part of the area can fall beyond it. Not checked in F5.
- **Not verified:** the F5 run with the on-screen F3 readout (only headless traces were run).
- **Deferred QA:** high-speed tight loops, corners, obstacles, routes, negative or inverted tuning, pathological fast retargets, extreme rudder-curve shapes and multi-ship performance.

## Remaining work

**Next:** technical re-review and owner F5 playtest of PR #32 (course heading and turn-rate limit trial). After that come Task 16 (#29, retro-thruster braking) and Task 17 (#30, reaction delays), one at a time.

Later: routes and navigation, destination resolution, collision response and banking, each through its own ticket. Route-failure notifications, impact feedback, collisions with other body types and obstacle appearance remain undecided. There is no measured performance target.
