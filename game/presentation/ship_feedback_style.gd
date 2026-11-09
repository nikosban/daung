class_name ShipFeedbackStyle
extends Resource
## Shared appearance. The selection ring uses world metres.

@export var material: StandardMaterial3D
@export var pending_material: StandardMaterial3D
@export_range(0.01, 1000.0, 0.01, "or_greater", "suffix:m") var selection_radius := 8.0
@export_range(0.01, 32.0, 0.01, "or_greater", "suffix:m") var selection_stroke := 0.5
@export_range(1.0, 256.0, 0.1, "suffix:px") var destination_inner_radius := 30.0
@export_range(1.0, 256.0, 0.1, "suffix:px") var destination_outer_radius := 45.0
@export_range(0.1, 359.9, 0.1, "degrees") var destination_arc_degrees := 120.0
@export_range(0.1, 32.0, 0.1, "suffix:px") var ring_stroke := 4.0
@export_range(0.1, 32.0, 0.1, "suffix:px") var line_width := 3.0
@export_range(0.0, 64.0, 0.1, "suffix:px") var line_gap := 8.0
