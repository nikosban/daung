class_name NavigationBudget
extends Resource
## Global planning limits for ship navigation (Tasks #46, #56), shared by every ship. Provisional technical guardrails,
## not movement tuning. Configuration only; never written at runtime.

## Wall-clock time all navigation jobs together may use in one physics tick. Work that does not finish continues on
## the next tick. A checked-flight decision that is not ready at its interval boundary makes the ship brake for that
## interval (Task #56); otherwise the allowance only spreads work over ticks.
@export_range(250, 8000, 1, "suffix:µs") var plan_time_per_tick: int = 1500
## Destination resolution (Task #54): path-query tests one order's search may make before it ends as "search
## exhausted". Candidates rejected by the arrival-allowance and hull checks do not count; the search horizon (the
## navigation regions' bounds) bounds those. Provisional technical guardrail.
@export_range(1, 64, 1) var destination_candidates_per_order: int = 16
## Alternative-passage queries (Task #56) one order may start when its path cannot be negotiated; each query counts,
## found or not. When they are used up and nothing passes from rest, the order is blocked (unresolved). Provisional.
@export_range(0, 8, 1) var path_recoveries_per_order: int = 2
## A* searches one alternative-passage query may run (each search can yield one distinct passage). Provisional.
@export_range(1, 8, 1) var passage_searches_per_query: int = 4
