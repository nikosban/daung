# Architecture

## Status and units

This is the target design approved in Task #1, not implemented code. The actual inventory is listed below.

**1 world unit = 1 metre.** Gameplay movement is horizontal on Godot's X/Z plane. Ordinary movement does not chase Y; any later vertical animation belongs to the model only.

Future data assets use m/s for speed, m/s² for acceleration and braking, degrees/s for rotation, and metres for dimensions and distances.

## Planned module map

| Module | Owns | May use | Status |
|---|---|---|---|
| Movement | Move/stop requests; authoritative planar translation, heading, velocity and movement state; future movement-profile definitions | Godot engine APIs only | Planned; not implemented |

Movement is the only planned top-level gameplay module. Navigation guidance/route following and locomotion are distinct internal responsibilities, not independently exposed global modules.

Dependencies follow the one-way May-use map. Changes require an approved ticket stating the map change. Enforcement is review-only; no dependency tooling is installed or planned here.

## Planned movement boundary and authority

The command flow is caller → move-to or stop request → Movement's internal navigation guidance → locomotion → authoritative ship transform.

- Movement alone writes the ship's authoritative transform and owns its heading, velocity and movement state. External callers request movement rather than writing transforms.
- Navigation supplies path or heading guidance. Locomotion determines feasible continuous motion from that guidance and the ship's motion limits. Navigation does not issue separate stop, accelerate or rotate orders at intermediate vertices.
- Callers may read movement state/velocity and subscribe to significant notifications. No per-tick cross-system notifications are specified.
- Exact replacement, cancellation, arrival and failure notification semantics are **UNDECIDED**, except for the confirmed behavior below. API signatures, state names, notification contracts, queues and hidden states are not prescribed.
- Movement does not call visual, input, UI or future gameplay systems. Scene-level input/order adaptation is future composition glue, not a global orchestration module. Other gameplay systems enter the dependency map only through later approved tickets.

## Confirmed movement behavior

- From rest, translation and turning begin together. Movement accommodates forward, backward, lateral and diagonal directions. Short journeys may end before the hull faces the destination.
- While moving, turns are relatively wide and momentum-aware. Very sharp corners need not be followed exactly; the ship follows a continuous trajectory toward its destination.
- A near-opposite order, measured relative to **actual travel direction**, brakes the ship to rest before stationary movement begins. The near-opposite angle threshold is a future owner tuning decision.
- Acceleration and braking are gradual, with straightforward tunable rates. Heavy, momentous movement remains controlled; special stopping curves and a generic state-machine framework are not required.
- Arrival ends commanded rotation. There is no final alignment phase or requirement to finish yaw before arrival.
- Intermediate route vertices are not arrival targets. Route following must avoid waypoint-induced stop/start, heading resets and jitter, producing one continuous journey.

Engine movement/navigation primitives will be evaluated in later playable work. Exact physics, obstacle pathfinding and smoothing techniques remain open; no custom navigation or physics algorithm is selected here.

## Planned reusable ship composition

A reusable ship scene is planned, not present. It separates authoritative movement from a visual/model child:

- The child consumes Movement's read-only motion/turn output; Movement never calls it.
- Only the child tilts visually. The authoritative root and collision never tilt; visual roll does not affect physical movement or navigation coordinates.
- Broad gradual maneuvers heel outward; sharper maneuvers bank inward. These are different maneuvers, not phases of one turn. The model straightens on straight travel.
- Banking thresholds, angles, intensity and response curves are **UNDECIDED**. No separate top-level visual module is introduced.

Shared function and appearance use one authoritative scene/script/resource. Ship differences use configuration rather than duplicated implementations; check existing assets before creating another shared definition. Per-instance runtime state must not modify shared resources. No reusable movement implementation exists to extend today.

The owner's placeholder is `Assets/Ships/Whitebox/Arrata_Frigate_001.glb`. Preserve the source unchanged, including its scale and pivot; import metadata is asset metadata, not a movement design decision.

## Future data and validation

Per-ship tuning belongs in Godot `Resource` data assets, not code constants. Shared assets hold configuration only; runtime state belongs to the individual ship. Each future tunable requires a default, unit and owner-approved range, including the near-opposite angle and banking parameters. No numeric tuning defaults are confirmed and no tuning assets are created in this task. Start conservatively and adjust in play.

The first playable work uses one ship in open space in the developing game scene, rather than multiple test scenes. The intended battle scale is tens of units; assess it with real combat later, without treating that intention as a measured performance target.

The rejected upfront alternative is a global command/orchestration framework, an independently deployable navigation system and custom simulation. They add coupling and complexity before confirmed users require them.

## Actually implemented inventory

- Minimal `project.godot` scaffold named Daung, using engine defaults.
- Protected ship source and its import sidecar.
- Workflow documents and generic repository formatting/ignore rules.
- **No Movement module, gameplay scripts, authored gameplay scenes, movement profiles, routing or banking implementation.** No main scene, export presets, gameplay tests or added dependencies.

## Undecided and deferred

**UNDECIDED (owner, later tickets):** exact order lifecycle and notifications; speed/acceleration/braking/yaw defaults and ranges; near-opposite angle and low-speed travel-direction classification; arrival/braking feel; banking parameters; obstacle/pathfinding and collision/avoidance behavior; and a performance target beyond the intended scale.

**DEFERRED:** engine technique selection and playable validation, obstacle routing, collision/avoidance, dense fleets, unusual maneuvers and vertical animation. None is implemented or validated by this documentation/reset task.
