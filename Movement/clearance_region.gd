class_name ClearanceRegion
extends NavigationRegion3D

## A baked navigation region for one clearance class. Must be a child of a
## StaticNavigation node, which places it on that class's map.

@export var clearance: NavigationClearance


func _ready() -> void:
	if navigation_mesh.get_polygon_count() == 0:
		push_error("%s: navmesh is not baked; ships using it stay pending." % name)
	if navigation_mesh.agent_radius < clearance.required_radius():
		push_error("%s: navmesh agent_radius %.2f is below footprint + margin %.2f; rebake." % [name, navigation_mesh.agent_radius, clearance.required_radius()])
	var navigation := get_parent() as StaticNavigation
	if navigation == null:
		push_error("%s must be a child of a StaticNavigation node." % name)
		return
	navigation.register_region(self)
