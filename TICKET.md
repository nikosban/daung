# Ticket format

The tech lead creates every issue with this body. The top three sections are
for the owner, in plain language; the technical part is folded.

Issue title: `Task <n>: <imperative title>`

```markdown
## What you'll see
<What changes in the game and how to try it, in plain language.>

## Your answers
<The owner's words and numbers, quoted exactly.>

## Done when
<The decisive in-play check, with numbers. Setup reproducible in under a
minute.>

<details><summary>Technical (tech lead and agent)</summary>

- **Scope**: In / Out.
- **Technique**: engine feature / known technique (source) / custom
  (owner-approved).
- **Reuse**: what it extends, or which reuse case applies.
- **Map change**: none, or the new module or dependency.
- **Design**: owner module; interface changes; state added or removed;
  strongest rejected alternative and why.
- **Values**: tuning values with data asset, default, unit, range, and
  whether provisional.
- **Edge cases**: critical (this ticket) / QA (deferred).
- **Interactions**: affected systems and the effect on each.
- **Debt**: incurred / repaid.
- **Needs owner decision**: gameplay or visual questions only, or none.
- **Open**: UNKNOWN / UNDECIDED (whose).
- **Size**: S / M.

</details>
```
