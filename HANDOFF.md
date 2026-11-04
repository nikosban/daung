# Handoff

## Current state

Daung has open-space ship movement on **Movement v3, slice 1** (Task #27, Task 1 of 4 in the Movement v3 rewrite). It replaces the earlier heading-and-throttle locomotion, routes, navigation, destination resolution, the obstacle hard stop and banking entirely.

Running the project opens `Main/main.tscn`:
- **Scene:** one frigate at the origin facing −Z; 2 m ring markers at (100, 0, 0), (0, 0, 0), (60, 0, 0), (60, 0, −40) and (20, 0, −40); the grey 6 m test sphere at (83, 0, 0).
- **Collision isolation:** the ship's collision mask is 0 in this scene, so it passes through the sphere.
- **Test area:** the inert 800 × 800 m navigation floor; nothing bounds the ship.
- **Camera:** starts at the 45° view. **Middle-drag** pans and the **wheel** zooms; the camera never follows the ship.
- **Orders:** right-clicking the Y = 0 plane orders the ship straight there; a new click replaces the order at once. Shift + right-click does nothing.
- **F3** toggles a readout of speed, velocity, heading, main-engine command, thruster command (magnitude and XZ), destination and order state.

**How it moves** (`Movement/ship_movement.gd`, `ShipMovement`):
- **One velocity:** one world planar velocity and one heading.
- **Pilot:** each physics tick it wants to move toward the destination at `min(15, sqrt(2 · 12 · distance))` m/s. It requests the acceleration that closes the gap to the actual velocity in 0.25 s.
- **Main engine:** supplies the forward part along the bow, up to 12 m/s². It never fires while the ship has any stern-first motion, so it never brakes.
- **Thrusters:** supply the rest in any direction from one 60 / 5 = 12 m/s² budget.
- **Forward together:** forward, engine and thrusters add up to 24 m/s² (owner-approved Option A).
- **Integration:** only applied acceleration is integrated, and the speed is hard-capped at 15 m/s.
- **Heading:** held fixed (temporary, this slice only).
- **Arrival:** within 2 m **and** at most 0.5 m/s. Afterwards, and after `stop()`, the thrusters brake toward zero velocity. There is no snap and no position hold, and overshoot can happen.
- **Bad profile:** a missing profile or any value ≤ 0 logs an error and the ship does not move.

**Files:**
- `Movement/movement_profile.gd` (`MovementProfile`, seven provisional values) and `Movement/Profiles/frigate_movement_profile.tres`. `ARCHITECTURE.md` lists the values, units and ranges.
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
  - **Heading:** fixed for this slice only.
  - **Collision isolation:** the scene's collision mask 0 is test isolation, not a collision design.
- **Owner statement for the sequence:** "Rotation should not persist without thrust." (Task 15.)
- **Banking:** deferred; the old bank files were deleted with owner approval (Task #27). Visual tilt must never affect the authoritative root or collision.
- **Earlier movement decisions:** routes, near-opposite braking, turning from rest, and arrival ending rotation are listed in `ARCHITECTURE.md`. They are not implemented now; later Movement v3 tickets state which carry over.
- Ship differences use shared reusable definitions and Resource configuration, with per-instance runtime state. Work happens in the one developing game scene.
- **Input:** right-click to move, with the ship already controlled (no selection). No stop key. The camera looks 45° down, pans with middle-drag and zooms with the wheel, and does not follow the ship.
- **Provisional movement values** (Task #27, placeholders):
  - mass 5;
  - main acceleration 12 m/s²;
  - thrusters 60 (12 m/s²);
  - max speed 15 m/s (owner tuning trial 2; was 50, then 20 in trial 1);
  - pilot response 0.25 s (owner tuning trial 1, was 0.5);
  - arrival 2 m and 0.5 m/s.

  The owner rejected the first feel (too fast, too much overshoot). After playtesting trial 1 (20 m/s, 0.25 s), the owner asked for 15 m/s. These values are approved as trials only, not as final balance. If the pickup is still too sharp afterwards, the tech lead's next proposal is weaker main acceleration and thrusters together (for example 6 m/s² and 30). That is not applied.

## Known limitations

Values were measured with deterministic 60 Hz headless traces of the shipped profile in `Main/main.tscn` (Task #27, trial 2: 15 m/s and 0.25 s). The first values (50 m/s, 0.5 s) gave 11.7 m sideways overshoot and a wide loop on retarget; trial 1 (20 m/s) gave 3.6 m. The numbers are in PR #31.

- **Decisive sideways check, (0, 0, 0) → (100, 0, 0):**
  - **First second:** X rises from the first tick (6.3 m at 1.0 s), the heading stays 0.000°, the main command stays 0 and the thrusters push +X at 12 m/s².
  - **Peak and overshoot:** 15 m/s (14.7 at 1.57 s), overshooting to X = 102.5 (2.5 m), then back.
  - **Arrival:** 9.15 s after the order; the ship rests at X = 99.35.
  - **No jumps:** the largest per-tick velocity change is 0.20 m/s (12 m/s²), and no step exceeds the speed cap.
- **Forward 100 m:** engine + thrusters reach 24 m/s²; 14.7 m/s at 1.10 s, capped at 15; 2.5 m overshoot; arrival 8.85 s; rests 0.68 m short of the click.
- **Forward 400 m:** the same pickup and 2.5 m overshoot; arrival 28.85 s; rests 0.68 m short.
- **Stern-first stop (regression check):** from 15 m/s (the cap) straight stern-first, `stop()` keeps the main command at 0 on every tick, while the thrusters brake at ≤ 12 m/s². The ship stops over 9.6 m.
- **Retarget while moving:** a new click to (0, 0, −100) at 3 s, while moving at 15 m/s toward +X, swings out to X ≈ 44.9 and then flies a straight diagonal. It overshoots once (to Z ≈ −102.2, X ≈ −1.2) and arrives 12.80 s after the first order, resting 0.66 m from the click. There is no loop or repeated orbit. The pilot does not damp sideways speed separately; high-speed tight loops are deferred QA.
- **Small cases:**
  - A click at the ship's own position while stopped completes on the next tick, with no motion.
  - Passing within 2 m above 0.5 m/s keeps the order active.
  - A profile with mass 0 logs an error and the ship never moves.
- **Overshoot is expected:** the 0.25 s response still lets the speed run a little above the stopping profile. There is no arrival snap, so the ship rests up to about 0.7 m from the click.
- **Gone for now:** no rotation, routes, Shift-click waypoints, navigation, detours, destination resolution, obstacle stop, collision response or banking. The ship flies through the test sphere.
- **No world bounds:** the ship can be ordered anywhere on the Y = 0 plane.
- **Camera far plane:** 1000 m; at maximum zoom the far part of the area can fall beyond it. Not checked in F5.
- **Not verified:** the F5 run with the on-screen F3 readout (only headless traces were run).
- **Deferred QA:** high-speed tight loops, corners, obstacles, routes, negative or inverted tuning and multi-ship performance.

## Remaining work

**Next:** owner F5 playtest of Task #27 (see the PR's playtest setup), then **Task 15** (issue #28: speed-dependent powered turning). After that come Task 16 (#29, retro-thruster braking) and Task 17 (#30, reaction delays), one at a time.

Later: routes and navigation, destination resolution, collision response and banking, each through its own ticket. Route-failure notifications, impact feedback, collisions with other body types and obstacle appearance remain undecided. There is no measured performance target.
