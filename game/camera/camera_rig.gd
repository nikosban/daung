class_name CameraRig
extends Node3D
## The root is the horizontal floor focus. Only its active Camera3D accepts input.

@export var settings: CameraSettings

var _height: float
var _target_height: float
var _yaw: float
var _held_keys: Dictionary[int, InputEventKey] = {}
var _orbiting := false
var _zoom_repeat_left := 0.0

@onready var _pitch: Node3D = $PitchPivot
@onready var _camera: Camera3D = $PitchPivot/Camera3D


func _ready() -> void:
	if settings == null or settings.min_height <= 0.0 or settings.max_height < settings.min_height \
			or settings.initial_height < settings.min_height or settings.initial_height > settings.max_height \
			or settings.pitch_degrees <= 0.0 or settings.pitch_degrees >= 90.0 \
			or settings.zoom_factor <= 1.0 or settings.zoom_smoothing_time <= 0.0 \
			or settings.keyboard_zoom_interval <= 0.0:
		push_error("CameraRig requires valid camera settings and initial height within its zoom limits.")
		set_process(false)
		set_process_input(false)
		set_process_unhandled_input(false)
		return
	get_window().focus_exited.connect(_clear_input)
	_camera.fov = settings.field_of_view
	_camera.near = settings.near_clip
	_camera.far = settings.far_clip
	set_view(global_position, settings.initial_height, settings.initial_yaw_degrees)


func get_camera() -> Camera3D:
	return $PitchPivot/Camera3D


## Immediate placement; focus Y supplies the horizontal floor elevation.
func set_view(focus_position: Vector3, height: float, yaw_degrees: float) -> void:
	global_position = focus_position
	_height = clampf(height, settings.min_height, settings.max_height)
	_target_height = _height
	_yaw = deg_to_rad(yaw_degrees)
	_apply_view()
	reset_physics_interpolation()


func _input(event: InputEvent) -> void:
	# Releases must clear state even when a UI consumes them later.
	if not _camera.current:
		_clear_input()
	elif event is InputEventKey and not event.pressed:
		_held_keys.erase(_key_id(event))
	elif event.is_action_released("camera_orbit"):
		_orbiting = false


func _unhandled_input(event: InputEvent) -> void:
	if not _camera.current:
		return
	if event is InputEventKey:
		if not event.pressed or event.echo:
			return
		for action in [&"camera_zoom_in", &"camera_zoom_out", &"camera_rotate_left", &"camera_rotate_right",
				&"camera_pan_forward", &"camera_pan_back", &"camera_pan_left", &"camera_pan_right"]:
			if event.is_action(action):
				var was_zooming := _zoom_direction()
				_held_keys[_key_id(event)] = event
				var zooming := _zoom_direction()
				if zooming != was_zooming:
					if zooming != 0.0:
						_zoom(zooming)
					_zoom_repeat_left = settings.keyboard_zoom_interval
				get_viewport().set_input_as_handled()
				return
	elif event is InputEventMouseButton:
		if event.is_action_pressed("camera_orbit"):
			_orbiting = true
		elif event.is_action_pressed("camera_zoom_in"):
			_zoom(-event.factor)
		elif event.is_action_pressed("camera_zoom_out"):
			_zoom(event.factor)
		else:
			return
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _orbiting:
		_yaw -= deg_to_rad(event.screen_relative.x * settings.mouse_rotation_sensitivity)
		_apply_view()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _camera.current or get_viewport().gui_get_focus_owner() != null:
		_clear_input()
	else:
		var zooming := _zoom_direction()
		if zooming != 0.0:
			_zoom_repeat_left -= delta
			while _zoom_repeat_left <= 0.0:
				_zoom(zooming)
				_zoom_repeat_left += settings.keyboard_zoom_interval
		var turning := float(_action_held(&"camera_rotate_left")) - float(_action_held(&"camera_rotate_right"))
		_yaw += deg_to_rad(turning * settings.keyboard_rotation_speed) * delta
	_height = lerpf(_height, _target_height, 1.0 - exp(-delta / settings.zoom_smoothing_time))
	var pan := Vector3(float(_action_held(&"camera_pan_right")) - float(_action_held(&"camera_pan_left")),
		0.0, float(_action_held(&"camera_pan_back")) - float(_action_held(&"camera_pan_forward")))
	global_position += pan.normalized().rotated(Vector3.UP, _yaw) * settings.pan_speed * (_height / settings.initial_height) * delta
	_apply_view()


func _apply_view() -> void:
	_yaw = wrapf(_yaw, -PI, PI)
	global_basis = Basis(Vector3.UP, _yaw)
	_pitch.rotation = Vector3(-deg_to_rad(settings.pitch_degrees), 0.0, 0.0)
	_camera.position = Vector3(0.0, 0.0, _height / sin(deg_to_rad(settings.pitch_degrees)))


func _zoom(direction: float) -> void:
	_target_height = clampf(_target_height * pow(settings.zoom_factor, direction), settings.min_height, settings.max_height)


func _action_held(action: StringName) -> bool:
	for key in _held_keys.values():
		if key.is_action(action):
			return true
	return false


func _zoom_direction() -> float:
	return float(_action_held(&"camera_zoom_out")) - float(_action_held(&"camera_zoom_in"))


func _key_id(key: InputEventKey) -> int:
	return key.physical_keycode if key.physical_keycode != 0 else key.keycode


func _clear_input() -> void:
	_held_keys.clear()
	_orbiting = false
	_zoom_repeat_left = 0.0
