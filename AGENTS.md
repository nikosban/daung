# AGENTS.md

Shared instructions for all coding agents (Claude Code, Codex) in this
repository. Do not create CLAUDE.md or run /init.

## Session start

1. Read this file for operating rules.
2. Read `ARCHITECTURE.md` for units, the module map, and data rules.
3. Read `HANDOFF.md` for current project state, accepted decisions, known
   limitations, and the next task.
4. Consult closed issues, pull requests, and Git history only when
   historical context is relevant to the task; do not read them all every
   session.

## Roles

The project owner makes all design, technical, and implementation decisions.
The tech lead writes tickets as GitHub issues and reviews plans and pull
requests. The agent inspects, reports, asks, recommends, and implements only
after explicit approval.

| | Tech lead | Agent | Owner only |
|---|---|---|---|
| Issue body (the ticket) | writes | never edits | |
| Issue and PR comments | reviews, answers | plans, questions, reports | |
| Code, branches, pull requests | never | writes | |
| `approved` label, merging | | | ✔ |

## Confirmed requirements

[Written per project.]

- No systems, code, documentation, configuration, or dependencies from
  previous projects.

Decisions recorded as accepted in `HANDOFF.md` are also confirmed; anything
else is undecided. Do not infer mechanics, architecture, genre, gameplay
loops, or requirements.

## GitHub

- Tasks arrive as GitHub issues following `TICKET.md`. The issue body is the
  ticket. The owner's `approved` label is the owner's approval of the
  ticket.
- One open task at a time. Work on one branch per issue and deliver through
  one pull request that closes the issue.
- Questions go as issue comments labelled by type: `gameplay` (the owner
  answers) or `technical` (the tech lead answers).

## Owner edits

Changes the owner made (commits not made by an agent, or uncommitted changes)
are owner decisions. Never revert, overwrite, or "correct" them. In A, list
them. If any are uncommitted, ask the owner to commit them before branching.
If one conflicts with the ticket, stop and ask. If one changes a documented
value, update that doc in the pull request.

## Workflow (every task)

- **A. Inspection:** Read the task and the code it touches. Where relevant,
  check what interacts with it: callers, scenes and variants that instance or
  override it, signals, references, processing order, shared resources, and
  covering tests. Modify nothing. Report unexpected files and any existing
  defects or conflicting behavior found.
- **B. Findings and questions:** Report findings, risks, open questions,
  and recommendations. Separate verified facts from assumptions. Ask only
  questions that block the current task, as labelled issue comments. Wait
  for answers; repeat until resolved.
- **C. Plan:** When the issue carries `approved` and the plan has no
  deviations from the ticket and no blocking questions, the label is the
  approval: say so in one issue comment and continue to D. Otherwise post
  one issue comment with the deviations, each with a reason, and a
  complexity report: state, flags, or branches added; special cases; files
  or modules touched outside the ticket; and the root cause addressed
  (versus the symptom). STOP for explicit approval.
- **D. Implementation:** Implement only the approved plan and files. If an
  unforeseen decision arises, stop and ask. Verification budget: build the
  project, run the existing tests that cover the changed files, and prepare
  the decisive check. Write new automated tests only when the ticket asks
  for them. Open a pull request that closes the issue. Its description
  states:
  - changes, verification run and results, what was not verified, and any
    files the editor modified as a side effect;
  - the complexity report;
  - **playtest setup:** how to reproduce the decisive check in under a
    minute (test scene, debug key, or spawn command);
  - **tuning map:** each new or changed tuning value, its data asset, and
    default, unit, and range;
  - map changes, applied to `ARCHITECTURE.md` in the same pull request.
  In the same pull request, update `HANDOFF.md` to reflect current state
  only (replace outdated content; do not append history) and update any doc
  whose described behavior changed.
- **E. User validation:** Stop. The task is not complete until the owner
  merges the pull request. Review comments, and owner comments starting
  with "bug:", return to A, B, or C.
- **F. Handoff:** After merge, report final state and stop. Update
  `AGENTS.md` only for approved project-wide changes. Remove temporary task
  documents only with approval.

## Rules

- A recommendation is not an approved decision.
- An owner-approved ticket is an approved decision for everything it
  specifies, architecture included. Deviations from it are recommendations:
  report them with a reason; do not implement them.
- Behavior, visual design, architecture, scope, and substantive
  implementation choices need owner approval; routine coding details within
  an approved plan are the agent's judgment. If unsure which, ask.
- Missing requirements are not permission to invent behavior.
- Never expand scope silently or implement future tasks early.
- Prefer simple implementations; no unrequested features or abstractions.
- A system or abstraction specified in an approved ticket counts as
  requested.
- Owner values in the ticket are literal: never convert or rescale them.
- Tuning values live in data assets as `ARCHITECTURE.md` describes, never as
  constants in code.
- Respect the module map in `ARCHITECTURE.md`. Never add a dependency
  between modules unless the ticket states the map change.
- Never claim tests passed unless they were executed.
- Without approval: do not initialize Git, generate projects, install
  dependencies, or create configuration files or extra documents.
- Never modify files outside this project directory.
- Keep documentation concise and factual. Distinguish unknown facts from
  undecided choices.

## Strict reusability policy

All objects and systems sharing the same function and visual appearance must
use centralized reusable scenes, scripts, and resources.

- Before creating a shared scene, script, or resource, check whether an
  existing one can be extended through configuration, and report what you
  checked.
- Shared implementations must have a single authoritative source.
- Differences between instances must be expressed through configuration
  rather than duplicated implementations.
- Changes to shared definitions must propagate predictably throughout the
  game.
- Per-instance adjustments must not unintentionally modify shared resources.
- Avoid unique implementations unless justified by genuine functional
  differences.
- Favor reusable production assets over one-off implementations.
- Do not introduce unnecessary abstraction layers merely to achieve reuse.

Apply this policy to all future development; do not retroactively refactor
unrelated systems.
