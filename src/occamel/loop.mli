(* Loop mode (§6.6): the conventional observe-act loop, kept honest by types.
   Model calls, tool calls, notes, and approvals are EFFECTS; [run] and
   [replay] are the handler stacks. No architectural injection resistance —
   Ctx may hold tool results (see §13). *)

module Ctx : sig
  type message = { role : string; content : string }
  type t = message list

  val make : system:string -> user:string -> t
  val add_user : t -> string -> t
  val add_tool_result : t -> tool:string -> string -> t
  val hash : t -> string
end

module Tool_def : sig
  type ('a, 'r) t = {
    name : string;
    dangerous : bool;  (** dangerous tools trigger the approval handler *)
    args_schema : Yojson.Safe.t;
    encode_args : 'a -> Yojson.Safe.t;
    encode_result : 'r -> Yojson.Safe.t;
    decode_result : Yojson.Safe.t -> ('r, Codec.error) result;
    run : 'a -> ('r, string) result;
  }
end

type approval = Approved | Denied of string
type approval_view = { tool : string; fields : (string * string) list }

(* The effects a loop-mode agent performs. The user writes direct-style code
   that performs these; [run]/[replay] handle them. *)
type _ Effect.t +=
  | Ask : Ctx.t * 'a Schema.typed -> 'a Effect.t
  | Invoke : ('a, 'r) Tool_def.t * 'a -> ('r, string) result Effect.t
  | Note : string -> unit Effect.t
  | Approve : approval_view -> approval Effect.t

val view_of_args : tool:string -> Yojson.Safe.t -> approval_view
(** Render args for approval — truncation- and homoglyph/bidi-safe (§13.6). *)

type run_error =
  [ `Ask_backend of string
  | `Unparseable of Codec.error list ]

val run :
  ask:(Ctx.t -> name:string -> schema:Yojson.Safe.t -> (string, string) result) ->
  ?approve:(approval_view -> approval) ->
  ?max_repairs:int ->
  (unit -> 'out) ->
  ('out, run_error) result * Trace.t
(** Production handler: Ask → backend + repair; Invoke → real tool (+ approval
    on dangerous tools). Records a trace. *)

type replay_error =
  [ `Trace_exhausted
  | `Mismatch of string ]

val replay : trace:Trace.t -> (unit -> 'out) -> ('out, replay_error) result
(** Pure deterministic replay from a trace; fails loudly on any divergence.
    No live tool runs (§13.7). *)
