class_name NavigationBudget
extends Resource
## Global planning limits for ship navigation (Task #46), shared by every ship. Provisional technical guardrails, not
## movement tuning. Configuration only; never written at runtime.

## Wall-clock time all planning jobs together may use in one physics tick. A job that does not finish continues on
## the next tick (the same job, never restarted). It only spreads planning over ticks; it never changes an outcome.
@export_range(250, 8000, 1, "suffix:µs") var plan_time_per_tick: int = 1500
## Legacy full-flight prediction limit, retained in serialized data; unused by the Task #60 local navigator.
@export_range(10.0, 600.0, 1.0, "suffix:s") var plan_prediction_per_order: float = 120.0
## Destination resolution (Task #54): path-query tests one order's search may make before it ends as "search
## exhausted". Candidates rejected by the arrival-allowance and hull checks do not count; the search horizon (the
## navigation regions' bounds) bounds those. Provisional technical guardrail.
@export_range(1, 64, 1) var destination_candidates_per_order: int = 16
## Destination limit (Task 37, #78): destination resolution accepts no point farther than this from the ship's
## requested point; 0 = no additional limit (the search stays bounded by the navigation area and the budgets above).
## Provisional; gameplay decides.
@export_range(0.0, 1000.0, 0.5, "or_greater", "suffix:m") var max_destination_displacement: float = 30.0
