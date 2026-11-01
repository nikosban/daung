class_name NavigationClearance
extends Resource

## Clearance class for static routes. One per ship type; ships and the
## navigation regions baked for them share the same resource.

## The ship type's physical footprint (authoritative; see ARCHITECTURE.md).
@export var footprint: CylinderShape3D
## Extra berth kept around fixed obstacles beyond the footprint. Navmeshes for
## this class are baked with agent_radius >= footprint.radius + margin.
@export_range(0.0, 20.0, 0.1, "suffix:units") var margin: float


func required_radius() -> float:
	return footprint.radius + margin
