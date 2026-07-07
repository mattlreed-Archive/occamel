# Gemma 4 canary results (local verification)

Date: 2026-07-06 · Ollama 0.31.1 (brew) · macOS, M4 Pro 24GB

Matt prefers Gemma 4 models; this note verifies them for M0 alongside qwen3
and updates the thinking-mode guidance from `m0-ollama-structured-outputs.md`
and `m0-qwen3-constrained.md` with locally observed behavior.

## Models pulled

| model | size | notes |
|---|---|---|
| `qwen3:14b` | 9.3 GB | dense, thinking-capable |
| `gemma4:12b` | 7.6 GB | dense, 256K ctx, thinking-capable (new in Gemma 4) |

Not pulled: `gemma4:26b` MoE (18 GB — fits 24 GB unified but squeezes the GPU
allocation; quality fallback only), `gemma4:31b` (20 GB — not realistic here).

## Canary matrix (single canary each — smoke test, not conformance proof)

Schema: `{action: enum[search,answer], payload: string}`, strict,
`additionalProperties: false`.

| model | path | thinking | result |
|---|---|---|---|
| qwen3:14b | `/v1` `response_format` | default | ✅ conformant (13 completion tokens) |
| qwen3:14b | `/api/chat` `format` | `think: false` | ✅ conformant — **bug #14645 not reproduced on 0.31.1** |
| gemma4:12b | `/v1` `response_format` | default (on) | ✅ conformant |
| gemma4:12b | `/api/chat` `format` | `think: false` | ✅ conformant — **bug #15260 not reproduced on 0.31.1** |

## Implications for M0

- **Both silent-constraint-drop bugs (ollama#14645 qwen3, ollama#15260 gemma4)
  appear fixed in 0.31.1.** The web research (reported against 0.20.0) is
  stale on this point for the local install.
- **The durable lesson is unchanged and strengthened**: these failures were
  version-specific, model-specific, and silent. Capability probing must run
  per (model, backend, version) triple, and the M0 probe stays mandatory —
  a passing canary today says nothing about the next `brew upgrade ollama`.
- Gemma 4 sampling per model card: temp 1.0 / top_p 0.95 / top_k 64.
  Qwen3 per Qwen docs: temp 0.7 / top_p 0.8 / top_k 20, never greedy.
- M0 eval should run both models as planned; thinking on/off is now a free
  variable on 0.31.1 rather than a bug workaround, so measure both if cheap
  (thinking off is faster; thinking on may plan better).
