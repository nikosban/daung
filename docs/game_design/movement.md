
# Ship Movement

**Daung — Game Design Document**

## 1. Movement Fantasy

Ships in Daung should feel like massive naval warships operating in space, not starfighters.

Movement is deliberate, heavy, and driven by momentum. A ship cannot instantly change direction, stop, or reposition itself simply because the player issues a new order. Every maneuver requires time, distance, and space.

The primary inspirations are the movements of large warships in _Battlefleet Gothic: Armada_ and _Falling Frontier_, with the feeling of naval combat translated into a three-dimensional environment.

Although ships are three-dimensional, their tactical movement takes place on a two-dimensional plane.

**The central fantasy is commanding a vessel with weight, inertia, and physical limitations, without having to manually control its movement.**

The player decides where a ship should go. The ship determines how to get there using its available capabilities.

As long as an order can be completed, the ship is expected to accomplish it autonomously. The player should not need to repeatedly correct its course, manage its speed, or intervene in routine navigation.

This is particularly important in fleet warfare, where the player must be able to command multiple vessels without micromanaging their individual maneuvers.

Movement should be predictable enough for players to make informed tactical decisions, but never so responsive that positioning becomes trivial.

## 2. Core Movement Principles

### Momentum and commitment

A moving ship carries momentum. Changing its destination does not erase its existing motion.

Ships gradually alter their trajectory through acceleration, braking, and turning. At higher speeds, changing direction becomes increasingly expensive in terms of time and space.

A ship traveling at full speed cannot perform the same maneuvers as a stationary or slow-moving vessel.

The distance to the new destination is equally important. A distant destination allows a ship to preserve momentum through wider maneuvers, while a nearby destination may require substantial braking and careful repositioning.

This makes positioning a commitment. Players who send ships into unfavorable positions must live with the consequences of those orders.

### Mass and maneuverability

Different vessels should feel physically distinct.

A smaller, lighter ship can accelerate, brake, and change course more effectively than a larger, heavier vessel.

Larger ships require more room to maneuver, carry their momentum farther, and take longer to respond to significant changes in direction.

Mass is one factor among several that determine maneuvering behavior. Speed, destination distance, and available maneuvering room are equally relevant to the decisions a ship makes.

A frigate establishes the baseline for movement. Larger and smaller classes express different degrees of the same movement philosophy rather than following entirely different rules.

### Powered movement

Ships do not move or rotate freely.

Their main engines provide forward propulsion, allowing them to accelerate and travel over long distances.

Directional thrusters provide additional maneuvering capabilities, including sideways movement, braking, and turning. Their thrust is low and consistent compared with the main engines.

At high speeds, a ship's accumulated momentum limits how effectively its directional thrusters can reposition it. When significant lateral maneuvering is required, the ship may need to reduce speed before that maneuver becomes effective.

Braking, turning, and repositioning can occur together, but these actions remain limited by the ship's available propulsion and movement capabilities.

The ship's movement must always reflect its physical limitations.

### Autonomous execution

Ships are responsible for executing accepted movement orders without continuous player intervention.

This includes managing their speed, selecting suitable maneuvers, avoiding obstacles, resolving destinations, and recovering from interruptions whenever possible.

The ship should adapt its behavior as circumstances change while continuing to pursue the player's intended destination.

A ship must not abandon a completable order simply because its initial approach becomes unsuitable.

Player intervention is only necessary when the ship can no longer complete its order.

Autonomy does not remove the physical consequences of movement. A capable ship can still be slow, difficult to turn, or unable to avoid a collision.

## 3. Movement From Rest

A stationary ship has its greatest freedom to reposition.

When ordered to move, it can begin translating toward its destination while simultaneously rotating its hull to face the intended direction of travel.

It does not need to finish turning before moving.

This creates a distinct low-speed maneuvering behavior. The ship can move sideways, diagonally, forwards, or backwards while gradually adjusting its orientation.

For short distances, the ship may reach its destination before completing its rotation.

In these situations, it finishes rotating toward its destination before the movement order is considered complete.

Turning from rest should still convey the vessel's mass. A large ship must not spin rapidly in place simply because it has little forward momentum.

**The intended feeling is controlled repositioning, not an instant pivot followed by forward travel.**

## 4. Movement Underway

Once a ship is moving, its behavior changes.

Forward propulsion becomes dominant, and the ship increasingly commits to the direction it is traveling.

Its bow and actual trajectory should remain aligned as closely as its physical limitations allow. Temporary differences are acceptable during maneuvers, but a moving vessel should not routinely travel in one direction while facing another.

The ship should seek to make its actual trajectory follow its orientation throughout movement.

### Gradual course changes

When given a new destination at a moderate angle to its current direction, the ship should transition into a curved trajectory.

Its hull turns gradually, and its actual movement follows.

When the destination is far away, the ship should preserve momentum wherever possible, performing a wide and deliberate turn rather than unnecessarily braking.

The result is a broad, flowing naval maneuver rather than a sharp change of direction.

### Sharp course changes

Larger changes in direction require more room and more time.

The necessary maneuver depends on the ship's current speed, mass, distance to the destination, and available maneuvering room.

A distant destination may allow a wide turn that preserves momentum.

A nearby destination may require the ship to reduce speed considerably before it can turn or reposition effectively.

The ship should not automatically stop and rotate whenever a sharp order is issued. As long as it has sufficient room and maneuvering capability, it should continue moving through the turn.

However, it must respect its physical limitations rather than forcing itself along a trajectory it cannot follow.

### Reversing direction

An order to travel opposite the ship's current movement is a significant maneuver.

The new direction is evaluated against where the ship is actually moving, not simply where its bow is pointing.

The distance to the destination determines how the reversal should be approached.

If the destination is far away, the ship may preserve momentum through a wide maneuver where physically possible.

If the destination is nearby and behind its direction of travel, it must substantially reduce speed before it can perform the necessary turn.

If the destination is extremely close and directly opposite its direction of travel, the ship must stop and use controlled low-speed repositioning to reach it.

Reversing direction should feel costly and deliberate, particularly for larger vessels.

### Speed management

The ship manages its traveling speed autonomously.

For long-distance movement, it accelerates toward its available cruising speed, accounting for the time and distance required to reach that speed and eventually slow down.

For shorter movements, it may remain at lower speeds to preserve the maneuverability required for accurate positioning.

Speed must also adjust to the demands of upcoming turns, obstacles, and available space.

A ship should slow down when its current speed would prevent it from performing the maneuver required to reach its destination.

The player is not responsible for managing this process.

## 5. Braking and Arrival

Ships should naturally reduce their speed as they approach a destination.

Braking is part of the movement itself, not a correction performed after the ship reaches its target.

The ship must account for its existing momentum, mass, available stopping power, and distance to the destination.

The expected behavior is a gradual approach followed by a controlled and accurate arrival.

### Arrival accuracy

Ships should reach their intended destination with very little positional deviation.

Small deviations are acceptable when required by the circumstances of the destination or the ship's physical limitations.

The ship should not repeatedly circle, reverse, or make unnecessary corrections simply to occupy an exact point.

### Overshooting

Under normal circumstances, speed management should prevent overshooting.

However, a ship may receive an order while traveling at a speed that makes stopping before the destination physically impossible.

In these exceptional circumstances, overshooting is acceptable.

The ship must then perform a controlled maneuver to return to its destination, respecting its mass, momentum, and available maneuvering capabilities.

Overshooting should be a consequence of unavoidable physical limitations, not a routine part of arrival.

### Final orientation

The ship should finish facing the direction of its final destination.

The player does not specify a separate final heading. Orientation is handled autonomously as part of the movement.

A ship may reach its destination before completing its rotation. In that case, it must finish rotating before the order is considered complete.

Once the destination and final orientation have been achieved, the vessel should settle naturally without unnecessary movement.

A new order begins a new maneuver from the ship's actual position, heading, and movement state.

**Arrival should feel like a vessel coming to rest, not an object snapping into place.**

## 6. Navigation and Obstacles

Ships operate in environments containing asteroids, other vessels, and physical obstacles.

Navigation must respect the ship's dimensions, momentum, speed, and maneuvering capabilities.

A route that is geometrically clear is not necessarily a route the ship can safely follow.

A ship traveling at speed may require a wide passage to turn, while the same ship at low speed may navigate much tighter spaces through controlled repositioning.

### Clearance and maneuvering room

Navigation must account for the space occupied by the ship's entire hull.

Clearance is not merely the distance between the ship and an obstacle. It also concerns whether the ship has enough room to rotate, brake, and continue moving without a collision.

A long or large vessel may fit through a passage while traveling straight but lack the space required to turn within it.

When a ship cannot rotate safely in its current position, it should reposition forwards or backwards to create sufficient maneuvering room.

The ship must not attempt rotations that its available clearance cannot accommodate.

Visual banking is excluded from these physical considerations. Banking does not change the ship's collision footprint or maneuvering capabilities.

### Obstacle avoidance

When an obstacle interrupts the journey, the ship should navigate around it using the same movement rules that govern travel in open space.

It may reduce speed, take a wider route, or reposition itself to pass safely.

The ship should preserve momentum when possible, but slowing down is acceptable when necessary to perform a safe maneuver.

It should not suddenly acquire unrealistic turning or braking capabilities because an obstacle is nearby.

A ship should avoid committing to maneuvers it cannot safely execute when the obstacle and available space can be anticipated.

### Unexpected obstacles

An obstacle may appear or move into the ship's path after a maneuver has already begun.

The ship should respond by braking and reevaluating its movement within its existing physical capabilities.

If its accumulated momentum and available maneuvering room make a collision unavoidable, the collision is accepted as a consequence of the situation.

The ship must not violate its movement rules to guarantee collision avoidance.

### Destination resolution

The player's movement order expresses a desired destination.

If the exact position is obstructed or cannot be reached safely, the ship should automatically select the nearest suitable reachable position within an adjustable maximum displacement of 30 units.

The destination marker must represent the actual position the ship will attempt to reach, including when an alternative destination has been selected.

The ship does not need to notify the player about this adjustment.

Reaching the resolved destination counts as successful completion of the movement order.

If no suitable destination or safe route exists, the ship must reject the order and warn the player.

### Recovery and failed navigation

An accepted movement order remains the ship's responsibility.

If the planned route becomes obstructed or unsuitable during movement, the ship should attempt to resolve the situation independently.

It may slow down, reposition, or find another suitable route while remaining bound by its physical limitations.

The ship should not require repeated movement orders merely to overcome ordinary navigation difficulties.

If the ship can no longer complete its order, it must communicate that failure to the player rather than continuing indefinitely without making progress.

### Other vessels and fleet movement

Other vessels are physical obstacles and must be considered during navigation.

When multiple ships require passage through the same space, a priority vessel should be selected and granted right of passage. Other ships should yield accordingly.

Ships navigate toward their destinations using individual paths.

Group movement must not depend on the player manually correcting the trajectory of every participating vessel.

Detailed formation behavior is outside the scope of this movement document.

## 7. Orders and Responsiveness

The player commands ships rather than directly controlling their engines or thrusters.

A movement order expresses an intention. The ship then executes that intention using its available maneuvering capabilities.

### Crew responsiveness

Orders are not necessarily executed immediately.

Crew responsiveness introduces a delay between receiving and executing a command. A more experienced crew may respond sooner than an inexperienced one.

The delay begins when the new order is received.

During this period, the ship continues executing its previous active order.

When the delay expires, the previous order is canceled and the new order becomes active.

### Changing orders

A new movement order does not reset the ship's physical state.

The ship must transition smoothly from its previous movement into the maneuver required by the new destination.

This transition may include a recovery phase in which the ship reduces speed, adjusts its trajectory, or repositions before it can proceed effectively.

Abrupt changes in heading, velocity, or movement capabilities are not acceptable.

The consequences of the previous order remain relevant even after that order has been canceled.

### Player control and feedback

The player does not directly control movement speed or individual propulsion systems.

The ship determines the necessary movement behavior autonomously.

Normal acceleration, braking, turning, obstacle avoidance, and repositioning should be understandable through the ship's visible behavior.

The player should not receive unnecessary notifications while a movement order is progressing successfully.

The destination marker provides a visual indication of where the ship is actually traveling.

Warnings are reserved for situations in which a movement order cannot be accepted or can no longer be completed.

**The player should be able to trust an accepted, achievable order without continuously supervising its execution.**

## 8. Tactical Consequences

Movement is a fundamental part of combat decision-making.

A ship's position, heading, speed, mass, and available maneuvering room affect what it can do next.

A vessel committed to one direction cannot instantly disengage, reverse course, or reposition to another angle.

A larger ship may have considerable combat value, but its limited maneuverability creates vulnerabilities that a smaller ship may not share.

The player should learn to anticipate movement rather than continuously correcting it.

Good positioning should feel rewarding because achieving it requires planning and commitment.

Poor positioning should carry a real cost, but that cost must come from understandable movement rules rather than unpredictable navigation or unreliable order execution.

A vessel that requires more time and space to maneuver is not less capable of following orders. It simply pays a greater cost to achieve them.

In fleet warfare, the player's responsibility is to make tactical decisions for multiple vessels, not to personally supervise their individual maneuvers.

## 9. Intended Player Experience

The movement system succeeds when the following situations feel natural:

- **From rest:** A frigate ordered sideways begins moving toward its destination while slowly rotating its bow. If it reaches the position first, it finishes rotating before completing the order.
    
- **At cruising speed:** A frigate ordered toward a distant position 90 degrees to its current course performs a wide, deliberate turn while preserving momentum.
    
- **On a nearby sharp turn:** A frigate reduces speed sufficiently to perform the necessary maneuver instead of forcing an unrealistic turn at full speed.
    
- **On a distant reversal:** A frigate uses the available distance to carry out a wide maneuver where its physical capabilities allow.
    
- **On a close reversal:** A frigate substantially slows down, potentially stopping and using directional thrusters to reposition when the destination is extremely close.
    
- **Near an asteroid:** A moving frigate takes a route with sufficient clearance, slowing or repositioning if necessary rather than attempting an impossible turn.
    
- **At an obstructed destination:** A frigate automatically selects a suitable nearby position, with the destination marker reflecting its resolved target.
    
- **On an interrupted journey:** A frigate adapts to a newly obstructed route and continues toward its destination without requiring another order, provided that the order remains achievable.
    
- **When collision is unavoidable:** A frigate respects its physical limitations rather than performing an impossible evasive maneuver.
    
- **On arrival:** A frigate approaches its destination, gradually brakes, reaches the required position, completes its final rotation, and settles.
    
- **On an abrupt new order:** A frigate continues its existing order during crew response delay, then transitions smoothly toward its new destination.
    
- **Between ship classes:** A smaller vessel performs comparable maneuvers with less time and space, while a larger vessel makes the same actions feel more consequential.
    
- **During fleet movement:** Multiple ships navigate independently toward their destinations without requiring the player to constantly correct their movements.
    

These are not separate movement modes with unrelated behavior. They are expressions of the same underlying rules under different conditions.

## 10. Design Intent

Daung's movement should reward anticipation, positioning, and commitment.

Ships should feel powerful because of their mass and presence, not because they can perform impossible maneuvers.

They are capable vessels, not helpless objects. They should competently carry out orders while remaining bound by their physical limitations.

The ideal experience is that a player can observe a ship maneuvering and understand why it behaves as it does.

The player's challenge comes from choosing where and when to position ships, understanding the consequences of those decisions, and coordinating vessels with different capabilities.

It should not come from repeatedly correcting navigation or compensating for a ship's inability to execute reasonable orders.

**The player should feel like an admiral commanding heavy warships, not a pilot flying starfighters.**