# Plan: the 5 deferred technical items

Executed as a sequence of tested increments, dependency-ordered. Items 1+2
share a foundation (a real tool registry), so they land together; 3 builds on
it; 4 and 5 are more independent.

## Foundation → Items 1 + 2 — Tool registry with capabilities and typed args

The root cause of both gaps is that strict tools are stringly-typed: `Call.args`
is `(string * expr) list` and policies match free-string field names. Fix by
introducing a **tool spec** that ties together, per tool:
- `arg_schema : Schema.t` (+ optional refinements) — decode/validate `Call`
  args through the §3.3 choke point (Item 2);
- `caps : Cap.t list` — required capabilities (Item 1);
- the sink policy (already exists) keyed to the arg schema's field names.

Then:
- **Item 1 (§13.3 capability axis):** the runner *grants* a cap set; admission
  rejects any Call whose tool's caps ⊄ granted (default-deny). A tool with no
  spec is unknown → rejected (no silent Allow).
- **Item 2 (typed args):** admission/runtime validate each Call's args against
  the tool's `arg_schema` + refinement; a field the policy guards but the
  schema doesn't declare is a registration error.

## Item 3 — Channel-width into a typed `Extract`

Add a `schema` ref to the plan DSL's `Extract` (currently only `question`).
The extractor answers INTO that named schema; admission computes
`Schema.channel_width` and fires the unbounded-string lint when an untrusted
extraction of unbounded width reaches a capability sink. Enforces the M4
primitive at admission — the last mile of the §13.2 bound.

## Item 4 — Foreach (M3b)

Add `Foreach of { bind; over; body }` + a list-valued runtime model. `over`
resolves to a list; each element binds `bind` in the body; the body executes
under the source's provenance plus branch taint (mechanically the `If` case,
per element). Extend admission with per-element taint and scoping.

## Item 5 — Replay-into-live approval seam (other half of F4)

`Strict_run.replay_then_live`: replay recorded events up to a cut point, then
execute the remainder live. The live transition MUST `load_verified` (reject
unsigned/tampered) and re-run admission + the approval handler for any live
effect — recorded approvals are never honored to authorize a live action.

## Verification

Each item: incremental commits, adversarial tests (esp. taint/admission for
3–4, downgrade/tamper for 5). A consolidated security-reviewer pass over
items 1–5 before the tutorials.
