# Ollama Structured Outputs: Current Behavior (M0 Research)

Date: 2026-07-06

Scope: verify, against live sources, how Ollama enforces structured outputs today — the native `/api/chat` `format` parameter, the OpenAI-compatible `/v1/chat/completions` `response_format`, known bugs (recursion, thinking models, streaming), and silent-failure modes relevant to capability probing. Ollama's latest stable release at time of writing is v0.31.1 (2026-06-30); v0.31.2-rc1 was tagged today ([releases](https://github.com/ollama/ollama/releases)). Source-code claims below were read from `ollama/ollama` `main` on 2026-07-06.

## 1. Native `/api/chat` `format` parameter

**Semantics.** `format` accepts either the string `"json"` (unschema'd JSON mode) or a full JSON Schema object ([docs.ollama.com/capabilities/structured-outputs](https://docs.ollama.com/capabilities/structured-outputs), [docs/api.md](https://github.com/ollama/ollama/blob/main/docs/api.md): "`format`: the format to return a response in. Format can be `json` or a JSON schema"). In the Go API it is `Format json.RawMessage` on both `GenerateRequest` and `ChatRequest` ([api/types.go](https://github.com/ollama/ollama/blob/main/api/types.go)). Any other value is rejected with an error: `invalid format: %q; expected "json" or a valid JSON Schema object` ([llm/llama_server.go](https://github.com/ollama/ollama/blob/main/llm/llama_server.go)). Schema-based structured outputs shipped in v0.5 (Dec 2024, [blog post](https://ollama.com/blog/structured-outputs), [PR #7900](https://github.com/ollama/ollama/pull/7900)).

**Enforcement is token-level grammar sampling — but the plumbing changed in 2026.** As of v0.30 (May 2026) Ollama replaced its own inference engines (the CGO llama.cpp runner and the Go-native "ollamarunner" new engine) with upstream llama.cpp's `llama-server` for all GGUF models ([v0.30.0 release notes](https://github.com/ollama/ollama/releases/tag/v0.30.0): "improved compatibility and performance using llama.cpp"; [PR #16031](https://github.com/ollama/ollama/pull/16031) "runner: Remove CGO engines, use llama-server exclusively for GGML models", merged 2026-05-29). The repo now pins a llama.cpp build via a `LLAMA_CPP_VERSION` file (currently `b9888`) and builds `llama-server` from it with compat patches ([llama/README.md](https://github.com/ollama/ollama/blob/main/llama/README.md)).

Per the header comment in [llm/llama_server.go](https://github.com/ollama/ollama/blob/main/llm/llama_server.go):

> "For structured output, JSON schemas are passed directly to llama-server via its json_schema field (avoiding the CGO SchemaToGrammar dependency). Raw BNF grammars are passed via the grammar field."

So today: schema object -> llama-server `json_schema` field -> llama.cpp's `json-schema-to-grammar` -> GBNF -> token-mask sampling. `format: "json"` sends a built-in generic JSON GBNF grammar (`grammarJSON` in the same file). On this path Ollama is genuinely token-level enforced (T1 in Occamel's tier model). There is also a native-chat path that forwards to llama-server's own chat endpoint wrapping the schema as `response_format: {type: "json_schema", json_schema: {name: "schema", schema: ...}}` (`llamaServerChatResponseFormat` in the same file).

**Critical exception: the MLX engine does not enforce format at all.** On Apple Silicon, Ollama runs supported models on its MLX engine (`x/mlxrunner`). The MLX client's `Completion` builds its request from only `Prompt`, `Options`, `Logprobs`, `TopLogprobs` — the `Format` field of `llm.CompletionRequest` is silently dropped, and `x/mlxrunner`'s `CompletionRequest` struct has no format/grammar/schema field at all ([x/mlxrunner/client.go](https://github.com/ollama/ollama/blob/main/x/mlxrunner/client.go); no file under `x/mlxrunner/` references grammars or JSON schemas). No error is returned. On the MLX path, `format` is a no-op (effectively T3 with zero signal that enforcement was skipped).

**Thinking models: the "double request" mechanism.** Since [PR #12460](https://github.com/ollama/ollama/pull/12460) ("routes: structured outputs for thinking models /chat endpoint", merged 2025-10-09), `/api/chat` handles format + thinking models by issuing the first completion *unconstrained*, watching the parser for the thinking-to-content transition, then cancelling and re-issuing a second request whose prompt includes the emitted thinking as an assistant-message prefix, this time with the grammar applied ([server/routes.go](https://github.com/ollama/ollama/blob/main/server/routes.go), `structuredOutputsState` machine; for gpt-oss it force-prefills the Harmony final channel: `prompt += "<|end|><|start|>assistant<|channel|>final<|message|>"`). This means thinking is not suppressed by the grammar, and the constrained portion is still token-level enforced. `/api/generate` does NOT have this: [PR #14288](https://github.com/ollama/ollama/pull/14288) ("server: structured outputs for thinking models in /api/generate", opened 2026-02-17) is still open as of today.

## 2. OpenAI-compatible `/v1/chat/completions`

**`response_format: {"type": "json_schema", "json_schema": {"schema": {...}}}` is supported, and has been since the v0.5.x era (Dec 2024).** The compat layer maps `json_object` -> `format:"json"` and `json_schema` -> `format:<schema>` ([openai/openai.go](https://github.com/ollama/ollama/blob/main/openai/openai.go)):

```go
case "json_object":
    format = json.RawMessage(`"json"`)
case "json_schema":
    if r.ResponseFormat.JsonSchema != nil {
        format = r.ResponseFormat.JsonSchema.Schema
    }
```

The same code exists verbatim at tags v0.5.4, v0.6.2, v0.9.0 and main (checked via raw.githubusercontent.com), so the historical claim that Ollama's OpenAI endpoint only supported `json_object` is outdated. [Issue #10001](https://github.com/ollama/ollama/issues/10001) ("Improve compatibility with OpenAI structured outputs json_schema response format") was closed as completed on 2025-03-27; the support already existed when it was filed. Note the still-stale wording on [docs.ollama.com/api/openai-compatibility](https://docs.ollama.com/api/openai-compatibility), which lists only "JSON mode" as a feature — the code is ahead of that page. The [structured-outputs docs](https://docs.ollama.com/capabilities/structured-outputs) do say "Structured outputs work through the OpenAI-compatible API via `response_format`".

Caveats in the compat mapping:
- Only the nested `json_schema.schema` field is read. `name`, `strict`, and `description` are silently ignored — there is no `strict: true` semantics beyond what the grammar enforces.
- If `json_schema` is sent without a nested `schema` key (a shape some clients emit), `format` stays empty and the request runs **unconstrained with no error**.
- Any `response_format.type` other than `json_object`/`json_schema` is silently ignored (the `switch` has no default error case).

Requests through `/v1/chat/completions` are converted to native chat requests and go through the same `handleChat` path as `/api/chat`, so the double-request thinking mechanism and llama-server grammar enforcement apply equally. Whether the "new engine" changed enforcement: yes, twice — the Go-native ollamarunner (2025) had its own sampler-level constraint implementation, and both it and the CGO runner were then deleted in favor of llama-server (v0.30, [PR #16031](https://github.com/ollama/ollama/pull/16031)), so enforcement quality is now whatever the pinned llama.cpp build provides, except on MLX where it is absent.

## 3. Known limits and bugs

### Recursive schemas ($ref/$defs) — the big one for Occamel
- [Issue #7993](https://github.com/ollama/ollama/issues/7993) "Structured generation cannot handle self referencing (recursion)" — **still open** (opened Dec 2024; maintainer ParthSareen in Jan 2025: deliberately not implemented pending accuracy benchmarking; users still asking for updates as of 2026-01-13 with no answer).
- [Issue #8444](https://github.com/ollama/ollama/issues/8444) "Ollama not respecting structured outputs with some ordering of refs" — **still open**. Root cause identified by a user as a binding bug in `json-schema-to-grammar.cpp` (refs resolved before being visited, `input#` prefix mismatch), meaning whether a `$defs` schema works can depend on the **alphabetical order of definition names**. Unanswered pings through Nov 2025.
- Since Ollama now delegates conversion to llama.cpp, llama.cpp's documented limits apply directly ([llama.cpp grammars README](https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md)): "Nested `$ref`s are broken", remote `$ref`s unsupported in the C++ converter, "Unsupported features are skipped silently", "Can't mix `properties` w/ `anyOf` / `oneOf` in the same type", `additionalProperties` defaults to `false` ("produces faster grammars + reduces hallucinations"), `minimum`/`maximum` only for `integer`, `pattern` must be `^...$`-anchored. Enums are supported; unions via top-level `anyOf`/`oneOf` are supported with the properties-mixing caveat.

### Thinking models + format
- [Issue #14645](https://github.com/ollama/ollama/issues/14645) "format is ignored when think is disabled for qwen3.5 series" — **open**, 18 comments. With `think:false` (or a `/no_think` system prompt), the schema constraint is **silently not applied** for qwen3.5/qwen3.6-class models; user reports confirm it persisting on v0.19, v0.20.x, v0.21.x and **v0.30.7 (June 2026)**, with one report that plain qwen3-era models became affected starting v0.30.0. The equivalent gemma4 bug ([issue #15260](https://github.com/ollama/ollama/issues/15260)) was fixed in v0.21.1 by a gemma4-specific hack (`forceImmediate := m.Config.Parser == "gemma4" && ...` in routes.go, explicitly marked `TODO ... temporary fix`).
- gpt-oss: [issue #11691](https://github.com/ollama/ollama/issues/11691) (87 comments, **reopened**) — structured outputs produced whitespace-only/garbage output with the OpenAI SDK. Fixed for `/api/chat` in Oct 2025 (via the double-request PR); maintainer confirmed `/generate` still pending; reports of residual breakage (Harmony format handling) as late as Dec 2025.
- Historically (pre-Oct-2025), applying a grammar to a thinking model constrained the whole output and suppressed/broke `<think>` blocks; the double-request mechanism is the fix, and it exists only on the chat endpoints.

### Streaming
- `format` + `stream:true` is allowed and grammar enforcement is token-level, so streaming does not weaken enforcement on the llama-server path. But: [issue #14440](https://github.com/ollama/ollama/issues/14440) "Structured outputs not enforced for gpt-oss:20b when streaming + thinking" (OpenAI endpoint) was real and was closed as completed 2026-02-27; and the older [issue #4446](https://github.com/ollama/ollama/issues/4446) "JSON Mode + Streaming + OpenAI API ... never sends STOP, and a lot of whitespace after the JSON" documents the classic failure shape.
- Note the double-request mechanism cancels mid-stream and restarts; clients see thinking deltas, then constrained content deltas. Budget for a latency bubble at the transition (prompt re-processing, mitigated by prefix cache).

### Whitespace / empty responses
- The generic `format:"json"` grammar historically permitted unbounded trailing whitespace, producing endless `\n` streams from small models ([issue #2577](https://github.com/ollama/ollama/issues/2577), [issue #2623](https://github.com/ollama/ollama/issues/2623), [issue #4446](https://github.com/ollama/ollama/issues/4446)); [PR #10131](https://github.com/ollama/ollama/pull/10131) improved grammar spacing. Whitespace-only responses were also the symptom in the gpt-oss issue above. Schema-based format is less exposed than bare `"json"` mode but the failure class (model "done" but grammar permits more whitespace) is worth a client-side stop/timeout.
- [Issue #8063](https://github.com/ollama/ollama/issues/8063) "Ollama Not Respecting Structured Outputs" was closed as completed 2026-06-13 — plausibly mooted by the llama-server migration, though no fix commit is linked.

### Performance
- Grammar-constrained sampling adds per-token masking cost and a schema-to-grammar compile on request start; llama.cpp's README notes `additionalProperties: false` (the default) "produces faster grammars". The docs recommend `temperature: 0` for determinism ([structured outputs docs](https://docs.ollama.com/capabilities/structured-outputs)). The double-request path for thinking models roughly doubles prompt processing for the constrained turn. No current primary source quantifies overhead; treat as small-but-nonzero and measure in M0.

### Ollama Cloud
- "Ollama's Cloud currently does not support structured outputs" ([docs](https://docs.ollama.com/capabilities/structured-outputs)). Local-only feature for now.

## 4. Silent-ignore cases (capability probing)

Cases where Ollama accepts the request but does not enforce, with no error:

1. **MLX engine (Apple Silicon)**: `Format` dropped in `x/mlxrunner` client; no enforcement, no warning. Same server version behaves differently per model/backend.
2. **qwen3.5/3.6 + `think:false`** (and historically gemma4): format silently ignored ([#14645](https://github.com/ollama/ollama/issues/14645)), reported as probabilistic — the model often emits valid JSON anyway, so a single lucky canary can misclassify.
3. **OpenAI layer**: unknown `response_format.type` values ignored; `json_schema` missing the nested `.schema` key ignored; `strict`/`name` ignored.
4. **llama.cpp converter**: unsupported schema keywords "skipped silently" — the endpoint can be T1 for the grammar it built while enforcing strictly less than your schema (e.g. `format`/`pattern` nuances, number bounds, broken nested `$refs`).
5. **Cloud models**: structured outputs unsupported.
6. Counterpoint: an outright invalid `format` value (neither `"json"` nor an object) does produce an error on the native path, so "accepts the parameter" is at least testable.

Probe design consequence: a single "did it return JSON" canary is insufficient. A tier-classifying probe should (a) use a schema whose satisfaction is vanishingly unlikely without enforcement (e.g. a `const`/single-member `enum` sentinel field plus `additionalProperties:false`), (b) run per model, not per endpoint, (c) run with the same `think` setting the real workload will use, and (d) ideally include one intentionally-unsatisfiable-by-prose trap prompt (the reporter in #14645 used exactly this to expose probabilistic non-enforcement).

## Implications for M0

- **Tier classification of Ollama**: not a single tier. `/api/chat` (or `/v1/chat/completions`) with a schema against a GGUF model on the llama-server backend is **T1** (schema -> GBNF -> token masking). The same request against an MLX-backed model, a cloud model, or a qwen3.5-class model with `think:false` is **effectively T3** and silently so. Occamel should classify per (endpoint, model) pair, and the design-doc plan for canary-based capability probing is not optional for Ollama — it is the only way to detect the MLX and think:false holes.
- **The recursive plan AST is the highest-risk item.** Self-referential/nested `$ref`s are the documented broken case in the exact converter Ollama now uses ([#7993](https://github.com/ollama/ollama/issues/7993) open, [#8444](https://github.com/ollama/ollama/issues/8444) open, llama.cpp README: "Nested `$ref`s are broken"). For a plan type where `If`/`Foreach` contain nested step lists, do not ship a naively recursive schema. Options, in order of preference: (1) emit a depth-unrolled schema (inline the step type to a fixed max nesting depth, no `$ref`), which sidesteps every known ref bug at the cost of schema size; (2) probe: send the real recursive schema as a canary and check both for HTTP errors and for constraint actually binding; (3) fall back to T3 parse+repair for plans while keeping T1 for flat outputs. Also avoid mixing `properties` with `anyOf` at the same level when encoding the step sum type — encode variants as a top-level `anyOf` of distinct object schemas (or a tagged union with `enum` discriminators), and set `additionalProperties: false` explicitly rather than relying on the default.
- **`/api/chat` vs `/v1/chat/completions`**: both converge on the same enforcement path, so choose on ergonomics. `/v1/chat/completions` does accept `response_format: {"type":"json_schema","json_schema":{"schema": ...}}` today, so M0's "minimal OpenAI-compatible client" plan is viable against Ollama — but remember `strict` is a no-op and the schema must sit under `json_schema.schema`. The native `/api/chat` is slightly safer for M0: simpler `format` field, an actual error on malformed format values, and first-class `think` control. A pragmatic M0 shape: OpenAI-wire client with a small Ollama adapter that also knows the native endpoint for probing.
- **qwen3-class specifics**: do not combine `format` with `think:false` on qwen3.5+ models (open bug #14645, silent). Either leave thinking on (the double-request mechanism handles grammar-after-thinking on `/api/chat` since Oct 2025) or verify per-model with a probe. Use `/api/chat`, never `/api/generate`, for structured outputs with thinking models (PR #14288 unmerged). Expect a mid-response restart latency blip when thinking + format are combined.
- **Repair layer stays necessary**: even at T1, llama.cpp silently under-enforces unsupported keywords, so Occamel's post-parse validation against the full schema (T3 machinery) should run on T1 outputs too, treating grammar enforcement as an optimization rather than a guarantee.

## Uncertainty notes

- **Source freshness**: code claims (openai.go mapping, llama_server.go json_schema pass-through, mlxrunner Format drop, routes.go double-request) were read from `main` on 2026-07-06, which may differ slightly from the v0.31.1 release binary. The MLX Format-drop was verified in source only, not by running a release build; I could not confirm exactly which models route to MLX vs llama-server on Apple Silicon in v0.31.x.
- **Docs lag**: [docs.ollama.com/api/openai-compatibility](https://docs.ollama.com/api/openai-compatibility) still advertises only "JSON mode" for the OpenAI endpoint; the code supports `json_schema`. Conversely the structured-outputs docs page claims OpenAI-API support works — trust the code reading over either page.
- **Recursion status is inferred, not tested**: #7993/#8444 remain open and llama.cpp's README (fetched today) still says nested `$refs` are broken, but I did not run a live recursive-schema request against v0.31.1. It is possible the pinned llama.cpp build `b9888` behaves better than the README's blanket statement; this is exactly what an M0 probe should test empirically.
- **#8063's June 2026 closure** ("completed") has no linked fix; whether the llama-server migration actually resolved that class of report is unverified.
- **Version boundary of the engine switch is fuzzy**: v0.30.0 (2026-05-13) release notes announce llama.cpp-based execution, but the commit deleting the CGO engines merged 2026-05-29; some 0.30.x point releases may have mixed paths.
- Several summaries above (docs pages, blog post, some issue threads) came via a fetch-and-summarize tool; direct quotes from Go source and GitHub API metadata (issue states, dates) are exact, paraphrased doc content is secondhand.
