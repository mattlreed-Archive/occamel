(** Streaming, transport-agnostic Server-Sent Events (SSE) parser.

    A pure, spec-exact port of [eventsource-parser] v3.1.0
    (https://github.com/rexxars/eventsource-parser, MIT, pinned at commit
    83db3dec52a3494e22ee7e6eb4e1349380f75e36) per design-doc Appendix C.
    Provenance, deliberate divergences, and fuzzing record:
    [docs/ports/eventsource-parser.md].

    The parser is a fold over byte chunks: feed it arbitrary slices of the
    wire stream (splits may land mid-line, mid-field, even mid-UTF-8-rune)
    and it emits completed SSE events, retry intervals, comments, and typed
    parse errors in stream order. It performs no I/O and raises no
    exceptions.

    Per WHATWG (https://html.spec.whatwg.org/multipage/server-sent-events.html):
    [data]/[event]/[id]/[retry] fields, comment lines, [LF]/[CR]/[CRLF] line
    terminators, one leading UTF-8 BOM, multi-line data accumulation joined
    with [LF]. Interpretation of the [data] payload (e.g. OpenAI's [[DONE]]
    sentinel, JSON deltas) belongs to the layer above; this module is framing
    only. *)

type event = {
  id : string option;
      (** Last [id:] field of the event, if any. [None] when absent or when
          the value contained a NUL byte (ignored per spec). *)
  event_type : string option;
      (** Last [event:] field of the event. [None] when absent or empty —
          note: not defaulted to ["message"], mirroring upstream (browsers
          default it). *)
  data : string;  (** [data:] lines joined with [\n]. *)
}
(** A parsed SSE event. Dispatched at each blank line, and only when at
    least one [data] line was seen (an event consisting solely of
    [id:]/[event:] fields is dropped, per spec). *)

type error =
  | Invalid_retry of { value : string; line : string }
      (** A [retry:] field whose value is not all ASCII digits (the field is
          ignored per spec; surfaced so callers can log). *)
  | Unknown_field of { field : string; value : string; line : string }
      (** A field name other than [data]/[event]/[id]/[retry] (ignored per
          spec; surfaced so callers can detect non-SSE responses, e.g. a JSON
          error body). *)
  | Buffer_limit_exceeded of { limit : int }
      (** The combined size of the buffered partial line and the
          accumulated event data exceeded [max_buffer_size] (§13.8 resource
          bound). The parser drops its buffers and becomes terminated:
          subsequent {!feed}s are no-ops until {!reset}. *)

type output =
  | Event of event
  | Retry of int
      (** Reconnection interval in milliseconds from a valid [retry:] field.
          Values that would overflow [int] saturate to [max_int]. *)
  | Comment of string
      (** A [:]-prefixed comment line, with the colon and at most one
          following space stripped (e.g. keep-alive heartbeats). *)
  | Parse_error of error

type t
(** Immutable parser state. Feeding returns a new state; old states remain
    valid (the fold is persistent). *)

val create : ?max_buffer_size:int -> unit -> t
(** A fresh parser for one stream.

    [max_buffer_size] bounds, in bytes, the sum of (a) a partial line not
    yet terminated and (b) the accumulated multi-line event data — the two
    surfaces that grow {e across} [feed] calls. On overflow the parser emits
    [Parse_error (Buffer_limit_exceeded _)] once, drops its buffers, and
    terminates (§13.8).

    Two limits to the guarantee, faithful to upstream, that the wire layer
    must close for full §13.8 compliance:
    - The check runs once per [feed], {e after} the chunk is processed, so
      retained bytes can transiently exceed [max_buffer_size] by up to one
      whole chunk (a single oversized chunk containing a complete event is
      dispatched before the check fires). Callers must therefore also bound
      transport read sizes — this is a "max retained buffer" control, not a
      "max event size" one on its own.
    - The [id] and [event_type] buffers are {e not} counted (they hold a
      single field value each, bounded by one line, and cannot accumulate
      across data lines).

    A non-positive [max_buffer_size] rejects everything: the first [feed]
    (even of [""]) overflows and terminates — fail-closed, deliberate.

    Default: unbounded, mirroring upstream. Wire-layer call sites (the
    streaming clients) MUST pass this; it is optional only so the pure
    parser stays usable in tests. *)

val feed : t -> string -> t * output list
(** [feed t chunk] consumes the next slice of the byte stream and returns
    the successor state plus outputs completed by this chunk, in stream
    order. Chunk boundaries are immaterial: bytes that do not yet form a
    complete line are buffered inside [t]. Feeding a terminated parser
    (after [Buffer_limit_exceeded]) returns [t] unchanged with no outputs —
    a typed-state divergence from upstream, which throws. *)

val reset : ?consume:bool -> t -> t * output list
(** [reset t] returns a fresh parser with the same [max_buffer_size] —
    required between reconnections. With [~consume:true], a buffered
    incomplete line is first parsed as if newline-terminated, and any
    resulting outputs (typically [Parse_error] for a non-SSE body, possibly
    [Retry]/[Comment]; never [Event]) are returned. *)

val is_terminated : t -> bool
(** [true] after a [Buffer_limit_exceeded]; cleared by {!reset}. *)
