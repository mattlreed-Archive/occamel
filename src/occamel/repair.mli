(* The §8 repair loop: validate → structured error → bounded re-prompt →
   `Unparseable as a caller-visible variant. Backend-agnostic (no HTTP).

   §13.8 by construction: the repair message is built ONLY from the structured
   error's category+path (Codec.safe_message) and the schema — never the
   invalid payload. An injection that deliberately fails validation gets no
   fragment of its own payload re-presented. *)

type 'e failure =
  [ `Unparseable of Codec.error list  (** one error per failed attempt, in order *)
  | `Backend of 'e ]

val repair_message : schema:Yojson.Safe.t -> Codec.error -> string

val run :
  ?max_repairs:int ->
  ask:(extra:string list -> (string, 'e) result) ->
  parse:(string -> ('a, Codec.error) result) ->
  schema:Yojson.Safe.t ->
  unit ->
  ('a * Codec.error list, 'e failure) result
(** Returns the parsed value plus the errors of the failed attempts before it
    (empty list = first try succeeded). [ask ~extra] appends the repair
    messages to the model context. *)
