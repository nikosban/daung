# Architecture

1. **Map and group the current system.** Catalogue active modules and meaningful internal responsibilities, their dependencies and connections to the wider project. Group where it clarifies existing architectural boundaries; distinguish modules from scene composition and implementation helpers.

2. **Document interfaces.** Describe what each module provides, consumes and controls, including ownership and dependency direction. Include only contracts another component must rely on or respect. Retain necessary distinctions in command activation, cancellation, failure handling and fallback behavior; avoid exhaustive API inventories.

3. **Keep it minimal and current.** Update existing entries instead of appending explanations; add entries for genuinely new responsibilities and remove obsolete information. Exclude low-level algorithms, numeric tuning, implementation walkthroughs, history and test records. Retain units, coordinate conventions, configuration ownership and useful source links. Verify claims against current code and report substantive conflicts with approved decisions for owner review.

## System map

| Boundary | Owns | Dependencies |
|---|---|---|
| [Main composition](Main/main.tscn) | World, static obstacles and baked navigation geometry; camera, ship, player input and debugging instances | Shared camera, ship, asteroid, player input and debugging scenes; Godot |
| [Ship composition](Ships/ship.tscn) | Movement body, collision hull, movement profile, model and command presentation | Movement; shared profile, model and presentation assets |
| [Movement](Movement/ship_movement.gd) | Commands, authoritative position, planar velocity and yaw; internal pilot/propulsion and navigation | Godot APIs and its own internal components only |
| [Camera](game/camera/camera_rig.tscn) | Floor focus, view transform and camera input | Shared camera settings; Godot only |
| [Player input](game/input/player_ship_input.tscn) | Single-ship selection and player move dispatch | Active viewport camera and physics space; Movement commands and ship presentation |
| [Ship presentation](game/presentation/ship_selection/ship_command_presentation.tscn) | Selection ring, destination marker and straight connector; latest player move receipt per ship | Movement's accepted destination observation; shared presentation style; Godot |
| [Debugging](debugging/debugging_suite.tscn) | F4 diagnostic stop, telemetry display and diagnostic visuals | Movement requests/read-only observations; injected scene references; Godot |
| [Display and UI configuration](project.godot) | Window/reference sizing and proportional UI scaling; shared UI theme | Godot; shared [theme resource](game/ui/ui_theme.tres) |

Movement and Camera are independent gameplay modules. Main and Ship are composition boundaries. Movement never depends on Camera or Debugging. New module dependencies require an approved ticket stating the map change.

Main supplies the navigation map through Godot's `NavigationRegion3D` and physics geometry. Static obstacle instances share [one scene](Main/asteroid.tscn); geometry changes require rebaking the navigation mesh. The navigation floor is bake geometry and is excluded from the ship's physical collision mask.

The ship's collision shape is navigation's authoritative hull source; hull queries currently support boxes. Visual presentation belongs under `Visual` and must not tilt the movement root or collision hull. Preserve the imported model's source, scale and pivot.

## Movement

### External contract

- Callers use `move_to(world_position)` and `stop()`. Both enter a per-ship FIFO and activate after their reaction delay. The active order continues meanwhile. Activation replaces it and cancels its navigation work without resetting momentum. Destination Y is ignored. A move returns a receipt ID. `get_pending_move_destination(receipt)` exposes the requested point while that move is queued or initially planning. `get_resolved_move_destination(receipt)` exposes the destination while the move is active, accepted and unblocked.
- `ShipMovement` alone applies authoritative motion through the character body. Read-only observations expose commands, requested/resolved destination, status and telemetry; there are no movement notification signals. Invalid movement configuration disables motion.
- Arrival requires both distance and speed tolerances. Arrival and stop leave ordinary braking, without position holding or final alignment. Driving into a stationary static obstacle ends the active order and zeroes motion; pending commands survive.

### Internal responsibilities

**Controller — [ShipMovement](Movement/ship_movement.gd).** Owns command/order lifecycle, live motion and route-following state. It obtains guidance, supplies pilot state/targets, applies results and handles collision stops. Planning reads live state through its snapshot interface.

**Pilot/propulsion — [ShipPilot](Movement/pilot.gd).** Updates supplied simulation state and steering intent from targets/configuration, returning arrival and telemetry results. It never moves scene objects or advances position. Steering, engines, thrusters, braking and powered turning share this implementation. Turning and translation share thruster capacity; yaw never rotates velocity.

**Navigation — [Movement/Navigation](Movement/Navigation/).** Supplies guidance and clearance decisions to the controller:

- **Routes:** `Navigator` manages jobs/cancellation; `RoutePlanner` acquires Godot paths and resolves unsuitable clicks through bounded search. `RouteGuidance` converts routes and per-ship progress into pilot targets. A route guides movement; it does not certify the entire flight.
- **Clearance:** `HullProbe` queries the real hull, static space and navigation boundaries. `ManeuverRollout` checks the immediate response using the same pilot on copied state/targets, then checks stopping room. Physical hull clearance and the navigation mesh's centre no-go constraint are separate requirements. None of these helpers writes live motion.
- **Work ownership:** `Navigator`/`PlanClock` share work accounting across ships, including live clearance. Boundary caches are shared per map, invalidated by map iteration changes and released when its last ship leaves. Pending work does not itself request braking; physical clearance can.

The controller can refresh a stale route once and apply checked local corrections. Exhausted local recovery retains a blocked order; distinct-passage recovery is not implemented. Bounded destination-search failure is reported separately from local movement failure and does not prove impossibility.

Direct movement with the static-contact fallback is selected only for no enabled navigation regions, no navigation polygons after synchronization checks, or a requested destination outside every enabled region's bounds. An inactive or unsynchronized map leaves the route job pending, with live clearance still checked. Pathfinding or destination-search failure does not select this fallback.

## Camera

[CameraRig](game/camera/camera_rig.gd) owns a horizontal floor focus and its child Camera3D. Zoom and yaw orbit preserve that focus at screen center; camera-relative panning translates it. Only the active camera accepts unhandled input, and held controls clear on window focus loss or deactivation. Removing Debugging leaves camera controls available.

Levels instance the master scene and place its root at their initial floor focus. The shared [settings resource](game/camera/camera_settings.tres) is Inspector-editable and read-only at runtime; local tuning copies/overrides are avoided so master changes propagate. View and input state belong to each rig. Pan speed scales with current smoothed height relative to the configured starting height. Input bindings belong to Project Settings' Input Map.

Consumers obtain Camera3D through `get_camera()`; `set_view(focus_position, height, yaw_degrees)` immediately places the view and synchronizes zoom within its limits. Focus Y defines the camera's floor elevation; this does not change Movement's X/Z gameplay plane.

## Player input and ship presentation

One [controller](game/input/player_ship_input.gd) per playable viewport processes unhandled clicks in input order. The physics-space pick selects one ship or clears selection. A right-click projected onto Y = 0 issues a move immediately when selection is settled. An earlier pending pick is processed first in the physics tick.

Each ship instances [command presentation](game/presentation/ship_selection/ship_command_presentation.tscn) under `Visual`. The selected ship displays only its latest player move receipt. Blue feedback marks the requested point during the reaction delay and initial planning. Gray feedback marks the accepted endpoint. The selection ring is a fixed horizontal mesh in world metres that follows the ship's rendered X/Z position at Y = 0. The destination glyph uses fixed render-target pixels projected onto the ground. Its arc faces the rendered ship position. The connector starts from the projected world ring edge and leaves pixel gaps at both ends. Camera coordinates convert through the viewport stretch transform. World depth applies to all feedback. Deselecting hides it. The [preview](game/presentation/movement/move_feedback_preview.tscn) uses the production input, camera and ship scenes.

## Debugging integration

[DebuggingSuite](debugging/debugging_suite.gd) receives the test ship, collision shapes and reference positions from its host. Removing it cleans up generated outlines attached to external collision shapes.

F4 queues a diagnostic stop on the test ship. The overlay reads telemetry and the F3 trail samples actual world positions after movement. Shared visual definitions and settings remain reusable; runtime state belongs to each suite.

The suite owns the overlay's scene-based Control layout, margins and wrapping telemetry label. Diagnostic Controls ignore mouse input. The label selects the shared theme's `DebuggerLabel` variation; its outline does not apply to ordinary UI labels. On initialization and viewport resize, the overlay caps its label's nominal screen-pixel font size using that variation's limit and the actual viewport stretch, rounding down. The font override belongs to the label instance; the shared theme and ordinary UI scaling remain unchanged.

## Display and UI configuration

[Project settings](project.godot) own the logical UI reference and independent initial window size. Canvas-item stretching scales UI proportionally; expand aspect handling adds logical space for other aspect ratios. Startup is resizable and windowed, with no enforced minimum size. The 3D view renders at the window resolution; Camera does not own display configuration.

The external [UI theme](game/ui/ui_theme.tres) supplies the project-wide default font size and the opt-in debugger outline variation. Shared theme data is read-only at runtime. Layout dimensions belong to reusable scene resources. Godot's embedded-game sizing remains an editor preference, separate from project window/scaling settings.

## Data and units

Shared Godot Resources hold configuration and are not mutated per instance. Orders, motion and route progress belong to each ship. Tuning values belong in data assets, with defaults, units and approved ranges defined by their resource scripts:

- [MovementProfile](Movement/movement_profile.gd) defines movement configuration; the [frigate resource](Movement/Profiles/frigate_movement_profile.tres) supplies the active hull's values and curves.
- [NavigationBudget](Movement/Navigation/navigation_budget.gd) and its [resource](Movement/Navigation/navigation_budget.tres) configure shared navigation limits.
- [Trail settings](debugging/movement_trail_settings.gd) and their [resource](debugging/movement_trail_settings.tres) configure diagnostic sampling.
- [Ship feedback style](game/presentation/ship_feedback_style.tres) configures shared materials and the selection radius and stroke in world metres. The destination sizes, line width and connector gaps use output pixels.
- [Camera settings](game/camera/camera_settings.gd) and their [resource](game/camera/camera_settings.tres) configure view, zoom, orbit and pan behavior.

One world unit is one metre. Gameplay motion uses world X/Z; the bow points along local -Z. Speed uses m/s, acceleration m/s², distances metres and durations seconds. Angles use degrees in data/debug output and radians internally; angular acceleration/rate use °/s² and °/s in data. Gameplay mass is a dimensionless divisor for thruster strength; main-engine and turning acceleration are specified directly.
