# M3 — strict mode (planner/executor with provenance + admission)

Date: 2026-07-07 · design doc §6.2–§6.5, §13.2–§13.3

## What M3 delivers

The thesis centerpiece: the CaMeL planner/executor architecture with a
**compiler-checked** privilege boundary.

- **`Prov`** — provenance lattice. Source sets over
  `User | Static | Tool_result | Extracted | Branch`, joined along data flow
  and control flow; `is_trusted` iff every source is User/Static.
- **`Trusted`** — the compile-time boundary (§13.2, G6). `Trusted.t` has only
  `of_user` / `of_static` / `launder` constructors; no path from a tool result
  or `Untrusted.t` except the audited `launder`. The strict planner's input is
  `Trusted.t`, so "a tool result reaches the planner" is a *type error*.
- **`Strict`** — the provenance-tracking executor over the plan AST
  (Call/Extract/If), per-tool/field sink policies, and **plan admission**: a
  static worst-case provenance walk that rejects a bad plan before anything
  runs, with structured reasons.
- **Control-flow taint** is enforced at the **sink**: a trusted literal used
  inside a branch whose condition is untrusted is treated as
  attacker-influenced, in both admission and runtime. This is the case a naive
  data-flow-only tracker admits and this one rejects (tested).
- **`Strict_run`** — plan → admit → execute → trace, plus deterministic replay
  that re-runs admission on the recorded plan (§13.7) and answers
  tools/extractions from the trace.

## Success criterion — met

The M2 research scenario, re-expressed as a strict agent, runs end-to-end
against qwen3: **plan → admit → web_search → Q-LLM extract → return
"Mount Everest"**, with the answer's provenance `{tool_result, extracted}`
(untrusted), and its golden trace replays deterministically offline in
`dune runtest` — same trace format as loop mode, different architecture. The
two modes now sit on one substrate, which is exactly the controlled comparison
M6 needs.

## The compiler-checked claim, precisely

The narrow, true statement (not "taint is tracked everywhere"):
1. The privileged planner's context never contains untrusted bytes — enforced
   by `Trusted.t` having no constructor from tool output. **Compile-time.**
2. The plan itself therefore cannot be injected; tracked provenance is the only
   channel of attacker influence. **Runtime, but sound because of (1).**
3. A trusted-only sink cannot receive attacker-influenced data along any path
   admission accepts — enforced by the sink policy check being a sound
   over-approximation (admission taints both branches; runtime one).

## Deferred: Foreach (→ M3b)

The design doc §5.2 lists `Foreach`; M3 ships Call/Extract/If. Foreach needs a
list-valued runtime model the current string-valued environment lacks, and its
taint story (loop-variable provenance joins the iterated source; body executes
under that taint) is mechanically the `If` case applied per element. Deferring
keeps the security core clean rather than rushing the construct where taint is
most subtle. This is a scope split within the milestone, not a design change —
the doc already lists Foreach, so no version bump; M3b adds it plus a
list-value model and a per-element taint test.

## Security review

`docs/research/m3-security-review.md`. Headline: the reviewer independently
confirmed the core claim — no untrusted data reaches a trusted-only sink or the
planner along any path admission accepts; admission is a sound
over-approximation; the planner boundary holds. Two real fail-open bugs found
and fixed with tests (H1: multiple policies per tool silently dropped; M5:
unbound vars treated as trusted). A fail-closed `default_policy` option added
(partial M2). TCB boundary hardened (`Untrusted.read`, audited `launder`). The
capability axis (§13.3), typed tool-arg codecs (§3.3 for tools), whole-plan
approval rendering (§13.6), and trace signing (F4) are the M4 carry-forward.

## Known carry-forward (from M1+M2, still open)

- F4: trace integrity is unkeyed MD5, and replay honors recorded approvals
  rather than re-prompting. Strict replay re-runs *admission* (good), but the
  same signing + live-approval-seam work is required before any replay-into-
  live. M4.
- Extract is free-text in M3; M4 adds the channel-width schema + the
  unbounded-string lint (§13.2) and whole-plan approval rendering (§13.6).
