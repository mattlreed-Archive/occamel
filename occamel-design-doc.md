# Occamel — Design Document

**A type-safe agentic harness in OCaml: constrained generation + a compiler-checked planner/executor (CaMeL) architecture**

*Status: Draft v0.6 · July 2026 — restored the free-form loop as a first-class v1 mode and the experimental control (§6.6); strict planner/executor remains the flagship. Previous: v0.5 went all-in on the planner/executor architecture (§6), removed the phantom-typed state machine, reframed as a research project (§1.1); v0.4 added §13 Security Model; removed the Shell tool (§5.1).*

> **Occamel** = OCaml + camel + a nod to Ollama — and Occam's razor, which is the actual design philosophy: constrained generation is entity-reduction applied to model output, and the planner/executor split is entity-reduction applied to *trust*. Do not multiply possible outputs — or trusted parties — beyond necessity; make everything else unrepresentable. (That the architecture we adopt is literally named **CaMeL** is a naming coincidence too good to decline.)

---

## 1. Motivation

Every agentic harness today has the same two soft underbellies.

**The first is the stringly-typed boundary.** The model emits JSON, the harness parses it, and a validation layer — usually ad hoc, usually incomplete — stands between "the model said something" and "the program does something." Failures at this boundary are a dominant failure mode of agent systems: malformed tool calls, hallucinated tool names, missing arguments, states the loop author never considered.

**The second is prompt injection, and it is architecturally unsolvable in the standard loop.** The standard agent is one model that reads tool outputs and decides the next action. Once untrusted text enters the context, everything the model subsequently emits is derived from attacker-influenced input — no amount of value-level taint tracking survives the model-mediated laundering step. The only known fix with a soundness argument is architectural: DeepMind's **CaMeL** ("Defeating Prompt Injections by Design") splits the agent into a *privileged planner* that never sees untrusted bytes and a *quarantined reader* that processes untrusted data but holds no authority, with data flow between them explicitly tracked.

Occamel's core bet is that three technologies compose into something none of them achieves alone:

1. **Constrained generation.** Grammar- or schema-constrained decoding guarantees the *syntactic shape* of model output at sampling time. The model literally cannot emit an invalid token sequence — including an invalid *plan*.
2. **OCaml's type system.** Algebraic data types, GADTs, phantom types, and abstract types with smart constructors make illegal states unrepresentable at compile time — including the state "the planner's prompt contains untrusted bytes."
3. **The CaMeL architecture.** The privileged planner emits a typed plan AST; a library interpreter executes it with provenance tracked on every value; a quarantined extraction call is the only place untrusted data is read, and its output is schema-bounded.

Combined: **the privileged model's entire output surface is a grammar-constrained, typed plan; the privileged/quarantined boundary is enforced by the compiler; and the injection channel that remains is measurable in the extraction schemas.** The agent loop stops being something the user writes and becomes something the library interprets. No Python harness can make any of these claims.

### 1.1 What this project is for

Occamel is a research and learning vehicle, not a framework play. It does not compete with LangGraph, the OpenAI Agents SDK, or any orchestration platform. Success is measured in knowledge artifacts — a working compiler-checked CaMeL implementation, a written-up evaluation, upstream contributions to the OCaml ecosystem — not adoption. "CaMeL, but the separation is compiler-checked and the plans are grammar-constrained" is, as far as we know, unbuilt; building it is the point.

The project ships **two modes on one substrate** (§6): a free-form typed loop (the ReAct baseline every mainstream harness runs) and the strict planner/executor. The pairing is itself the experiment: same tools, same traces, same models, same type-derived constraints — only the architecture varies — so the utility/security trade the CaMeL paper reports can be measured cleanly, with everything else held constant (M6). Strict mode is the flagship claim; loop mode is both the control condition and the mode most everyday tasks actually want.

### Why OCaml specifically (vs. Rust, Haskell, TypeScript)

- **Variants + exhaustiveness checking** map one-to-one onto "the model must choose one of N actions" — and onto the constructors of a plan AST.
- **OCaml 5 effect handlers** are an unusually natural fit for the interpreter (§6): planning, extraction, and tool calls are *effects* the interpreter performs and the harness handles, giving suspension, resumption, and replay essentially for free — without monad transformer towers (Haskell) or async runtime ceremony (Rust).
- **ppx metaprogramming** lets us derive JSON schemas and grammars from type definitions with zero runtime cost and no macro hygiene nightmares.
- **Pragmatism.** OCaml compiles fast, produces small native binaries, and reads like ML pseudocode. The ecosystem gap (§10) is real but bounded.

---

## 2. Goals and Non-Goals

### Goals

- **G1 — Typed boundary.** Every model output that drives program behavior is a value of a user-defined OCaml type before any harness logic touches it. For the privileged model, that type is the plan AST.
- **G2 — Constraint derivation.** JSON schemas (hosted APIs) and GBNF grammars (local inference) are derived automatically from type definitions via ppx. One source of truth — for tool args, extraction schemas, and the plan DSL alike.
- **G3 — Two typed modes, one substrate.** *Loop mode:* the user writes a direct-style loop whose every model output is a typed action — a `match` expression the compiler checks for exhaustiveness. *Strict mode:* the loop is a library-provided interpreter over a typed plan AST; user code declares tools, capabilities, policies, and extraction schemas, and does not write the loop. Ill-formed plans are unrepresentable (grammar-constrained generation); ill-*behaved* plans are rejected before execution (admission, §6.4). Both modes share tools, effects, traces, repair, and backends.
- **G4 — Replayable traces.** Every run serializes to a typed trace that can be replayed deterministically against the handler stack (mocked tools, recorded model outputs, recorded plans).
- **G5 — Backend plurality.** Same agent definition runs against Anthropic/OpenAI hosted structured outputs *or* local llama.cpp/vLLM with full grammar constraints, with the guarantee level explicit in types.
- **G6 — Compiler-enforced privilege separation.** The planner prompt is constructible only from trusted-typed values. Feeding a tool result to the planner is a type error, not a policy violation. This is the CaMeL boundary, checked at compile time.

### Non-Goals

- **NG1 —** Not a prompt-engineering framework. Occamel constrains *outputs*; prompt construction is user territory (with helpers).
- **NG2 —** Not a multi-agent orchestration platform (v1). Single-agent plans first; composition later (§12).
- **NG3 —** Not an inference engine. We integrate with llama.cpp et al.; we don't sample tokens ourselves.
- **NG4 —** Not RAG, memory, or vector-store infrastructure.
- **NG5 —** Not chasing generality or adoption. Where a design choice trades breadth of use cases against strength of guarantees or clarity of the research result, guarantees win (see §1.1). Corollary for the two-mode design: loop mode (§6.6) is a baseline and a workhorse, but it never grows features that blur the modes' security claims — anything that needs injection *resistance* belongs in strict mode, not in an incrementally hardened loop.

---

## 3. Core Concepts

### 3.1 Types as the source of truth

The user defines tools, extraction targets, and (implicitly, via the library) the plan DSL as ordinary OCaml types:

```ocaml
type search_args = {
  query : string; [@doc "Search query, 1-6 words"]
  max_results : int; [@default 5] [@min 1] [@max 10]
} [@@deriving occamel]

type finding = {
  claim : string;
  source_url : string;
} [@@deriving occamel]   (* an extraction schema the quarantined model may fill *)
```

`[@@deriving occamel]` generates, per type:

- `val t_schema : Occamel.Schema.t` — a JSON-schema-compatible representation
- `val t_grammar : Occamel.Grammar.t` — a GBNF grammar (for local backends)
- `val t_of_json : Yojson.Safe.t -> (t, Occamel.Parse_error.t) result`
- `val json_of_t : t -> Yojson.Safe.t`
- Doc-string and constraint metadata that flows into the schema (descriptions, defaults, numeric bounds, enum values)
- Channel-width metadata for extraction schemas (§13.2): how much attacker-influenceable information the type can carry

### 3.2 The three-tier guarantee model

Not all backends give the same guarantee. Occamel makes the tier explicit rather than papering over it:

| Tier | Backend | Guarantee | Residual risk |
|------|---------|-----------|---------------|
| **T1 — Grammar** | llama.cpp (GBNF/llguidance), vLLM & SGLang (xgrammar/llguidance) | Token-level: output *is* in the grammar | Semantic invariants only (§3.3) |
| **T2 — Schema** | Anthropic structured outputs; OpenAI strict mode; Ollama `format` | Provider-enforced JSON schema conformance | Schema-inexpressible invariants; provider bugs |
| **T3 — Parse** | Any chat API, no structured mode | None at generation; parse + repair loop (§8) | Parse failures, retries |

The tier is a phantom type parameter on the backend, so a role can *require* at least T2 at compile time:

```ocaml
type 'tier backend
val anthropic : config -> [ `T2 ] backend
val llama_cpp : config -> [ `T1 ] backend
val raw_chat  : config -> [ `T3 ] backend

(* OpenAI-compatible endpoints span all three tiers depending on the server;
   the constructor is honest about that, and capability probing narrows it: *)
val oai_compat : config -> [ `T1 | `T2 | `T3 ] backend_dynamic
val probe : backend_dynamic -> [ `T1 ] backend option * [ `T2 ] backend option * [ `T3 ] backend

(* The strict runner refuses planners without enforcement: *)
val run : planner:[< `T1 | `T2 ] backend -> q_llm:_ backend -> 'a agent -> 'a run_result
```

Note the coupling with §5.2: the plan AST is recursive, which pushes the *planner* toward T1 (grammars handle recursion natively) or a bounded-depth T2 encoding. The quarantined extractor's schemas are typically flat records/enums — comfortably T2.

### 3.2.1 The OpenAI-compatible surface is the primary backend

The `/v1/chat/completions` wire format is the de facto lingua franca: OpenAI itself, Ollama, vLLM, SGLang, llama.cpp's server, LM Studio, Groq, Together, OpenRouter, and most gateways all speak it. One well-built `occamel-oai` backend therefore covers the local-inference story *and* most hosted providers, which changes the priority order: **build `occamel-oai` first**, `occamel-anthropic` second (as the native-protocol backend that unlocks Claude-specific features like `output_config` and prompt caching).

The catch is that "OpenAI-compatible" is a wire format, not a guarantee level. The same request shape hits very different enforcement machinery: `response_format: json_schema` on OpenAI proper is provider-enforced (T2); on vLLM/SGLang it's backed by a real grammar engine (effectively T1); on some proxies it's silently ignored (T3 wearing a T2 costume). Occamel handles this with **capability probing**: on first use, send a canary request with a deliberately narrow schema and verify conformance, caching the result per endpoint. The phantom tier is then assigned from *observed* behavior, not from the server's marketing. A config override exists for endpoints the user already trusts. Probing establishes conformance, never trust — see §13.5.

### 3.3 Smart-constructor choke point

Schemas and grammars can't express everything (`"path must be inside the workspace"`, `"query is non-empty after trimming"`). Occamel's rule: **exactly one validation choke point**, in the derived parser, via optional refinement functions:

```ocaml
type path = Path.t  (* abstract *)
[@@deriving occamel ~parse:Path.of_string_workspace_relative]
```

The refinement runs during `of_json`. Downstream code never sees an unvalidated `path`. Refinement failures feed the repair loop (§8) with a structured error the model can act on — not a stack trace. The same choke point hosts per-program argv refinements for any future `Exec` tool (§5.1).

### 3.4 One privileged writer, one quarantined reader

The whole architecture in three sentences. The **planner** (P-LLM) sees only trusted input — the user's request and the tool specifications — and emits a plan as a typed AST; it never sees a tool result. The **quarantined extractor** (Q-LLM) is the only model call that reads untrusted data (tool outputs), and it can only answer into a user-declared schema; it can never invoke a tool. The **interpreter** executes the plan, tracks the provenance of every value, and checks per-tool policies at each capability-bearing sink.

This is **strict mode**. Its sibling, **loop mode** (§6.6), is the conventional observe-act loop with typed actions — same tools, same traces, no architectural injection resistance. Every security claim in this document is mode-qualified (§13). Details in §6.

---

## 4. Architecture

```
┌─────────────────────────────────────────────────────────┐
│  User agent code                                        │
│  types + tools + capabilities + policies + extraction   │
│  schemas ([@@deriving occamel]) — no loop to write      │
├─────────────────────────────────────────────────────────┤
│  occamel.ppx        │  occamel.core                     │
│  schema + grammar   │  plan DSL, interpreter,           │
│  + codec derivation │  provenance lattice, admission,   │
│  + channel lints    │  effects, repair loop, trace      │
├─────────────────────┴───────────────────────────────────┤
│  occamel.backends                                       │
│  oai_compat (OpenAI/Ollama/vLLM/llama.cpp/LM Studio…)   │
│  anthropic (native) │ llama_cpp (in-proc) │ mock/replay │
├─────────────────────────────────────────────────────────┤
│  occamel.wire  — HTTP/SSE client (cohttp-eio), JSON     │
└─────────────────────────────────────────────────────────┘
```

**Packages** (opam): `occamel` (core: plan DSL, interpreter, effects, provenance), `occamel-ppx`, `occamel-oai` (the OpenAI-compatible backend — first-class, covers OpenAI plus Ollama/vLLM/SGLang/llama.cpp-server/LM Studio/most gateways), `occamel-anthropic` (native protocol), `occamel-llama` (in-process llama.cpp for true T1), `occamel-mock`. Core has no HTTP dependency — backends are pluggable, mock backend included for testing.

**Prior art to build on, not around:** an `anthropic` package already exists on opam (Thibaut Mattio) — eio-based, type-safe bindings with streaming + backpressure, tool use, batch processing, and built-in retries. It predates structured-outputs GA, so `occamel-anthropic` should begin as an evaluate-and-extend of this package (adding `output_config.format` and `strict` tool support) rather than a from-scratch client. Anil Madhavapeddy's "language-integrated LLMs" work (LLM as ordinary OCaml library; the Bastion agentic system using Eio capabilities for effect-policy reasoning) is directly adjacent prior art — worth engaging with the OCaml community early. And the **CaMeL paper** (Debenedetti et al., DeepMind) is the architectural reference for §6 and §13: mine it for the plan-DSL design, the provenance semantics, the policy examples, and the AgentDojo evaluation methodology.

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

(* Registry entry ties schema + implementation + capabilities + result codec together *)
type packed_tool =
  | Tool : {
      spec : ('a, 'r) tool;
      name : string;
      schema : Schema.t;              (* derived from 'a *)
      caps : Cap.t list;              (* §13.3 — declared, granted at registration *)
      run : 'a -> ('r, Tool_error.t) result;
      encode_result : 'r -> Yojson.Safe.t;
    } -> packed_tool
```

A plan's `Call` steps resolve against the registry at admission time (§6.4), so dispatch during execution is a total function — there is no "unknown tool name" branch, because the plan grammar only admits registered tool names as enum values, and admission re-verifies it.

**The tool universe is closed at compile time, and in v1 that is a feature.** Runtime tool discovery (MCP et al.) is deferred (§12): a research harness wants a small, fully-analyzed world, and the planner/executor's admission check depends on knowing every tool's capabilities and policies up front. The sketched extension — a `Dynamic` invocation variant plus a `promote` function that checks a user-written type against a server's advertised schema at connection time — is recorded in §12 for post-v1.

**Design rule: no `Shell` tool.** A shell tool embeds an infinite untyped language inside the typed boundary — it is every capability at once, its arguments defeat provenance policies (§13.2) and approval rendering (§13.6), and it contradicts the project thesis twice over (a plan whose steps are opaque strings cannot be admission-checked). Instead: file ops go through `Eio.Path` capabilities, where the workspace sandbox falls out of the API shape; code search goes through typed verbs backed by ripgrep/ast-grep, whose structured results (path/line/context records) are cheaper in tokens and more legible to the model than raw grep text. **Build the typed verb set reactively, not speculatively:** v1 ships file ops, search, and — only if unavoidable — `Exec` over an *allowlisted program enum* with an argv list (never shell-interpreted), gated behind an explicit capability and sandbox (§13.4). Every `Exec` use in a trace is a bug report against the typed tool set; let observed usage drive which typed verbs (`Dune of dune_cmd`, `Git of git_op`, …) get built. Caveat recorded honestly: allowlisting the program is necessary but not sufficient — argv cells carrying plan-supplied strings remain an injection surface for programs with expressive flags (`git -c`, `find -exec`), so per-program argv refinements live in the §3.3 choke point.

### 5.2 The plan DSL

The privileged model's entire output is a value of this type (names indicative, surface deliberately small):

```ocaml
type expr =
  | Var of var_id                       (* reference to an earlier binding *)
  | Lit of literal                      (* string/int/bool/enum literal *)
[@@deriving occamel]

type step =
  | Call    of { bind : var_id; tool : tool_name; args : (field * expr) list }
  | Extract of { bind : var_id; source : expr; schema : schema_ref; question : string }
  | If      of { cond : expr; then_ : step list; else_ : step list }
  | Foreach of { bind : var_id; over : expr; body : step list }
  | Return  of expr
[@@deriving occamel]

type plan = step list
```

Design notes:

- **Six constructors, on purpose.** Every constructor added to the DSL is surface the planner can misuse, the admission checker must analyze, and a small local model must learn to emit. Start at the expressivity floor (CaMeL's DSL is the reference for what real tasks need) and grow only under evidence. Occam again.
- **`Extract` is in the plan**, not improvised at runtime: the planner declares *up front* where untrusted data will be read and into which schema. Admission can therefore see the entire untrusted→sink data-flow graph before anything executes.
- **`schema_ref` and `tool_name` are enums** derived from the registry — the grammar physically cannot name a tool or schema that doesn't exist.
- **Recursion pushes the planner toward T1** (§3.2). GBNF handles the recursive AST natively; for T2-only planners the ppx emits a bounded-depth encoding (nesting beyond ~3 levels of `If`/`Foreach` is rare in practice and a smell in a plan anyway).
- **No general expressions.** No arithmetic, no string concatenation, no lambdas. If a task needs computation over values, that is either a typed tool or evidence the DSL is being asked to be a programming language, which is the road back to `Shell`.

---

## 6. The Effectful Core: Two Modes, One Substrate

The centerpiece. Model calls, extraction, tool calls, and approvals are *effects*; agents are code that performs them, and the harness is a handler stack. Two modes run on this substrate. **Strict mode** (§6.2–§6.5, the flagship): the user parameterizes a library interpreter over the plan DSL and does not write the loop. **Loop mode** (§6.6, the baseline and control): the user writes the loop in direct style over typed actions.

### 6.1 Effects

```ocaml
type _ Effect.t +=
  | Plan    : Trusted.text * Tool_spec.t list -> plan Effect.t                    (* P-LLM, strict *)
  | Extract : Untrusted.text * 'a Schema.typed * string -> 'a Prov.t Effect.t     (* Q-LLM, strict *)
  | Ask     : Ctx.t * 'a Schema.typed -> 'a Effect.t                              (* loop mode only *)
  | Invoke  : ('a, 'r) tool * 'a -> ('r, Tool_error.t) result Effect.t            (* tools, both *)
  | Note    : Trace.event -> unit Effect.t                                        (* observability *)
  | Approve : Approval_view.t -> approval Effect.t                                (* human-in-the-loop *)
```

`Ask` is the unconstrained-context model call loop mode is built on — its `Ctx.t` may (and normally does) contain tool results. The strict runner installs no handler for `Ask`, so a strict agent cannot perform it even by accident: the two modes are separated by their handler stacks, not by convention.

The signature of `Plan` *is* goal G6: its prompt argument is `Trusted.text`, and there is no constructor from tool output to `Trusted.text` (§13.2). The privileged/quarantined boundary is not a convention the interpreter maintains; it is a type the compiler checks. `Extract` is the dual: its input is `Untrusted.text`, its output is a typed value still wrapped in provenance, and no tool-invoking effect is reachable from inside its handler.

### 6.2 The interpreter

The executor is an ordinary environment-passing interpreter over §5.2's AST — perhaps 200 lines of the most heavily-audited code in the project:

- `Call` resolves the tool, decodes args from the environment through the §3.3 choke point, checks the sink policy (§6.3), performs `Invoke`, binds the result with provenance `{Tool_result site}`.
- `Extract` performs the Q-LLM effect; the binding's provenance is `{Extracted {from; schema}}` — typed, but *never* trusted.
- `If`/`Foreach` evaluate their scrutinee and add a `Branch site` source to the provenance of **everything executed inside the body** when the scrutinee's provenance is untrusted — control-flow taint, so a plan cannot launder data influence through branching (§13.2).
- `Return` yields the final value with its full provenance to the caller.

Handlers give you, without touching the interpreter:

- **Production handler:** `Plan`/`Extract` → backend calls with derived constraints; `Invoke` → real tool.
- **Replay handler:** all effects answered from a recorded trace. Deterministic tests of nondeterministic systems.
- **Approval handler:** renders the admission-time plan view (§6.4) and any policy-triggered per-sink escalations (§13.6).
- **Budget handler:** counts tokens/calls, aborts by *not resuming* the continuation. Cancellation is trivially correct because the continuation just gets dropped.
- **Checkpoint handler:** the trace + deterministic replay *is* the checkpoint (continuations aren't serializable).

Honesty note on "compile-time": OCaml 5 effects are themselves untyped — an unhandled effect is a runtime exception, and continuations are one-shot. What the compiler checks is the *data* discipline (G1, G6, exhaustive matches over plan constructors and error variants), not handler coverage. The handler stack is small, closed, and owned by the library, which is the mitigation.

### 6.3 Provenance and policies

Every plan binding carries a source set, joined along both data flow and control flow:

```ocaml
type source =
  | User                                          (* the original trusted request *)
  | Tool_result of call_site
  | Extracted   of { from : call_site; schema : Schema.id }
  | Branch      of cond_site                      (* control-flow taint *)

type prov = Source_set.t

(* Per-tool, per-field sink policies, checked by the interpreter before Invoke: *)
val policy : tool_name -> field -> prov -> [ `Allow | `Deny of reason | `Needs_approval ]
```

Examples in the CaMeL spirit: `send_email.to` requires provenance ⊆ `{User}` or an existing-contact refinement; `delete.path` requires `{User}`; `write.content` may be fully untrusted (writing attacker text to a workspace file the user asked for is fine — *where* it goes is the guarded field). Display sinks (the final `Return` shown to the user) accept anything: the user reading untrusted content is the product working.

### 6.4 Plan admission

Because the plan is data, it is analyzed **before** anything executes:

1. **Well-formedness re-check** — every `tool_name`/`schema_ref` resolves; every `Var` is bound before use (the grammar makes most of this unrepresentable; admission is the belt to that suspenders).
2. **Static provenance walk** — compute each binding's *worst-case* provenance and evaluate every sink policy. A plan that would be denied at step 7 is rejected at step 0, with a structured reason the planner can repair against (§8).
3. **Whole-plan approval** — one `Approve` renders the entire data-flow graph: every tool call, every guarded sink and its provenance chain, every extraction and its schema's channel width (§13.2). One informed approval of a verified graph, instead of N mid-run prompts training the user to click yes (§13.6). Policies may still mark specific sinks `Needs_approval` for a second, targeted confirmation at execution time.

### 6.5 Replanning

The hard problem, with a typed answer. Feeding execution results back to the planner would reopen the laundering hole, so the rule is: **the planner may only ever see trusted values, and the type system decides what qualifies.**

- **`Tool_error.t` is harness-generated** — timeouts, refusals, not-found, policy denials. It is constructed by Occamel, not by attacker-readable content, so it is `Trusted` by construction. Replan-on-error is therefore safe: the planner sees its own plan plus the typed error, never tool output. This covers the majority of real replanning needs (the file wasn't there; the API was down; admission rejected step 3).
- **Content-dependent adaptation** must be declared in the plan as `If` over an `Extract` into a *narrow* type (a bool, a small enum). The attacker's influence is then bounded by the enum's channel width and visible at admission.
- Anything else — "let the planner read the results and improvise" — is loop mode's territory (§6.6), not a backdoor in this one.

### 6.6 Loop mode (`Occamel.Loop`)

The conventional observe-act loop, kept honest by types. The user writes direct-style code; every model output arrives as a typed action via `Ask`; tool results flow back into the context and the model adapts:

```ocaml
let research_agent question =
  let rec go ctx =
    match Effect.perform (Ask (ctx, Action.typed)) with
    | Search args ->
        let r = Effect.perform (Invoke (Web_search, args)) in
        go (Ctx.add ctx r)
    | Answer { text } -> text
  in
  go (Ctx.of_question question)
```

Everything except the security architecture is shared with strict mode: the same tool registry and capabilities (§13.3), the same repair loop (§8), the same traces and replay (§9), the same backends and tiers (§3.2), the same approval handler — which in loop mode intercepts capability-bearing `Invoke`s and renders *best-effort* provenance (which tool results were in the context that produced this action). What loop mode does **not** get is the injection-resistance claim: once a tool result enters `Ctx.t`, every subsequent action is attacker-influenceable, and no type can say otherwise (§13.2's static guarantee is unavailable by construction — `Ask` takes `Ctx.t`, not `Trusted.text`). The compiler still checks what it can — exhaustive action handling, the `` `Unparseable `` path, capability declarations — and the honest posture is "guarded by approvals and sandboxing, not by architecture."

Why loop mode is in v1 rather than deferred: it is the **experimental control**. Measuring strict mode's utility cost and security gain requires a baseline on the *same* substrate — same tools, same traces, same models, same derived constraints — so that the only varying factor is the architecture (M6). It is also the mode most everyday tasks want: low-stakes, open-ended work where adaptation beats predictability. Choosing a mode is choosing a point on the utility/guarantee curve, and Occamel makes that choice explicit — one function name apart — instead of pretending one point fits all.

This is the design element that makes Occamel distinctive rather than "LangChain in OCaml" or "CaMeL in another language": the boundary CaMeL enforces with an interpreter and discipline is here a compile-time property, the plans CaMeL parses are here grammar-constrained, and nobody in the mainstream ecosystems has a first-class effects story to build the interpreter on.

---

## 7. Constraint Derivation

### 7.1 The schema subset (T2)

Hosted structured-output modes support a restricted JSON Schema dialect (no `oneOf` at root in some, no recursive refs in others, `additionalProperties: false` required, etc.). On the Claude API, structured outputs are now **GA** — `output_config.format` for JSON outputs and `tools[].strict: true` for grammar-guaranteed tool arguments; no beta headers. The provider compiles the schema into a grammar server-side and caches it (~24h).

Crucially, the provider enforces **grammar-complexity limits**, and they apply to the *combined* total across all strict schemas in a request (e.g., four strict tools with six optional parameters each trips a 24-optional-parameter limit). Optional fields, unions, and nesting interact multiplicatively in the compiled grammar, with a hard compilation timeout (~180s) as the backstop. This yields an Occamel feature no other SDK has: **`occamel.ppx` should estimate compiled-grammar complexity at compile time** and emit a warning ("this type will likely exceed provider limits; consider fewer `option` fields, or a T1 backend") before the first 400 ever happens. It is a warning, never an error — the limits are undocumented and moving; CI conformance tests (§10) are the ground truth. Practical derivation heuristics that fall out of the limits: prefer required fields with explicit defaults over optional ones; keep variant payloads flat; and for the plan DSL specifically, prefer a T1 planner or the bounded-depth encoding (§5.2).

`occamel.ppx` targets the **intersection dialect** and reports, at compile time, when a type can't be represented for a given tier:

- Variants → tagged unions: `{ "type": "search", "args": {...} }` with `type` as enum discriminant
- Records → objects, all fields `required` (optionality via explicit `option`, encoded as `anyOf [T, null]`)
- `int` bounds, string patterns, enum values from attributes
- **Not representable at T2:** GADT indices, functional fields, recursive types beyond provider depth limits → compile error with a message suggesting a T1 backend or a type restructure

### 7.2 GBNF generation (T1)

For local backends the same type compiles to a GBNF grammar. This is strictly more expressive: recursion is fine — which is why the plan DSL's natural home is a T1 planner — and we can encode e.g. fixed-precision decimals or bounded-length arrays directly in the grammar. Emission of whitespace-canonical JSON keeps grammars small and decoding fast.

### 7.3 Round-trip law

The ppx emits a property test per type (via qcheck): `of_json (to_json x) = Ok x`, and — run in CI against a schema validator — `to_json x` always validates against the derived schema. The derivation is trustworthy because it is *tested by construction*, not by convention. The plan DSL gets an additional generator: random well-formed plans, round-tripped and admission-checked, so the interpreter and admission walk are property-tested against the grammar.

---

## 8. The Repair Loop

Both model roles can fail semantically even when generation is constrained. The planner can emit a plan that admission rejects (§6.4); the extractor can produce a value that a §3.3 refinement refuses. Occamel standardizes one recovery path:

```
model output → parse → refine/admit ──ok──▶ typed value / admitted plan
                   │        │
                 fail     fail
                   ▼        ▼
             Structured_error (what was wrong, in schema/policy terms)
                   │
                   ▼
       repair prompt (error + original constraint) → retry (bounded, n=2 default)
                   │
                 exhausted
                   ▼
             `Unparseable of raw * errors  (surfaced to the caller as a typed case)
```

Key decision: **repair exhaustion is a variant, not an exception.** The caller must handle `` `Unparseable `` — the compiler enforces that the failure path exists. Note that at T1/T2 the planner's repair loop only ever fires on *admission* failures (syntax is guaranteed), so its repair prompts are policy-shaped ("step 3 sends extracted data to a trusted-only sink") — a structured error the planner can genuinely act on. Security constraint on repair prompts: §13.8.

---

## 9. Observability & Replay

Every effect performance appends a typed event to a `Trace.t`:

```ocaml
type Trace.event =
  | Ask_response   of { ctx_hash : string; schema : Schema.id; output : Yojson.Safe.t; usage : usage }  (* loop mode *)
  | Plan_generated of { prompt_hash : string; plan : plan; attempt : int }
  | Plan_admitted  of { verdict : [ `Ok | `Rejected of reason list ]; approval : approval option }
  | Extraction     of { site : call_site; schema : Schema.id; output : Yojson.Safe.t; usage : usage }
  | Tool_call      of { tool : string; schema_hash : string; args : Yojson.Safe.t;
                        result : Yojson.Safe.t; prov : prov; ms : int }
  | Repair         of { role : [ `Planner | `Extractor ]; attempt : int; error : Parse_error.t }
  | Approval       of { view_hash : string; decision : approval }
```

Traces serialize to JSONL. Tool events record the **schema hash** of the tool at call time, and replay fails loudly on mismatch — "the same tool" across two runs is otherwise only a naming convention, and silent replay against a drifted tool would quietly break G4. The `occamel-mock` backend replays a trace as the handler, which yields:

- **Golden tests:** record once, replay in CI forever — including the plan itself, so a model upgrade that changes planning behavior is a visible diff, not a mystery.
- **Eval harness integration:** a trace is exactly the artifact an eval suite wants — run N agents, score traces against rubrics. The admission verdicts and provenance chains make security-specific rubrics (did any untrusted value reach a guarded sink?) mechanically checkable.
- **Time-travel debugging:** replay to event k, then switch to the live handler.

Security requirements on traces (integrity, redaction, replay-into-live): §13.7.

---

## 10. Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| **Small local models can't plan well in a bespoke DSL** | **High — the central research risk** | Constrained decoding eliminates the *syntax* failure mode entirely (that's the thesis); few-shot plan examples in the planner prompt; keep the DSL at six constructors; M0 measures plan quality before anything else is built; fallback: a bigger hosted planner is one call per run — the cheap place to spend quality |
| Plan-first architecture loses utility on open-ended tasks | Accepted & measured | Loop mode (§6.6) exists precisely so the gap is *measured* on our own substrate (M6) rather than assumed from the paper; users choose the mode per task |
| No *official* Anthropic/OpenAI OCaml SDKs | Low-Med | Community `anthropic` opam package exists (eio, streaming, tools, retries). Extend it with `output_config` + `strict`; for full API-type coverage, generate OCaml types from Anthropic's OpenAPI spec rather than hand-porting an SDK. |
| SSE/streaming ergonomics in OCaml | Medium | eio + cohttp-eio (or the existing package's transport); port `eventsource-parser` (TS) for a spec-exact SSE state machine (Appendix B); streaming constrained JSON can be incrementally validated against the schema automaton |
| Provider grammar-complexity limits (T2) | Medium | Compile-time complexity estimation in `occamel.ppx` (§7.1); derivation heuristics favoring required-with-default over optional fields; conformance tests that submit derived schemas to the API in CI |
| Provider schema dialects drift | Medium | Tier system makes dialect explicit; mine `rust-genai`'s per-provider schema-normalization tables as the reference for dialect quirks; conformance tests per backend in CI |
| T1 token-mask engine correctness | Medium | **Bind, don't port**: llguidance/xgrammar runtimes are hot-loop, tokenizer-entangled Rust/C++. FFI via ctypes, or drive llama.cpp's built-in llguidance support. Port only the pure schema→grammar *translation* layer (Appendix C). |
| "OpenAI-compatible" servers vary wildly in structured-output enforcement | Medium | Capability probing (§3.2.1): canary request verifies conformance per endpoint before assigning a tier; per-endpoint quirk table maintained like `rust-genai`'s adapters |
| Interpreter/provenance bugs undermine the security claim | Medium | The interpreter is small (~200 lines) by design; property-test with generated plans (§7.3); the admission walk and the runtime walk are two implementations of the same lattice — differentially test them against each other |
| ppx maintenance burden across OCaml versions | Low-Med | Target ppxlib stable API; keep derivation surface small |
| GADT/phantom ergonomics scare off contributors | Low | Keep the *user-facing* API to plain variants + records; fancy types stay inside the library |
| Effects are still unfamiliar territory | Low | Users never see them (they don't write the loop at all now); document the handler stack thoroughly; Madhavapeddy's Eio-capability agent work is adjacent prior art to cite and align with |

---

## 11. MVP Milestones

**M0 — Spike: can models plan in the DSL? (1–2 weekends.)** Hand-written schema for a hand-written 4-constructor plan type; `occamel-oai` minimal client against **Ollama locally** (free, fast iteration, `format` param for schema enforcement); a single-tool loop to drive it. The go/no-go question is not "does the plumbing work" but **"do qwen3-class local models emit sensible plans under constraint, with how much few-shot help?"** Measure it before building anything else. The single-tool loop built here is embryonic loop mode — it graduates into M2 rather than being thrown away. Agent-port `eventsource-parser` for streaming (Appendix C).

**M1 — Derivation.** `occamel-ppx` for records/variants → schema + codecs; grammar-complexity estimation warnings (§7.1); round-trip property tests; instructor-pattern repair loop; capability probing for oai_compat endpoints.

**M2 — Loop mode.** `Ask`/`Invoke`/`Note`/`Approve` effects; production + mock handlers; trace record/replay; approval handler with best-effort provenance rendering (§6.6). Success criterion: rewrite one existing eval scenario as a loop-mode agent and replay its trace deterministically in CI.

**M3 — Strict mode: the interpreter.** Full plan DSL (`If`/`Foreach`/`Extract`); provenance lattice with control-flow taint; plan admission (static walk + structured rejections); sink policies; plans and provenance in traces. Success criterion: the M2 scenario re-expressed as a strict agent — same tools, same trace format, different architecture — replayed deterministically in CI.

**M4 — Quarantine and approval.** `Extract` effect with channel-width metadata and the unbounded-string lint (§13.2); whole-plan approval rendering per §13.6; replan-on-`Tool_error` (§6.5); redaction layer and `Secret.t` (§13.9).

**M5 — Native + T1 backends.** `occamel-anthropic` via the existing opam package extended with `output_config`/`strict`; GBNF/llguidance grammar emission (the plan DSL's natural home); in-process llama.cpp integration; tier phantom types wired through.

**M6 — Evaluate and write up.** Run a slice of **AgentDojo** (the CaMeL paper's benchmark) through Occamel **in both modes** — same tools, same models, only the architecture varying — and measure the utility delta and the injection-resistance delta. The controlled comparison is the headline artifact; write it up including the negative parts. Docs, examples (a research agent, a file-editing agent), opam publish, announce. Success criterion is a documented, reproducible result, not stars.

---

## 12. Open Questions

1. **DSL expressivity floor.** Are `If` + `Foreach` enough for the AgentDojo task distribution, or do real plans need joins/parallel fan-out? (Effects + eio fibers make parallel `Foreach` mechanically easy; the question is provenance semantics for partial orders and what it does to admission.) Use CaMeL's DSL and task corpus as the evidence base before adding constructors.
2. **Replan granularity.** Full replan on `Tool_error` vs. plan *patching* (replace the failed step's subtree). Is a patch admission-checkable incrementally, and is the plan diff renderable for re-approval?
3. **Q-LLM model choice.** Same model in a quarantined role, or a deliberately smaller model? Smaller is cheaper and arguably safer (less capable of being talked into clever misextraction), but weaker at hard extractions. Channel width (§13.2) may matter more than model choice — measure in M6.
4. **Streaming partial plans.** Can we surface *typed partial* values mid-stream (e.g., the first `Call` step known before the plan completes) by running the schema automaton incrementally — enabling pipelined admission? High wow-factor; possibly v2.
5. **Dynamic tools / MCP (deferred, sketch retained).** Post-v1: a `Dynamic` invocation variant (runtime-discovered tools as one *typed* case, schema-validated but not OCaml-typed, capability-starved and untrusted-output by default) plus `promote : Mcp.server -> name:string -> 'a Schema.typed -> ('a, Yojson.Safe.t) tool option` — compile-time types for chosen MCP tools, conformance-checked against the server's advertised schema at connection time, failing at connect rather than mid-run. Admission needs every tool's caps/policies declared, so dynamic tools would enter as `Needs_approval`-everything until mapped.
6. **Multi-turn.** What is a *conversation* in strict mode? Each user turn is fresh trusted input — likely: new plan per turn, with prior turns' *trusted* artifacts (the user's words, harness summaries of typed results?) carried forward. The tempting shortcut — feeding prior tool output into the next planning prompt — is exactly the laundering hole; whatever crosses turns must pass through the same `Trusted`/`Extract` discipline.
7. **Mode composition.** Can a loop-mode agent delegate a dangerous sub-task to a strict-mode sub-agent — improvise the *what*, execute the *how* under admission? The delegation boundary is another `Trusted`/`Extract` discipline problem: the loop agent's request is itself attacker-influenceable (its context contains tool results), so it cannot become the strict planner's `Trusted.text` without laundering — it may need to be treated as an extraction into a goal schema. Graduated autonomy is possibly the most interesting research direction the two-mode design opens.
8. ~~**Name.**~~ Resolved: **Occamel**. Sounds like OCaml; contains the camel — and now the architecture is literally CaMeL, which is either nominative determinism or a sign. Occam's razor remains the design philosophy in miniature (§ epigraph).

---

## 13. Security Model

Type safety guarantees *shape*, not *intent* — and constrained generation *helps the attacker* in a naive design, because injected actions arrive syntactically flawless and machine-dispatchable. Occamel's answer is architectural and **mode-qualified**:

- **Strict mode's claim:** the model with authority never reads attacker bytes, that boundary is a compile-time property, and the attacker influence that remains flows only through declared, schema-bounded, provenance-tracked channels.
- **Loop mode's claim is deliberately weaker:** capabilities (§13.3), sandboxing (§13.4), approval rendering (§13.6), and client hardening (§13.8) apply in full, but there is **no architectural injection resistance** — once a tool result enters the context, every subsequent action is attacker-influenceable, and the API and docs say so rather than implying otherwise.

Everything below applies to both modes except §13.2's static guarantee and §6.4's admission, which are strict-only. What follows makes each clause concrete, plus the unglamorous client-layer hardening that any harness needs.

### 13.1 Threat model

In scope: prompt injection via tool results (primary threat — addressed architecturally, §6/§13.2); malicious or compromised OpenAI-compatible endpoints/gateways; tampered traces; resource exhaustion via streaming; secrets leakage through traces/logs/repair prompts; supply-chain risk in agent-ported code. Out of scope (v1): a malicious *user*, model-weight-level attacks, multi-tenant isolation. Acknowledged residual (inherited from CaMeL, see 13.2): data-level attacks within extraction channel capacity, and utility-degrading attacks (injected content causing the Q-LLM to extract *wrong* values that policies permit).

### 13.2 Privilege separation as a compile-time property

The static guarantee — the strong, honest one:

```ocaml
module Trusted : sig
  type text                                   (* abstract *)
  val of_user   : string -> text              (* the user's request *)
  val of_static : string -> text              (* prompts, tool specs — author-controlled *)
  val launder   : justification -> Untrusted.text -> text   (* audited, logged, rare *)
end

(* The ONLY constructor of planner input takes Trusted.text (§6.1).
   There is no path from a tool result to Trusted.text except launder. *)
```

Feeding tool output to the planner is a type error. This replaces v0.4's value-level taint claim, which could not survive model-mediated laundering: we no longer claim to track taint *through* a model's context — we claim the privileged model's context never contains untrusted bytes at all, and the compiler checks it.

The dynamic layer — provenance on plan variables (§6.3): source sets joined along data flow and control flow (`Branch` taint), evaluated against per-sink policies at admission and again at execution. Sound for the CaMeL reason: the plan itself cannot be injected (its author never saw attacker bytes), so tracked variables are the *only* channel of attacker influence.

The measured residual — extraction channel width: injected content can still flip the *values* the Q-LLM extracts. Constrained extraction makes that channel quantifiable: a `bool` gives the attacker one bit; an enum, log₂(n) bits; an unbounded `string`, an open pipe. The ppx computes channel-width metadata per extraction schema, and **lints the composition**: an unbounded string extracted from untrusted data and reaching a capability-bearing sink is a warning with a named fix (narrow the schema, or route through a refinement). No other harness can even see this property.

### 13.3 Capabilities, not a `[@dangerous]` blocklist

Default-allow with opt-in danger marking fails when someone forgets the annotation. Inverted: every tool *declares* required capabilities; handlers *grant* them explicitly.

```ocaml
type cap = Fs_read of Eio.Path.t | Fs_write of Eio.Path.t | Net of Domain_allowlist.t | Exec of Program.t list
val register : caps:cap list -> ('a, 'r) tool -> ...
```

Undeclared capability = the tool cannot be registered, and admission (§6.4) knows every step's capability footprint before execution. This extends eio's capability-passing style upward into the tool layer (and aligns with Madhavapeddy's Bastion work). `[@dangerous]` survives only as UI metadata for approval rendering.

### 13.4 Sandboxing and the no-shell rule

No `Shell` tool exists (§5.1). File tools receive an `Eio.Path.t` *directory capability* — paths outside the workspace are unconstructible, with refinement specifying symlink resolution then `..`-normalization, and TOCTOU-aware open-then-verify. Any future `Exec` runs an allowlisted program (enum, argv list, no shell interpretation) in a jail: scoped filesystem view, no ambient network, rlimits — with per-program argv refinements at the §3.3 choke point, because program allowlisting alone does not bound expressive flags.

### 13.5 Endpoint trust ≠ guarantee tier

Capability probing (§3.2.1) establishes *conformance*, never *trust* — a malicious gateway passes canaries deliberately, and cached probe results are a poisoning target. The backend type carries two independent axes:

```ocaml
type ('tier, 'trust) backend
(* 'trust : [ `First_party | `Self_hosted | `Gateway ] — set by configuration, never by probing *)
```

A T2 guarantee from an untrusted gateway is a claim, not a property. The strict runner can require both axes at compile time — and the *planner's* backend deserves the stricter trust requirement, since a malicious planner endpoint controls the plan (admission and policies still bound the damage, which is the architecture earning its keep).

### 13.6 Approval rendering is a security control

The primary approval is the **whole-plan admission view** (§6.4): the full data-flow graph, every guarded sink with its provenance chain, every extraction with its schema and channel width — one informed decision about a verified object, instead of N mid-run prompts training the user to click yes. Rendering rules for it and for any per-sink `Needs_approval` escalation: canonical, truncation-safe display of *exactly the values that will execute* — full paths (post-refinement), content lengths + hashes rather than 10k-char bodies, argv arrays never joined into strings, homoglyph/control-character escaping. Rate-limit approvals to resist fatigue attacks; N denials aborts the run.

### 13.7 Trace integrity, redaction, and replay safety

Traces contain prompts, plans, tool args, and results — i.e., secrets, PII, and file contents. Requirements: a redaction layer at write time (`Secret.t` values are unserializable by construction, §13.9; user-registered scrubbers for PII); HMAC/signature over the event log; and **replay-into-live transitions verify integrity first and run under the same admission + approval handlers as a fresh run** — a tampered trace must not be able to drive real tool execution, and a replayed plan re-passes admission before touching anything live.

### 13.8 Client-layer hardening

- **SSRF:** model-supplied URLs resolve through a validator denying private ranges, link-local (`169.254.0.0/16` — cloud metadata), and re-validating on every redirect hop. Fail closed.
- **Resource limits:** max SSE event size, max total stream size, Yojson depth limits, bounded incremental tool-call-argument assembly. Unbounded streaming JSON accumulation is a default-shipped memory-DoS otherwise.
- **Repair-loop hardening:** repair prompts include the structured error and the schema, but do **not** echo the full invalid payload — an injection that deliberately fails validation must not get re-presented with bonus context about the validator. For the *planner's* repair loop this is free (admission errors reference plan steps, which contain no untrusted bytes); for the *extractor's* it is load-bearing. Bounded retries (already §8).

### 13.9 Secrets hygiene

API keys are `Secret.t`: abstract, redacted printer, no `yojson` codec (a compile error to serialize), sourced from env/keychain, excluded from traces and repair prompts by construction.

### 13.10 Supply chain for agent-ported code

Upstream test suites encode *specified* behavior; a port can pass every test and still add an out-of-spec vulnerability — and Appendix C's two flagship ports (SSE parser, schema→grammar compiler) are both parser code, the classic home of such bugs. Mandate **differential fuzzing** against the original (same inputs → both implementations → compare outputs), not just test parity. Pin and hash-verify the FFI'd llguidance build; the ctypes boundary is the one memory-unsafety window in an otherwise safe language.

---

## Appendix A — Minimal end-to-end sketch

```ocaml
open Occamel

(* 1. Closed-world tools (§5.1) *)
type search_args = { query : string } [@@deriving occamel]

type (_, _) tool = Web_search : (search_args, search_results) tool

(* 2. An extraction schema the quarantined model may fill (§6.1) *)
type finding = { claim : string; source_url : string } [@@deriving occamel]

(* 3. Registration: capabilities declared, policies attached *)
let registry =
  Registry.
    [ tool Web_search ~caps:[ Net Search_domains.allowlist ] ~run:Search_impl.run ]

let () =
  Eio_main.run @@ fun env ->
  (* Local Ollama for development — planner wants T1/T2, so probe first (§3.2.1) *)
  let backend = Oai_compat.create ~base_url:"http://ether:11434/v1" ~model:"qwen3:14b" () in
  let question = Trusted.of_user "What changed in OCaml 5.3's effect syntax? Cite sources." in
  let trace, result =
    Strict.run ~planner:backend ~q_llm:backend ~registry
      ~policies:Policy.defaults ~approve:Approve.tty
      question ~returns:(module Finding_list)
  in
  Trace.save trace "run.jsonl";
  match result with
  | Ok findings -> List.iter print_finding findings
  | Error (`Plan_rejected reasons) -> report reasons     (* admission said no (§6.4) *)
  | Error (`Unparseable (_, errs)) -> report_repair errs (* repair exhausted (§8) *)

(* What the planner actually emitted (recorded in the trace), rendered as OCaml: *)
let _example_plan : plan =
  [ Call    { bind = "r1"; tool = `Web_search;
              args = [ "query", Lit (String "OCaml 5.3 effect syntax changes") ] };
    Extract { bind = "f1"; source = Var "r1"; schema = `Finding_list;
              question = "List each concrete change with its source URL" };
    Return  (Var "f1") ]
(* Admission sees: Web_search needs Net (granted); f1 is Extracted (untrusted) and
   flows only to Return (display sink — allowed). One approval, then execution. *)
```

Loop mode is one function name away — same registry, same backend, same trace format, the user-written loop from §6.6 in place of the plan:

```ocaml
let trace, answer =
  Loop.run backend ~registry ~approve:Approve.tty research_agent
    "What changed in OCaml 5.3's effect syntax? Cite sources."
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
- **Token counting & cache control** (optional, v1.1): count-tokens endpoint; prompt-cache `cache_control` markers on stable prefixes (system prompt + tool schemas — and in strict mode the planner prompt is *fully* stable per task, which caching rewards disproportionately).

Everything else in typical SDKs (files, batches, admin) is out of scope for the harness.

---

## Appendix C — Porting plan: reference libraries by strategy

Strategy legend: **Port** (agent translates code + test suite), **Pattern** (port the architecture, not the code), **Bind** (FFI), **Mine** (read for design decisions), **Generate** (derive from spec).

| Library | Lang | Strategy | What Occamel takes | Why it ports well (or doesn't) |
|---|---|---|---|---|
| `eventsource-parser` | TS | **Port** | Spec-exact SSE state machine for `occamel.wire` | Tiny, pure, no I/O, spec-driven, existing test suite becomes ground truth. Ideal first agent-port; the state machine maps directly to a variant-based fold. |
| **CaMeL** (paper + released code) | Python | **Pattern** | Plan-DSL surface, provenance/capability semantics, policy examples, AgentDojo evaluation methodology (§6, §13.2, M6) | The architectural reference. Port the *semantics*, not the Python interpreter — Occamel's whole point is that OCaml can express the boundary statically. |
| `instructor` | Python | **Pattern** | The validate → structured-error → re-prompt repair loop (§8) | The reference implementation of schema-repair. It's architecture, not Python — porting code would import Pydantic-isms for no gain. |
| `llguidance` (schema→grammar compiler only) | Rust | **Port** | JSON-schema → grammar translation semantics for the ppx (§7) | The translation layer is pure and well-specified (merged into Chromium for `window.ai` schema enforcement; available in llama.cpp). This is the semantic core `occamel.ppx` must get right. |
| `llguidance` / `xgrammar` (mask runtime) | Rust/C++ | **Bind** | T1 token-mask engine | Hot-loop, tokenizer-entangled; benchmarks favor llguidance (lower latency, 0.12% vs 2.21% invalid-output rate vs xgrammar). A port buys bugs, not value. FFI via ctypes or drive llama.cpp directly. |
| `rig` | Rust | **Mine** | Provider abstraction shape: `CompletionModel`-trait hierarchy → OCaml module signatures + functors | Most production-proven trait design in the space; traits translate mechanically to OCaml signatures. |
| `rust-genai` | Rust | **Mine** | Per-provider JSON-schema normalization tables (const, nullable, `additionalProperties`, rejected keywords) | This is the tier-dialect problem (§7.1) pre-researched across ~25 providers. |
| Effect AI (`@effect/ai-*`) | TS | **Mine** | Effects-based provider abstraction; documented pitfalls | Closest philosophical cousin. Its tracker records the key mistake to avoid: emulating structured output via forced tool calls instead of native `output_config` (loses constrained decoding). |
| Official Anthropic SDKs | Py/TS/Go | **Generate** | API types via OpenAPI spec → OCaml codegen | SDKs are themselves generated; port the spec, not the artifact. |
| `anthropic` (opam) | OCaml | **Extend** | Transport, streaming, retries — already idiomatic eio | Exists today; add `output_config` + `strict` support and upstream it. |

**Suggested agent-porting order** (each yields a usable artifact): `eventsource-parser` → `occamel-oai` minimal client (validated against local Ollama) → plan-DSL spike + toy interpreter (M0's go/no-go) → llguidance schema→grammar compiler (with its test corpus as oracle) → instructor-style repair loop → extend opam `anthropic` with structured outputs → llguidance runtime binding.
