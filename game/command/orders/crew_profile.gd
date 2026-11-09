class_name CrewProfile
extends Resource
## Shared crew configuration. Read-only at runtime; all values are provisional.

## Crew reaction delay: time between receiving a move or stop command and the ship acting on it. Every command waits
## its own delay; the active order stands until then. 0 acts on the next physics tick.
@export_range(0.0, 5.0, 0.01, "suffix:s") var reaction_delay: float = 0.3
