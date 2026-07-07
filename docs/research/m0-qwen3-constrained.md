# M0 research: Qwen3 under constrained decoding and tool calling

Date: 2026-07-06

Scope: published experience (docs, GitHub issues, benchmarks, blog posts) with Qwen3-class
models under JSON-schema-constrained decoding and tool calling, as input to the M0 go/no-go
spike ("does qwen3:14b on Ollama emit sensible recursive plan ASTs under `format`
enforcement, with how much few-shot help?").

## 1. Thinking mode vs. constrained decoding

**Model lineup context.** The original Qwen3 line (April 2025: 0.6B–32B dense including
14B, plus 30B-A3B and 235B-A22B MoE) is *hybrid*: one checkpoint serves both a thinking
mode (`<think>...</think>` blocks) and a non-thinking mode, controlled by the
`enable_thinking` flag in the chat template (which, when false, pre-fills an empty
`<think></think>`) and per-turn soft switches `/think` and `/no_think` in the prompt
(https://huggingface.co/Qwen/Qwen3-8B, https://qwenlm.github.io/blog/qwen3/). In the July
2025 "2507" refresh, Qwen abandoned hybrid thinking and shipped separate
`-Instruct-2507` and `-Thinking-2507` variants — but only for 4B, 30B-A3B, and 235B-A22B
(e.g. Qwen3-30B-A3B-Instruct-2507); the 8B, 14B, and 32B dense models never got a 2507
refresh and remain hybrid-only
(https://docs.unsloth.ai/models/qwen3-how-to-run-and-fine-tune/qwen3-2507,
https://www.marktechpost.com/2025/08/08/alibaba-qwen-unveils-qwen3-4b-instruct-2507-and-qwen3-4b-thinking-2507-refreshing-the-importance-of-small-language-models/).
The stated reason for the split was that hybrid mode cost quality — relevant because it
means the 14B's non-thinking mode is the "weaker half" of a compromise checkpoint.

**Does the grammar clamp from token one?** It depends on the stack, and this is the
single most version-sensitive area found:

- **Ollama:** thinking output is parsed out separately from content, and the `format`
  grammar masking is intended to engage only on the content channel — an Ollama issue
  notes the runner "expects the end of thinking token before engaging probability
  masking" (https://github.com/ollama/ollama/issues/14645). But the combination is buggy
  in both directions: `think=true` + `format` produced malformed JSON with duplicated
  escaped braces (`{"{"summary"...`) on qwen3, issue open as of this check
  (https://github.com/ollama/ollama/issues/10929); and for newer model generations,
  `think=false` + `format` caused the format constraint to be *silently ignored* because
  the think-close token never arrives to trigger masking
  (https://github.com/ollama/ollama/issues/14645, similar for gemma:
  https://github.com/ollama/ollama/issues/15260). A third report: thinking + tools +
  qwen3 yields empty output (https://github.com/ollama/ollama/issues/10976). A detailed
  write-up concludes Ollama JSON mode and thinking are effectively mutually exclusive:
  when the GBNF grammar is active from the first token it makes `<think>` tags
  ungenerable (https://zenn.dev/7shi/articles/fa36989a04c9ed?locale=en).
- **llama.cpp:** grammar enforcement is *completely inactive* when thinking is enabled —
  `response_format` + `enable_thinking:true` silently produces unconstrained output
  (https://github.com/ggml-org/llama.cpp/issues/20345). There is a long-standing feature
  request for "free to think, strict to answer"
  (https://github.com/ggml-org/llama.cpp/issues/12276).
- **vLLM:** the inverse bug — guided decoding with `enable_thinking=False` produced
  gibberish/malformed JSON (extra brackets, backticks) on Qwen3-32B-INT8 and
  Qwen3-30B-A3B-INT4 with both xgrammar and guidance backends, when the reasoning parser
  was enabled; workarounds were enable thinking, put `/no_think` in the prompt text, or
  disable the reasoning parser (https://github.com/vllm-project/vllm/issues/18819).
- **Hosted Qwen (Alibaba Cloud Model Studio):** structured output is officially
  unsupported in thinking mode; combining them errors. Their recommended pattern for
  "thinking-quality JSON" is two-step: think freely first, then a second constrained call
  to (re)format (https://www.alibabacloud.com/help/en/model-studio/qwen-structured-output).

**Qwen's recommended sampling settings** (model cards / docs,
https://huggingface.co/Qwen/Qwen3-8B, https://qwen.readthedocs.io/en/latest/getting_started/quickstart.html):

- Thinking mode: temperature 0.6, top_p 0.95, top_k 20, min_p 0.
- Non-thinking mode: temperature 0.7, top_p 0.8, top_k 20, min_p 0.
- presence_penalty up to 1.5 recommended for *quantized* models to suppress repetition
  (with a warning that high values can cause language mixing / slight quality loss).
- "DO NOT use greedy decoding" — it causes degradation and endless repetition. This
  directly conflicts with Ollama's structured-output doc advice of temperature 0
  (https://docs.ollama.com/capabilities/structured-outputs); see Implications.
- The 2507 Instruct/Thinking cards adjust these slightly (e.g. Thinking-2507 general:
  temp 1.0/top_p 0.95 per some guides); for the hybrid 14B the numbers above apply.

## 2. JSON schema conformance quality

- Practical reports of qwen3 under Ollama `format` are mostly positive on *syntactic*
  conformance at small sizes: a hands-on write-up testing qwen3:4b and qwen3:8b found
  both reliably produced parseable schema-conformant JSON for extraction tasks, with
  residual *semantic* deviations (missed required property, extra fields) recommended to
  be caught by a Pydantic/validation layer
  (https://www.glukhov.org/llm-performance/ollama/llm-structured-output-with-ollama-in-python-and-go/).
  No published size-threshold study (8b vs 14b vs 32b) for structured-output quality was
  found; the vLLM bug reports involved 30B/32B quantized models, i.e. failures there were
  stack bugs, not size effects.
- Reported failure modes to watch for: endless repetition/whitespace-style loops under
  greedy decoding (Qwen's own warning); truncated invalid JSON when a max-tokens cap is
  set (Alibaba explicitly says do not set max_tokens with structured output,
  https://www.alibabacloud.com/help/en/model-studio/qwen-structured-output); empty or
  garbage output when the prompt is silently truncated by Ollama's small default context
  (see section 4); and grammar-silently-not-applied bugs (section 1) which masquerade as
  "model ignoring the schema".
- **The degradation debate.** "Let Me Speak Freely?" (arXiv 2408.02442,
  https://arxiv.org/abs/2408.02442) reported significant reasoning degradation under
  format restrictions, worse with stricter constraints. The dottxt rebuttal "Say What You
  Mean" (https://blog.dottxt.ai/say-what-you-mean.html) showed the effect was largely an
  artifact: the paper used different prompts for structured vs unstructured runs, and its
  JSON schema placed the `answer` key *before* the `reason` key, forcing answer-before-
  reasoning; with matched prompts and sensible key ordering, structured generation
  matched or beat unstructured. Follow-up benchmarking ("Generating Structured Outputs
  from Language Models", arXiv 2501.10868, https://arxiv.org/html/2501.10868v1) supports
  the rebuttal for well-designed schemas but shows large engine-dependent compliance
  gaps on hard schemas (see section 5). Practical takeaway: key order inside the schema
  is load-bearing — put any rationale/plan-description field before the decision fields.

## 3. Tool calling

- Qwen3 uses **Hermes-style** tool calls and Qwen's docs recommend the Hermes parser
  (vLLM `--tool-call-parser hermes`, vLLM >= 0.8.5). They explicitly warn against
  stopword-based templates like ReAct for reasoning models, because the model may emit
  the stopwords inside its thought section; and they concede the model "is not
  guaranteed... to always follow the protocol", recommending validation/rectification in
  production (https://qwen.readthedocs.io/en/latest/framework/function_call.html).
- **BFCL placement:** the Qwen3 launch materials report Qwen3-235B-A22B at 70.8 on BFCL
  v3 (https://arxiv.org/abs/2505.09388). Qwen3-14B/-14B-FC and Qwen3-30B-A3B were added
  to the leaderboard in May 2025
  (https://github.com/ShishirPatil/gorilla/blob/main/berkeley-function-call-leaderboard/CHANGELOG.md);
  per-size numbers seen in secondary sources include Qwen3-4B (prompt mode) ~62 and
  Qwen3-Coder-30B-A3B-Instruct 76.6 on BFCL-v2. Exact current 14B/30B-A3B standings
  should be read off https://gorilla.cs.berkeley.edu/leaderboard.html; the picture is
  "competitive open-weight tool caller for its size, meaningfully below frontier".
- **Ollama template/parser bugs (the bigger practical risk):**
  - qwen3:32b tool-call JSON returned as plain content, never parsed into `tool_calls`
    (https://github.com/ollama/ollama/issues/11662).
  - Tool definitions rendered into the prompt as Go structs instead of JSON when using
    the `tools` parameter, plus soft-switch thinking interference
    (https://github.com/ollama/ollama/issues/14601).
  - On the newer generation (qwen3.5, Ollama's new Go engine): renderer/parser mapped to
    the wrong tool-call format, penalty sampling (repeat/presence/frequency) *silently
    discarded* by the Go runner sampler, and unclosed `<think>` corruption when an
    assistant turn has thinking + tool_calls but no text — breaking the tool round-trip
    (https://github.com/ollama/ollama/issues/14493). qwen3 dense models mostly run on the
    llama.cpp runner where penalties work, but this shows Ollama runner behavior differs
    per model family.
  - Qwen3-Coder via Ollama flips from JSON to XML-formatted tool calls in content when
    given more than ~5 tools (https://github.com/block/goose/issues/6883).
- Hallucinated tool names/args: no systematic qwen3-specific study found; the general
  reports (and Qwen's own docs) treat occasional protocol violations and invalid
  arguments as expected without constraints. This favors Occamel's design of emitting
  typed actions under schema constraint rather than relying on Ollama's tool-call
  template/parser path at all: an enum of tool names in the schema makes name
  hallucination impossible, and sidesteps the parser bugs above.

## 4. Recommended settings for constrained JSON on Ollama

- **Context length is the top pitfall.** Ollama defaults to num_ctx 4096 (2048 in older
  versions) and *silently truncates from the beginning* when exceeded — no error, no
  warning; agent prompts lose their system/few-shot prefix first, which manifests as
  inexplicably bad or empty structured output
  (https://docs.ollama.com/context-length,
  https://jangwook.net/en/blog/en/ollama-num-ctx-silent-truncation-experiment/,
  https://news.ycombinator.com/item?id=42833427). Set `options.num_ctx` per request (or
  `OLLAMA_CONTEXT_LENGTH`); note a Modelfile `PARAMETER num_ctx` overrides the env var.
  For a planner prompt with schema + few-shot plans + task context, 16384 is a sane
  floor; qwen3:14b natively supports 32k (131k with YaRN).
- **Sampling:** follow Qwen, not Ollama's temp-0 suggestion: temperature 0.7, top_p 0.8,
  top_k 20, min_p 0 (non-thinking mode). If using a quantized pull (Ollama default q4)
  and repetition appears, add presence_penalty 1.5 per Qwen's guidance — but verify the
  penalty actually takes effect on your Ollama version/runner (see silently-discarded
  penalties above). Avoid greedy decoding.
- **Output budget:** don't set a tight `num_predict`; truncation mid-JSON is unparseable.
- **Prompting:** Ollama's own docs recommend including the JSON schema in the prompt text
  in addition to passing `format` — grounding plus enforcement
  (https://docs.ollama.com/capabilities/structured-outputs).
- **Thinking:** pass an explicit `think: false` (or `/no_think`) and then *verify
  enforcement*, since the failure mode on several versions is format silently not
  applied. A cheap canary: require an improbable literal key in the schema and check it
  appears; if the model can omit it, the grammar isn't active.

## 5. Recursive / nested schemas

- Ollama converts the `format` schema to a llama.cpp GBNF grammar. GBNF is a CFG, so
  recursion via `$defs`/`$ref` is expressible in principle — but Ollama's
  json-schema-to-grammar has a known **$ref binding/ordering bug**: the same schema
  produces correct or broken grammars depending on the alphabetical order of `$defs`
  entries, unresolved as of this check; workaround is reordering definitions
  (https://github.com/ollama/ollama/issues/8444).
- llama.cpp's converter also silently skips unsupported JSON Schema features and has open
  bugs on complex constructs (anyOf with multiple types, PCRE shorthands, sampler init
  failures on some schemas) (https://github.com/ggml-org/llama.cpp/issues/22314,
  https://github.com/ggml-org/llama.cpp/issues/21571,
  https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md — which advises
  running the Python converter to see warnings and validating with llama-gbnf-validator).
- Engine benchmarking (JSONSchemaBench line of work, https://arxiv.org/html/2501.10868v1,
  summarized at
  https://beancount.io/bean-labs/research-logs/2026/07/08/jsonschemabench-structured-outputs-language-models)
  found compliance collapses on hard schemas with multi-level nesting and recursive $ref:
  roughly Guidance 41%, llama.cpp 39%, XGrammar 28%, Outlines 3%. FSM-based engines
  cannot represent unbounded recursion at all; CFG-based ones (GBNF, XGrammar,
  llguidance) can, with varying fidelity.
- **No published evidence** was found on the *semantic* quality of small models filling
  recursive schemas at depth (do they produce sensible nested step lists, or degenerate?).
  This is genuinely unmeasured territory — it is exactly what the M0 spike exists to
  answer. Keep the plan schema's JSON-Schema feature surface minimal: `$defs` + `$ref`,
  `type`/`properties`/`required`/`enum`/arrays; avoid `anyOf` unions where a
  discriminator-tag field + per-variant object works, avoid `pattern`, `if/then`,
  `unevaluatedProperties` entirely.

## Implications for M0

- **Model:** start with `qwen3:14b` as planned (it fits the target class), but pull
  `qwen3:30b-a3b` (and ideally the Qwen3-30B-A3B-**Instruct-2507** GGUF) as the first
  fallback/comparison: the 2507 Instruct variant is non-hybrid, was tuned specifically
  for instruction following and tool use, and its 3B active params make it fast. If 14B
  underperforms in non-thinking mode, that is expected (hybrid-checkpoint tax) and the
  right next move is 30B-A3B-Instruct-2507, not more prompt engineering.
- **Thinking:** OFF for the constrained plan emission (`think: false`, and put
  `/no_think` in the prompt as belt-and-braces given the vLLM finding that the textual
  soft switch fixed guided decoding). The grammar makes `<think>` ungenerable anyway on
  the paths where it works; on the paths where it doesn't, you get silent
  non-enforcement or mangled JSON. If plan quality without thinking is insufficient, use
  the **two-call pattern**: call 1 unconstrained with thinking to draft the plan in
  prose/loose JSON; call 2 non-thinking, schema-constrained, to emit the AST. Do not
  attempt think-then-constrained in a single Ollama call.
- **Recover thinking inside the schema:** a lighter alternative — give the plan object a
  leading `rationale` (string) field before `steps`. The dottxt result says field order
  matters; this buys chain-of-thought inside the grammar.
- **Sampling:** temperature 0.7, top_p 0.8, top_k 20, min_p 0; `num_ctx` >= 16384 set
  explicitly on every request; no `num_predict` cap; presence_penalty 1.5 held in
  reserve for repetition on quantized weights. Not temperature 0.
- **Few-shot:** expect to need 1–3 full exemplar plans (covering Call/Extract/If/Foreach/
  Return and at least one nested step list) plus the schema text in the prompt. Published
  experience suggests syntactic validity comes free from the grammar even at 4b–8b; the
  few-shot budget is for *semantic* sensibility (right tools, sensible nesting), which
  nobody has published data on for recursive ASTs.
- **Spike checklist / what to watch for:**
  1. Verify the grammar is actually enforced on the installed Ollama version (canary key
     test) — silent non-enforcement is a documented bug class.
  2. Test the recursive schema's grammar generation up front; if outputs are
     structurally wrong, suspect the `$defs` ordering bug (#8444) and try reordering
     defs, or inline the step type to a bounded depth (e.g. 3 levels) as a fallback.
  3. Watch for repetition loops and empty outputs; check num_ctx first, sampling second.
  4. For loop mode, prefer schema-constrained typed actions over Ollama's `tools`
     parameter — the qwen3 tool template/parser path has multiple open bugs.
  5. Log raw responses; several failure modes (double-braces, unparsed tool JSON in
     content) are only diagnosable from the raw string.

## Uncertainty notes

- **Evidence strength is low-to-medium overall.** Most stack-behavior findings come from
  individual GitHub issues pinned to specific versions (Ollama 0.9.x–0.14.x era,
  specific quantizations); several are open with no confirmed fix, others closed without
  clear resolution (vLLM #18819). Behavior on the Ollama version installed for M0 must
  be re-verified empirically — the same flag combination has been observed to work,
  produce garbage, or silently no-op across versions.
- **Reports conflict on thinking + format:** Ollama nominally applies the grammar after
  the think block (per maintainer comments in #14645) but #10929 shows it corrupting
  output, and the zenn analysis argues they are inherently exclusive; llama.cpp skips the
  grammar entirely with thinking on; vLLM broke in the opposite (non-thinking) case.
  There is no single authoritative statement of "format applies during vs after think"
  that holds across stacks and versions.
- **BFCL per-size numbers for Qwen3-14B/30B-A3B were not directly verified** in this
  pass (the live leaderboard is JS-rendered); only the 235B (70.8, v3) and
  Coder-30B (76.6, v2) figures and secondary ~62 (4B prompt-mode) figures were sourced.
  Treat the mid-60s expectation for 14B as an inference, not a citation.
- **Some cited Ollama issues concern the newer "qwen3.5" generation** on Ollama's new Go
  engine (#14493, #14645, #14745); the qwen3 dense line may run a different (llama.cpp)
  code path with different bugs. They are included because they illustrate the *classes*
  of failure (silent penalty drop, silent format drop, template mismatch) to test for.
- **Recursive-schema semantic quality at 8–32B is unmeasured** in anything found; the
  engine-compliance numbers (llama.cpp 39% on hard schemas) measure grammar-engine
  coverage, not model sensibility, and their schema corpus is far gnarlier than
  Occamel's planned AST.
- The structured-output degradation literature (2408.02442 vs the dottxt rebuttal) was
  fought out on GPT-3.5/4-class and Llama-class models in 2024–25; direct replication on
  Qwen3 was not found.
