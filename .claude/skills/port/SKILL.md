---
name: port
description: Port a reference library into Occamel per design-doc Appendix C discipline — upstream tests as oracle plus differential fuzzing. Use when porting eventsource-parser, the llguidance schema→grammar layer, or any external code into this repo.
---

# Porting discipline (design doc Appendix C + §13.10)

Ported parser code passing every upstream test can still add an out-of-spec
vulnerability. This skill makes the mandated process un-skippable. Do the steps
in order; do not mark the port done with any step skipped.

## 1. Fetch and pin the upstream

- Clone the upstream repo at a specific tag/commit into the scratchpad (never
  into this repo). Record: repo URL, commit hash, license, in
  `docs/ports/<name>.md`.
- Confirm the license permits derivation; note attribution requirements.

## 2. Port with upstream tests as the oracle

- Port the upstream test suite FIRST, then the implementation. The tests are
  ground truth; the port is done when they pass, not when it "looks right".
- Idiomatic OCaml is the goal (variants for state machines, `result` for
  failures) — port semantics, not syntax. Note every place the port
  deliberately diverges (API shape, error types) in `docs/ports/<name>.md`.

## 3. Differential fuzzing (mandatory, §13.10)

- Build a harness that runs the SAME input through the upstream original and
  the OCaml port and compares outputs. For a TS/Python/Rust upstream, drive
  the original via its own runtime in the scratchpad.
- Generate inputs with qcheck: valid inputs, boundary cases, and malformed/
  adversarial inputs (truncated, interleaved, oversized, invalid UTF-8 —
  parser attacks live in the malformed space).
- Run at least 10k generated cases; record the corpus size and any divergences
  in `docs/ports/<name>.md`. A divergence is either a port bug (fix it) or an
  upstream bug (document it and decide deliberately which behavior to keep).
- Check in the differential harness under `test/differential/` so it can rerun
  in CI when either side updates.

## 4. Security pass

- Run the `security-reviewer` agent on the ported code (parsers are checklist
  item 13).
- Bound all resource use: input size limits, recursion depth, allocation per
  event. Upstream may not have these; we require them (§13.8).

## 5. Record provenance

- `docs/ports/<name>.md` must contain: upstream URL + commit, license, port
  date, deliberate divergences, fuzz corpus size + results, security-review
  outcome.
- Commit message includes the upstream commit hash.
