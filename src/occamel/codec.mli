(* Shared JSON decoding runtime. ppx-generated codecs and hand-written ones
   (Plan) both call into here. One structured error shape everywhere, so the
   repair loop (§8) always has something to work with. *)

(* Failure category. Note the split: [code] is payload-free and safe to show a
   model; [msg] may contain attacker/model bytes and is LOCAL-only (traces,
   logs). The repair prompt uses [safe_message] (code + path), never [msg]. *)
type code =
  | Invalid_json
  | Missing_field
  | Unexpected_field
  | Type_mismatch
  | Out_of_bounds
  | Bad_enum
  | Duplicate_field
  | Refinement_failed
  | Other

type error = { path : string; msg : string; code : code }

val error_to_string : error -> string
(** Full local rendering (path + msg) — for logs/traces, NOT for a model. *)

val safe_message : error -> string
(** Payload-free rendering (path + category phrase) — safe for a repair
    prompt (§13.8): reveals nothing of the invalid payload. *)

val err : ?code:code -> string -> string -> ('a, error) result
val err_bad_enum : string -> kind:string -> string -> ('a, error) result

val ( let* ) : ('a, 'e) result -> ('a -> ('b, 'e) result) -> ('b, 'e) result
(** Result-bind, exported so codecs can [open Codec] and use let-syntax. *)

(* Primitive decoders: [path] is the JSON path used in error messages. *)
val field : string -> string -> Yojson.Safe.t -> (Yojson.Safe.t, error) result
val field_opt : string -> string -> Yojson.Safe.t -> (Yojson.Safe.t option, error) result
val as_string : string -> Yojson.Safe.t -> (string, error) result
val as_int : string -> Yojson.Safe.t -> (int, error) result
val as_float : string -> Yojson.Safe.t -> (float, error) result
val as_bool : string -> Yojson.Safe.t -> (bool, error) result
val as_list : string -> Yojson.Safe.t -> (Yojson.Safe.t list, error) result
val as_option :
  (string -> Yojson.Safe.t -> ('a, error) result) ->
  string -> Yojson.Safe.t -> ('a option, error) result
val nonempty_string : string -> Yojson.Safe.t -> (string, error) result
val bounded_int : ?min:int -> ?max:int -> string -> Yojson.Safe.t -> (int, error) result

val no_extra_fields : string -> string list -> Yojson.Safe.t -> (unit, error) result
(** Rejects any key not in the allowed list AND duplicate keys, so a first-wins
    decode can't disagree with an all-keys validator (F5). *)

val map_result :
  (string -> 'a -> ('b, error) result) -> int -> string -> 'a list -> ('b list, error) result
val list_of :
  (string -> Yojson.Safe.t -> ('a, error) result) ->
  string -> Yojson.Safe.t -> ('a list, error) result

val refine : ('a -> ('a, string) result) -> string -> 'a -> ('a, error) result
(** The §3.3 refinement hook: run a user check after structural parsing. *)

val of_string :
  of_json:(Yojson.Safe.t -> ('a, error) result) -> string -> ('a, error) result
(** Parse a string then decode. Enforces §13.8 size and nesting limits and
    converts a Stack_overflow into a structured error before touching Yojson —
    a hostile endpoint can't crash the agent with deeply-nested JSON. *)
