# Architecture

Current responsibilities, dependencies and integration contracts. Update this map when those boundaries change. Linked source and resources hold implementation details and tuning; GitHub and Git hold history.

## System map

| Boundary | Owns | Dependencies |
|---|---|---|
| [Main composition](Main/main.tscn) | World, camera, static obstacles and baked navigation geometry; ship and debugging instances | Shared ship, asteroid and debugging scenes; Godot |
| [Ship composition](Ships/ship.tscn) | Movement body, collision hull, movement profile and visual/model child | Movement; shared profile and model assets |
| [Movement](Movement/ship_movement.gd) | Commands, authoritative position, planar velocity and yaw; internal pilot/propulsion and navigation | Godot APIs and its own internal components only |
| [Debugging](debugging/debugging_suite.tscn) | Temporary input/camera controls, telemetry display and diagnostic visuals | Movement requests/read-only observations; injected scene references; Godot |

Movement is the only gameplay module. Main and Ship are composition boundaries. Movement never depends on Debugging. New module dependencies require an approved ticket stating the map change.

Main supplies the navigation map through Godot's `NavigationRegion3D` and physics geometry. Static obstacle instances share [one scene](Main/asteroid.tscn); geometry changes require rebaking the navigation mesh. The navigation floor is bake geometry and is excluded from the ship's physical collision mask.

The ship's collision shape is navigation's authoritative hull source; hull queries currently support boxes. Visual presentation belongs under `Visual` and must not tilt the movement root or collision hull. Preserve the imported model's source, scale and pivot.

## Movement

### External contract

- Callers use `move_to(world_position)` and `stop()`. Both enter a per-ship FIFO and activate after their reaction delay; the active order continues meanwhile. Activation replaces the previous order and cancels its navigation work without resetting momentum. Destination Y is ignored.
- `ShipMovement` alone applies authoritative motion through the character body. Read-only observations expose commands, requested/resolved destination, status and telemetry; there are no movement notification signals. Invalid movement configuration disables motion.
- Arrival requires both distance and speed tolerances. Arrival and stop leave ordinary braking, without position holding or final alignment. Driving into a stationary static obstacle ends the active order and zeroes motion; pending commands survive.

### Internal responsibilities

**Controller — [ShipMovement](Movement/ship_movement.gd).** Owns command/order lifecycle, live motion and route-following state. It obtains guidance, supplies pilot state/targets, applies results and handles collision stops. Planning reads live state through its snapshot interface.

**Pilot/propulsion — [ShipPilot](Movement/pilot.gd).** Updates supplied simulation state and steering intent from targets/configuration, returning arrival and telemetry results. It never moves scene objects or advances position. Steering, engines, thrusters, braking and powered turning share this implementation. Turning and translation share thruster capacity; yaw never rotates velocity.

**Navigation — [Movement/Navigation](Movement/Navigation/).** Supplies guidance and clearance decisions to the controller:

- **Routes:** `Navigator` manages jobs/cancellation; `RoutePlanner` acquires Godot paths and resolves unsuitable clicks through bounded search. `RouteGuidance` converts routes and per-ship progress into pilot targets. A route guides movement; it does not certify the entire flight.
- **Clearance:** `HullProbe` queries the real hull, static space and navigation boundaries. `ManeuverRollout` checks the immediate response using the same pilot on copied state/targets, then checks stopping room. Physical hull clearance and the navigation mesh's centre no-go constraint are separate requirements. None of these helpers writes live motion.
- **Work ownership:** `Navigator`/`PlanClock` share work accounting across ships, including live clearance. Boundary caches are shared per map, invalidated by map iteration changes and released when its last ship leaves. Pending work does not itself request braking; physical clearance can.

The controller can refresh a stale route once and apply checked local corrections. Exhausted local recovery retains a blocked order; distinct-passage recovery is not implemented. Bounded destination-search failure is reported separately from local movement failure and does not prove impossibility. Navigation unavailable or destinations outside its bounds use the direct movement/contact fallback.

## Debugging integration

[DebuggingSuite](debugging/debugging_suite.gd) receives ship, camera, collision shapes and reference positions from its host. Removing it removes its controls and cleans up generated outlines attached to external collision shapes.

Input sends Movement requests. The overlay reads telemetry; the trail samples actual world positions after movement; markers/outlines change presentation only. Camera controls operate the supplied camera. Shared visual definitions/settings remain reusable; runtime state belongs to each suite.

## Data and units

Shared Godot Resources hold configuration and are not mutated per instance. Orders, motion and route progress belong to each ship. Tuning values belong in data assets, with defaults, units and approved ranges defined by their resource scripts:

- [MovementProfile](Movement/movement_profile.gd) defines movement configuration; the [frigate resource](Movement/Profiles/frigate_movement_profile.tres) supplies the active hull's values and curves.
- [NavigationBudget](Movement/Navigation/navigation_budget.gd) and its [resource](Movement/Navigation/navigation_budget.tres) configure shared navigation limits.
- [Trail settings](debugging/movement_trail_settings.gd) and their [resource](debugging/movement_trail_settings.tres) configure diagnostic sampling.

One world unit is one metre. Gameplay motion uses world X/Z; the bow points along local -Z. Speed uses m/s, acceleration m/s², distances metres and durations seconds. Angles use degrees in data/debug output and radians internally; angular acceleration/rate use °/s² and °/s in data. Gameplay mass is a dimensionless divisor for thruster strength; main-engine and turning acceleration are specified directly.
