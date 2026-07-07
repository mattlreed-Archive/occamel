// Differential-fuzz runner: drives the ORIGINAL eventsource-parser (TS) on
// JSONL test cases and prints normalized output sequences, one JSON array
// per case, for comparison against the OCaml port (see diff_fuzz.ml).
//
// Usage:
//   node runner.mjs /path/to/eventsource-parser/src/parse.ts < cases.jsonl > expected.jsonl
//
// The upstream clone must be pinned at 83db3dec52a3494e22ee7e6eb4e1349380f75e36
// (v3.1.0). Node >= 23 executes the TypeScript source directly (type stripping).
//
// Case format (one JSON object per line):
//   {"chunks": ["<hex bytes>", ...], "max": <int|null>, "consume": <bool>}
//
// Bytes are carried as hex and decoded latin1 so that JS string code units
// are exactly the wire bytes the OCaml port sees (UTF-8 decoding would make
// invalid-UTF-8 inputs unrepresentable and U+FEFF ambiguous — see
// docs/ports/eventsource-parser.md).
//
// Normalized outputs (must match diff_fuzz.ml's `norm`):
//   event <id-hex|-> <type-hex|-> <data-hex>
//   retry <n|BIG>          (BIG when > 1e15: JS floats vs OCaml ints diverge there)
//   comment <hex>
//   error invalid-retry <value-hex> <line-hex>
//   error unknown-field <field-hex> <value-hex> <line-hex>
//   error max-buffer
import {createInterface} from 'node:readline'
import {pathToFileURL} from 'node:url'

const srcPath = process.argv[2]
if (!srcPath) {
  console.error('usage: node runner.mjs /path/to/eventsource-parser/src/parse.ts')
  process.exit(2)
}
const {createParser} = await import(pathToFileURL(srcPath).href)

const hex = (latin1) => Buffer.from(latin1, 'latin1').toString('hex')
const unhex = (h) => Buffer.from(h, 'hex').toString('latin1')

const results = []
const rl = createInterface({input: process.stdin, terminal: false})
for await (const line of rl) {
  if (!line.trim()) continue
  const c = JSON.parse(line)
  const out = []
  const parser = createParser({
    onEvent: (e) =>
      out.push(
        [
          'event',
          e.id === undefined ? '-' : hex(e.id),
          e.event === undefined ? '-' : hex(e.event),
          hex(e.data),
        ].join(' '),
      ),
    onRetry: (ms) => out.push(`retry ${ms > 1e15 ? 'BIG' : String(ms)}`),
    onComment: (comment) => out.push(`comment ${hex(comment)}`),
    onError: (err) => {
      if (err.type === 'invalid-retry') {
        out.push(`error invalid-retry ${hex(err.value ?? '')} ${hex(err.line ?? '')}`)
      } else if (err.type === 'unknown-field') {
        out.push(
          `error unknown-field ${hex(err.field ?? '')} ${hex(err.value ?? '')} ${hex(err.line ?? '')}`,
        )
      } else {
        out.push('error max-buffer')
      }
    },
    maxBufferSize: c.max ?? undefined,
  })
  for (const chunk of c.chunks) {
    try {
      parser.feed(unhex(chunk))
    } catch (err) {
      // ONLY the post-overflow termination throw is an expected divergence
      // (the OCaml port's typed-state equivalent is a silent no-op). Any
      // other thrown error is a real behavioral difference the port would
      // NOT reproduce — surface it instead of masking it as a match.
      if (!/max buffer size/.test(err?.message ?? '')) throw err
    }
  }
  if (c.consume) {
    parser.reset({consume: true})
  }
  results.push(JSON.stringify(out))
}
process.stdout.write(results.join('\n') + (results.length ? '\n' : ''))
