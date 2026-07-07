# Occamel — Design Document

**A type-safe agentic harness in OCaml, built on constrained generation**

*Status: Draft v0.4 · July 2026 — added §13 Security Model after review; removed the Shell tool (§5.1)*

> **Occamel** = OCaml + camel + a nod to Ollama — and Occam's razor, which is the actual design philosophy: constrained generation is entity-reduction applied to model output. Do not multiply possible outputs beyond necessity; make everything else unrepresentable.

---

## 1. Motivation

Every agentic harness today has the same soft underbelly: the boundary between the model and the program is stringly typed. The model emits JSON, the harness parses it, and a validation layer — usually ad hoc, usually incomplete — stands between "the model said something" and "the program does something." Failures at this boundary are the dominant failure mode of agent systems: malformed tool calls, hallucinated tool names, missing arguments, states the loop author never considered.

Two technologies, combined, can close this gap almost entirely:

1. **Constrained generation.** Grammar- or schema-constrained decoding guarantees the *syntactic shape* of model output at sampling time. The model literally cannot emit an invalid token sequence.
2. **OCaml's type system.** Algebraic data types, GADTs, phantom types, and abstract types with smart constructors make illegal states *unrepresentable* at compile time.

Occamel's core bet: **derive the generation constraint from the OCaml types, so that everything the model emits arrives already parsed into a value the compiler has verified you handle exhaustively.** The agent loop becomes a `match` expression. Forgetting to handle a tool result variant is a compile error, not a 2 a.m. incident.

### Why OCaml specifically (vs. Rust, Haskell, TypeScript)

- **Variants + exhaustiveness checking** map one-to-one onto "the model must choose one of N actions."
- **OCaml 5 effect handlers** are an unusually natural fit for the agent loop (§6): a tool call is an *effect* the agent performs and the harness handles, giving suspension, resumption, and replay essentially for free — without monad transformer towers (Haskell) or async runtime ceremony (Rust).
- **ppx metaprogramming** lets us derive JSON schemas and grammars from type definitions with zero runtime cost and no macro hygiene nightmares.
- **Pragmatism.** OCaml compiles fast, produces small native binaries, and reads like ML pseudocode. The ecosystem gap (§10) is real but bounded.

---

## 2. Goals and Non-Goals

### Goals

- **G1 — Typed boundary.** Every model output that drives program behavior is a value of a user-defined OCaml type before any harness logic touches it.
- **G2 — Constraint derivation.** JSON schemas (hosted APIs) and GBNF grammars (local inference) are derived automatically from type definitions via ppx. One source of truth.
- **G3 — Typed agent loop.** The loop is an effect-handled state machine whose states and transitions are types. Invalid transitions don't compile.
- **G4 — Replayable traces.** Every run serializes to a typed trace that can be replayed deterministically against the handler stack (mocked tools, recorded model outputs).
- **G5 — Backend plurality.** Same agent definition runs against Anthropic/OpenAI hosted structured outputs *or* local llama.cpp/vLLM with full grammar constraints, with the guarantee level explicit in types.

### Non-Goals

- **NG1 —** Not a prompt-engineering framework. Occamel constrains *outputs*; prompt construction is user territory (with helpers).
- **NG2 —** Not a multi-agent orchestration platform (v1). Single-agent loops first; composition later (§12).
- **NG3 —** Not an inference engine. We integrate with llama.cpp et al.; we don't sample tokens ourselves.
- **NG4 —** Not RAG, memory, or vector-store infrastructure.

---

## 3. Core Concepts

### 3.1 Types as the source of truth

The user defines tools and agent outputs as ordinary OCaml types:

```ocaml
type search_args = {
  query : string; [@doc "Search query, 1-6 words"]
  max_results : int; [@default 5] [@min 1] [@max 10]
} [@@deriving occamel]

type file_op =
  | Read of { path : string }
  | Write of { path : string; content : string }
  | Delete of { path : string } [@dangerous]
[@@deriving occamel]

type action =
  | Search of search_args
  | File of file_op
  | Respond of { message : string }
  | Done of { summary : string }
[@@deriving occamel]
```

`[@@deriving occamel]` generates, per type:

- `val action_schema : Occamel.Schema.t` — a JSON-schema-compatible representation
- `val action_grammar : Occamel.Grammar.t` — a GBNF grammar (for local backends)
- `val action_of_json : Yojson.Safe.t -> (action, Occamel.Parse_error.t) result`
- `val json_of_action : action -> Yojson.Safe.t`
- Doc-string and constraint metadata that flows into the schema (descriptions, defaults, numeric bounds, enum values)

### 3.2 The three-tier guarantee model

Not all backends give the same guarantee. Occamel makes the tier explicit rather than papering over it:

| Tier | Backend | Guarantee | Residual risk |
|------|---------|-----------|---------------|
| **T1 — Grammar** | llama.cpp (GBNF/llguidance), vLLM & SGLang (xgrammar/llguidance) | Token-level: output *is* in the grammar | Semantic invariants only (§3.3) |
| **T2 — Schema** | Anthropic structured outputs; OpenAI strict mode; Ollama `format` | Provider-enforced JSON schema conformance | Schema-inexpressible invariants; provider bugs |
| **T3 — Parse** | Any chat API, no structured mode | None at generation; parse + repair loop (§8) | Parse failures, retries |

The tier is a phantom type parameter on the backend, so an agent can *require* at least T2 at compile time:

```ocaml
type 'tier backend
val anthropic : config -> [ `T2 ] backend
val llama_cpp : config -> [ `T1 ] backend
val raw_chat  : config -> [ `T3 ] backend

(* OpenAI-compatible endpoints span all three tiers depending on the server;
   the constructor is honest about that, and capability probing narrows it: *)
val oai_compat : config -> [ `T1 | `T2 | `T3 ] backend_dynamic
val probe : backend_dynamic -> [ `T1 ] backend option * [ `T2 ] backend option * [ `T3 ] backend

(* An agent that refuses to run without provider-side enforcement: *)
val run : [< `T1 | `T2 ] backend -> 'a agent -> 'a run_result
```

### 3.2.1 The OpenAI-compatible surface is the primary backend

The `/v1/chat/completions` wire format is the de facto lingua franca: OpenAI itself, Ollama, vLLM, SGLang, llama.cpp's server, LM Studio, Groq, Together, OpenRouter, and most gateways all speak it. One well-built `occamel-oai` backend therefore covers the local-inference story *and* most hosted providers, which changes the priority order: **build `occamel-oai` first**, `occamel-anthropic` second (as the native-protocol backend that unlocks Claude-specific features like `output_config` and prompt caching).

The catch is that "OpenAI-compatible" is a wire format, not a guarantee level. The same request shape hits very different enforcement machinery: `response_format: json_schema` on OpenAI proper is provider-enforced (T2); on vLLM/SGLang it's backed by a real grammar engine (effectively T1); on some proxies it's silently ignored (T3 wearing a T2 costume). Occamel handles this with **capability probing**: on first use, send a canary request with a deliberately narrow schema and verify conformance, caching the result per endpoint. The phantom tier is then assigned from *observed* behavior, not from the server's marketing. A config override exists for endpoints the user already trusts.

### 3.3 Smart-constructor choke point

Schemas and grammars can't express everything (`"path must be inside the workspace"`, `"query is non-empty after trimming"`). Occamel's rule: **exactly one validation choke point**, in the derived parser, via optional refinement functions:

```ocaml
type path = Path.t  (* abstract *)
[@@deriving occamel ~parse:Path.of_string_workspace_relative]
```

The refinement runs during `of_json`. Downstream code never sees an unvalidated `path`. Refinement failures feed the repair loop (§8) with a structured error the model can act on — not a stack trace.

---

## 4. Architecture

```
┌─────────────────────────────────────────────────────────┐
│  User agent code                                        │
│  (types + [@@deriving occamel] + effectful agent fn)     │
├─────────────────────────────────────────────────────────┤
│  occamel.ppx        │  occamel.core                       │
│  schema + grammar  │  agent loop, effects, tool         │
│  + codec derivation│  registry, trace, repair loop      │
├────────────────────┴────────────────────────────────────┤
│  occamel.backends                                        │
│  oai_compat (OpenAI/Ollama/vLLM/llama.cpp/LM Studio…)   │
│  anthropic (native) │ llama_cpp (in-proc) │ mock/replay │
├─────────────────────────────────────────────────────────┤
│  occamel.wire  — HTTP/SSE client (cohttp-eio), JSON      │
└─────────────────────────────────────────────────────────┘
```

**Packages** (opam): `occamel` (core + effects), `occamel-ppx`, `occamel-oai` (the OpenAI-compatible backend — first-class, covers OpenAI plus Ollama/vLLM/SGLang/llama.cpp-server/LM Studio/most gateways), `occamel-anthropic` (native protocol), `occamel-llama` (in-process llama.cpp for true T1), `occamel-mock`. Core has no HTTP dependency — backends are pluggable, mock backend included for testing.

**Prior art to build on, not around:** an `anthropic` package already exists on opam (Thibaut Mattio) — eio-based, type-safe bindings with streaming + backpressure, tool use, batch processing, and built-in retries. It predates structured-outputs GA, so `occamel-anthropic` should begin as an evaluate-and-extend of this package (adding `output_config.format` and `strict` tool support) rather than a from-scratch client. Separately, Anil Madhavapeddy's recent "language-integrated LLMs" work (LLM exposed as an ordinary OCaml library; the Bastion agentic system using Eio capabilities for effect-policy reasoning) is directly adjacent prior art — worth engaging with the OCaml community early.

**Runtime:** OCaml 5.x, eio for structured concurrency. Effects require 5.x anyway, and eio's capability-passing style suits a harness that wants explicit, auditable access to network/filesystem.

---

## 5. Type Design

### 5.1 Tools as a GADT

Tools pair an argument type with a result type. A GADT keeps the pairing honest:

```ocaml
type (_, _) tool =
  | Search      : (search_args, search_results) tool
  | Read_file   : (read_args, file_contents) tool
  | Search_code : (code_search_args, code_match list) tool  (* ripgrep/ast-grep engine *)

(* Registry entry ties schema + implementation + result codec together *)
type packed_tool =
  | Tool : {
      spec : ('a, 'r) tool;
      name : string;
      schema : Schema.t;              (* derived from 'a *)
      run : 'a -> ('r, Tool_error.t) result;
      encode_result : 'r -> Yojson.Safe.t;
    } -> packed_tool
```

The model's tool choice deserializes into an existentially packed `Invocation : ('a, 'r) tool * 'a -> invocation`, so dispatch is a total function — there is no "unknown tool name" branch, because the grammar/schema only admits registered tool names as enum values.

**Design rule: no `Shell` tool.** A shell tool embeds an infinite untyped language inside the typed boundary — it is every capability at once, its arguments defeat taint analysis (§13.2) and approval rendering (§13.6), and it contradicts the project thesis. Instead: file ops go through `Eio.Path` capabilities, where the workspace sandbox falls out of the API shape; code search goes through typed verbs backed by ripgrep/ast-grep, whose structured results (path/line/context records) are cheaper in tokens and more legible to the model than raw grep text; dev workflows get a curated typed verb set (`Dune of dune_cmd`, `Git of git_op`, …) — compile-time versions of the runtime allowlists agent products use today. If an escape hatch is ever unavoidable, it is `Exec` over an *allowlisted program enum* with an argv list (never shell-interpreted), gated behind an explicit capability and sandbox (§13.4), and every use of it is treated as a bug report against the typed tool set.

### 5.2 Agent state as phantom-typed machine

```ocaml
type planning  = Planning
type acting    = Acting
type finished  = Finished

type _ state =
  | Fresh     : { goal : string }                       -> planning state
  | Executing : { plan : step list; done_ : step list } -> acting state
  | Complete  : { summary : string; trace : Trace.t }   -> finished state

val plan   : planning state -> acting state io
val step   : acting state -> [ `Continue of acting state | `Finish of finished state ] io
```

You cannot call `step` on a fresh agent or `plan` on a finished one. The loop's legal transitions are the function signatures.

---

## 6. The Effectful Agent Loop

The centerpiece. Tool calls, model calls, and checkpoints are *effects*; the harness is a handler stack.

```ocaml
type _ Effect.t +=
  | Ask     : prompt * 'a Schema.typed -> 'a Effect.t         (* constrained model call *)
  | Invoke  : ('a, 'r) tool * 'a -> ('r, Tool_error.t) result Effect.t
  | Note    : Trace.event -> unit Effect.t                    (* observability *)
  | Approve : approval_request -> approval Effect.t           (* human-in-the-loop *)

(* User writes direct-style agent code: *)
let research_agent goal =
  let plan = Effect.perform (Ask (planning_prompt goal, Plan.typed)) in
  List.iter
    (fun step ->
      match Effect.perform (Invoke (Search, step.query_args)) with
      | Ok results -> Effect.perform (Note (Found results))
      | Error e -> Effect.perform (Note (Tool_failed e)))
    plan.steps;
  Effect.perform (Ask (synthesis_prompt goal, Report.typed))
```

Handlers give you, without touching agent code:

- **Production handler:** `Ask` → backend call with derived constraint; `Invoke` → real tool.
- **Replay handler:** both effects answered from a recorded trace. Deterministic tests of nondeterministic systems.
- **Approval handler:** intercepts `Invoke` on tools marked `[@dangerous]`, performs `Approve` before proceeding — the human-in-the-loop is a composable handler, not an if-statement scattered through the loop.
- **Budget handler:** counts tokens/calls, aborts by *not resuming* the continuation. Cancellation is trivially correct because the continuation just gets dropped.
- **Checkpoint handler:** serializes continuation state at each `Ask` boundary (via trace, not continuation capture — continuations aren't serializable; the trace + deterministic replay *is* the checkpoint).

This is the design element that would make Occamel distinctive rather than "LangChain in OCaml." Nobody in the mainstream ecosystems has a first-class effects story.

---

## 7. Constraint Derivation

### 7.1 The schema subset (T2)

Hosted structured-output modes support a restricted JSON Schema dialect (no `oneOf` at root in some, no recursive refs in others, `additionalProperties: false` required, etc.). On the Claude API, structured outputs are now **GA** — `output_config.format` for JSON outputs and `tools[].strict: true` for grammar-guaranteed tool arguments; no beta headers. The provider compiles the schema into a grammar server-side and caches it (~24h).

Crucially, the provider enforces **grammar-complexity limits**, and they apply to the *combined* total across all strict schemas in a request (e.g., four strict tools with six optional parameters each trips a 24-optional-parameter limit). Optional fields, unions, and nesting interact multiplicatively in the compiled grammar, with a hard compilation timeout (~180s) as the backstop. This yields a Occamel feature no other SDK has: **`occamel.ppx` should estimate compiled-grammar complexity at compile time** and emit a warning ("this type will likely exceed provider limits; consider fewer `option` fields, or a T1 backend") before the first 400 ever happens. Practical derivation heuristics that fall out of the limits: prefer required fields with explicit defaults over optional ones; keep variant payloads flat; split many-tool agents into strict-critical and lax tools.

`occamel.ppx` targets the **intersection dialect** and reports, at compile time, when a type can't be represented for a given tier:

- Variants → tagged unions: `{ "type": "search", "args": {...} }` with `type` as enum discriminant
- Records → objects, all fields `required` (optionality via explicit `option`, encoded as `anyOf [T, null]`)
- `int` bounds, string patterns, enum values from attributes
- **Not representable at T2:** GADT indices, functional fields, recursive types beyond provider depth limits → compile error with a message suggesting a T1 backend or a type restructure

### 7.2 GBNF generation (T1)

For local backends the same type compiles to a GBNF grammar. This is strictly more expressive: recursion is fine, and we can encode e.g. fixed-precision decimals or bounded-length arrays directly in the grammar. Emission of whitespace-canonical JSON keeps grammars small and decoding fast.

### 7.3 Round-trip law

The ppx emits a property test per type (via qcheck): `of_json (to_json x) = Ok x`, and — run in CI against a schema validator — `to_json x` always validates against the derived schema. The derivation is trustworthy because it is *tested by construction*, not by convention.

---

## 8. The Repair Loop (T3 and refinement failures)

Even at T1/T2, semantic refinements (§3.3) can fail. At T3 everything can fail. Occamel standardizes one recovery path:

```
model output → parse → refine ──ok──▶ typed value
                   │        │
                 fail     fail
                   ▼        ▼
             Structured_error (what was wrong, in schema terms)
                   │
                   ▼
       repair prompt (error + original constraint) → retry (bounded, n=2 default)
                   │
                 exhausted
                   ▼
             `Unparseable of raw * errors  (surfaced to the loop as a typed case)
```

Key decision: **repair exhaustion is a variant, not an exception.** The agent author must handle `` `Unparseable `` — the compiler enforces that the failure path exists.

---

## 9. Observability & Replay

Every effect performance appends a typed event to a `Trace.t`:

```ocaml
type Trace.event =
  | Model_call of { prompt_hash : string; schema : Schema.t; output : Yojson.Safe.t; usage : usage }
  | Tool_call  of { tool : string; args : Yojson.Safe.t; result : Yojson.Safe.t; ms : int }
  | Repair     of { attempt : int; error : Parse_error.t }
  | Approval   of { request : string; decision : approval }
```

Traces serialize to JSONL. The `occamel-mock` backend replays a trace as the handler, which yields:

- **Golden tests:** record once, replay in CI forever.
- **Eval harness integration:** a trace is exactly the artifact your eval suite wants — run N agents, score traces against rubrics. (This should slot into your existing eval directory structure with minimal glue.)
- **Time-travel debugging:** replay to event k, then switch to the live handler.

---

## 10. Ecosystem Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| No *official* Anthropic/OpenAI OCaml SDKs | Low-Med (downgraded) | Community `anthropic` opam package exists (eio, streaming, tools, retries). Extend it with `output_config` + `strict`; for full API-type coverage, generate OCaml types from Anthropic's OpenAPI spec rather than hand-porting an SDK. |
| SSE/streaming ergonomics in OCaml | Medium | eio + cohttp-eio (or the existing package's transport); port `eventsource-parser` (TS) for a spec-exact SSE state machine (Appendix B); streaming constrained JSON can be incrementally validated against the schema automaton |
| Provider grammar-complexity limits (T2) | Medium (new) | Compile-time complexity estimation in `occamel.ppx` (§7.1); derivation heuristics favoring required-with-default over optional fields; conformance tests that submit derived schemas to the API in CI |
| Provider schema dialects drift | Medium | Tier system makes dialect explicit; mine `rust-genai`'s per-provider schema-normalization tables as the reference for dialect quirks; conformance tests per backend in CI |
| T1 token-mask engine correctness | Medium | **Bind, don't port**: llguidance/xgrammar runtimes are hot-loop, tokenizer-entangled Rust/C++. FFI via ctypes, or drive llama.cpp's built-in llguidance support. Port only the pure schema→grammar *translation* layer (Appendix B). |
| "OpenAI-compatible" servers vary wildly in structured-output enforcement | Medium (new) | Capability probing (§3.2.1): canary request verifies conformance per endpoint before assigning a tier; per-endpoint quirk table maintained like `rust-genai`'s adapters |
| ppx maintenance burden across OCaml versions | Low-Med | Target ppxlib stable API; keep derivation surface small |
| GADT/phantom ergonomics scare off contributors | Low | Keep the *user-facing* API to plain variants + records; fancy types stay inside the library |
| Effects are still unfamiliar territory | Low | Direct-style user code hides them; document the handler stack thoroughly; Madhavapeddy's Eio-capability agent work is adjacent prior art to cite and align with |

---

## 11. MVP Milestones

**M0 — Spike (1–2 weekends).** Hand-written schema for one `action` type; `occamel-oai` minimal client against **Ollama locally** (free, fast iteration, `format` param for schema enforcement) with the same code then pointed at OpenAI proper; single-tool loop; prove the end-to-end feel. Agent-port `eventsource-parser` for streaming (Appendix C).

**M1 — Derivation.** `occamel-ppx` for records/variants → schema + codecs; grammar-complexity estimation warnings (§7.1); round-trip property tests; instructor-pattern repair loop; capability probing for oai_compat endpoints.

**M2 — Effects loop.** `Ask`/`Invoke`/`Note` effects; production + mock handlers; trace record/replay; approval handler for `[@dangerous]`.

**M3 — Native + T1 backends.** `occamel-anthropic` via the existing opam package extended with `output_config`/`strict`; GBNF/llguidance grammar emission; in-process llama.cpp integration; tier phantom types wired through.

**M4 — Polish & release.** Docs, examples (a research agent, a file-editing agent), opam publish, announce.

Success criterion for M2: rewrite one of your existing eval scenarios as a Occamel agent and replay its trace deterministically in CI.

---

## 12. Open Questions

1. **Streaming partial values.** Can we surface *typed partial* values mid-stream (e.g., `action` known to be `Search` before args complete) by running the schema automaton incrementally? High wow-factor; possibly v2.
2. **Multi-turn conversation typing.** Should conversation history be typed (each turn's schema recorded) or opaque? Leaning typed-per-turn with an existential wrapper.
3. **Parallel tool calls.** Effects + eio fibers make this natural mechanically; the question is trace semantics (partial order vs. serialized).
4. **Agent composition.** Sub-agents as effects performed by parent agents? Elegant, but defer until single-agent ergonomics are proven.
5. ~~**Name.**~~ Resolved: **Occamel**. Sounds like OCaml; contains the camel and a nod to Ollama; and contains Occam — whose razor is the design philosophy in miniature (§ epigraph).

---

## 13. Security Model

Type safety guarantees *shape*, not *intent*. A perfectly typed `Delete { path }` is still a disaster if a web page talked the model into it — and constrained generation *helps the attacker*, because injected actions arrive syntactically flawless and machine-dispatchable. Occamel's honest security claim is therefore not "invalid states are unrepresentable" but: **the security architecture — taint, capabilities, trust — is made of compile-time properties instead of conventions.** No Python harness can say that.

### 13.1 Threat model

In scope: prompt injection via tool results (primary threat); malicious or compromised OpenAI-compatible endpoints/gateways; tampered traces; resource exhaustion via streaming; secrets leakage through traces/logs/repair prompts; supply-chain risk in agent-ported code. Out of scope (v1): a malicious *user*, model-weight-level attacks, multi-tenant isolation.

### 13.2 Taint as a phantom type

Every string entering the context through an `Invoke` result is untrusted data, not instruction. Taint is tracked in the type:

```ocaml
type trusted   = Trusted
type untrusted = Untrusted

type 'taint text                    (* abstract; no direct constructor for trusted *)
val of_user      : string -> trusted text
val of_tool      : string -> untrusted text
val launder      : justification -> untrusted text -> trusted text  (* audited, rare *)

(* Dangerous-capability tools require trusted provenance for sensitive args: *)
type write_args = { path : Path.t; content : untrusted text }   (* content may be tainted *)
type delete_args = { path : (Path.t, trusted) provenanced }     (* path may NOT be *)
```

The `Invoke` handler enforces the residual dynamic check: when a capability-bearing tool's arguments *derive from* untrusted values (tracked through `Ctx`), the handler refuses or escalates to `Approve` with the provenance chain displayed. This is the design point of DeepMind's **CaMeL** ("Defeating Prompt Injections by Design") — capability- and data-flow-tracking around an LLM — which Occamel should cite both for the architecture and the almost cosmic naming coincidence.

### 13.3 Capabilities, not a `[@dangerous]` blocklist

Default-allow with opt-in danger marking fails when someone forgets the annotation. Inverted: every tool *declares* required capabilities; handlers *grant* them explicitly.

```ocaml
type cap = Fs_read of Eio.Path.t | Fs_write of Eio.Path.t | Net of Domain_allowlist.t | Exec of Program.t list
val register : caps:cap list -> ('a, 'r) tool -> ... 
```

Undeclared capability = the tool cannot be registered. This extends eio's capability-passing style upward into the tool layer (and aligns with Madhavapeddy's Bastion work). `[@dangerous]` survives only as UI metadata for approval prompts.

### 13.4 Sandboxing and the no-shell rule

No `Shell` tool exists (§5.1). File tools receive an `Eio.Path.t` *directory capability* — paths outside the workspace are unconstructible, with refinement specifying symlink resolution then `..`-normalization, and TOCTOU-aware open-then-verify. Any future `Exec` runs an allowlisted program (enum, argv list, no shell interpretation) in a jail: scoped filesystem view, no ambient network, rlimits.

### 13.5 Endpoint trust ≠ guarantee tier

Capability probing (§3.2.1) establishes *conformance*, never *trust* — a malicious gateway passes canaries deliberately, and cached probe results are a poisoning target. The backend type carries two independent axes:

```ocaml
type ('tier, 'trust) backend
(* 'trust : [ `First_party | `Self_hosted | `Gateway ] — set by configuration, never by probing *)
```

A T2 guarantee from an untrusted gateway is a claim, not a property; agents can require both axes at compile time.

### 13.6 Approval rendering is a security control

`Approve` must display a canonical, truncation-safe rendering of *exactly the values that will execute*: full paths (post-refinement), content lengths + hashes rather than 10k-char bodies, argv arrays never joined into strings, homoglyph/control-character escaping, and the taint-provenance chain (§13.2). Rate-limit approvals to resist fatigue attacks; N denials aborts the run.

### 13.7 Trace integrity, redaction, and replay safety

Traces contain prompts, tool args, and results — i.e., secrets, PII, and file contents. Requirements: a redaction layer at write time (`Secret.t` values are unserializable by construction, §13.9; user-registered scrubbers for PII); HMAC/signature over the event log; and **replay-into-live transitions verify integrity first and run under the same approval handlers as a fresh run** — a tampered trace must not be able to drive real tool execution.

### 13.8 Client-layer hardening

- **SSRF:** model-supplied URLs resolve through a validator denying private ranges, link-local (`169.254.0.0/16` — cloud metadata), and re-validating on every redirect hop. Fail closed.
- **Resource limits:** max SSE event size, max total stream size, Yojson depth limits, bounded incremental tool-call-argument assembly. Unbounded streaming JSON accumulation is a default-shipped memory-DoS otherwise.
- **Repair-loop hardening:** repair prompts include the structured error and the schema, but do **not** echo the full invalid payload — an injection that deliberately fails validation must not get re-presented with bonus context about the validator. Bounded retries (already §8).

### 13.9 Secrets hygiene

API keys are `Secret.t`: abstract, redacted printer, no `yojson` codec (a compile error to serialize), sourced from env/keychain, excluded from traces and repair prompts by construction.

### 13.10 Supply chain for agent-ported code

Upstream test suites encode *specified* behavior; a port can pass every test and still add an out-of-spec vulnerability — and Appendix C's two flagship ports (SSE parser, schema→grammar compiler) are both parser code, the classic home of such bugs. Mandate **differential fuzzing** against the original (same inputs → both implementations → compare outputs), not just test parity. Pin and hash-verify the FFI'd llguidance build; the ctypes boundary is the one memory-unsafety window in an otherwise safe language.

---

## Appendix A — Minimal end-to-end sketch

```ocaml
open Occamel

type action =
  | Search of { query : string }
  | Answer of { text : string }
[@@deriving occamel]

let agent question =
  let rec loop ctx =
    match Effect.perform (Ask (ctx, action_typed)) with
    | Search { query } ->
        let results = Effect.perform (Invoke (Web_search, { query })) in
        loop (Ctx.add ctx results)
    | Answer { text } -> text
  in
  loop (Ctx.of_question question)

let () =
  (* Same agent, any backend: local Ollama for development... *)
  let backend = Oai_compat.create ~base_url:"http://ether:11434/v1" ~model:"qwen3:14b" () in
  (* ...or: Anthropic.create ~model:"claude-sonnet-4-6" () *)
  let trace, answer = Run.with_recording backend ~tools:[web_search] agent "..." in
  Trace.save trace "run.jsonl";
  print_endline answer
```

---

## Appendix B — Minimum client-layer capabilities (`occamel.wire` scope)

Two wire protocols, sharing SSE and retry machinery:

**B.1 — OpenAI-compatible surface (`occamel-oai`, primary):**

1. **Chat completions endpoint.** `POST /v1/chat/completions` with typed codecs for messages, `tools` (function calling), `tool_choice`, and `response_format: { type: json_schema, json_schema: { strict: true, schema } }`.
2. **SSE streaming.** `data:` chunk framing with `[DONE]` sentinel; delta accumulation for content and streamed tool-call arguments (which arrive as string fragments needing incremental JSON assembly — the fiddliest part of the whole client).
3. **Capability probing** (§3.2.1). Canary request per new endpoint to establish the real tier; cached; user-overridable.
4. **Endpoint quirk table.** Ollama's `format` parameter, vLLM/SGLang guided-decoding extensions, servers that ignore `strict` — the `rust-genai` adapter layer is the reference catalogue.

**B.2 — Anthropic native surface (`occamel-anthropic`):**

1. **Messages endpoint.** `POST /v1/messages` with typed codecs for the request (system, messages, tools, `tool_choice`, `output_config`) and response (content blocks: text / `tool_use` / thinking; `stop_reason`; usage).
2. **SSE streaming.** Event framing (`message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`, `ping`, `error`) plus incremental accumulation of JSON deltas into content blocks. Streaming is compatible with structured outputs, so the parser must handle constrained-JSON text deltas.
3. **Structured-output plumbing.** `output_config.format = { type: json_schema, schema }` and `tools[].strict = true`. Handle the schema-complexity 400 family distinctly from other client errors — these are *Occamel bugs or ppx warnings*, not runtime transients.

**Shared:**

- **Retry/backoff + error taxonomy.** 429/529/overloaded as retryable; schema-rejection 400s as non-retryable and surfaced with the offending schema; respect `retry-after`.
- **Token counting & cache control** (optional, v1.1): count-tokens endpoint; prompt-cache `cache_control` markers on stable prefixes (system prompt + tool schemas), which agent loops benefit from disproportionately.

Everything else in typical SDKs (files, batches, admin) is out of scope for the harness.

---

## Appendix C — Porting plan: reference libraries by strategy

Strategy legend: **Port** (agent translates code + test suite), **Pattern** (port the architecture, not the code), **Bind** (FFI), **Mine** (read for design decisions), **Generate** (derive from spec).

| Library | Lang | Strategy | What Occamel takes | Why it ports well (or doesn't) |
|---|---|---|---|---|
| `eventsource-parser` | TS | **Port** | Spec-exact SSE state machine for `occamel.wire` | Tiny, pure, no I/O, spec-driven, existing test suite becomes ground truth. Ideal first agent-port; the state machine maps directly to a variant-based fold. |
| `instructor` | Python | **Pattern** | The validate → structured-error → re-prompt repair loop (§8) | The reference implementation of schema-repair. It's architecture, not Python — porting code would import Pydantic-isms for no gain. |
| `llguidance` (schema→grammar compiler only) | Rust | **Port** | JSON-schema → grammar translation semantics for the ppx (§7) | The translation layer is pure and well-specified (merged into Chromium for `window.ai` schema enforcement; available in llama.cpp). This is the semantic core `occamel.ppx` must get right. |
| `llguidance` / `xgrammar` (mask runtime) | Rust/C++ | **Bind** | T1 token-mask engine | Hot-loop, tokenizer-entangled; benchmarks favor llguidance (lower latency, 0.12% vs 2.21% invalid-output rate vs xgrammar). A port buys bugs, not value. FFI via ctypes or drive llama.cpp directly. |
| `rig` | Rust | **Mine** | Provider abstraction shape: `CompletionModel`-trait hierarchy → OCaml module signatures + functors | Most production-proven trait design in the space; traits translate mechanically to OCaml signatures. |
| `rust-genai` | Rust | **Mine** | Per-provider JSON-schema normalization tables (const, nullable, `additionalProperties`, rejected keywords) | This is the tier-dialect problem (§7.1) pre-researched across ~25 providers. |
| Effect AI (`@effect/ai-*`) | TS | **Mine** | Effects-based provider abstraction; documented pitfalls | Closest philosophical cousin. Its tracker records the key mistake to avoid: emulating structured output via forced tool calls instead of native `output_config` (loses constrained decoding). |
| Official Anthropic SDKs | Py/TS/Go | **Generate** | API types via OpenAPI spec → OCaml codegen | SDKs are themselves generated; port the spec, not the artifact. |
| `anthropic` (opam) | OCaml | **Extend** | Transport, streaming, retries — already idiomatic eio | Exists today; add `output_config` + `strict` support and upstream it. |

**Suggested agent-porting order** (each yields a usable artifact): `eventsource-parser` → `occamel-oai` minimal client (validated against local Ollama) → llguidance schema→grammar compiler (with its test corpus as oracle) → instructor-style repair loop → extend opam `anthropic` with structured outputs → llguidance runtime binding.
