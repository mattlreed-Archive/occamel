(* The plan DSL (design doc §5.2) — the privileged planner's ENTIRE output is a
   value of [t]. Small on purpose: every constructor is surface the planner can
   misuse and admission must analyze. Recursive, so its schema/codec are
   hand-written (the ppx targets non-recursive types). *)

type expr =
  | Var of string
  | Lit of string

type step =
  | Call of { bind : string; tool : string; args : (string * expr) list }
  | Extract of { bind : string; source : expr; schema : string option; question : string }
      (** [schema] names a registered extraction schema the extractor answers
          INTO (§13.2). None = free-text (unbounded channel). *)
  | If of { cond : expr; then_ : step list; else_ : step list }
  | Foreach of { bind : string; over : expr; body : step list }
  | Return of expr

type t = step list

val known_tools : string list
(** The global tool enum the grammar admits (a known simplification smell — a
    per-agent enum would be cleaner; see the technical tutorial). *)

type error = Codec.error
val error_to_string : error -> string

val schema : Yojson.Safe.t
(** The depth-unrolled JSON grammar the planner is constrained to (no nested
    if/foreach — keeps the grammar finite and dodges buggy $ref handling). *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, error) result
val of_string : string -> (t, error) result
(** Parse and fully re-validate (shape, tool enum, scoping) — backend
    enforcement is never trusted (§3.2.1). *)

val validate_scoping : t -> (unit, error) result
(** Binds fresh, vars bound before use, and — load-bearing for taint —
    names bound inside an if/foreach body do NOT escape it. *)
