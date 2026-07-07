# Occamel

[![CI](https://github.com/mattreed555/occamel/actions/workflows/ci.yml/badge.svg)](https://github.com/mattreed555/occamel/actions/workflows/ci.yml)

**A type-safe agentic harness in OCaml: constrained generation + a
compiler-checked CaMeL planner/executor.**

> **Status: a personal learning project**, not a novel research contribution.
> The security architecture is a re-implementation of published ideas — CaMeL
> (Debenedetti et al., DeepMind) and the broader information-flow-control-for-
> agents line (ACE, FIDES, …); the typed-boundary idea is the standard
> structured-output pattern (Instructor / TypeChat / Zod), with static
> information-flow types going back to FlowCaml (2003). The value here is
> understanding that space deeply by building it end-to-end, and a clean
> two-mode controlled evaluation — see [`docs/`](docs/) for an honest write-up.

## The idea in one screen

The boundary between an LLM and a program is usually stringly-typed and
injection-prone. Occamel makes it typed and, in strict mode, injection-resistant
by construction. Run the 30-line taste:

```sh
dune exec examples/hello.exe
```

It shows the core bet: define a variant → the ppx derives its JSON schema → a
(constrained) model reply → parse into a typed value → handle with an exhaustive
`match`. Delete a case and it won't compile.

## Two modes, one substrate

- **Loop mode** (`Occamel.Loop`) — the conventional observe-act agent, with
  typed actions. No architectural injection resistance.
- **Strict mode** (`Occamel.Strict`) — the CaMeL split: a *planner* that sees
  only trusted input and emits a typed plan, a *quarantined extractor* that
  reads untrusted data but holds no authority, and an interpreter that tracks
  **provenance** on every value and checks **sink policies** before any tool
  runs. The trust boundary is a compile-time property (`Trusted.text` has no
  constructor from tool output).

In the injection evaluation (`docs/research/m5-results.md`), on the same tasks
and model, strict mode blocked **0/5 → 100%** of prompt injections while loop
mode was compromised on **2/5**; a worst-case arm shows strict's resistance is
architectural (it holds even against a model that always obeys).

## Learn it

- **[`docs/tutorial-architecture.md`](docs/tutorial-architecture.md)** — the
  *why*: the problems, the design, the security model, and a glossary.
- **[`docs/tutorial-technical.md`](docs/tutorial-technical.md)** — the *how*: a
  module-by-module code walkthrough, a reading path, and a tests-as-docs guide.
- **[`occamel-design-doc.md`](occamel-design-doc.md)** — the normative design
  doc.
- **[`docs/research/`](docs/research/)** — milestone write-ups and the
  adversarial security reviews at each gate.

## Build & test

Requires OCaml 5.x and opam.

```sh
opam install dune yojson ppxlib cohttp-eio eio_main qcheck alcotest
dune build
dune runtest        # offline suite
```

The model-backed demos (`bin/m*_eval`, `bin/m*_agent`) drive a local
[Ollama](https://ollama.com) on `localhost:11434` (M0 used `qwen3:14b` and
`gemma4:12b`); they are not part of `dune runtest`.

## Layout

```
src/occamel/        core library (no HTTP): plan DSL, interpreter, provenance,
                    admission, effects, traces, repair — each .ml has a .mli
src/occamel_ppx/    [@@deriving occamel] — schema + codec derivation
src/occamel_oai/    OpenAI-compatible HTTP client (cohttp-eio)
src/occamel_wire/   SSE parser (ported from eventsource-parser)
examples/hello.ml   the 5-minute standalone example
docs/               tutorials + research write-ups
test/               offline test suite (unit, property, golden-trace replay)
```

## License

Not yet chosen — this is a private learning repository.
