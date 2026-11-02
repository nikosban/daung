class_name MovementProfile
extends Resource
## Shared movement tuning for a ship type. Configuration only; never written at runtime.

@export_range(0.0, 60.0, 0.1, "suffix:m/s") var max_speed: float = 10.0
@export_range(0.1, 30.0, 0.1, "suffix:m/s²") var acceleration: float = 6.0
@export_range(0.1, 40.0, 0.1, "suffix:m/s²") var braking: float = 10.0
@export_range(1.0, 120.0, 0.1, "suffix:°/s") var turn_rate: float = 35.0
@export_range(0.1, 10.0, 0.1, "suffix:m") var arrival_tolerance: float = 2.0
