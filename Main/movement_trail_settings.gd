class_name MovementTrailSettings
extends Resource
## Debug-only configuration of the F3 movement trail (not movement tuning). Provisional technical guardrails for
## bounded cost and sample density. Configuration only; never written at runtime.

## Most recorded positions kept; when exceeded, the oldest are dropped and tracing continues.
@export_range(256, 8192, 1) var max_trail_points: int = 4096
## A position is recorded only once the ship is at least this far (XZ) from the last recorded one.
@export_range(0.01, 0.5, 0.01, "suffix:m") var min_sample_distance: float = 0.1
