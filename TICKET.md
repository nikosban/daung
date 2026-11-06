# Optional GitHub issue format

Use an issue when a task needs a durable, cross-session approved plan or a PR discussion. Small tasks in one conversation do not require a ticket.

The agent may create the issue and post a proposal during `-plan`, `-bug` or `-visual`. The owner approves the **specific plan revision**, not the issue in general. Never silently edit an approved plan in place; post a new revision and obtain renewed approval.

Suggested issue/plan contents:

- **Plan name and revision:** e.g. `Destination marker — v2`.
- **Intent:** what the player should experience; exclusions.
- **Requirements:** numbered, observable, literal values preserved.
- **Implementation:** ordered steps, affected systems, rationale.
- **Tradeoffs and edge cases:** meaningful now, deferred or unresolved.
- **Verification:** focused technical check and owner playtest.

Once approved, `-implement` uses that exact plan/comment as its source. The PR compares delivery against its numbered requirements. No separate Tech Lead approval or mandatory labels.
