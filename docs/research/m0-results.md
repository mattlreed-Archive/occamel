# M0 results: do local models emit sensible plans under format constraint?

Date: 2026-07-06 · Runner: `bin/m0_eval.ml` (committed) · Raw data: `docs/research/m0-raw/*.jsonl`

## Verdict: **GO.**

qwen3:14b produced 15/15 schema-valid plans passing all automated sensibility
checks, including correct variable chaining across dependent searches and
correct branch-local scoping in conditionals. gemma4:12b reached 12/15 valid /
10/15 fully passing, and every failure is legible and mitigable (details
below) — two of its five failures are exactly the class the design doc's §8
repair loop exists to fix. Constrained planning into a bespoke typed DSL
works on consumer hardware with local models. Proceed to M1.

## Setup

- Ollama 0.31.1, brew service, `http://127.0.0.1:11434/v1` (OpenAI-compatible
  surface, non-streaming), M4 Pro 24 GB.
- Plan DSL: M0 subset (`Call`/`Extract`/`If`/`Return` over `Var`/`Lit`),
  hand-written depth-unrolled inline schema (no `$ref`, no nested `if`),
  full client-side re-validation (`Plan.of_json`): shape, tool enum, bind
  freshness, use-before-bind, branch-scope containment.
- Models:
  - `qwen3:14b` — thinking off (`/no_think` suffix), temp 0.7, top_p 0.8
  - `gemma4:12b` — thinking on (default), temp 1.0, top_p 0.95
  - **Config deviation from CLAUDE.md**: `top_k` and `num_ctx` are not
    expressible on the `/v1` surface (quirk Q1 below). Prompts were ~360
    tokens, so `num_ctx` was irrelevant here.
- `max_tokens` 3000 per request; one attempt per task, **no retries and no
  prompt iteration** — the system prompt below is the first and only version
  tried (the no-torture rule).

## Probe outcomes (goal step 3)

Sentinel-enum canary (`{"magic": enum["xyzzy-4242"]}`) on an off-topic prompt;
free generation cannot satisfy it by chance.

| model | probe |
|---|---|
| qwen3:14b (`/no_think`) | ✅ enforced |
| gemma4:12b (thinking on) | ✅ enforced |

## Conformance and checks

Automated checks per task: `uses_needed_ops` (plan contains the op kinds the
task requires), `min_calls`, `on_topic` (task keyword appears in a query/lit).

| | qwen3:14b | gemma4:12b |
|---|---|---|
| schema-valid (client-side) | **15/15** | 12/15 |
| all automated checks pass | **15/15** | 10/15 |
| mean latency per plan | 29.1 s | 29.6 s |
| mean completion tokens | 170 | n/a (thinking inflates) |

### gemma4 failure detail (all five)

| task | failure | class |
|---|---|---|
| t01, t02 | plan is a single `call` with no `return` | incomplete plan — schema permits it (minItems only); prompt rule ignored |
| t08, t14 | `variable used before being bound` (e.g. referenced `k2_h` before the extract that binds it) | **scoping violation — grammar-invisible, caught by client-side validation; the §8 repair loop's home case** (the structured error names the exact variable and position) |
| t10 | empty content after 137 s; `completion_tokens` = 3000 (the cap) | thinking-token runaway: reasoning consumed the whole `max_tokens` budget before one constrained token was emitted |

## Plan quality (rubric judgment)

Rubric: 2 = correct ops, on-topic queries, coherent data flow, no degenerate
steps; 1 = right idea with a flaw; 0 = unusable.

- **qwen3:14b: 14×2, 1×1.** Standout: t15 chains an extracted variable into
  the *next search query* (`"query": {"kind":"var","name":"author_name"}`) —
  dependent data flow, exactly what the DSL exists to express. Conditionals
  (t12, t13) use the idiomatic extract-then-branch shape with branch-local
  returns.
- **gemma4:12b: 9×2, 4×1, 2×0.** Its good plans are genuinely good — t12
  does a branch-local extract-and-return inside `then`, scope-correct. Its
  failures are consistency failures, not capability failures.
- **Shared 1-score (t11), a DSL expressivity finding:** the task requires a
  comparison ("taller than 300 m?") and the DSL has no predicate primitive,
  so BOTH models extracted the raw height and branched on it as always-true
  evidence. The fix is a prompt rule ("an extract feeding an `if` must ask a
  yes/no question") or a predicate primitive — evidence for design doc §12
  open question 1, not a blocker.

## Findings for the design doc

Nothing contradicts the doc; several sections got their first empirical
confirmation. Candidate additions to the §B.1 endpoint quirk table:

- **Q1**: Ollama `/v1` cannot express `top_k`/`num_ctx` (native `/api/chat`
  `options` or a Modelfile required).
- **Q2**: eio resolves `localhost` to `::1` first and does not fall back
  across address families; Ollama binds IPv4 only → `127.0.0.1` in config,
  and the real client needs multi-address connect (wire-layer TODO).
- **Q3**: with thinking-capable models, reasoning tokens spend the
  `max_tokens` budget *before* constrained output begins; a too-low cap
  yields empty content with HTTP 200 (gemma4 t10). Budget for thinking or
  bound it.

Validated by this run: capability probing (§3.2.1) — both probes passed but
the design caught nothing *this time* precisely because we could verify that;
grammar ≠ semantics (§3.3, §7) — every gemma hard failure was schema-valid
JSON with invalid scoping, caught only by the typed validation layer; the
repair loop's expected value (§8) — the two scoping failures come with
structured errors a retry could act on (M1 should measure the repaired rate).

## Interpreter note (goal step 4)

The toy interpreter executed t04's straight-line plan end-to-end
(`Returned "hello world"`) and the unit suite covers call/return against the
stubbed `web_search`. All other eval plans use `Extract`/`If` (M3 features) —
expected, since the exemplar demonstrates `extract`; execution breadth was
not this milestone's question.

## System prompt used (verbatim, first version, no iteration)

```
You are a planner. Reply with ONLY a JSON plan matching the required schema.

Available tool:
  web_search(query: string) -> search results text

Plan semantics — a plan is a list of steps executed in order:
  call:    invoke a tool and bind its result to a fresh name.
  extract: pull one specific piece of information out of a previously bound
           value; bind it to a fresh name.
  if:      cond names a previously bound value treated as yes/no evidence;
           execute then or else. No nested if.
  return:  finish with a value (a bound variable or a literal string).

Rules: bind a name before referencing it; never reuse a bind name; variables
bound inside an if branch are NOT visible after the if; use as few steps as
the task needs; the last executed step must be a return.

Example — task: "What is the capital of Italy?"
{"steps":[
 {"op":"call","bind":"r1","tool":"web_search",
  "args":[{"name":"query","value":{"kind":"lit","value":"capital of Italy"}}]},
 {"op":"extract","bind":"cap","source":{"kind":"var","name":"r1"},
  "question":"What is the capital city?"},
 {"op":"return","value":{"kind":"var","name":"cap"}}]}

Example — task: "Return the word ping without searching."
{"steps":[{"op":"return","value":{"kind":"lit","value":"ping"}}]}
```

## What M0 leaves open

- The eventsource-parser port (streaming) — separate goal via `/port`.
- Repair-loop efficacy on the observed scoping failures — M1 measures it.
- Whether gemma4's consistency improves with a "always end with return"
  few-shot exemplar or lower temperature — one cheap experiment, M1.
