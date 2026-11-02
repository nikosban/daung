class_name MovementProfile
extends Resource
## Shared movement tuning for a ship type. Configuration only; never written at runtime.

@export_range(0.0, 60.0, 0.1, "suffix:m/s") var max_speed: float = 8.0
@export_range(0.1, 30.0, 0.1, "suffix:m/s²") var acceleration: float = 6.0
@export_range(0.1, 40.0, 0.1, "suffix:m/s²") var braking: float = 10.0
@export_range(1.0, 120.0, 0.1, "suffix:°/s") var turn_rate: float = 20.0
@export_range(0.1, 10.0, 0.1, "suffix:m") var arrival_tolerance: float = 2.0
## How fast a moving ship can rotate its travel direction (not its hull).
@export_range(1.0, 90.0, 0.1, "suffix:°/s") var travel_turn_rate: float = 12.0
## Orders at least this far from the current travel direction brake to rest before starting.
@export_range(90.0, 180.0, 0.1, "suffix:°") var near_opposite_angle: float = 150.0
