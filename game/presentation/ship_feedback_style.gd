class_name ShipFeedbackStyle
extends Resource
## Shared appearance. All sizes use world metres on the Y = 0 plane.

@export var material: StandardMaterial3D
@export var pending_material: StandardMaterial3D
@export_range(0.01, 1000.0, 0.01, "or_greater", "suffix:m") var selection_radius := 8.0
@export_range(0.01, 32.0, 0.01, "or_greater", "suffix:m") var selection_stroke := 0.5
@export_range(0.01, 1000.0, 0.01, "or_greater", "suffix:m") var destination_inner_radius := 5.0
@export_range(0.01, 1000.0, 0.01, "or_greater", "suffix:m") var destination_outer_radius := 7.5
@export_range(0.1, 359.9, 0.1, "degrees") var destination_arc_degrees := 120.0
@export_range(0.01, 32.0, 0.01, "or_greater", "suffix:m") var ring_stroke := 0.5
@export_range(0.01, 32.0, 0.01, "or_greater", "suffix:m") var line_width := 0.65
@export_range(0.0, 64.0, 0.01, "or_greater", "suffix:m") var line_gap := 1.0
