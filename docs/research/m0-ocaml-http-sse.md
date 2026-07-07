# M0 research: OCaml HTTP client stack and SSE parsing (eio)

Date: 2026-07-06

Scope: pre-implementation research for `occamel.wire` — an eio-based HTTP/SSE client layer for
OpenAI-compatible and Anthropic endpoints (streaming POST, `data:`/named-event SSE framing,
retries, timeouts, TLS to hosted providers, plain http to local Ollama). All versions verified
against live opam/GitHub pages on 2026-07-06.

## 1. eio

- **Current release: v1.3**, published 2025-07-20 (GitHub release; the opam page lists 24 Jul 2025).
  Sources: https://ocaml.org/p/eio/latest, https://github.com/ocaml-multicore/eio/releases
- **OCaml compatibility: `ocaml >= 5.2.0`, no upper bound.** OCaml 5.4.0 was released 2025-10-09
  (https://ocaml.org/releases/5.4.0) and eio 1.3 installs against it; the repo is actively
  maintained — commits merged to `main` as recently as **2026-07-06** (getaddrinfo error
  reporting, `chown` flags). Source: https://github.com/ocaml-multicore/eio/commits
- **API stability:** post-1.0 the core client-facing surface (`Eio.Flow`, `Eio.Buf_read`,
  `Switch`, `Eio_main`) has had **no breaking changes**. v1.3 was a bugfix release (POSIX/FreeBSD
  error handling, Windows stdin/EPIPE); v1.2's only signature change was making some
  `Eio_unix.Net` return types *more* polymorphic. Source:
  https://github.com/ocaml-multicore/eio/blob/main/CHANGES.md
- Relevant for SSE: `Eio.Buf_read.line` strips both `\n` and `\r\n` terminators, so LF/CRLF
  handling comes free when parsing line-by-line.

## 2. cohttp-eio

- **Current version: 6.2.1**, released 2025-12-16 (in lockstep with cohttp/http 6.2.1).
  Sources: https://ocaml.org/p/cohttp-eio/latest, https://github.com/mirage/ocaml-cohttp/releases
- **Client maturity:** the 6.x line is a complete rewrite of cohttp-eio behind the common
  `Cohttp.Generic.Client` interfaces (mefyl #984, talex5 #1002). It is no longer flagged
  experimental on the opam page, and 6.2.0 (2025-12-02) added client-side forward-proxy support —
  i.e. the client is receiving feature work, not just maintenance. Source:
  https://github.com/mirage/ocaml-cohttp/blob/master/CHANGES.md
- **TLS is NOT out of the box.** `Cohttp_eio.Client.make` takes
  `~https:(Uri.t -> two_way flow -> two_way flow) option`; with `~https:None` any https URI is
  rejected. The caller must wire the wrapper manually: initialize `Mirage_crypto_rng`, build an
  authenticator with `Ca_certs.authenticator ()`, create a `Tls.Config.client`, and wrap with
  `Tls_eio.client_of_flow`. This is exactly what `tmattio/ocaml-anthropic` does (~30 lines,
  `default_https` in `lib/anthropic.ml` lines 260–315). Certificate validation therefore works,
  but only if you wire it. Sources:
  https://ocaml.org/p/cohttp-eio/latest/doc/Cohttp_eio/Client/index.html,
  https://github.com/tmattio/ocaml-anthropic/blob/main/lib/anthropic.ml
- **Streaming reads:** the response body is an Eio flow (`Body.t`); the idiom is
  `Eio.Buf_read.of_flow ~max_size body |> Eio.Buf_read.line` in a loop (or `take_all` for
  non-streaming). Chunked transfer decoding is handled by the library — ocaml-anthropic reads
  SSE lines directly off the body flow of Anthropic's chunked streaming responses and it works
  in practice.
- **Pitfalls:** docs warn to "consume the response body in a timely fashion" (the connection is
  tied to a `Switch`); there is **no built-in timeout** (wrap calls in
  `Eio.Time.with_timeout`); there is **no connection pooling/reuse** across requests — each
  `call` dials a new connection. Retries/backoff are also on the caller (ocaml-anthropic
  implements retry-with-`retry-after` itself, `lib/anthropic.ml` lines 340–460).

## 3. piaf and other contenders

- **piaf 0.2.0**, released 2024-09-06, **is eio-native** (the lwt-to-eio port shipped in 0.2.0;
  depends on `eio_main >= 1.0`, `ocaml >= 5.1`). HTTP/1.1 (via httpun-eio) **and HTTP/2** (via
  h2-eio); **TLS out of the box** via `ssl`/`eio-ssl` — note this is **OpenSSL bindings**, a C
  dependency, not ocaml-tls. Streaming body API exists and is reasonable:
  `Piaf.Body.to_stream` (`Bigstringaf.t IOVec.t Stream.t`), `to_string_stream`, `fold`, `iter`.
  Sources: https://ocaml.org/p/piaf/latest, https://github.com/anmonteiro/piaf,
  https://ocaml.org/p/piaf/latest/doc/Piaf/Body/index.html
- **piaf maintenance:** last release Sep 2024; last master commit **Oct 2025** ("fix wscat
  example") with the bulk of 2025 activity in January. Docs are thin (README says "read the mli
  file for now"). Alive but slow-cadence.
- **httpun / httpun-eio 0.2.0** (Sep 2024; last commit Nov 2024): anmonteiro's http/af
  successor. It does support client use (it is piaf's HTTP/1.x engine), but it is a low-level
  protocol library — connection management, TLS, redirects, pooling are all on you. Not a
  direct fit for occamel.wire; use it only via piaf. Source: https://ocaml.org/p/httpun-eio/latest
- **curl-based (ezcurl, ocurl, cohttp-curl):** blocking or lwt/async integrations only; no eio
  bridge exists. Would require running curl calls in `Eio_unix.run_in_systhread` or a domain —
  workable but awkward for incremental SSE deltas. Not recommended.
- **http-lwt-client / httpcafe (robur):** lwt-based, not eio. Out of scope.
- **ocaml-requests (Anil Madhavapeddy, Dec 2025):** an eio-based "batteries-included" client
  (pooling, redirect handling, TLS) synthesized agentically from a 50-client survey. The
  author himself says it needs line-by-line human review before adoption, and it is **not on
  opam** and no public repo was found as of today. A signal of where the ecosystem wants to go,
  not a dependency candidate. Source: https://anil.recoil.org/notes/aoah-2025-13

### Comparison

| | cohttp-eio 6.2.1 | piaf 0.2.0 | httpun-eio 0.2.0 | curl-based (ezcurl/ocurl) |
|---|---|---|---|---|
| eio-native | yes | yes | yes | no (blocking/lwt) |
| HTTP/1.1 client | yes | yes | yes (low-level) | yes |
| HTTP/2 | no | yes | no (h2 is separate) | via libcurl |
| TLS out of the box | **no** — manual tls-eio + ca-certs wiring | yes (OpenSSL via eio-ssl) | no (bring your own) | yes (system TLS) |
| Pure-OCaml TLS option | yes (ocaml-tls) | no (links OpenSSL) | yes | no |
| Streaming body read | Eio flow -> `Buf_read` (line-by-line) | `Body.to_stream` / `iter` | direct `Body.Reader` callbacks | callback chunks, no eio backpressure |
| Timeouts built in | no (`Eio.Time.with_timeout`) | partial (config) | no | yes (libcurl) |
| Connection reuse | no | yes (pooling, redirects) | manual | yes |
| Last release | 2025-12-16 | 2024-09-06 | 2024-09-04 | — |
| Maintenance | active (mirage org) | slow (last commit 2025-10) | quiet since 2024-11 | active upstream |
| Proven for LLM SSE | yes (ocaml-anthropic) | no known example | no known example | no known example |

## 4. SSE in OCaml

- **No SSE/eventsource package exists on opam.** Searches for "sse" and "eventsource" on
  https://ocaml.org/packages/search?q=sse and ...?q=eventsource return nothing relevant (hits
  are ppx_assert, dnssec, etc.).
- **How ocaml-anthropic does it** (https://github.com/tmattio/ocaml-anthropic,
  `lib/anthropic.ml` lines ~789–828): a hand-rolled loop over `Eio.Buf_read.line`:
  - blank line dispatches the accumulated event; `String.split_on_char ':'` on each line;
    `event:` and `data:` field values are `String.trim`-ed and appended to buffers; everything
    else (`id`, `retry`, comment lines) is ignored; events are pushed to an
    `Eio.Stream.create 16` from a forked fiber.
  - **Spec deviations** (all fine for Anthropic's actual output, but not spec-exact):
    `String.trim` strips trailing space and *all* leading spaces (spec: strip at most one
    leading space); multi-line `data:` fields are concatenated **without** the `\n` joiner the
    spec requires; no UTF-8 BOM handling; no bare-`\r` line-ending support; no `retry:`/`id:`
    semantics; a comment line containing a colon-suffixed field name would still be misparsed
    if it matched `event`/`data` after the first split.
- **Idiom and pitfalls for a Buf_read-based parser:** `Buf_read.line` covers LF and CRLF (bare
  CR, allowed by the WHATWG spec, is not covered — negligible for LLM providers); the parser
  must handle: comment lines starting `:` (OpenAI sends `: ping`-style keepalives on some
  endpoints), multi-line `data:` joined with `\n`, at-most-one leading space stripped from
  field values, a possible UTF-8 BOM before the first event, OpenAI's `data: [DONE]` sentinel,
  and Anthropic's named events (`event: content_block_delta` + `data: {...}` pairs, plus
  `event: ping` and `event: error`).
- **Conclusion: porting `eventsource-parser`** (https://github.com/rexxars/eventsource-parser)
  **remains the right call.** Nothing on opam can be depended on, and the one in-ecosystem
  implementation (ocaml-anthropic) is ad hoc and spec-divergent. The port is small (the TS
  library is a single-file state machine) and gives spec-exact behavior for both framings. One
  design note: eventsource-parser is a *push* parser fed arbitrary chunks; on eio it is equally
  valid to write it *pull*-style over `Buf_read.line`, keeping the same field-processing state
  machine but letting Buf_read own chunk reassembly. Either way, keep the parser
  transport-agnostic (string chunks or lines in, events out) so it is testable without I/O.

## 5. Ecosystem signals

- **tmattio/ocaml-anthropic** (opam `anthropic` 0.1.0, Jul 2025): cohttp-eio + tls-eio +
  ca-certs + mirage-crypto-rng, `Buf_read`-based SSE, hand-rolled retries honoring
  `retry-after`/`retry-after-ms`. The strongest existence proof that the cohttp-eio client
  works against a hosted LLM streaming API in production-ish conditions.
  Sources: https://ocaml.org/p/anthropic/latest, https://github.com/tmattio/ocaml-anthropic
- **ahrefs/ocaml-ai-sdk** (OCaml port of Vercel's AI SDK; OpenAI + Anthropic, streaming SSE,
  tool calling): very active — pushed **2026-07-06** — but its native transport is
  **cohttp-lwt-unix** (lwt), not eio. Signal: cohttp remains the default transport choice for
  OCaml LLM clients; nobody prominent has bet on piaf for this.
  Source: https://github.com/ahrefs/ocaml-ai-sdk
- discuss.ocaml.org's substantive client-comparison threads ("Choosing a HTTP client library"
  #7998, "Simple, modern HTTP client library?" #11239) date from 2022–2023 and predate the
  cohttp-eio 6.x rewrite; no 2025–2026 recommendation thread was found. The freshest 2025
  commentary is Anil's aoah-2025-13 note, which implicitly confirms no batteries-included eio
  client exists yet.

## Implications for M0

- **Use cohttp-eio 6.2.1 for M0's minimal Ollama client.** Rationale: M0 talks plain
  `http://localhost:11434`, so cohttp-eio's one real weakness (manual TLS wiring) is moot —
  `Client.make ~https:None env#net` is the entire setup. It is the most recently released and
  most actively maintained eio client, it lives in the mirage org (low abandonment risk), its
  body-as-Eio-flow model plugs directly into `Buf_read` for line-oriented SSE, and
  ocaml-anthropic proves the exact stack (cohttp-eio + Buf_read SSE) against a real LLM
  streaming API.
- **TLS at M5:** budget a small `occamel.wire.tls` shim: `mirage-crypto-rng-eio` init +
  `ca-certs` authenticator + `tls-eio` wrapper passed as `~https` (copy the shape of
  ocaml-anthropic's `default_https`). This keeps the stack pure-OCaml (no OpenSSL). Add the
  deps (`tls-eio >= 1.0`, `ca-certs >= 1.0`, `mirage-crypto-rng`) to the opam file at M5, not M0.
- **Own the missing pieces from day one, since no client provides them on eio:** timeouts via
  `Eio.Time.with_timeout` around connect/first-byte and an inter-chunk idle timeout inside the
  SSE read loop; retries/backoff in occamel.wire (honor `retry-after`); accept one TCP
  connection per request for now (fine for an agent loop's request cadence).
- **Keep piaf as the documented fallback**, to be revisited if M5+ needs HTTP/2, connection
  pooling, or built-in redirects — at the cost of an OpenSSL C dependency and a slower-moving
  upstream. The wire API should hide the client behind a small signature (request -> response
  status/headers + chunk source) so swapping is cheap.
- **Port eventsource-parser: yes.** No opam alternative exists; the only prior art is ad hoc.
  Implement it as a pure, transport-agnostic state machine (chunks/lines in, `{event; data; id;
  retry}` records out), spec-exact per WHATWG (single-leading-space strip, `\n` join for
  multi-line data, comment lines, BOM), with the OpenAI `[DONE]` sentinel and Anthropic named
  events handled a layer above the parser.

## Uncertainty notes

- Version/date figures were cross-checked against the GitHub API on 2026-07-06; opam-page
  summaries were read via an extraction model and may paraphrase. One known discrepancy: the
  opam page shows eio 1.3 as "24 Jul 2025" while the GitHub release is 2025-07-20 (likely
  opam-repository merge lag; immaterial).
- cohttp-eio connection behavior (no reuse/pooling) is inferred from the API shape
  (`call ~sw` dialing per request) and the 2023-era design discussion, not from an explicit
  statement in current docs — verify with a quick two-request trace against Ollama in M0.
- piaf master may contain unreleased improvements beyond 0.2.0 (256 commits on master); if
  piaf is ever adopted, pin a commit rather than the 2024 release.
- eio 1.3 + OCaml 5.4 compatibility is asserted from the open-ended opam bound and active repo
  CI, not from a release explicitly testing 5.4; no issues were found, but confirm in CI when
  choosing the compiler version.
- Anil Madhavapeddy's `ocaml-requests` may be published on opam later in 2026; if it ships
  reviewed, it would be a direct competitor to this plan's hand-rolled retry/timeout layer.
- No 2025–2026 discuss.ocaml.org comparison thread was found; community-preference claims rest
  on project archaeology (which libraries real LLM clients chose), not stated consensus.
