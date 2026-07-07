(* The compile-time privilege boundary (design doc §13.2, goal G6).

   [Trusted.text] is what the strict planner (P-LLM) prompt is built from. The
   ONLY constructors are [of_user] (the user's request) and [of_static]
   (author-controlled prompts / tool specs), plus [launder] — an audited,
   rare, explicitly-justified escape hatch. There is NO constructor from a
   tool result or an extraction to [Trusted.text]. Therefore "a tool result
   reaches the planner prompt" is a *type error*, not a policy violation the
   interpreter must remember to enforce.

   [Untrusted.text] wraps everything that entered via a tool result. It can be
   read by the quarantined extractor (Q-LLM) and displayed, but it can never
   become [Trusted.text] except through [launder].

   This is the honest, narrow claim that replaces v0.4's value-level taint:
   we do not track taint *through* a model's context; we guarantee the
   privileged model's context never contains untrusted bytes at all. *)

module Untrusted : sig
  type t

  val of_tool_result : string -> t
  val to_string : t -> string
  (* reading untrusted bytes is allowed; it just can't authorize anything *)
end

type justification = string

type t
(* abstract; no public constructor from Untrusted except [launder] *)

val of_user : string -> t
val of_static : string -> t
val launder : justification -> Untrusted.t -> t * justification
(* returns the laundered text and echoes the justification for the audit log *)

val to_string : t -> string
val concat : t list -> t
val ( ^^ ) : t -> t -> t
