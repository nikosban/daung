class_name NavigationBudget
extends Resource
## Global planning limits for ship navigation (Task #46), shared by every ship. Provisional technical guardrails, not
## movement tuning. Configuration only; never written at runtime.

## Wall-clock time all planning jobs together may use in one physics tick. A job that does not finish continues on
## the next tick (the same job, never restarted). It only spreads planning over ticks; it never changes an outcome.
@export_range(250, 8000, 1, "suffix:µs") var plan_time_per_tick: int = 1500
## Total predicted flight time one order's planning may simulate over all its candidate predictions; a search that
## reaches it is declined. Counted in predicted time, not wall-clock time, so the same order from the same state always
## gets the same result on any machine.
@export_range(10.0, 600.0, 1.0, "suffix:s") var plan_prediction_per_order: float = 120.0
