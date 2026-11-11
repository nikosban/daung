# Daung — Movement Redesign Specification

**Status:** Draft for owner review  
**Date:** 11 November 2026  
**Scope:** Movement, navigation, obstacle response, arrival and coordinated fleet movement  
**Purpose:** Replace the current shared directional-thrust approach with independent forward, retro and rotational propulsion, while preserving Daung's heavy naval movement fantasy.

## 1. Player experience

The player selects a destination, not a method of travel. The ship autonomously reaches that destination through believable maneuvers constrained by its momentum, orientation and propulsion. Movement should feel deliberate and substantial, not like a fighter that can instantly correct its position. Ordinary achievable orders should complete without repeated player intervention.

All tactical movement remains on a two-dimensional plane, with three-dimensional ship models.

## 2. Propulsion and physical behavior

**MOV-01 — Independent propulsion.** Every ship has three independent controls: main engines accelerate along the bow; retro thrusters accelerate toward the stern, enabling braking and reverse travel; RCS rotates the hull. These systems may operate simultaneously and do not share a thrust budget.

**MOV-02 — No sideways translation from RCS.** RCS supplies rotation only. No directional thruster can directly push a ship sideways. Sideways displacement can still occur as a consequence of existing momentum, but it cannot be commanded as independent lateral propulsion.

**MOV-03 — Persistent momentum.** Changing a destination or turning the hull does not rotate, reset or cancel the ship's existing movement. Only propulsion and physical contact can change its actual velocity. All accelerations and turns are limited by the ship's configured capabilities; no snapping.

**MOV-04 — Different vessels.** Ship classes use the same movement principles but can have different forward thrust, retro thrust, rotation capability, speed and mass-related behavior. The frigate is the first playable baseline.

## 3. Intended direction, corridor and Pilot

**MOV-05 — Distinguish intent from travel.** The player's destination defines where to go, not a straight line the ship must follow. Navigator provides a safe movement corridor. The ship's actual path emerges as Pilot operates its engines and RCS within that space; it is not forced onto a predefined curve.

**MOV-06 — Pilot owns physical execution.** Pilot uses current position, real velocity, hull heading, destination, remaining travel distance, corridor guidance and immediate hazard information to select heading, forward thrust, retro thrust and rotation. No other system changes the ship's movement directly.

**MOV-07 — Trajectory-oriented heading.** RCS aligns the hull to the heading useful for progressing along the intended trajectory, rather than blindly pointing at the destination. The bow and actual movement direction may temporarily differ during a maneuver. Rotation alone never changes the ship's travel direction.

**MOV-08 — Maneuvers depend on circumstances.** Pilot can rotate while accelerating; preserve a broad turn while underway; brake before a tight or nearby maneuver; and, when useful, reverse slightly while rotating before moving forward. Reversing at departure is an option, not a required sequence. The ship need not face the destination before it starts moving.

**MOV-09 — Distance-aware speed.** Long open journeys can use cruising speed. Short journeys, approaching turns, nearby destinations and restricted maneuvering space call for lower speed. A new order continues from the ship's actual motion instead of resetting it.

## 4. Arrival

**ARR-01 — Controlled approach.** Pilot anticipates the remaining distance, speed, direction of travel and available retro thrust to begin braking before arrival. Braking uses dedicated retro propulsion and can occur while RCS rotates the hull.

**ARR-02 — Accept small imperfections.** Arrival has configurable position and speed tolerances. A very small overshoot or final positional offset is acceptable when the ship settles naturally. Exact-point corrections must not produce repeated back-and-forth movements, circles, abrupt snaps or visibly strange finishing maneuvers.

**ARR-03 — Complete or report a problem.** The ship completes an achievable order autonomously. If it cannot reach an acceptable final position, it reports the failure rather than moving indefinitely. Final heading remains governed by the existing GDD unless changed explicitly; no artificial rotation or position snap may be introduced to satisfy it.

## 5. Static navigation and corridor clearance

**NAV-01 — Known map obstacles.** Navigator knows the static obstacles on each map before ordinary movement begins. Environments are expected to have generous open space; narrow corridors and exhaustive maneuver proofs are not the target.

**NAV-02 — Enlarged navigation footprints.** Asteroids and occupied ship locations have navigation footprints larger than their physical collision shapes. The additional clearance accounts for the moving ship's full hull reach, its ability to rotate, and a safety margin. Physical collision shapes remain unchanged.

**NAV-03 — Corridor rather than rigid track.** Navigator chooses traversable space outside enlarged footprints and supplies a corridor or equivalent boundaries and route guidance. Pilot can vary its actual path inside that space. Navigator does not directly command rotations, engine thrust or exact frame-by-frame movement.

**NAV-04 — Adjust to obstacles.** When an intended corridor conflicts with a known obstacle, Navigator adjusts the relevant ship's route. If the requested destination is occupied, existing nearby-destination resolution applies, including its configurable 30-unit displacement limit and visible resolved destination marker. Orders with no suitable route or endpoint are declined with feedback.

**NAV-05 — Corridor feasibility is tested in play.** We do not add exhaustive advance proofs that a maneuver is possible at every speed. If actual ships cannot remain inside a corridor reliably, the owner evaluates the behavior in-game before deciding what to change.

## 6. Unexpected obstructions and collisions

**OBS-01 — Lookout is reactive.** Lookout watches the area immediately ahead of the ship's actual movement, using a check wide enough for its hull and early enough to account for stopping distance. It detects unexpected obstructions and requests braking from Pilot. It does not steer, push, plan routes or override propulsion limits.

**OBS-02 — No impossible rescue.** Pilot responds to Lookout using only its available retro propulsion and RCS. If the ship cannot avoid contact, the physical collision system handles it. There is no guarantee of collision-free travel under sudden changes.

**OBS-03 — Stationary ships are obstacles.** An approaching ship navigates around an already occupying vessel's enlarged footprint. The occupying vessel does not have to reverse, sidestep or yield merely to clear the approaching ship's route.

## 7. Moving ships and fleet orders

**FLT-01 — No global prediction-based traffic management.** Unrelated moving ships do not require complex future-trajectory prediction, priority negotiation, deadlock resolution or forced right-of-way maneuvers. Immediate obstructions are handled by Lookout; unavoidable contact uses collision handling.

**FLT-02 — One coordinated fleet plan.** When multiple ships receive the same fleet order, their intended routes are considered together. Navigator generates a coordinated collection of individual corridors/curves with room for their hulls, rather than creating unrelated routes and making the ships negotiate afterward.

**FLT-03 — Individual execution.** Each ship's Pilot independently executes its assigned corridor with its own propulsion and momentum. Its intended corridor is available to the rest of the ordered group during planning. Ships whose corridors intersect known obstacles receive individual adjustments; unaffected ships need not reroute.

**FLT-04 — No formation promise.** Coordinated routes should avoid unnecessary planned interference, but this specification does not introduce formations, synchronized arrival times or guarantees against collisions after the ships' actual movements diverge.

## 8. Responsibility boundaries

| System | Owns | Does not own |
|---|---|---|
| Orders | Player intent, command delivery and crew delay | Propulsion or navigation |
| Navigator | Known obstacles, inflated footprints, corridors, endpoint resolution, coordinated fleet routes | Physical steering and thrust |
| Pilot | Heading and maneuver choice, acceleration, braking, reverse movement, arrival | Map-wide route selection |
| Lookout | Immediate obstruction detection and braking request | Direct movement control or route planning |
| Propulsion / Ship Movement | Applying configured forward, retro and RCS limits; authoritative motion | Choosing the destination |
| Collision | Physical contact and existing contact fallback | Guaranteed avoidance |

Retain existing Orders, command delay, selection, camera, destination feedback and debugging behavior unless a later approved change explicitly replaces them.

## 9. Acceptance scenarios

Use the frigate in a simple test map first. Every item is a visible gameplay check, not a requirement for a particular algorithm.

- [ ] **From rest, sideways destination:** The frigate maneuvers through rotation and forward/reverse thrust, without instant lateral translation or a forced rotate-then-move sequence.
- [ ] **Long 90° order while cruising:** The frigate keeps its momentum and follows a broad, believable turn rather than snapping sideways.
- [ ] **Destination behind the ship:** The frigate uses a deliberate maneuver, potentially braking or reversing, and does not teleport, snap or abruptly reset velocity.
- [ ] **Short destination:** The ship adjusts speed early and arrives naturally without repeated corrections.
- [ ] **Changed order underway:** Existing motion carries over; the ship autonomously adapts to the new destination.
- [ ] **One known asteroid:** The ship navigates outside the enlarged footprint and maneuvers through available space without being forced onto an exact track.
- [ ] **Unexpected obstruction:** Lookout requests braking; the ship obeys its physical limits, with contact possible if stopping is impossible.
- [ ] **Parked ship:** A moving ship routes around it; the parked vessel remains in place.
- [ ] **Fleet of 3, then more:** One coordinated order produces distinct, compatible corridors; each ship independently follows its assigned route and only necessary routes adjust around known obstacles.
- [ ] **Existing controls:** Orders, crew delay, selection, markers, camera, debug trail and collision fallback still work.

## 10. Deliberately excluded

No direct lateral propulsion; no artificial steering of velocity; no exact path-locking; no perfect arrival requirement; no rigid library of mandatory maneuver animations; no exhaustive turn-feasibility proof; no complex moving-ship prediction; no continuous right-of-way negotiation; no dynamic collision-avoidance guarantee; no new formation mechanics.

## 11. Differences from the current movement GDD

This proposal intentionally supersedes the current GDD's sideways translation from rest, directional-thruster braking, and mandatory ship-traffic priority/yield system. The rest of the naval fantasy—momentum, deliberate turns, physical limitations, autonomous orders, destination resolution and crew delay—continues. The owner must approve corresponding GDD edits before this becomes the new authoritative movement baseline.

## 12. Values and decisions deliberately deferred

Exact main/retro/RCS strengths, turning limits, corridor margin, position/speed arrival tolerances, acceptable overshoot, and the practical maneuvering room needed at different speeds are not set here. They should be exposed for tuning and resolved by visible playtesting, beginning with a single frigate. The existing GDD's final-heading requirement is preserved pending an explicit gameplay decision if it conflicts with natural arrival.

**Delivery order:** (1) propulsion and Pilot in open space; (2) arrival; (3) enlarged footprints and corridors; (4) Lookout and parked ships; (5) coordinated fleet routes. Do not replace the accepted playable baseline until the new movement has been accepted in play.
