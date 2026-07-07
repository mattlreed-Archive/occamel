# M4 — quarantine, approval, secrets, integrity

Date: 2026-07-07 · design doc §6.5, §13.2, §13.6, §13.7, §13.9

## What M4 delivers

- **`Secret.t`** (§13.9) — abstract, no yojson codec and no `to_string`, so
  serializing a secret is a *compile error*; plaintext reachable only via
  `use` (callback), a redacted fingerprint printer otherwise. Retires L3.
- **Trace redaction + HMAC signing** (§13.7) — write-time scrubbers over every
  string field; a keyed HMAC over the event lines, verified on
  `load_checked` (`Verified | Unsigned | Bad_signature`). Retires the F4
  integrity half (keyed, not the unkeyed MD5 F4 flagged). The live-approval
  seam for replay-into-live remains future work (strict replay already re-runs
  admission).
- **Whole-plan approval** (§6.4 step 3, §13.6) — `Strict.analyze` collects the
  data-flow graph (every guarded sink + provenance, every extraction);
  `render_report` renders it truncation- and homoglyph/bidi-safe;
  `Strict_run.run` shows ONE approval before execution. Retires the M4 "N
  mid-run prompts" finding.
- **Channel-width analysis** (§13.2) — `Schema.channel_width` quantifies the
  injection channel of an extraction schema (enum = log2 n, bool = 1, free
  string = Unbounded); `extraction_lint` flags unbounded untrusted extraction
  reaching a sink. Works on any derived schema.
- **Replan-on-Tool_error** (§6.5) — `Strict_run.run_with_replan` lets the
  planner revise after a harness-generated tool failure. Safety hinge: the
  planner sees only a static note naming the failed tool, never the error
  string; the replan prompt stays `Trusted.t`. Non-transient failures (denied
  sink, approval denial) are not replanned.

## Prior findings retired

- **F4 (integrity half)** — keyed HMAC now signs traces; tampering is detected
  on load. (Replay-into-live approval seam still M-future; strict replay
  re-admits.)
- **L3** — `Secret.t` exists and is unserializable by construction.
- **M4 whole-plan-approval finding** — the single whole-plan view is the
  primary control; per-sink runtime approval is defense-in-depth.

## Remaining (carried forward)

- Typed extraction: wiring `channel_width` into the plan DSL's `Extract` (a
  schema ref on Extract) so per-extraction width is enforced at admission —
  the M0 Extract is free-text. This is the last mile of §13.2 enforcement.
- Full §13.3 capability axis and typed per-tool arg codecs (M1 from the M3
  review) — M5, tied to the tool registry.
- Foreach (M3b).
- Replay-into-live approval re-prompt seam (the other half of F4).

## Security review

`docs/research/m4-security-review.md`. The review confirmed F4/L3/whole-plan
approval are genuinely retired and the replan Trusted-flow + admission/runtime
lattice remain sound. Fixed: a MEDIUM channel-width under-report (open objects
scored as bounded — the dangerous direction, now Unbounded), a MEDIUM
redaction gap (plan/verdict/prov now scrubbed), and two LOW items (provenance
escaping, signature-strip downgrade → Bad_signature under a key). One
deliberate scope choice documented (approval prompts only when a sink needs
it).
