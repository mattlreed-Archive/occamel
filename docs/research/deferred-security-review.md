# Security review — the 5 deferred items — findings and disposition

Date: 2026-07-07 · Reviewer: `security-reviewer` agent (adversarial pass over
Items 1–5) · Scope: strict, strict_run, plan, prov, schema, trace, trusted,
codec, against §3.3, §6, §13.2/.3/.6/.7.

## Headline

Items 1–4 confirmed **sound**. All findings were in Item 5 (the replay-into-live
seam), plus one LOW footgun in the tool-spec defaults. One HIGH (a real
confused-deputy), two MEDIUM, one LOW — all fixed with tests.

## Verified sound (no change needed)

- **Items 1+2 (registry):** no-spec ⇒ default-deny at admission *and* runtime;
  capability check fires at both; the §3.3 choke point (arg-schema validate →
  refine → policy) runs before the tool sees args; `most_restrictive`/`combine`
  can't drop a guarding rule.
- **Item 3 (channel width):** fail-safe throughout — `extraction_width` of
  `None`/unknown-name is `Unbounded`; `channel_width` never under-reports a
  bounded width for an open channel; an extracted value is always untrusted
  regardless of schema name, so no name can launder it to trusted.
- **Item 4 (Foreach):** admission and runtime compute *identical* per-element
  taint; loop var and body binds don't escape; a `Return` inside a body carries
  the loop taint. Admission remains a sound over-approximation.
- **Prior guarantees intact:** Trusted planner boundary (no `launder` in the
  strict path; replan note carries only the tool name); no `Ask` handler in the
  strict runner; admission-vs-runtime lattice agreement; trace
  integrity/redaction and `load_verified`.

## HIGH — Confused deputy in `replay_then_live` — FIXED

Inside the replay window, if the recorded tool-result queue was exhausted,
`run_tool` fell through to a **live** call while the paired `approve` still
popped a **recorded** approval — a live, capability-bearing action gated only by
a stale replayed approval (the exact F4 seam the design forbids). Reachable by
resuming a signed trace of an interrupted run with a `cut` larger than the
recorded tool count.

Fix: (1) reject `cut > recorded_tool_count` at entry (`Cut_exceeds_recording`);
(2) inside the window, a missing recorded result FAILS CLOSED (never live); (3)
dropped the recorded-approval queue — the replay window's per-sink approvals
auto-accept (integrity + the whole-plan approval authorized the executed
prefix), and the live tail always re-prompts the live approver.

## MEDIUM-1 — No whole-plan approval for the live continuation — FIXED

`replay_then_live` re-ran admission but never re-requested the whole-plan
approval, so the live tail executed under only per-sink prompts — a downgrade
from "same approval handlers as a fresh run" (§13.7/§13.6). Fix: added a
required `~approve_plan` callback; the rendered whole-plan view is presented
before the live continuation, and `Live_plan_denied` stops the run before any
live sink.

## MEDIUM-2 — Whole-plan approval replayed as per-sink decisions — FIXED

Production `run` emits a single `<whole-plan>` approval event; the old
`replay_then_live` popped it inside the per-sink `approve` hook — a category
error and the vehicle for the HIGH bug. Fix: the recorded-approval queue is
gone; replay-window per-sink approvals auto-accept, the live tail re-prompts.

## LOW — Capability-bearing tool with no arg schema skips the §3.3 choke point — FIXED

The `tool` constructor defaults `arg_schema = `Null` and `policy = allow_all`, so
a capability-bearing tool registered without a closed schema skipped both the
admission field-name check and runtime value validation — a field-keyed policy
(`require_trusted ~fields:["to"]`) could be dodged via an undeclared field. Fix:
admission now rejects a capability-bearing tool that declares no arg schema, so
the choke point can't be skipped.

## Net

The security-critical taint/admission core (Items 1–4) needed no changes. The
new replay-into-live seam had a real confused-deputy that is now closed and
tested, and the tool-spec footgun is fail-closed. The F4 debt (integrity +
live-approval seam) is fully retired.
