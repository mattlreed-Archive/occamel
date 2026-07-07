# Port provenance: eventsource-parser

Per design doc Appendix C + §13.10 and `.claude/skills/port/SKILL.md`.

## Upstream

- **Repo:** https://github.com/rexxars/eventsource-parser
- **Pinned commit:** `83db3dec52a3494e22ee7e6eb4e1349380f75e36` (release v3.1.0, 2026-05-27)
- **License:** MIT (verified in `LICENSE` and `package.json` at the pinned
  commit; copyright Espen Hovlandsdal). MIT permits derivation with
  attribution — attribution is carried in this file, in
  `src/occamel_wire/eventsource.{ml,mli}` headers, and in commit messages.
- **Port date:** 2026-07-06
- **Ported into:** `src/occamel_wire/eventsource.{ml,mli}` (library
  `occamel_wire`), tests in `test/eventsource/`, differential harness in
  `test/differential/`.
- **Scope:** `src/parse.ts` (the parser state machine) and the
  `test/parse.test.ts` suite. `src/stream.ts` (a Web `TransformStream`
  wrapper) is deliberately **not** ported — Occamel's wire layer will
  integrate the parser with eio directly.

## API shape (deliberate divergences)

Upstream is callback-based and mutable (`createParser({onEvent, ...})`,
`feed(chunk): void`). The port is a persistent variant-based fold:

```ocaml
val create : ?max_buffer_size:int -> unit -> t
val feed   : t -> string -> t * output list   (* Event | Retry | Comment | Parse_error *)
val reset  : ?consume:bool -> t -> t * output list
val is_terminated : t -> bool
```

Divergences, all deliberate:

1. **Outputs instead of callbacks.** The four upstream callbacks become one
   ordered `output list` per `feed`. Relative ordering of
   events/retries/comments/errors is preserved exactly (verified by the
   differential harness, which compares the merged sequence).
2. **Errors are variants, not exceptions** (repo convention). Upstream's
   `ParseError` class becomes the `error` variant carried in
   `Parse_error`. Upstream's *message-string* truncation of long unknown
   field names (20 chars + ellipsis) has no analogue — the variant carries
   the full field/value/line.
3. **Feed-after-overflow is a no-op, not a throw.** Upstream `feed()`
   throws after a `maxBufferSize` overflow until `reset()`. The port
   returns `(t, [])` from `feed` on a terminated parser and exposes
   `is_terminated`. Same reachable behavior (nothing parses until reset),
   no exception surface. Normalized identically in the fuzz harness.
4. **`retry` values saturate at `max_int`.** Upstream `parseInt` degrades
   to imprecise floats above 2^53. All-digit values that exceed OCaml's
   `int` saturate to `max_int`. The harness normalizes both sides to `BIG`
   above 10^15; real-world retry intervals are milliseconds and never get
   near either bound.
5. **Bytes, not UTF-16 code units.** OCaml strings are byte strings; the
   parser is byte-oriented and encoding-agnostic (multibyte payloads pass
   through untouched, including chunk splits mid-UTF-8-rune — covered by
   tests and fuzzing). `max_buffer_size` is therefore in **bytes**, where
   upstream's `maxBufferSize` counts UTF-16 code units. One test-suite
   consequence: upstream's "invalid BOM" test feeds `U+FEFF` as a single
   UTF-16 code unit, which upstream does *not* strip, while the three-byte
   sequence `EF BB BF` it *does* strip. At the byte level both are the
   same three bytes, so that test has no distinct byte-level counterpart
   (its N/A is noted in the ported suite); a leading `EF BB BF` is
   stripped, which is what WHATWG specifies after UTF-8 decoding.

## Upstream quirks discovered (kept, for bug-compatibility; all verified by fuzzing)

- **`id` buffer resets between events.** WHATWG says the *last event ID
  buffer* persists across events; upstream clears it at each dispatch, so
  an event only carries an `id` if an `id:` field appeared in that event's
  own block. Mirrored.
- **An `id` containing NUL sets the buffer to none.** Spec says "ignore
  the field" (keep the previous value); upstream overwrites with
  `undefined`. Mirrored.
- **BOM split across the first two chunks is not stripped.** Upstream only
  inspects the first three code units of the literal first `feed()` call
  (an empty first chunk also consumes the opportunity). Mirrored — the
  wire layer feeds whole network reads, where this is harmless.
- **Deferred trailing CR vs. end-of-stream.** A chunk-final `\r` is held
  back (its `\n` may arrive next). If the *stream* then ends with a
  non-terminator tail and no further terminator ever arrives, the line
  before that CR is parsed under some chunkings and left buffered under
  others. Inherent to CR deferral; found by the port's qcheck
  chunk-split-invariance property (excluded there, reproduced faithfully
  in the differential harness where both sides see identical chunking).
- **With `max_buffer_size` set, overflow timing is chunking-dependent.**
  The bound is checked once per `feed` (as upstream does), so whether a
  stream overflows before a dispatching blank line depends on chunk
  boundaries. Acceptable for a resource bound; noted so nobody expects
  chunk-split invariance of the *error*, only of successful parses.
- **Comments are reported with `:` plus at most one space stripped**, and
  `retry`/unknown-field lines surface diagnostics the spec says to ignore
  silently. Upstream ergonomics, kept (they matter for detecting non-SSE
  error bodies, cf. `reset ~consume:true`).

## Resource bounds (§13.8 — required addition)

Upstream v3.1.0 already provides `maxBufferSize` (older versions did not);
the port keeps it as `create ?max_buffer_size` and it is the §13.8
max-event-size bound: it caps the sum of (a) the buffered unterminated
line and (b) the accumulated multi-line event data — the only two
unbounded surfaces. On overflow the parser emits
`Parse_error (Buffer_limit_exceeded {limit})` **once**, drops all buffers,
and becomes terminated (`is_terminated`, `feed` no-ops) until `reset`.
No exception is involved. Default remains unbounded to mirror upstream;
**wire-layer call sites must set it** (enforce at `occamel-oai`/
`occamel-anthropic` integration).

Allocation notes: pending bytes are kept as reversed fragment lists and
joined once per terminator arrival; data lines are joined once per
dispatch — a large event streamed in tiny slices stays linear (upstream
had the same O(N²)→O(N) fix; the huge-message test covers ~5 MB).
Measured 2026-07-06 (M4 Pro, scratch bench, not committed): ≈ 296 MB/s
over 4 KB-chunked single-line events, ≈ 234 MB/s on the pathological
20 MB single line fed in 1 KB slices — i.e. no quadratic blowup.

## Test oracle

All applicable `test/parse.test.ts` cases are ported to
`test/eventsource/test_eventsource.ml` (alcotest, offline, in
`dune runtest`): **35 alcotest cases** = 31 ported upstream cases + 4 port
additions (retry saturation, chunk-split-invariance property, and
zero/negative `max_buffer_size` fail-closed). Upstream has 35 tests; 2 are
N/A (see below) and 2 near-duplicate pairs are each merged into one port
test (`time` event name is a strict subset of the unbalanced-chunks
fixture; the two `reset()`-skip tests are one `test_reset_without_consume`).
All passing. Adaptations:

- Fixture async delays dropped (parser is synchronous; chunk sequence is
  what matters).
- The huge-message test builds a ~5 MB multi-line event and verifies
  length/head/tail by construction instead of vendoring sha256.
- The multibyte fixture uses a 3-line subset of upstream's corpus and
  splits chunks mid-UTF-8-rune (harsher than upstream's UTF-16 split);
  full multibyte coverage is delegated to the fuzz corpus.
- "invalid BOM" N/A (divergence 5 above); `createParser(fn)` type-error
  test N/A (type system).
- Port additions: retry saturation test; qcheck chunk-split-invariance
  property (2 000 generated stream/chunking pairs per run).

## Differential fuzzing (§13.10)

Harness: `test/differential/diff_fuzz.ml` (generator + comparator) +
`test/differential/runner.mjs` (drives the original TS via node ≥ 23 type
stripping, importing `src/parse.ts` from the pinned clone; refuses to run
if the clone's HEAD ≠ pinned commit). Bytes cross the JS boundary as hex
decoded latin1, so JS code units are exactly the wire bytes — invalid
UTF-8 is representable and the comparison is byte-faithful.

Corpus per case: a stream drawn from {structured SSE lines (valid +
near-valid, all field kinds, empty values, huge retry digits, NULs),
adversarial fragment concatenations (truncated fields, interleaved
partial keywords, mid-stream/partial BOMs, invalid UTF-8, 200–3200-byte
oversized lines, pathological `\r`/`\n`/`\r\n` mixes), biased byte soup};
random chunk splits over the same bytes (whole-stream, ≤ 8 cuts, or
byte-at-a-time); `max_buffer_size` ∈ {unset 70 %, 1–101 30 %};
`reset ~consume` flipped randomly.

Results (2026-07-06, node v25.8.1, upstream `83db3dec…`):

| Run | Seed | Cases | Divergences |
|---|---|---|---|
| smoke | 20260706 | 200 | 0 |
| full | 20260706 | 10 000 | 0 |
| full | 424242 | 10 000 | 0 |
| full + stats | 20260706 | 10 000 | 0 |
| full + stats | 424242 | 10 000 | 0 |

**Total: 30 200+ generated cases, zero divergences.** Corpus shape per
10 k-case run (from the harness's built-in stats, so passing runs are
non-vacuous): ≈ 2.4 k events, 3.5 k retries, 4.2 k comments, 14.8 k field
errors, 1.2 k buffer-limit overflows; ≈ 17 % of cases produce no output.

The only divergence found during development was by the *self*-invariance
qcheck property, not the differential harness: the deferred-trailing-CR
end-of-stream case above — an upstream-inherited behavior, kept.

Rerun:
```sh
git clone https://github.com/rexxars/eventsource-parser /tmp/esp \
  && git -C /tmp/esp checkout 83db3dec52a3494e22ee7e6eb4e1349380f75e36
EVENTSOURCE_UPSTREAM=/tmp/esp \
  opam exec -- dune exec --root . test/differential/diff_fuzz.exe -- -n 10000
```

## Security review (§13, checklist item 13)

`security-reviewer` agent run 2026-07-06 over the parser, tests, and
harness, with independent verification (fresh clone at the pin confirmed to
be tag v3.1.0; side-by-side read of `parse.ts`; 33/33 tests re-run;
differential harness re-run at an unrecorded seed `987654321`, 0
divergences; standalone adversarial probes for non-positive limits,
single-chunk giant events, deferred-CR + consume, 200k byte-at-a-time feeds
with resets).

**Outcome: no exploitable vulnerability.** Verdicts:

- **Port fidelity: CONFIRMED** end-to-end by source read (BOM byte check,
  space stripping, NUL-id reset, `/^\d+$/` retry gate, no-rescan deferral,
  CRLF-across-chunks, per-feed buffer check all byte-exact).
- **Exception-freedom (`.mli` claim): PASS, CONFIRMED** — every
  `String.sub`/`.[]`/`index_from_opt` site hand-checked as bounds-safe;
  `saturating_int_of_digits` overflow-proof; length bookkeeping cannot
  overflow below 2^62 input bytes; 200k randomized byte feeds raised
  nothing. Bonus: the port's cached CR/LF scan is O(n) where upstream's
  repeated `indexOf` is quadratic on `"\n"*n ^ "\r"` — strictly better
  against scan-complexity DoS.
- **Differential fuzzing: PASS** — reproduced independently at a fresh seed.
- **Termination after `Buffer_limit_exceeded`: PASS** — buffers dropped,
  no post-overflow accumulation path, `reset ~consume` cannot resurrect
  dropped bytes.
- **Shell-invocation audit (CLAUDE.md no-shell rule): PASS** — fuzz-generated
  (untrusted) bytes reach node only as hex-encoded JSON in a temp file; the
  `Sys.command` lines interpolate only operator/env/temp-path values, each
  `Filename.quote`d. No model- or fuzz-derived string reaches the shell.
- **§13.8 resource bound: PASS at module level**, conditional at system
  level (below). **FFI boundary: N/A** — pure OCaml, zero deps.

Findings, all hardening/documentation (no bug), and their disposition:

- **F1 (medium, latent): default-unbounded `max_buffer_size` relies on a
  comment, not the type system.** No streaming call site exists yet
  (`occamel-oai` is non-streaming), so nothing is currently vulnerable.
  Mitigated by strengthening the `.mli` to state that wire-layer callers
  MUST pass it (optional only for tests). Making it a mandatory type-level
  invariant is deferred to the first streaming call site, tracked here and
  in CLAUDE.md's ported-code rule.
- **F2 (low): the bound is per-feed and excludes `id`/`event_type`** — a
  single oversized chunk can be dispatched before the check, so retention
  can exceed the limit by up to one chunk. Faithful to upstream. Now
  documented explicitly in the `.mli`; end-to-end §13.8 requires the wire
  layer to also use bounded reads + a max-total-stream-size (a separate
  §13.8 control, correctly out of scope here).
- **F3 (low): non-positive limits were undocumented/untested.** Fail-closed
  already (fixed direction); now documented in the `.mli` and covered by
  `test_max_buffer_zero`/`test_max_buffer_negative`.
- **F4 (low): the differential runner's `catch {}` swallowed all upstream
  throws.** Tightened to rethrow anything that is not the known
  post-overflow "max buffer size" termination, so a genuine upstream crash
  can no longer be masked as a match. Re-ran 10k cases post-fix: 0
  divergences.
- **F5 (process): provenance doc was untracked.** Committed with the port.
- **F6 (info): "33 tests" overclaimed by two; a test used
  `Random.self_init`.** Count corrected above; the test now uses a fixed
  seed (`Random.init 20260706`).

Out-of-scope §13 items 1–12 (strict runner, provenance lattice, SSRF,
`Secret.t`, trace redaction, …) were explicitly not evaluated — the
corresponding code does not exist in the tree yet.
