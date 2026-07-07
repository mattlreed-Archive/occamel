(* Typed trace events (§9). Both modes serialize every effect here, to JSONL.
   Buys golden tests (record once, replay offline forever), integrity (HMAC),
   and replay. *)

type event =
  | Ask_response of {
      ctx_hash : string;
      schema_name : string;
      schema_hash : string;
      content : string;
    }
  | Plan_generated of { prompt_hash : string; plan : Yojson.Safe.t }
  | Plan_admitted of { verdict : string }
  | Extraction of {
      site : string;
      question : string;
      source_hash : string;
      output : string;
      prov : Yojson.Safe.t;
    }
  | Tool_call of {
      tool : string;
      args_schema_hash : string;
      args : Yojson.Safe.t;
      result : Yojson.Safe.t;
      ms : int;
    }
  | Tool_failed of {
      tool : string;
      args_schema_hash : string;
      args : Yojson.Safe.t;
      error : string;
    }
  | Approval of { tool : string; decision : string }
  | Note of string

type t = event list

val register_scrubber : (string -> string) -> unit
(** Register a write-time redactor run over every string field (§13.7). *)

val save : t -> string -> unit
(** Redact, write JSONL, and append an HMAC [#sig] line when
    OCCAMEL_TRACE_KEY is set. *)

type integrity = Verified | Unsigned | Bad_signature

val load : string -> (t, string) result
(** Load, dropping the integrity tag (accepts Unsigned). *)

val load_checked : string -> (t * integrity, string) result

val load_verified : string -> (t, string) result
(** REQUIRE a valid signature — rejects unsigned and tampered traces. For any
    integrity-sensitive caller (e.g. replay-into-live). *)
