# Handoff

## Current state

Daung has open-space ship movement on **Movement v3, slices 1–2** (Task #27 propulsion and Task #28 powered turning; Tasks 1–2 of 4 in the Movement v3 rewrite). It replaces the earlier heading-and-throttle locomotion, routes, navigation, destination resolution, the obstacle hard stop and banking entirely.

Running the project opens `Main/main.tscn`:
- **Scene:** one frigate at the origin facing −Z; 2 m ring markers at (100, 0, 0), (0, 0, 0), (60, 0, 0), (60, 0, −40) and (20, 0, −40); the grey 6 m test sphere at (83, 0, 0).
- **Collision isolation:** the ship's collision mask is 0 in this scene, so it passes through the sphere.
- **Test area:** the inert 800 × 800 m navigation floor; nothing bounds the ship.
- **Camera:** starts at the 45° view. **Middle-drag** pans and the **wheel** zooms; the camera never follows the ship.
- **Orders:** right-clicking the Y = 0 plane orders the ship straight there; a new click replaces the order at once. Shift + right-click does nothing.
- **F3** toggles a readout of speed, velocity, heading, target heading, turn rate, applied angular acceleration, rudder multiplier, shared-capacity scale, main-engine command, thruster command (magnitude and XZ), destination and order state.

**How it moves** (`Movement/ship_movement.gd`, `ShipMovement`):
- **One velocity:** one world planar velocity and one heading.
- **Pilot:** each physics tick it wants to move toward the destination at `min(15, sqrt(2 · 12 · distance))` m/s. It requests the acceleration that closes the gap to the actual velocity in 0.25 s.
- **Main engine:** supplies the forward part along the bow, up to 12 m/s². It never fires while the ship has any stern-first motion, so it never brakes.
- **Thrusters:** supply the rest in any direction from one 60 / 5 = 12 m/s² rating, shared with turning (below).
- **Forward together:** forward, engine and thrusters add up to 24 m/s² (owner-approved Option A).
- **Integration:** only applied acceleration is integrated, and the speed is hard-capped at 15 m/s.
- **Turning:** the pilot steers the bow toward the **desired velocity** (intended travel). Authority is `120 / 5 = 24°/s²` × the rudder curve of **actual** speed: 0 at rest, 1× at 7.5 m/s, 1.5× at 15 m/s (linear). It winds up and counter-turns with bounded angular acceleration (braking-distance rule). No yaw-rate cap. Yaw never rotates the velocity. Without an order or at zero speed the turn rate is 0, so rotation never persists without powered turning, and a ship at rest never turns in place.
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
  - **Heading target:** the desired velocity (intended travel), not the drift or braking direction (owner D1).
  - **Sharing:** turning and planar thrust share the directional-thruster capacity proportionally; no independent turning, no translation-priority leftovers, no budget coefficient (owner D4).
  - **No unpowered spin:** "Rotation should not persist without thrust." The turn rate drops to 0 in one tick when powered turning ends (heading continuous); no angular drag.
  - **Authority:** from actual speed through the rudder curve; zero at rest. No yaw-rate cap, phases, angle classes or reversal threshold. No final alignment.
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
  - turn authority 120 (24°/s² at 7.5 m/s, 36°/s² at 15 m/s before sharing) and the linear rudder curve (0,0), (0.5,1), (1,1.5) (owner-approved trial, Task #28).

  The owner rejected the first feel (too fast, too much overshoot). After playtesting trial 1 (20 m/s, 0.25 s), the owner asked for 15 m/s. These values are approved as trials only, not as final balance. If the pickup is still too sharp afterwards, the tech lead's next proposal is weaker main acceleration and thrusters together (for example 6 m/s² and 30). That is not applied.

## Known limitations

Values were measured with deterministic 60 Hz headless traces of the shipped profile in `Main/main.tscn` (Task #28). The numbers are in the Task #28 pull request; Task #27's fixed-heading numbers are in PR #31.

- **Decisive sideways check, (0, 0, 0) → (100, 0, 0):**
  - **Tick 1:** yaw 0.000°, rudder 0, thrusters +X at the full 12 m/s².
  - **From tick 2:** the turn claims half the capacity, so the thrusters give 6 m/s². Yaw −1.7° at 1 s (6.1 m/s), −12.8° at 2 s, −42.8° at 3 s, −83° at 4 s; aligned near −90.35° by about 5 s, at most 0.5° past the target, with sub-0.1° settling. Peak turn rate 52°/s.
  - **Overshoot and arrival:** to X = 105.1, arrival 12.82 s, resting at (101.15, −0.22). After the overshoot the desired direction reverses, so the hull swings further and freezes at about −142° when the order ends.
  - **No jumps:** largest per-tick change 0.27 m/s in velocity and 0.87° in heading.
- **Other orders (arrival time):** forward 100 m 11.88 s (final yaw −49°); rearward 100 m 12.85 s (peak 77°/s); retarget to (0, 0, −100) at 3 s 17.77 s (no loop); reverse retarget to the origin at 5 s 18.65 s.
- **Sharing costs:** cruising −Z at 15 m/s and turning while braking to (30, 0, −30) takes 9.87 s (about 4.85 s if turning were independent). Cruising −Z at 15 m/s with a crab + turn to (300, 0, −50) takes 26.7 s and crosses the target heading by up to 9.1° before settling, because the steering assumes full authority but gets a shared share.
- **Turning stops without power:** `stop()` mid-swing drops the rate from 18°/s to 0 in one tick (heading continuous). Arrival likewise ends rotation.
- **Small cases:** a click at the ship's own position completes on the next tick, with no motion or yaw.
- **Not re-measured in Task #28:** the stern-first stop, passing within 2 m above 0.5 m/s, and the mass-0 profile (the code paths are unchanged from Task #27).
- **Overshoot is expected:** there is no arrival snap and no final alignment, so the ship rests about 1–1.2 m past the click, facing wherever its last powered turn left it.
- **Gone for now:** routes, Shift-click waypoints, navigation, detours, destination resolution, obstacle stop, collision response and banking. The ship flies through the test sphere.
- **No world bounds:** the ship can be ordered anywhere on the Y = 0 plane.
- **Camera far plane:** 1000 m; at maximum zoom the far part of the area can fall beyond it. Not checked in F5.
- **Not verified:** the F5 run with the on-screen F3 readout (only headless traces were run).
- **Deferred QA:** high-speed tight loops, corners, obstacles, routes, negative or inverted tuning, pathological fast retargets, extreme rudder-curve shapes and multi-ship performance.

## Remaining work

**Next:** owner F5 playtest of Task #28 (see its PR's playtest setup). After that come Task 16 (#29, retro-thruster braking) and Task 17 (#30, reaction delays), one at a time.

Later: routes and navigation, destination resolution, collision response and banking, each through its own ticket. Route-failure notifications, impact feedback, collisions with other body types and obstacle appearance remain undecided. There is no measured performance target.
