# Occamel — Technical Tutorial

A code-level walkthrough. Read `tutorial-architecture.md` first for the *why*;
this is the *how*, module by module, with file pointers so you can jump in and
extend anything. Line numbers drift as code changes — use the function names as
the stable anchor.

The core library (`src/occamel/`) is ~2,300 lines across small, single-purpose
modules. Nothing here has an HTTP dependency; backends plug in at the edge.
Every core module has a `.mli` interface — **read the `.mli` first**; it's the
module's table of contents (its public surface, without the implementation).

```
src/occamel/            the core (no HTTP) — each .ml has a .mli
  codec.ml    schema.ml     JSON decode runtime + schema dialect/validator/width
  plan.ml                   the plan DSL: type, grammar, codec, scoping
  prov.ml     trusted.ml    provenance lattice + the compile-time trust boundary
  strict.ml                 strict mode: tool specs, admission, executor
  strict_run.ml             strict runner: plan→admit→exec→trace, replay, replay-into-live
  loop.ml                   loop mode: effects, handlers, replay
  repair.ml                 the §8 repair loop
  trace.ml                  typed events, redaction, HMAC signing
  secret.ml                 unserializable credentials
  interp.ml   tool.ml       M0 toy interp + stub tool (early scaffolding)
src/occamel_ppx/            [@@deriving occamel] — schema+codec derivation
src/occamel_oai/            OpenAI-compatible HTTP client (cohttp-eio)
src/occamel_wire/           SSE parser (ported eventsource-parser)
src/occamel_examples/       research_agent, injection_agent, tool fixtures
examples/hello.ml           the 5-minute standalone taste (see §0)
```

---

## 0. Start here — the 5-minute version

Before any of the modules, run and read the smallest possible program
(`examples/hello.ml`, ~30 lines, no model or network):

```
dune exec examples/hello.exe
```

It walks the whole core idea in five steps: **define a variant → the ppx
derives its JSON schema → a (pretend) constrained model reply → parse it into a
typed value at the boundary → handle it with an exhaustive `match`.** The
payoff is the last step: delete the `Answer` case and the program won't
compile — the compiler forces you to handle every action the model can choose.
That single property (`match` over the model's output, checked at compile time)
is the entire "typed boundary" bet in one screen. Everything else in the
codebase is that idea plus security machinery.

## 0.1 A reading path through the code

Reading `strict.ml` top-to-bottom first is the *wrong* order. This path builds
up the concepts in dependency order, smallest first:

1. **`examples/hello.ml`** — the boundary idea, standalone (§0).
2. **`prov.mli`** (then `prov.ml`, ~65 lines) — the whole trust model:
   sources, `join`, `is_trusted`. If you understand `is_trusted`, you
   understand strict mode's runtime guarantee.
3. **`trusted.mli`** (~15 lines) — the compile-time boundary. Note there is no
   constructor from a tool result to `Trusted.t`. That's the whole CaMeL
   guarantee, as a type.
4. **`plan.mli`** — the `Plan.step` type. This is what the privileged planner
   emits. Small on purpose.
5. **`strict.mli`** — read the interface: tool specs, `analyze`/`admit`,
   `run`. Then read `analyze` in `strict.ml` (the static walk), then `run`
   (the dynamic walk). They deliberately mirror each other; `control_taint` is
   the shared piece that keeps them in sync.
6. **`loop.mli`** — the effects (`Ask`/`Invoke`/`Note`/`Approve`) and the two
   handlers (`run`, `replay`). This is loop mode entire.
7. **`strict_run.ml`** — how a real strict run is wired: `plan_with` (planner)
   → `analyze` → whole-plan approval → `Strict.run`, recording a trace.

Everything else (`codec`, `schema`, `repair`, `trace`, `secret`, the ppx) is
supporting machinery you can read on demand when a step above references it.

## 0.2 Learn from the tests

The `test/` suite is the most concrete documentation in the repo — each test
encodes an invariant as a runnable example. When a prose explanation feels
abstract, open the matching test:

- **`test/test_strict.ml`** — the security rules as concrete plans: "a literal
  `delete.path` inside an `if` on an untrusted condition is *rejected*" (the
  control-flow-taint case), the capability checks, and the
  **differential test** (any admitted plan must never hit a denied sink at
  runtime — the soundness contract in executable form).
- **`test/test_derive.ml`** — the ppx laws: `of_json (to_json x) = Ok x` and
  channel-width, as property tests.
- **`test/test_replay.ml`, `test/test_golden.ml`** — record/replay determinism
  and every divergence class failing loudly.
- **`test/test_replay_live.ml`** — the replay-into-live seam: unsigned/tampered
  rejected, and a recorded approval NOT authorizing a live send.
- **`test/test_secret_trace.ml`** — `Secret.t` unserializability, redaction,
  and HMAC tamper-detection.

A good way to learn a mechanism: read its `.mli`, then its test, then the `.ml`.

---

## 1. The JSON runtime: `codec.ml` and `schema.ml`

Generated code and hand-written codecs both call into `Codec`. The key type is
one structured error shape used everywhere:

```ocaml
type code = Invalid_json | Missing_field | Unexpected_field | Type_mismatch
          | Out_of_bounds | Bad_enum | Duplicate_field | Refinement_failed | Other
type error = { path : string; msg : string; code : code }
```

`msg` may contain payload bytes (an offending token, a bad key) and is for
*local* logging only. `safe_message` renders `path + code` with **no payload** —
this is what the repair loop sends back to a model (§13.8: never echo the
invalid payload). `Codec.of_string` enforces size and bracket-depth limits and
catches `Stack_overflow` before handing bytes to Yojson (a hostile endpoint
can't crash the agent with deeply-nested JSON).

`Schema` (`schema.ml`) is Occamel's JSON-Schema *subset* — the "intersection
dialect" that hosted structured-output modes accept. Three things live here:

- `validate : t -> Yojson.Safe.t -> (unit, string) result` — validates our
  dialect (used by the round-trip property tests and by typed-arg checking).
- `complexity : t -> int` — the heuristic behind the ppx's compile-time
  "this type may exceed provider grammar limits" warning.
- `channel_width : t -> width` — how many bits an attacker can inject through an
  extraction into this schema (`Bits log₂n` for an enum, `Unbounded` for a free
  string or any object without `additionalProperties:false`). **Under-reporting
  here would hide an injection channel, so every ambiguous case returns
  `Unbounded`** — fail-safe.

---

## 2. The plan DSL: `plan.ml`

The privileged model's *entire* output is a value of `Plan.t`. The type is
small on purpose (every constructor is surface the planner can misuse and
admission must analyze):

```ocaml
type expr = Var of string | Lit of string
type step =
  | Call    of { bind : string; tool : string; args : (string * expr) list }
  | Extract of { bind : string; source : expr; schema : string option; question : string }
  | If      of { cond : expr; then_ : step list; else_ : step list }
  | Foreach of { bind : string; over : expr; body : step list }
  | Return  of expr
type t = step list
```

`plan.ml` hand-writes four things for this type, because it's recursive (which
the T2 schema dialect can't express, so the ppx can't derive it):

1. **`schema`** — the GBNF/JSON grammar the planner is constrained to. It's
   *depth-unrolled*: an `if`/`foreach` body admits only non-control steps (no
   nesting), which keeps the grammar finite and dodges buggy `$ref` handling in
   llama.cpp (a real M0 finding).
2. **`to_json` / `of_json`** — the codec. `of_json` re-validates *everything*
   the backend returns (shape, tool enum, field presence) because backend
   enforcement is never trusted (§3.2.1).
3. **`validate_scoping`** — binds must be fresh; vars must be bound before use;
   and crucially, names bound inside an `if`/`foreach` body **do not escape** it
   (a branch may not have run). This is what makes control-flow taint sound.

`Extract.schema` is an *optional* ref (Item 3) so older/golden traces without it
still parse; `None` means free-text (unbounded channel).

---

## 3. The trust boundary: `trusted.mli`

The whole CaMeL guarantee reduces to this interface (`trusted.mli`):

```ocaml
module Untrusted : sig
  type t
  val of_tool_result : string -> t
  val read : t -> string   (* the extractor may read; deliberately NOT to_string *)
end
type t                     (* abstract: Trusted.text *)
val of_user   : string -> t
val of_static : string -> t
val launder   : audit:(string -> unit) -> justification -> Untrusted.t -> t
```

`t` is abstract with only three constructors, and **none of them takes an
`Untrusted.t`** except `launder` (which forces an audit callback). The strict
planner's input is `Trusted.t`. So the compiler enforces "the planner never sees
untrusted bytes." `of_user`/`of_static` are the TCB trust-assertion points —
documented as "never feed these `Untrusted.read x`."

---

## 4. The provenance lattice: `prov.ml`

Sixty lines, and the heart of the runtime guarantee:

```ocaml
type source = User | Static | Tool_result of site | Extracted of {from; schema} | Branch of site
type t = SS.t                      (* a set of sources *)
let join = SS.union                (* data-flow join: can't lose taint *)
let add_branch site t = SS.add (Branch site) t     (* control-flow taint *)
let is_trusted t = SS.for_all (function User | Static -> true | _ -> false) t
```

`is_trusted` is the whole policy: *any* `Tool_result`/`Extracted`/`Branch`
source makes a value untrusted. `join` is set union, so it can never drop taint.
`extracted_froms` (used by the channel-width lint) returns which extractions a
value derives from.

---

## 5. Strict mode: `strict.ml` (the big one, ~500 lines)

This is where admission and execution live. Three sub-systems:

### 5.1 Tool specs and the registry (Items 1+2)

```ocaml
type cap = Fs_read | Fs_write | Net | Exec
type tool_spec = { ts_name; ts_caps; ts_arg_schema; ts_policy; ts_refine }
type registry = { specs : tool_spec list; granted : cap list; extraction_schemas : ... }
```

A tool with no spec cannot be called (`spec_of` returns `None` → reject). This
is default-deny — the fix for "forgotten policy = silent Allow." Policies are
composable `field_policy` functions (`require_trusted`, `approve_if_untrusted`,
`combine`); `most_restrictive` (Deny > Needs_approval > Allow) is how one tool
carries several field rules without any being dropped.

### 5.2 Admission: `analyze` and `admit`

`analyze : registry -> Plan.t -> report` is the single static walk. It computes
each binding's worst-case provenance (`prov_of_expr`, where an unbound var is
treated as *untrusted*, fail-safe) and, per `Call` (`check_call`):

1. rejects an unregistered tool or an ungranted capability;
2. rejects a Call field not declared by the arg schema (§3.3 name consistency);
3. evaluates the sink policy on each field's *effective* provenance —
   `join branch_taint (prov_of_expr ...)`, so control-flow taint is applied at
   the sink;
4. emits an advisory channel-width lint if a capability sink receives an
   unbounded-width untrusted extraction.

The walk handles `If`/`Foreach` by adding `Branch`/loop taint to the body when
the scrutinee is untrusted, and *ignores the body's returned env* (binds don't
escape). `admit` is just `analyze(...).rejections = []`. The report also drives
the **whole-plan approval** (`render_report`, which escapes every field to pure
ASCII — homoglyph/bidi-safe).

### 5.3 The executor: `run`

`run : registry -> exec_hooks -> Plan.t -> (value, exec_error) result` mirrors
`analyze` on *real values*. Same provenance formulas at the same points — which
is why **admission is a sound over-approximation**: the runtime executes a
*subset* of what admission walked (a prefix + one `if` branch / the actual loop
elements), all with identical taint. So anything the runtime could hit, admission
already checked. The executor also runs the typed-arg validation + refinement
(§3.3 choke point) and the extraction output-validation before a tool sees
anything. `exec_hooks` (run_tool / extract / approve) are plain functions, so
the core is effect- and HTTP-free and directly testable.

> **The single most important invariant to preserve when editing this file:**
> the two walks (`analyze` and `run`) must apply *identical* provenance and
> taint at *identical* points. The `test_strict.ml` differential test guards
> this: any admitted plan must never hit a denied sink at runtime.

---

## 6. The strict runner: `strict_run.ml`

Wires the pieces into a run and a trace:

- **`run`** — `plan_with goal` (the planner; input is `Trusted.t` — the boundary
  is in the *type*), then `analyze`, then a **single whole-plan approval** if
  any sink needs it, then `Strict.run` with hooks that record each effect to a
  `Trace.t`. The extractor and tools are `config` callbacks (production wires
  `occamel-oai`; tests pass stubs).
- **`run_with_replan`** (§6.5) — on a harness-generated `Tool_error`, re-invoke
  the planner with a *static* note naming the failed tool. The error *string*
  is destructured away (`{tool; _}`) so no tool content reaches the planner —
  the replan prompt stays `Trusted.t`. Only `Tool_error` triggers replan.
- **`replay`** — pure deterministic replay from a trace (re-runs admission; no
  live tools).
- **`replay_then_live`** (Item 5) — `load_verified` the trace (unsigned/tampered
  → rejected), re-admit, replay the first `cut` tool calls, then execute live.
  Past the cut, the *live* approver is always consulted — a recorded approval
  never authorizes a live action.

---

## 7. Loop mode: `loop.ml`

The conventional loop, built on OCaml 5 effects:

```ocaml
type _ Effect.t +=
  | Ask : Ctx.t * 'a Schema.typed -> 'a Effect.t
  | Invoke : ('a,'r) Tool_def.t * 'a -> ('r,string) result Effect.t
  | Note : string -> unit Effect.t
  | Approve : approval_view -> approval Effect.t
```

`run` installs the production handler (`Ask` → backend + repair; `Invoke` →
real tool, with an approval prompt on `dangerous` tools rendered
truncation/homoglyph-safe). `replay` answers every effect from a trace and fails
loudly on divergence (schema hash, context hash, tool, args). Strict mode
installs *no* `Ask` handler, so a strict agent can't perform an unconstrained
model call even by accident — the two modes are separated by their handler
stacks.

---

## 8. Deriving the boundary: `src/occamel_ppx/occamel_ppx.ml`

`[@@deriving occamel]` on a record or plain variant generates, at compile time:
`<t>_schema` (T2-dialect JSON schema), `<t>_of_json` / `<t>_to_json` (codecs
calling the `Codec` runtime), and `<t>_typed` (the `Schema.typed` carrier that
drives `Ask`). Attributes `[@doc]`, `[@default]`, `[@min]`/`[@max]` flow into the
schema; a `~parse:` deriver arg wires a §3.3 refinement. Recursive/GADT/tuple
types are a *compile error* with a message pointing at the T1/hand-written route.
The plan DSL is the deliberate hand-written exception (it's recursive).

Property tests (`test/test_derive.ml`) assert the two laws per derived type:
`of_json (to_json x) = Ok x` and `to_json x` validates against `<t>_schema`.

---

## 9. Secrets and traces: `secret.ml`, `trace.ml`

`Secret.t` is abstract with no yojson codec and no `to_string` — serializing one
is a *compile error*. Plaintext is reachable only via `use s (fun p -> ...)`;
everything else sees a redacted fingerprint.

`Trace` events are a typed sum serialized to JSONL. `save` runs registered
scrubbers over every string field (write-time redaction) and appends an HMAC
`#sig` line when `OCCAMEL_TRACE_KEY` is set. `load_checked` returns
`Verified | Unsigned | Bad_signature`; `load_verified` *requires* `Verified`
(rejects the strip-the-signature downgrade). This is the integrity substrate
`replay_then_live` stands on.

---

## 10. How to extend it — common tasks

- **Add a tool (strict):** `Strict.tool ~name ~caps ~arg_schema ~policy
  ~refine ()` and put it in the registry. No spec → the tool can't be called.
- **Add a typed extraction:** register a named schema in the registry's
  `extraction_schemas`, and have the planner emit `Extract{schema=Some name;...}`.
  Admission will lint unbounded ones; runtime validates the extractor output.
- **Add a model action type (loop):** define a variant with `[@@deriving
  occamel]`; its `_typed` value drives `Ask`. See
  `occamel_examples/research_agent.ml`.
- **Add a plan DSL constructor:** edit `plan.ml` (type, `schema`, codec,
  `validate_scoping`) and *both* walks in `strict.ml` (`analyze` and `run`) —
  and add the taint story if it's control flow. `Foreach` (Item 4) is the worked
  example to copy.
- **Add a backend:** implement the `ask` / `plan_with` / tool callbacks against
  your API; the core never sees HTTP. `occamel_oai/client.ml` is the reference.

---

## 11. Where the sharp edges are (for evaluating next steps)

- **`known_tools` in `plan.ml` is a global list**, not per-agent. It's the last
  stringly-typed seam; a per-agent tool enum (derived from the registry) is the
  clean fix and would let `of_json` reject unknown tools per agent.
- **The planner emitting *good* plans is under-de-risked.** M0 showed models
  *can* emit valid plans; production reliability across a task distribution is
  the open research risk, not the plumbing.
- **Extraction is free-text unless a schema is named.** Item 3 built the
  enforcement; a production strict agent should route dangerous-sink-feeding
  extractions through narrow named schemas to shrink the residual channel (M5
  showed why).
- **The differential (`analyze` vs `run`) is the load-bearing test.** Any change
  to taint or admission must keep it green; treat a failure there as a security
  regression, not a test nuisance.
