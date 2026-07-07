(* The provenance lattice (design doc §6.3) — the heart of strict mode's
   runtime guarantee. Every strict value carries a SET of sources describing
   where its data came from. A value is trusted iff every source is User or
   Static; any Tool_result / Extracted / Branch makes it untrusted. Sets join
   along data flow (union) and control flow (add_branch). *)

type site = string
(** A stable label for a plan location (a bind name, or "if"/"foreach"). *)

type source =
  | User  (** the original trusted request *)
  | Static  (** author-controlled constants (prompts, tool specs) *)
  | Tool_result of site
  | Extracted of { from : site; schema : string }
  | Branch of site  (** control-flow taint from a conditional/loop scrutinee *)

type t
(** A source set. *)

val empty : t
val user : t
val static : t
val tool_result : site -> t
val extracted : from:site -> schema:string -> t
val of_list : source list -> t
val to_list : t -> source list

val join : t -> t -> t
(** Data-flow join (set union). Cannot lose taint. *)

val join_all : t list -> t

val add_branch : site -> t -> t
(** Add control-flow taint (a Branch source) — used inside untrusted
    if/foreach bodies. *)

val is_trusted : t -> bool
(** True iff every source is User or Static. THE policy in one line. *)

val extracted_froms : t -> string list
(** The [from] site of every Extracted source — which extractions a value
    derives from (used by the channel-width lint, §13.2). *)

val to_string : t -> string
val to_json : t -> Yojson.Safe.t
