# M3 strict-mode security review — findings and disposition

Date: 2026-07-07 · Reviewer: `security-reviewer` agent (adversarial pass over
the strict boundary — the thesis-critical code) · Scope: prov, trusted, strict,
strict_run, plan, codec, repair, trace, tool, oai client, m3_strict driver.

## Headline

The reviewer could **not** find a path by which attacker-controlled tool-result
*content* reaches the planner prompt or defeats an *active* trusted-only sink
policy. Verified clean end-to-end:
- **Planner boundary holds** — `plan_with : Trusted.t -> _` is called once on
  `Trusted.of_user`; tool output flows only to the extractor; no replan-with-
  results loop.
- **Admission is a sound over-approximation** — `admit` and `run` compute
  provenance from plan structure only, with identical formulas at identical
  points; runtime executes a subset of admission's walk. No plan exists where
  admission says Ok but a runtime path hits a denied sink.
- **Control-flow taint** is applied at the sink in both walks; branch-bound
  names can't escape (scoping). The `Trusted`/`Untrusted` abstract types
  prevent untrusted *value* flow into trusted position; `launder` is the only
  bridge.

The findings are fail-open gaps and unimplemented controls, not taint bypasses.

## HIGH — fixed

### H1 — Multiple policies per tool: all but the first silently dropped (fail-open) — **FIXED**
`policy_for` returned the first matching policy, so registering
`require_trusted` and `approve_if_untrusted` for the same tool dropped the
second → the guarded field fell through to Allow. Exactly the silent-fail
§13.3 warns against, at the policy layer.

Fix: replaced with `field_verdict`, which folds **all** matching policies and
takes the most restrictive verdict (Deny > Needs_approval > Allow), in both
admission and runtime. Test: a tool with two policies denies the
require_trusted field while the second policy is present.

## MEDIUM

### M2 — Default-allow + no capability axis: forgotten policy on a dangerous tool is fully open — **PARTIALLY FIXED**
The §13.3 capability axis (default-deny, declared footprints) is not
implemented in M3. Partial mitigation shipped: `registry` gains an optional
`default_policy`, so a fail-closed registry denies any tool without an explicit
policy. Test covers it. The full capability axis (a tool with a footprint but
no policy = registration error) is **deferred to M4** with the rest of §13.3.

### M5 — Admission treated unbound vars as trusted (empty provenance) — **FIXED**
`prov_of_expr` returned `Prov.empty` (trusted) for an unbound var; only
`Plan.of_json`'s scoping check saved it, and `Strict_run.run` didn't re-run
that check. Fix: `admit` now runs `Plan.validate_scoping` itself (a scoping
violation is a rejection) and treats any unbound var as untrusted. Test: a plan
referencing an unbound var is rejected.

### M1 — No §3.3 choke point for tool args; policy field names decoupled from tool consumption — **DOCUMENTED, deferred**
Strict `Call.args` is an untyped `(string * expr) list` passed straight to
`run_tool`; there is no per-tool typed arg codec or path/argv refinement
(§13.4), and policy field names are free strings unrelated to how the tool
consumes them. Bounded by the trusted planner (fragility, not attacker-driven).
Full fix needs the typed/GADT tool registry (post-M3, tied to M4/M5 tool work):
bind args through a derived per-tool codec + refinement and derive policy field
names from the tool's arg type so a mismatch is a compile error. Tracked.

### M3 — `Trusted` boundary weaker than the doc claims; `of_user(Untrusted.read x)` forges trust — **HARDENED (docs + API), residual documented**
`of_user`/`of_static` accept any string, so re-wrapping a tool result as
trusted type-checks. Out of scope per §13.1 (malicious author), but the "launder
is the only bridge, audited and logged" claim was overstated. Hardening
shipped: `Untrusted.to_string` renamed to `Untrusted.read` (makes the misuse
legible at the call site); `of_user`/`of_static` documented as TCB
trust-assertion points; `launder` now takes `~audit` and calls it with the
justification, so a real crossing is logged by construction rather than by
caller convention. The residual (an author *can* still forge via
`of_user (Untrusted.read x)`) is inherent — `of_user` must accept a string —
and is the accepted TCB boundary.

### M4 — Whole-plan approval view not implemented; approval is per-sink mid-run — **DEFERRED to M4 (by design)**
Admission passes `Needs_approval` sinks and runtime prompts per-sink. The
single whole-plan approval view (§6.4 step 3 / §13.6) — the preferred control
that avoids "N mid-run prompts" — is the M4 milestone's "whole-plan approval
rendering." Not a hole (the control exists at runtime), just not the final UX.
M4 will move it to admission-time and render the data-flow graph.

## LOW

- **L1** (returned value under-reports branch taint) — **FIXED** before the
  review landed (returned value joins branch taint; accuracy only).
- **L2** (trace integrity / replay trusts recorded content by order) — the
  documented **F4** gap; strict replay does re-run admission and sink policies
  (a tampered plan that no longer admits can't execute), but pops
  tool/extraction outputs by order and replays approvals. Bounded (pure
  replay). Signing + live-approval seam = **M4**.
- **L3** (`Secret.t` absent) — **M4** (§13.9).

## Not evaluable (code absent)

SSRF/redirect validation (item 8) — no model-supplied-URL tool yet; must be
built before one ships. SSE bounds (item 9) — no streaming yet; decode-path
depth/size limits exist. Ported-parser fuzzing (item 13) — the eventsource
port is on a branch, out of this tree. §13.3 capabilities / Foreach — deferred.

## Net

Two real bugs (H1, M5) fixed with tests; one fail-closed option added (M2);
the TCB boundary hardened and honestly documented (M3). No change to the
core claim, which the review independently confirmed: **no untrusted data
reaches a trusted-only sink or the planner along any path admission accepts.**
