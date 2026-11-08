class_name CameraSettings
extends Resource
## Shared Inspector tuning. Runtime view/input state belongs to CameraRig, not this resource.
## Values and ranges are provisional, approved for the camera trial in issue #70.

@export_group("View")
## Starting height above the floor; also the reference height for pan_speed.
@export_range(1.0, 1000.0, 1.0, "suffix:m") var initial_height: float = 55.0
@export_range(1.0, 1000.0, 1.0, "suffix:m") var min_height: float = 15.0
@export_range(1.0, 1000.0, 1.0, "suffix:m") var max_height: float = 400.0
@export_range(5.0, 85.0, 1.0, "suffix:°") var pitch_degrees: float = 45.0
@export_range(-180.0, 180.0, 1.0, "suffix:°") var initial_yaw_degrees: float = 0.0
@export_range(20.0, 100.0, 1.0, "suffix:°") var field_of_view: float = 75.0
@export_range(0.01, 10.0, 0.01, "suffix:m") var near_clip: float = 0.05
@export_range(100.0, 10000.0, 1.0, "suffix:m") var far_clip: float = 2000.0

@export_group("Zoom")
## Reciprocal steps: zoom in divides height; zoom out multiplies it.
@export_range(1.01, 1.5, 0.01) var zoom_factor: float = 1.1
## Exponential time constant; about 95% settled after three times this duration.
@export_range(0.01, 1.0, 0.01, "suffix:s") var zoom_smoothing_time: float = 0.12
@export_range(0.05, 1.0, 0.01, "suffix:s") var keyboard_zoom_interval: float = 0.15

@export_group("Rotation and panning")
@export_range(1.0, 360.0, 1.0, "suffix:°/s") var keyboard_rotation_speed: float = 90.0
@export_range(0.01, 2.0, 0.01, "suffix:°/px") var mouse_rotation_sensitivity: float = 0.2
## Base metres/second at initial_height. Actual speed scales with current smoothed height.
@export_range(1.0, 500.0, 1.0, "suffix:m/s") var pan_speed: float = 75.0
