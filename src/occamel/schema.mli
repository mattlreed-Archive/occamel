(* Occamel's JSON-Schema SUBSET — the "T2 intersection dialect" (§7.1) that
   hosted structured-output modes accept, and that the ppx emits. Not a general
   JSON Schema implementation. *)

type t = Yojson.Safe.t

val member : string -> t -> Yojson.Safe.t option
val with_kvs : t -> (string * Yojson.Safe.t) list -> t
(** Layer extra keys (description/default/minimum…) onto an object schema —
    used by ppx-generated code to attach attribute metadata. *)

(* A schema paired with its parser — what an [Ask] (§6.1) is typed by. The ppx
   emits a [<name>_typed] value per derived type. *)
type 'a typed = {
  name : string;
  schema : t;
  parse : string -> ('a, Codec.error) result;
}

val hash : t -> string
(** Stable content hash — trace replay fails loudly on a schema-hash change. *)

val validate : t -> Yojson.Safe.t -> (unit, string) result
(** Validate a value against a schema in OUR dialect. Used by the §7.3 round-trip
    property tests and by typed-arg/extraction checking. *)

val complexity : t -> int
(** Heuristic for the §7.1 compile-time "may exceed provider grammar limits"
    warning (optional fields + union fan-out + nesting). *)

val warn_threshold : int

(* ── channel width (§13.2 — the measured injection residual) ──────────────
   How many bits an attacker can inject through an extraction INTO a schema.
   Under-reporting would hide a channel, so every ambiguous case is Unbounded. *)
type width = Bits of float | Unbounded

val channel_width : t -> width
(** enum = log2 n, bool = 1, bounded int = log2 range, object = sum of fields;
    free string / number / array / open object = Unbounded. *)

val width_to_string : width -> string

val extraction_lint :
  from_untrusted:bool -> reaches_sink:bool -> t -> string option
(** Advisory: warns when an unbounded-width extraction from untrusted data
    reaches a capability sink, with a named fix (narrow the schema). *)
