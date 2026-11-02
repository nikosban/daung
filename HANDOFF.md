# Handoff

## Current state

Daung has its first playable movement slice (Task #3). Running the project opens `Main/main.tscn`: a fixed camera, one frigate at the origin facing −Z, and a 2 m ring marker at (100, 0, 0). Right-clicking the Y = 0 plane orders the ship there.

- `Movement/`: the `MovementProfile` Resource (five provisional tunables), the shared `frigate_movement_profile.tres`, and `ShipMovement` (`CharacterBody3D`), the single writer of planar position, velocity and yaw, with `move_to()` and `stop()`.
- `Ships/ship.tscn`: the reusable ship. It has the movement root, a provisional box collision shape with no collision rules, and the protected GLB as a `Visual` child at identity.
- `Main/right_click_move_input.gd`: temporary scene input glue.
- `project.godot` sets the main scene, opens the window maximized with `canvas_items`/`expand` stretch, and enables physics interpolation.

The protected model `Assets/Ships/Whitebox/Arrata_Frigate_001.glb` and its sidecar are unchanged. Do not edit, relocate, rename, rescale or repivot them.

`ARCHITECTURE.md` lists the exact inventory and tuning values.

## Accepted decisions

- 1 world unit = 1 metre; authoritative gameplay movement uses X/Z.
- Movement is the only top-level gameplay module and may use Godot APIs only. It alone owns authoritative movement; guidance and locomotion stay internal.
- Translate and turn together from rest; moving turns are continuous and momentum-aware. Near-opposite orders relative to travel direction brake to rest before restarting. Acceleration/braking are gradual; arrival ends commanded rotation.
- Model-only presentation heels outward in broad maneuvers and banks inward in sharper ones. Visual tilt never affects the authoritative root or collision.
- Ship differences use shared reusable definitions and Resource configuration, with per-instance runtime state. Work happens in the one developing game scene.
- Right-click to move, with the ship already controlled (no selection), for this slice. No stop key. The fixed camera looks 45° down.
- Provisional movement defaults: 10 m/s (halved by the owner after the first playtest), 6 m/s², 10 m/s² braking, 35 °/s, 2 m arrival tolerance. Final balance comes from owner playtests.

## Known limitations

- A retarget while moving reuses the same bounded velocity change. It has no designed arc, and a near-opposite order decelerates through zero instead of using a brake-to-rest policy. Both are deferred to Task 3.
- The ship can coast slightly past the destination after entering tolerance; the measured overshoot is 0.08 m at the defaults. Extreme tunings are not validated.
- No routing, obstacles, collision response, banking, selection or UI.

## Remaining work

Task 3: moving retarget and near-opposite reversal. Task 4: banking. Obstacle/collision/avoidance behavior, the near-opposite threshold and banking values remain undecided. There is no measured performance target.
