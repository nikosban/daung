# Architecture

The current shape of the game's code. Changed only through tickets that
state a map change; the agent updates this file in the same pull request.

## Units

1 unit = [1 metre]. Owner numbers are in units unless stated otherwise.

## Modules

| Module | Owns | May use |
|---|---|---|
| Core | Shared data types, events, data asset definitions | — |
| [Module] | [What it is responsible for] | Core |

## Rules

- Dependencies point one way, exactly as "May use" lists. A new entry is a
  map change and needs an approved ticket.
- A module calls only the modules it may use; it notifies others through
  events.
- Tuning values live in data assets ([engine mechanism]), never as
  constants in code.
- Every shared definition has one authoritative source (see the reusability
  policy in `AGENTS.md`).

## Enforcement

[Engine mechanism that rejects undeclared dependencies, or "review only".]

## Data assets

| Asset | Module | Values |
|---|---|---|
| [Asset] | [Module] | [Values it holds] |
