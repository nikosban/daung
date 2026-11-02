# Handoff

## Current state

Daung is a blank Godot project with a minimal `project.godot` and the owner's placeholder `Assets/Ships/Whitebox/Arrata_Frigate_001.glb`, plus its import sidecar. The source model is protected: do not edit, relocate, rename, rescale or change its pivot.

No gameplay scripts, authored gameplay scenes, Movement module, movement profiles, routing or banking exist. There is no main scene, export preset, gameplay test suite or added dependency.

`ARCHITECTURE.md` records the approved target design separately from implemented files. `AGENTS.md` and `TICKET.md` provide the workflow. Generic UTF-8, line-ending and Godot-ignore rules remain in the repository.

## Accepted decisions

- 1 world unit = 1 metre; authoritative gameplay movement uses X/Z.
- Movement is the only planned top-level gameplay module and may use Godot APIs only. It alone owns authoritative movement; guidance and locomotion stay internal.
- Translate and turn together from rest; moving turns are continuous and momentum-aware. Near-opposite orders relative to travel direction brake to rest before restarting. Acceleration/braking are gradual; arrival ends commanded rotation.
- Model-only presentation heels outward in broad maneuvers and banks inward in sharper ones. Visual tilt never affects the authoritative root or collision.
- Future ship differences use shared reusable definitions and Resource configuration, with per-instance runtime state. First playable work uses one ship in the developing game scene.

## Verification

- Godot `4.7.2.stable.official.ed1daf0bf`: headless editor import completed with exit code 0; the protected model was rebuilt from source after removing its generated import cache. Import and visible editor logs contain no reported errors or warnings.
- Visible editor opened Daung with an empty scene, all canonical documents and the imported placeholder available as a PackedScene. The editor regenerated ignored local caches and added only its version feature metadata to `project.godot`; no rendering/physics/stretch overrides were restored.
- Protected source Git blob remains `7a3486cb05fddde69a6c32270ada0fad53f9560d`; its import sidecar also remains unchanged (`7e12b828f21bcd9dad92a0df5b6b0bd493526de4`).
- No gameplay verification applies to the blank scaffold; editor startup does not establish movement behavior. No playable build/export or gameplay tests were run.

## Remaining work

Movement, navigation and banking are unimplemented. Exact order lifecycle, motion defaults/ranges, near-opposite threshold, banking response, obstacle/collision/avoidance behavior and engine techniques are undecided or deferred. There is no measured performance target.

Next: plan and ticket the first playable open-space movement implementation in the developing game scene. Resolve the remaining owner decisions in that ticket; gameplay implementation requires separate approval and is not authorized by this reset.
