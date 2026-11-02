# Handoff

## Current state

Daung has open-space ship movement with moving turns and near-opposite reversals (Tasks #3 and #5). Running the project opens `Main/main.tscn`: a fixed camera, one frigate at the origin facing −Z, and 2 m ring markers at (100, 0, 0) and at the start location (0, 0, 0). Right-clicking the Y = 0 plane orders the ship there.

- `Movement/`: the `MovementProfile` Resource (seven provisional tunables), the shared `frigate_movement_profile.tres`, and `ShipMovement` (`CharacterBody3D`), the single writer of planar position, velocity and yaw, with `move_to()` and `stop()`.
- **Each order is classified once, from the actual travel velocity:**
  - at rest: translate and turn together;
  - 150° or more from travel: brake to rest, then start from rest;
  - anything else: a moving turn at up to 18 °/s of travel direction, slowing for near goals (pure-pursuit cap).
- An order completes only at rest inside the 2 m tolerance. If braking carries the ship out, it re-approaches from rest.
- `Ships/ship.tscn`: the reusable ship. It has the movement root, a provisional box collision shape with no collision rules, and the protected GLB as a `Visual` child at identity.
- `Main/right_click_move_input.gd`: temporary scene input glue.
- `project.godot` sets the main scene, opens the window maximized with `canvas_items`/`expand` stretch, and enables physics interpolation.

The protected model `Assets/Ships/Whitebox/Arrata_Frigate_001.glb` and its sidecar are unchanged. Do not edit, relocate, rename, rescale or repivot them.

`ARCHITECTURE.md` lists the exact inventory and tuning values.

## Accepted decisions

- 1 world unit = 1 metre; authoritative gameplay movement uses X/Z.
- Movement is the only top-level gameplay module and may use Godot APIs only. It alone owns authoritative movement; guidance and locomotion stay internal.
- Translate and turn together from rest. Moving turns are continuous and broad: about 90° of travel direction in 5 s at cruise. Orders 150°–180° from actual travel brake fully to rest before restarting. Arrival ends commanded rotation.
- Model-only presentation heels outward in broad maneuvers and banks inward in sharper ones. Visual tilt never affects the authoritative root or collision.
- Ship differences use shared reusable definitions and Resource configuration, with per-instance runtime state. Work happens in the one developing game scene.
- Right-click to move, with the ship already controlled (no selection). No stop key. The fixed camera looks 45° down.
- Provisional movement defaults:
  - 8 m/s max speed;
  - 6 m/s² acceleration and 10 m/s² braking;
  - 35 °/s hull yaw and 18 °/s travel turn rate;
  - 150° near-opposite angle;
  - 2 m arrival tolerance.

  Final balance comes from owner playtests.

## Known limitations

- **Very short clicks at speed:** a click inside 2 m at 8 m/s can show brake → coast about 3 m past → small re-approach. This is required by the "rest within 2 m" rule. Accepting natural overshoot instead is an open owner choice.
- **Slow-but-moving ships:** a ship that is moving slowly but not stopped, given an order 90°–149° away, swings wider as it speeds up during the turn, because the travel turn rate is fixed in °/s.
- **Hull yaw versus travel:** the hull turns toward the destination at 35 °/s, so during moving turns it leads the travel direction.
- **Deferred QA:** complex chained retargets and extreme tunings are not validated. There is no routing, obstacles, collision response, banking, selection or UI.

## Remaining work

Task 4: banking. Obstacle/collision/avoidance behavior and banking values remain undecided. There is no measured performance target.
