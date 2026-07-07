# M4 security review — findings and disposition

Date: 2026-07-07 · Reviewer: `security-reviewer` agent · Scope: secret, trace,
strict (analyze/render), strict_run (whole-plan approval + replan), schema
(channel_width) against §6.5, §13.2, §13.6, §13.7, §13.9.

## Retirements — all confirmed

- **F4 (trace integrity)** — genuinely retired. HMAC-MD5 construction verified
  textbook-correct (key hashing/padding, ipad/opad, inner raw digest); `save`
  signs the redacted on-disk bytes; `load_checked` recomputes over exact bytes;
  reordering/flips → `Bad_signature`. No length-extension (HMAC immune). MD5's
  collision weakness noted; "swap for a real MAC" intent documented.
- **L3 (Secret.t)** — genuinely retired. `.mli` exposes only abstract `t` +
  use/redacted/pp; no yojson/to_string/Marshal; `redacted` non-reversible. The
  `use s Fun.id` and in-process `Marshal` caveats are outside the §13.1 threat
  model.
- **Whole-plan-approval finding** — genuinely retired. Denial returns before
  the exec hooks are built; a denied plan runs zero tools.
- **Replan Trusted flow (§6.5)** and **admission/runtime lattice soundness**
  independently re-confirmed: only `Tool_error` triggers replan, only the tool
  *name* crosses (error string destructured away), all `Trusted`-typed;
  runtime sinks are a subset of statically-checked ones.

## Fixed

### M1 — MEDIUM — `channel_width` under-reported open objects (hid a channel) — **FIXED**
The object case summed only declared `properties` and ignored
`additionalProperties`, so `{"type":"object"}` scored 0 bits and a
narrow-fields-but-open object scored only its declared width — while the
extractor may emit arbitrary extra keys/values (an open channel). Under-report
is the dangerous direction (hides an injection channel). Fix: any object
without `additionalProperties:false` → `Unbounded`. ppx-derived records are
unaffected (they always emit `false`); the bug bit hand-written / provider /
probe schemas. Tests: open object and narrow-but-open object → Unbounded;
closed bool-only object → 1 bit.

### M2 — MEDIUM — redaction skipped three string-bearing fields (PII) — **FIXED**
`redact_event` left `Plan_generated.plan` (embeds the goal + Lit values —
trusted ≠ non-sensitive), `Plan_admitted.verdict`, and `Extraction.prov`
unscrubbed, contradicting the "every string field" contract. Fix: scrub all
three. (`Secret.t`'s unserializability already blocked keys; this closes
free-string PII in the goal.)

### L1 — LOW — approval-view provenance line not escaped — **FIXED**
`render_report` escaped tool/field/site but printed `Prov.to_string` raw. Now
`escape_ascii`'d like its siblings — uniform §13.6 control-char safety.

### L3 — LOW — signature-strip downgrade at the default loader — **HARDENED**
`load_verified` (added pre-review) already rejected unsigned/tampered; the
review noted the ergonomic risk that a caller reflexively uses `load`. Further
hardened: with a key configured, a missing `#sig` is now `Bad_signature`, not
`Unsigned` — the strip case collapses into the rejected branch at
`load_checked` itself. `Unsigned` now means only "no key configured."

## Deliberate / deferred

### L2 — approval view shows only guarded sinks, prompts only when approval is needed
By design for M4: policies mark specific sinks `Needs_approval`; Allow-sinks
are policy-approved and a plan of entirely-Allow sinks needs no prompt. The
§13.6 "full data-flow graph, always" rendering (showing Allow sinks too, for
auditability) is a UX enhancement, not a security gap — recorded as a possible
improvement, not a bug.

## Net

Four fixes (one MEDIUM soundness bug in channel_width, one MEDIUM PII gap, two
LOW), all with tests where applicable. The review confirmed the milestone's
headline claims: the F4/L3/whole-plan debts are retired, and the injection
boundary and replan flow remain sound.
