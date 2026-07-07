# Occamel

A type-safe agentic harness in OCaml: constrained generation + a compiler-checked
planner/executor (CaMeL) architecture. **This is a research/learning project** —
success is knowledge artifacts and a controlled two-mode evaluation, not adoption.

## The design doc is normative

`occamel-design-doc.md` is the source of truth for architecture, security claims,
and milestones. Code follows the doc; if implementation reveals the doc is wrong,
**edit the doc deliberately (with a version bump + changelog line in the status
header) in the same change** — never let them drift silently.

**Current milestone: M5 — evaluation** (design doc §11). Done: M0 GO; M1 (ppx
deriver, repair loop); M2 (loop mode); M3 (strict mode: provenance, admission,
sink policies); M4 (Secret.t, trace signing/redaction, whole-plan approval,
channel-width, replan-on-Tool_error). Each has a `docs/research/m{N}-*.md`
writeup + security review. M5: the two-mode (loop vs strict) utility +
injection-resistance comparison on an AgentDojo-inspired suite — the project's
headline artifact. Do NOT autonomously opam-publish or announce (external).
Deferred: full §13.3 capability axis, typed per-tool arg codecs, Foreach,
replay-into-live approval seam.

## Build & test

```sh
eval $(opam env)          # once per shell
dune build @check         # fast typecheck — run constantly (a hook runs it after every .ml/.mli edit)
dune build                # full build
dune runtest              # tests
dune fmt                  # format (ocamlformat)
```

The PostToolUse hook in `.claude/settings.json` runs `dune build @check` after
every `.ml`/`.mli` edit and feeds compiler errors back automatically. Never
stack multiple edits on top of a broken build — fix type errors as they appear.

## Local inference

- Ollama runs as a brew service on `http://localhost:11434` (OpenAI-compatible
  surface at `/v1`). M0 model: `qwen3:14b`.
- The design doc's example URL `http://ether:11434` refers to this machine
  (hostname `m4pro-ether`); use `localhost` in code and config.
- Models pulled: `qwen3:14b` and `gemma4:12b` (Matt prefers Gemma 4).
  Sampling — qwen3: temp 0.7/top_p 0.8/top_k 20, never greedy,
  `num_ctx >= 16384`; gemma4: temp 1.0/top_p 0.95/top_k 64.
- Key operational findings (details + sources in `docs/research/m0-*.md`,
  dated 2026-07-06): avoid recursive `$ref`/`$defs` in schemas (buggy in
  llama.cpp/Ollama) — ship depth-unrolled inline schemas and ALWAYS
  re-validate client-side; prefer schema-constrained `format` output over
  Ollama's native `tools` path; probe capabilities per
  (model, backend, version) triple — the historical silent-constraint-drop
  bugs (ollama#14645 qwen3, #15260 gemma4, both tied to `think: false`)
  are fixed in the installed 0.31.1 (verified by canary,
  `docs/research/m0-gemma4-canary.md`) but were silent and version-specific,
  so never skip the probe after an Ollama upgrade.

## Conventions

- **Errors are variants, not exceptions**, at every boundary (`result`,
  polymorphic variants for failure cases the caller must handle). Repair
  exhaustion is `` `Unparseable ``, per §8.
- **No shell-shaped escape hatches** — no tool, test helper, or dev utility
  that passes model-derived strings to a shell. §5.1 applies to our own
  tooling too.
- **Security invariants are load-bearing** (§13): planner input is
  `Trusted.text` only; repair prompts never echo the invalid payload;
  `Secret.t` has no serializer. Run the `security-reviewer` agent after
  touching the interpreter, provenance, wire layer, or any parser.
- **Ported code** (eventsource-parser, llguidance translation layer, …) goes
  through the `/port` skill: upstream tests as oracle + differential fuzzing.
  No exceptions — §13.10.
- Keep user-facing API to plain variants + records; GADTs/phantom types stay
  inside the library (§10).
- `docs/research/` holds dated research notes with sources; check there before
  re-researching ecosystem questions.

## Layout

- `src/occamel/` — core library (plan DSL, interpreter, effects, provenance)
- `test/` — tests (alcotest + qcheck once deps land)
- `docs/research/` — dated ecosystem research notes
- `occamel-design-doc.md` — normative design (see above)
