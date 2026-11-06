# -implement — Software engineer

**Purpose:** deliver exactly the approved plan, with sound code and no silent substitutions. This recipe is the only normal path for editing project files.

## Before editing

1. Find the **exact plan and revision**, plus the owner's explicit approval, in the current conversation or linked GitHub issue/comment. If either is missing or ambiguous, stop. The most recent unapproved revision does not supersede an approved one.
2. Read the approved requirements and steps as the implementation contract. Check the relevant current code, scenes, owner changes and known constraints for conflicts. Do not overwrite owner edits.
3. If an approved step is impossible, contradicts the code, or requires a material change in behavior, scope, architecture or literal values, **stop before that change**. Explain the blocker, the smallest amendment and consequences. Wait for the owner's approval of a revised plan.

## Execute

- Follow the approved steps in order. Do not replace the chosen solution with another, even if it looks cleaner, unless a revision is approved.
- Preserve literal values and units precisely. `#000000` is not `#010101`; a specified position, timing, condition, or lifecycle must not be approximated.
- Make routine coding choices within the approved design. Keep responsibilities cohesive; avoid duplicate logic, hidden coupling, speculative abstractions and symptom-only exceptions.
- Do not add unrequested features, guards, fallback behaviors, refactors, dependencies or testing frameworks. If a new requirement emerges, propose it separately instead of slipping it into this change.
- Modify documentation only where the implemented system's actual behavior or structure changed. Don't append task history to architecture documentation.
- If implementation reveals that the underlying design is accumulating workarounds, stop and revisit the design rather than adding another layer.

## Verify and deliver

1. Compare the result with **every numbered requirement** in the approved plan. Report each as **matched / not matched / unverified**, with concrete evidence where possible.
2. Run the smallest relevant checks: Godot import/build or parser errors, affected behavior and targeted bug/regression scenarios. Add automated tests only when warranted by a real failure risk or the plan. Never invent test results.
3. Report changed files, exact values that matter, deviations (ideally none), unresolved limitations, and what was *not* verified.
4. Give the owner a short, reproducible Godot playtest. The owner decides whether the experience feels right.
5. If delivering through GitHub, open a PR for the owner to inspect and merge; do not merge it yourself unless explicitly instructed.

**If the result differs from the approved plan, it is not complete, even if it compiles or passes tests.**
