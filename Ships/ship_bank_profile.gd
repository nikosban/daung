class_name ShipBankProfile
extends Resource
## Shared visual banking tuning for a ship family. Presentation only; never written at runtime.

## Broad maneuvers heel outward, away from the inside of the turn.
@export_range(0.0, 12.0, 0.1, "suffix:°") var outward_heel: float = 4.0
## Sharp maneuvers bank inward, toward the inside of the turn.
@export_range(0.0, 20.0, 0.1, "suffix:°") var inward_bank: float = 9.0
## Orders whose initial course change is at least this angle are sharp maneuvers.
@export_range(10.0, 149.0, 0.1, "suffix:°") var sharp_turn_angle: float = 70.0
## Maximum roll change rate, entering and recovering.
@export_range(0.5, 30.0, 0.1, "suffix:°/s") var roll_rate: float = 7.0
## The course counts as straight once the travel direction is within this angle of the goal.
@export_range(0.1, 10.0, 0.1, "suffix:°") var settle_angle: float = 3.0
