# M1+M2 security review — findings and disposition

Date: 2026-07-07 · Reviewer: `security-reviewer` agent (adversarial pass over
the §13 threat model) · Scope: repair loop, loop mode, codec/schema, ppx
output, eval drivers.

Five findings. Four fixed in this milestone; one (F4) is an integrity/redaction
concern the design doc explicitly defers to M4, documented here and tracked.

## F1 — HIGH — Repair prompts echoed attacker-controlled payload bytes (§13.8) — **FIXED**

The §8 repair message was built from `err.msg`, which carries payload
fragments through several channels: the offending token in a Yojson syntax
error, an unexpected field name, an unknown enum/`kind` value, an
out-of-bounds integer. In loop mode the context already holds
attacker-influenceable tool results; an injection could emit output that fails
validation with chosen bytes embedded, and the repair loop would re-present
those bytes to the model with validator framing — exactly what §13.8 forbids.
Load-bearing because `Repair` is the shared choke point strict mode's
quarantined extractor will also use.

Fix: `Codec.error` gained a payload-free `code` (category enum). The
model-facing `Codec.safe_message` renders only `code` + the structural `path`
(derived from the type/schema, never from payload). `Repair.repair_message`
uses `safe_message` exclusively; `err.msg` survives for local traces/logs
only. All echoing sites carry a code; the ppx emits `err_bad_enum` instead of
formatting the raw value. Test: a sentinel fed through every channel is absent
from `safe_message`.

## F2 — MEDIUM — Deep-JSON Stack_overflow DoS, no size/depth limits (§13.8) — **FIXED**

`Codec.of_string` caught only `Yojson.Json_error`, so a deeply nested body
from a hostile/compromised endpoint (in scope, §13.1) raised an uncaught
`Stack_overflow` that `Loop.run`'s handler re-raised → process crash.

Fix: `of_string` enforces `max_bytes` (4 MiB) and `max_depth` (200, via a
cheap string-scan that respects string literals/escapes) before parsing, and
catches `Stack_overflow` → structured error. `map_result` is now
tail-recursive. Same guard covers `Plan.of_string` (routed through
`Codec.of_string`). Test: 100k-deep input is rejected structurally, no crash.

## F3 — MEDIUM — Approval rendering not homoglyph/bidi/control-safe (§13.6) — **FIXED**

`render_field` used `Yojson.Safe.to_string`, which passes bidi overrides
(U+202E), zero-width, and non-ASCII homoglyphs through raw — so an approver
could see a benign-looking path/URL while a different value executes,
defeating the loop-mode approval control.

Fix: `escape_ascii` renders every byte outside printable ASCII (and `\`) as
`\xHH`. Bidi/zero-width/homoglyph bytes become visible escapes; the approver
reads exactly what executes. Escaping produces pure ASCII, so truncation can
no longer split a UTF-8 sequence; the length+md5 fingerprint hashes the raw
bytes. Test: a U+202E-bearing path renders as pure ASCII with the override
bytes shown as `\xe2\x80\xae`.

## F4 — MEDIUM (latent; HIGH if replay-into-live ships) — Trace integrity + replay-approval seam (§13.7) — **DOCUMENTED, deferred to M4**

Two parts:
1. **No signing.** Traces carry only unkeyed MD5 (`Digest`) hashes of
   ctx/schema/args; a tamperer recomputes them, so "fails loudly on mismatch"
   is defeatable. Today `Loop.replay` is *pure* replay — it never calls a live
   tool (results are decoded from the recorded event), so tampering can only
   corrupt a produced value / CI golden result (a supply-chain concern for the
   eval artifact), not drive a real side effect.
2. **No live-approval seam.** `replay` honors a recorded `Approval="approved"`
   directly and takes no `approve` callback. The design doc's §9 "time-travel
   debugging: replay to event k, then switch to the live handler" therefore
   has no safe way to re-run approvals — building it on today's API would
   violate §13.7's "replay-into-live … run under the same approval handlers."

Disposition: the design doc already scopes HMAC/signing and redaction to M4
(§13.7, §13.9; noted in `trace.ml`). Deferring F4 is consistent with that.
Guardrails added now: (a) `trace.ml` and `loop.ml` carry comments stating that
replay is pure-replay-only and MUST NOT be used to authorize live effects
until M4 lands signing + an approval-re-prompt seam; (b) this is recorded as a
hard prerequisite for any future replay-into-live work. **M4 requirements:**
keyed signature over the event log verified before use; `replay` variant that
re-invokes `approve` (and, in M3, admission) for any transition to live
execution; recorded approvals treated as bookkeeping, never authorization.

## F5 — LOW — Duplicate JSON keys accepted; first-wins vs all-keys divergence — **FIXED**

No exploitable divergence today (all consumption is first-wins), but latent:
`Schema.validate` checks all duplicate values, so if it becomes an admission
gate (M3) while `Codec` decodes first-wins, admitted ≠ executed; a last-wins
re-serializing proxy creates the same split.

Fix: `no_extra_fields` (run at the top of every record/variant decode) now
rejects duplicate keys. Test: a duplicate-key object is rejected.

## Checklist items N/A this milestone (code absent, not skipped)

Strict-mode boundary (`Trusted.text`/`launder`, planner runner, `If`/`Foreach`
`Branch` taint, admission static-vs-runtime walk, sink policies) — M3. `Ask`
exists only in loop mode; no strict runner to mis-handle it. SSRF and SSE
resource bounds — `occamel-oai` wire layer, not in scope files. `Secret.t` and
trace redaction — M4 (traces currently serialize raw args/results/content, per
the M4 deferral). Ported-parser differential fuzzing / FFI — none in scope
(the eventsource-parser port is a separate goal).
