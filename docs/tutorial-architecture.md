# Occamel — Architectural Tutorial

A guided tour of *why* Occamel is shaped the way it is. Read this first; the
companion `tutorial-technical.md` walks the code. Both assume you've skimmed
`occamel-design-doc.md` but don't require memorizing it.

---

## 0. Glossary

The vocabulary used throughout, in one place. Skim it now; come back when a term
bites.

- **Loop mode** — the conventional agent: one model reads tool results and
  decides the next action in a loop. No architectural injection resistance.
- **Strict mode** — the CaMeL split: a privileged *planner* + a quarantined
  *reader* + an interpreter. The injection-resistant mode.
- **Planner (P-LLM)** — the privileged model. Sees only the trusted request and
  tool specs; emits a *plan*; never sees tool output.
- **Quarantined extractor (Q-LLM)** — the only model call that reads untrusted
  tool output. Answers into a schema; can never invoke a tool.
- **Plan** — a typed AST (`Plan.t`) the planner emits: a list of
  Call/Extract/If/Foreach/Return steps. Because it's *data*, it can be analyzed
  before it runs.
- **Provenance** — a set of *sources* attached to every value, recording where
  its data came from (User, Static, Tool_result, Extracted, Branch). A value is
  **trusted** iff every source is User or Static.
- **Taint** — being untrusted / attacker-influenced. **Control-flow taint**:
  everything executed inside a branch or loop over untrusted data is tainted,
  because the attacker chose whether/how often it runs.
- **Sink** — a place a value flows *into* that does something consequential (a
  tool argument). A **capability-bearing sink** is a tool with capabilities.
- **Sink policy** — a rule per tool field: may a value of *this provenance*
  reach *this field*? Verdict is Allow / Deny / Needs_approval.
- **Admission** — the static analysis of a plan *before* execution: compute each
  value's worst-case provenance, check every sink policy, reject bad plans with
  a structured reason. A sound over-approximation of the runtime.
- **Capability** — a declared permission a tool needs (Fs_read, Net, …). The
  registry *grants* a set; a tool whose capabilities aren't granted is rejected
  (default-deny).
- **Channel width** — how many bits an attacker can inject through an extraction
  into a given schema (a bool = 1 bit; a free string = unbounded). The measured
  residual attack.
- **Laundering** — illegitimately turning untrusted data into trusted (the thing
  the type boundary and `launder`'s audit prevent).
- **Trace** — the JSONL record of every effect in a run. Replayable, signable.
- **Admission ≠ approval:** admission is the automatic policy check; **approval**
  is the human being shown the plan's data-flow graph and saying yes/no.

---

## 1. The two problems Occamel exists to solve

Every LLM agent harness sits between a model that emits text and a program that
takes actions. Two failure modes live at that boundary:

1. **The stringly-typed boundary.** The model emits JSON; the harness parses it;
   a hand-rolled validation layer stands between "the model said something" and
   "the program did something." Malformed tool calls, hallucinated tool names,
   missing arguments, unhandled states — all live here.

2. **Prompt injection, which is architecturally unsolvable in the standard
   loop.** The standard agent is *one model* that reads tool outputs and decides
   the next action. Once attacker-controlled text enters that model's context
   (via a web page, an email, a file), everything the model emits afterward is
   attacker-influenced. No amount of "taint tracking" on the *values* survives,
   because the laundering happens *inside the model* — it reads the injection
   and emits a fresh action.

Occamel's thesis is that the *same* structural idea fixes both: **make the
boundary typed, and make the trust boundary architectural.**

---

## 2. The three-technology bet

```
   constrained generation      OCaml's type system        the CaMeL split
  (grammar/schema decoding)   (ADTs, phantom types,     (privileged planner +
   the model *cannot* emit     smart constructors)         quarantined reader)
   an invalid token seq         illegal states are        the model with authority
         │                      unrepresentable            never reads attacker bytes
         └──────────────┬───────────────┴──────────────────────┬──────────────┘
                        ▼                                        ▼
        the boundary is typed & checked           the trust boundary is a
        (problem 1 solved)                         compile-time property
                                                   (problem 2 solved)
```

- **Constrained generation** guarantees the *shape* of model output at sampling
  time. If the model must emit an `action` or a `plan`, the grammar makes an
  invalid one impossible.
- **OCaml's types** turn "the harness handles every case" into a compile error
  when you don't. The agent loop becomes a `match`; a forgotten variant doesn't
  compile.
- **The CaMeL architecture** (DeepMind's "Defeating Prompt Injections by
  Design") splits the agent into a *planner* that has authority but never sees
  untrusted data, and a *quarantined reader* that sees untrusted data but has no
  authority.

Occamel's distinctive contribution is doing all three *together in a language
where the trust boundary is compiler-checked* — as far as we know, unbuilt
before this.

---

## 3. Two modes on one substrate

Occamel ships two agent architectures that share everything except their trust
model. This pairing is deliberate: it's the controlled experiment.

### Loop mode (`Occamel.Loop`) — the conventional agent, kept honest by types

```
  user question
       │
       ▼
   ┌───────┐   Ask (constrained)   ┌────────┐
   │ model │◀──────────────────────│  Ctx   │  the context grows with
   │       │──────────────────────▶│        │  tool results (untrusted!)
   └───┬───┘   typed action        └────────┘
       │
       ▼  Invoke a tool → result flows back into Ctx
```

The user writes a direct-style loop; every model output arrives as a typed
action (`Search`, `Answer`, …); tool results flow back into the context and the
model adapts. This is ReAct. **It has no architectural injection resistance** —
once a tool result enters `Ctx`, every subsequent action is attacker-influenced.
What it *does* get: typed actions (no malformed calls), capability-gated tools,
the repair loop, replayable traces, and an approval prompt on dangerous tools.
The honest posture is "guarded by approvals and sandboxing, not by
architecture."

### Strict mode (`Occamel.Strict`) — the CaMeL planner/executor

```
  user question (Trusted.text)
       │
       ▼
   ┌─────────┐  emits a typed PLAN     the planner NEVER sees tool output
   │ PLANNER │────────────────────┐    (that's a *type error*, §5)
   │ (P-LLM) │                    │
   └─────────┘                    ▼
                            ┌───────────┐   admission: analyze the plan's
                            │ ADMISSION │   whole data-flow graph BEFORE
                            └─────┬─────┘   running anything
                                  │ ok
                                  ▼
                            ┌───────────┐   executes the plan, tracking
                            │INTERPRETER│   PROVENANCE on every value
                            └─────┬─────┘
                     ┌────────────┼───────────────┐
                     ▼            ▼               ▼
                 tool calls   EXTRACTOR       sink policies
                 (provenance   (Q-LLM: the    (a trusted-only sink
                  tracked)      ONLY reader    can't receive
                                of untrusted   attacker-influenced
                                data)          data)
```

The planner emits a plan as a typed AST from the trusted request alone. The plan
is *data*, so it can be analyzed before execution (**admission**). The
interpreter runs it, tracking where every value came from (**provenance**). The
one place untrusted data is read is the quarantined **extractor**, which can
only answer into a schema and can never invoke a tool.

**Why the injection can't land:** the planner writes the plan from the benign
goal, so the plan never contains "send my secrets to the attacker." Even if a
later extraction pulls the attacker's address out of a malicious tool result,
that value is marked *untrusted*, and a policy on the dangerous tool's recipient
field requires *trusted* provenance — so admission rejects it before anything
runs.

---

## 4. The security model, layer by layer

Strict mode's guarantees come from five cooperating mechanisms. Each is a
compile-time or admission-time property, not a runtime hope.

### 4.1 The Trusted boundary (compile-time)

`Trusted.text` has exactly three constructors: `of_user`, `of_static`, and the
audited `launder`. There is **no constructor from a tool result**. The planner's
input is typed `Trusted.text`. Therefore "a tool result reaches the planner" is
a *type error* the compiler rejects — not a convention the interpreter must
remember. This is the honest, narrow claim that replaces naive value-level
taint: we don't track taint *through* the model's context; we guarantee the
privileged model's context never contains untrusted bytes at all.

### 4.2 Provenance (runtime, but sound because of 4.1)

Every value the interpreter produces carries a *source set*: where it came from
(`User`, `Static`, `Tool_result`, `Extracted`, `Branch`). Sets join along data
flow (an argument's provenance is the union of its inputs') and **control flow**
(everything inside a branch or loop over untrusted data gains a `Branch`/loop
source). A value is *trusted* iff every source is `User` or `Static`. Because the
plan itself can't be injected (4.1), these tracked sources are the *only* channel
of attacker influence — which is why tracking them is sound.

The control-flow part is the subtle bit. A trusted literal `"/etc/passwd"` used
*inside* an `if` whose condition is untrusted is still attacker-influenced (the
attacker chose whether that branch runs), so the taint is applied at the *sink*,
not just at binding.

### 4.3 Admission (before execution)

Because the plan is data, Occamel analyzes it *before* running anything:
computes each binding's worst-case provenance, evaluates every sink policy, and
rejects a plan that *would* be denied at step 7 — at step 0, with a structured
reason. Admission is a *sound over-approximation* of the runtime: it walks both
`if` branches (runtime takes one), so anything the runtime could hit, admission
already checked. The whole data-flow graph is rendered as **one** approval, not
N mid-run prompts.

### 4.4 Capabilities and sink policies (§13.3, §6.3)

Every tool declares a spec: its capability footprint (`Fs_read`, `Net`, …), an
argument schema, and a per-field sink policy. The registry *grants* a capability
set. A tool with no spec cannot be called (default-deny — no silent Allow); a
tool whose capabilities aren't granted is rejected. Policies like
`require_trusted ~fields:["to"]` express "this field may only receive trusted
data."

### 4.5 Channel width (the measured residual, §13.2)

The one attack CaMeL admits is *data-level*: injected content can flip the
*values* the extractor pulls out. Occamel makes that channel *measurable*: an
extraction into a `bool` gives the attacker 1 bit; into an enum, log₂(n); into a
free string, an open pipe. A lint flags an unbounded-width extraction from
untrusted data reaching a capability sink, with a named fix (narrow the schema).
This is why typed extraction (Item 3) matters — it shrinks the residual channel.

---

## 5. Everything is a trace, and traces replay

Both modes serialize every effect to a typed `Trace.t` (JSONL). This buys:

- **Golden tests:** record a run once against a real model, commit the trace,
  replay it deterministically offline forever. Replay fails loudly on any
  divergence (a schema hash changed, the context diverged, a tool's args
  differ) — so a model upgrade that changes behavior is a visible diff.
- **Integrity:** traces are HMAC-signed; a tampered trace fails verification. A
  strict loader (`load_verified`) rejects unsigned or tampered traces for
  security-sensitive callers.
- **Replay-into-live:** you can replay a trace up to a cut point and then switch
  to live execution — but only from a *verified* trace, re-running admission and
  re-prompting the approval handler for any live action. Recorded approvals
  never authorize a live effect.

---

## 6. How the pieces were built (the milestone arc)

The system grew in provable increments, each with an adversarial security
review at its gate:

- **M0** — proved local models can emit valid plans under grammar constraint.
- **M1** — a ppx that derives JSON schemas + codecs from OCaml types (one source
  of truth), plus the repair loop.
- **M2** — loop mode: effects, handlers, traces, replay.
- **M3** — strict mode's core: the `Trusted` boundary, provenance, admission,
  sink policies. *The thesis centerpiece.*
- **M4** — quarantine and hardening: `Secret.t`, trace signing/redaction,
  whole-plan approval, channel-width analysis, replan-on-error.
- **M5** — the evaluation: loop vs strict on an injection suite. Strict blocked
  100% of injections; loop was compromised on 40% with the same model. The
  worst-case arm proved strict's resistance is *architectural* (holds against a
  model that always obeys); the control arm showed strict's utility cost under
  attack is mostly injection-*degraded extraction* (the acknowledged residual),
  not inherent plan-first cost.

Then the five deferred items completed the security story: a real capability +
typed-arg tool registry, channel-width enforcement at admission, `Foreach` with
per-element taint, and the replay-into-live approval seam.

---

## 7. What to take away for deciding next steps

- **The security win is real and architectural**, and now measured. Strict mode
  is the reason to care about this project.
- **The utility cost is real too** — plan-first agents are worse at open-ended
  improvisation, and (M5) injection can degrade the quarantined extractor.
  Typed, narrow extraction schemas are the lever against the latter.
- **Loop mode is the honest baseline and the everyday workhorse.** Most tasks
  aren't under attack; the two-mode design lets you choose the point on the
  utility/security curve per task.
- **The biggest open frontiers:** wiring the real AgentDojo for an
  externally-comparable number; a production planner that reliably emits good
  plans in the DSL (M0's central risk, only lightly de-risked); and streaming
  (the eventsource-parser port is merged and ready to build on).

The technical tutorial (`tutorial-technical.md`) shows how each mechanism above
is implemented in the code, with file pointers, so you can evaluate or extend
any piece.
