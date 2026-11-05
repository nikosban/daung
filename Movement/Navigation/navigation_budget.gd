class_name NavigationBudget
extends Resource
## Global planning-time limits for ship navigation (Task #46), shared by every ship. Provisional technical
## guardrails, not movement tuning. Configuration only; never written at runtime.

## Wall-clock time all planning jobs together may use in one physics tick. A job that does not finish continues on
## the next tick (the same job, never restarted).
@export_range(250, 8000, 1, "suffix:µs") var plan_time_per_tick: int = 1500
## Total wall-clock time one order's planning job may use over all its ticks; exceeding it declines the order.
@export_range(2000, 100000, 1, "suffix:µs") var plan_time_per_order: int = 15000
