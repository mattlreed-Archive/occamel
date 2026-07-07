# M0 Research: State of the `anthropic` opam package (tmattio/ocaml-anthropic)

Date: 2026-07-06

## 1. Released version and dependencies

- Latest opam release: **0.1.0**, published to opam-repository **28 Jul 2025** (GitHub release tag 0.1.0 dated 18 Jul 2025). It is still the only release as of today. Source: https://ocaml.org/p/anthropic and https://opam.ocaml.org/packages/anthropic/
- Repo: https://github.com/tmattio/ocaml-anthropic (found via opam metadata; note it is `ocaml-anthropic`, not `anthropic`). License ISC.
- Constraints and transport (from the opam page / repo):
  - `ocaml >= 5.2`, `dune >= 3.19`, `eio >= 1.2`
  - HTTP transport: **cohttp / cohttp-eio** (no version constraint on cohttp-eio listed), with `tls >= 2.0.1`, `tls-eio`, `ca-certs`, `mirage-crypto-rng` for TLS
  - JSON: `yojson` + `ppx_deriving_yojson`; logging via `logs`
  - Not piaf, not httpun — plain cohttp-eio.

## 2. Repository activity and maintenance

- **Last push: 2025-07-18** (GitHub API `pushed_at`), i.e. dormant for ~12 months as of 2026-07-06.
- Entire history is **10 commits over one week (2025-07-12 to 2025-07-18)**: initial commit, helpers, logging, release polish, and a final `feat: Support Oauth authentication`.
- **0 open issues, 0 closed issues, 0 PRs, 0 forks, 5 stars.** Maintainer responsiveness is therefore untested — there has never been an external issue or PR to respond to.
- Thibaut Mattio himself is active on GitHub in 2026 (pushes to other repos through May 2026, opam-repository activity in March 2026), so the account is live; this specific package has simply had no post-release activity. He also maintains **tmattio/ocaml-mcp** (OCaml Model Context Protocol implementation, last push Aug 2025) and **ocaml-jsonschema**, both potentially relevant to Occamel.
- Sources: https://github.com/tmattio/ocaml-anthropic, GitHub API (`repos/tmattio/ocaml-anthropic`, commits, issues, forks endpoints, queried 2026-07-06).

## 3. API surface (from `lib/anthropic.mli` / `anthropic.ml` on main)

Single-module library (`lib/anthropic.ml` + `.mli`, ~2,600 lines total).

Covered:
- **Messages**: `Messages.send` (sync) and `Messages.send_stream`; params `max_tokens`, `temperature`, `top_k`, `top_p`, `stop_sequences`, `system`, `tools`, `tool_choice`, `metadata`. Also `iter_stream` (callback wrapper) and `accumulate_stream` (fold a stream back into a full response).
- **Streaming**: exposed as **`stream_event Eio.Stream.t`** with a bounded capacity of 16 (real backpressure); a fiber forked on the client's `Eio.Switch` reads the HTTP body and pushes parsed events.
- **Tool use**: tool definitions (`name`, `description`, `input_schema : Yojson.Safe.t`, `type_`, `cache_control : Yojson.Safe.t option`), `tool_choice`, tool-result content blocks (`is_error`), plus a `Tools` helper module for execution loops.
- **Batches**: full Batches API module (create/get/results as JSONL stream, request counts, statuses).
- **Models**: models listing endpoint with pagination (`page` type with `get_next_page`).
- **Beta.Files**: beta Files API (upload/list/delete).
- **Retries/errors**: hand-rolled retry loop — `max_retries` (default 2) on the client, `is_retryable` classification, honors `retry-after-ms` / `retry-after` headers, exponential backoff starting at 0.5s, sends `x-stainless-retry-count`. Errors are a typed `error` variant: `Api_error` (with `api_error_type`: invalid_request / authentication / permission / not_found / rate_limit / other), `Http_error`, `Connection_error of exn`.
- **Auth**: API key or OAuth bearer token (`auth_token`), `base_url` override (useful for proxies/compat endpoints).

Not covered / gaps:
- **No token counting** endpoint (`count_tokens` absent).
- **No extended thinking request parameter** (no `?thinking` / budget arg). Stream events do include `Thinking_block` / `Redacted_thinking_block` variants, but they are mis-typed as `{ id : string; name : string }` (copy-paste from tool_use; a real thinking block carries `thinking` text) — an actual bug to fix when extending.
- **No citations** support.
- **`cache_control`** exists only on tool definitions, as raw `Yojson.Safe.t`; not on message content blocks, so prompt caching of system/message content is not really supported.
- **Model type** is a closed polymorphic variant frozen at Claude 4 (May 2025) model IDs, with an `` `Other of string `` escape hatch — usable with any 2026 model via `Other`, but the variant list is stale.

## 4. Structured outputs: not supported, not requested

- Searched the repo code for `output_config`, `output_format`, `response_format`, `strict`: **no hits** for any structured-output feature. The only `strict` occurrences are `ppx_deriving_yojson`'s `{ strict = false }` decoder option (e.g. `lib/anthropic.ml`).
- No issue or PR requesting it exists (the repo has zero issues/PRs of any kind).
- Confirmed against Anthropic docs/ecosystem reports: structured outputs went GA with `output_config.format` (JSON outputs) plus `tools[].strict: true` (schema-guaranteed tool args), superseding the beta `output_format` param and `structured-outputs-2025-11-13` beta header — all of which postdate this package's July 2025 release. Sources: https://platform.claude.com/docs/en/build-with-claude/structured-outputs, https://github.com/Effect-TS/effect/issues/6091, https://github.com/helicone/helicone/issues/5639
- Conclusion: the design doc's premise holds exactly — the package predates structured-outputs GA and needs `output_config` + `strict` added.

## 5. SSE parsing

- **Hand-rolled, no SSE dependency.** Lives inline in `Messages.send_stream` in `lib/anthropic.ml` (~lines 788-827): `Eio.Buf_read.of_flow` on the response body, `Eio.Buf_read.line` loop, accumulates `event:` and `data:` fields into two `Buffer`s, dispatches on blank line to `parse_stream_event` (yojson), pushes onto the bounded `Eio.Stream`. `End_of_file` ends the stream; parse errors are logged and, for `error` events, converted to `Message_stop`.
- Caveats if reusing: it `String.trim`s field values and concatenates multi-line `data:` fields **without** the newline separator the SSE spec requires (fine for Anthropic's single-line JSON events, not spec-complete); `event`/`data` field parsing is `String.split_on_char ':'` rather than a real SSE tokenizer; a parse failure mid-stream silently degrades. The same pattern (not shared code) is reused for Batches JSONL results. It is a good idiom reference for eio + cohttp-eio streaming, but Occamel would want its own small, spec-correct SSE module rather than literal reuse.

## 6. Alternative OCaml Anthropic/LLM clients

- **avsm's `ocaml-claudeio` / `ocaml-claude`** (Anil Madhavapeddy, https://tangled.org/anil.recoil.org/ocaml-claudeio, started Dec 2025 in his "Advent of Agentic Humps" series, https://anil.recoil.org/notes/aoah-2025-4): OCaml/Eio SDK speaking the **Claude Code / Agent SDK JSON-RPC protocol** to the Claude CLI — not the raw HTTP Messages API. Uses `jsont` codecs, includes in-process MCP server support and tool schema helpers. Active as of ~May 2026. Complementary, not a substitute for a direct API client; its `claude.proto` codec-separation design and jsont usage are worth studying. Related: https://github.com/avsm/ocaml-claude-marketplace (Claude Code plugins for OCaml dev).
- **`openai` opam package** (Nymphium/openai-ocaml): stale — 0.0.1 from May 2023, Lwt + ezcurl, OCaml 4.14 era. Not useful as a reference for the M0 OpenAI-compat client. Source: https://opam.ocaml.org/packages/openai/
- **tmattio/ocaml-mcp** (https://github.com/tmattio/ocaml-mcp): OCaml MCP implementation by the same author, last pushed Aug 2025 — relevant if Occamel grows MCP support.
- No other Anthropic-API opam package found; `anthropic` 0.1.0 remains the only direct HTTP client on opam. No `ollama` OCaml bindings package found on opam.

## Implications for M0

M0 needs only the OpenAI-compat client against Ollama; the `anthropic` package matters here in two ways, and the verdict is split:

- **(a) Reference for eio HTTP + SSE idioms: holds, with caveats.** `lib/anthropic.ml` is a clean, compact demonstration of the exact stack Occamel plans to use — cohttp-eio + tls-eio requests, a forked fiber reading the body via `Eio.Buf_read`, a bounded `Eio.Stream.t` (capacity 16) for backpressure, switch-scoped lifecycle, retry-after-aware retries with typed errors. Copy the shape, but write Occamel's SSE parser fresh: the package's parser is not spec-complete (multi-line `data:` joining, field tokenization) and is inlined per call site rather than a reusable module.
- **(b) Validation of the M5 extend-don't-rewrite plan: holds technically, weakened socially.** Technically the codebase is small (~2,600 lines, one module), well-documented, and adding `output_config`, `tools[].strict`, a `thinking` request param, `count_tokens`, and content-level `cache_control` are all straightforward additive changes — extending beats rewriting. Socially, "upstream it" is riskier than the design doc implies: the repo has had zero commits since 2025-07-18, zero issues/PRs ever, and maintainer responsiveness on this repo is unknown (though tmattio is active elsewhere on GitHub in 2026). Plan for the realistic possibility that M5 ships from a fork (or vendored copy) with an upstream PR open in parallel, rather than blocking on an upstream release. Budget for stale-metadata fixes too: the model variant list stops at Claude 4, and the `Thinking_block` stream type is wrong (`{id; name}` instead of thinking text).

## Uncertainty notes

- Maintainer responsiveness (question 2) is genuinely unverifiable: no issue or PR has ever been filed against ocaml-anthropic, so there is no track record either way. Activity on tmattio's other repos in 2026 is indirect evidence he could respond.
- The opam page lists no upper bounds and no explicit cohttp-eio version constraint; I did not resolve which cohttp-eio release the opam solver currently picks, and cohttp-eio's own API has churned — a fresh `opam install anthropic` build on a 2026 switch (OCaml 5.3/5.4, current cohttp) was not tested and could conceivably fail. Worth a 10-minute build check before committing to M5's extend plan.
- Whether any newer beta features (citations request params, newer beta headers) were added post-release is settled by the commit log (nothing after 2025-07-18), but I only read `lib/anthropic.{ml,mli}` from `main` at that commit — there are no other branches I checked.
- The `28 Jul 2025` opam publish date comes from ocaml.org's rendered page; the GitHub release tag is 18 Jul 2025. Both are consistent (tag then opam-repo merge), not a conflict.
- ocaml-claudeio's exact latest commit date is approximate ("2 months ago" per tangled.org on 2026-07-06, so roughly May 2026); tangled.org does not render precise timestamps in the fetched view.
