# M1 repair-loop efficacy (gemma4:12b)

Date: 2026-07-07 · Ollama 0.31.1, gemma4:12b (temp 1.0 / top_p 0.95, thinking
on) · Raw: `docs/research/m0-raw/m1-repair-*.jsonl` · Runner: `bin/m1_repair.ml`

Goal item 4: does the §8 repair loop recover gemma4's M0 failures, and does the
cheap "always end with return" exemplar help? gemma4 is the model with observed
M0 failures (qwen3 was 15/15); it is the honest stress case.

## Headline

Repair lifts gemma4 from ~12/15 first-try to **14/15** final-valid by fixing
transient malformed-but-present plans on retry. The **one irreducible failure
is the empty-response mode** ("Blank input data" — gemma returns no content,
the M0 token-budget runaway, quirk Q3): repair cannot fix it, because retrying
a blank yields another blank (and the longer repair context makes a blank
*more* likely, not less). This is the key result: **repair recovers
plan-quality failures, not empty-response failures.** The two need different
remedies — repair for the former, a larger token budget / thinking-off for the
latter (M5 will measure that operational knob).

## Three arms (15 tasks each, one run per arm)

| Arm | Prompt | Repair | Final valid | Repaired | Exhausted |
|-----|--------|--------|-------------|----------|-----------|
| A-shipped | M0 prompt | yes, n=2, **payload-free msg** | **14/15** | 2 (t11, t13) | 1 (t09) |
| A-prefix | M0 prompt | yes, n=2, payload-echoing msg | 12/15 | 1 (t11) | 3 (t09, t12, t13) |
| B | M0 prompt + return exemplar | no | 12/15 | — | 3 (t08, t10, t12) |

All exhausted tasks in every arm failed with **"Blank input data"** (empty
model output), except two first-attempt scoping errors in A-prefix that then
went blank on retry.

### Repair on the failures that HAVE a plan to fix

Counting only first-try failures that produced actual (malformed) output:
- A-shipped: t11 (`if` on unbounded evidence → repaired), t13 (repaired). 2/2
  malformed-but-present plans recovered. t09 was empty-response: 0/1.
- The repair mechanism works. Where gemma emitted a wrong-but-real plan, one
  structured re-prompt fixed it both times this run.

### Payload-free repair message (F1 fix) does not hurt efficacy

A-shipped uses the hardened repair message (category + schema path + schema,
never the invalid bytes — §13.8). It recovered **2** failures vs A-prefix's
**1** with the old payload-echoing message. The difference is within gemma's
run-to-run variance (see caveat), but the hardened message is clearly not
worse — the model repairs fine from a category ("a value failed a semantic
constraint at steps[2].cond") plus the schema, without being shown its own bad
output. This retires the concern that F1's fix would trade security for repair
quality.

### The return-exemplar (Arm B) also works, differently

Arm B (no repair, one added exemplar) is also 12/15 and its failures are ALL
empty-response — meaning the exemplar eliminated M0's *scoping* and
*missing-return* failures (t01/t02/t14 from M0 are clean here) at first-try,
leaving only the irreducible blanks. So both interventions independently fix
the plan-quality tail; neither touches the empty-response tail. A production
config would use both (exemplar to reduce first-try failures, repair to catch
the rest) plus a token-budget fix for the blanks.

## Important caveat: stochasticity

gemma4:12b at temp 1.0 with thinking on has a substantial empty-response rate,
and *which* tasks blank varies run to run (t12/t13 exhausted in A-prefix but
passed in A-shipped; t08/t10 blanked in B but not A). Single-run per-task
results are therefore noisy. What is stable across runs: (a) ~12–14/15
final-valid, (b) empty-response is the dominant residual failure, (c) repair
fixes malformed-but-present plans. M5's larger AgentDojo slice should report
multi-seed rates, not single-run counts.

## Design-doc confirmations

- §8 repair loop behaves as specified: bounded (n=2), exhaustion surfaces as
  the typed `` `Unparseable `` variant carrying one error per attempt.
- §13.8 hardening (F1) is compatible with efficacy — the payload-free message
  repairs as well or better.
- New operational finding for the §B.1 quirk table / §7.1 heuristics:
  thinking-on models spend token budget on reasoning before constrained
  output; under a tight `max_tokens` this yields empty content that no repair
  or prompt can recover. Budget for thinking or disable it for planning.

Nothing here contradicts the design doc; no version bump.
