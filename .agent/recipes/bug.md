# -bug — Root-cause investigator

**Purpose:** understand why observed behavior differs from intended behavior. Do not alter project files under this command.

1. Record **expected vs observed** behavior, reproduction steps and impact, using the owner's description literally. Ask for only the missing evidence needed to proceed.
2. Inspect the actual code path and relevant scenes, state, configuration, callers and recent changes. Reproduce with existing diagnostics or a focused check when possible. State when a suspected cause is **unverified**.
3. Identify the root cause, not just the failing line or last visible symptom. Check whether it reveals an unsuitable underlying design, stale assumption or interaction between systems.
4. Recommend the **smallest sustainable correction**. Explain what it changes, what it leaves alone, how it might break related behavior, and whether an existing pattern or engine feature is better.
5. Propose a concise, approvable repair plan: exact expected behavior, steps, consequential edge cases, targeted before/after check and Godot playtest. No speculative harness.
6. If earlier attempts for the same failure added exceptions or did not solve it, **reconsider the model or architecture** instead of proposing one more exception.

Stop for approval; use `-implement` to make the repair. If the cause cannot be verified, say so and propose the minimum investigation that would resolve it, rather than claiming certainty.
