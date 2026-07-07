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

  val read : t -> string
  (* Reading untrusted bytes is allowed — the quarantined extractor must. This
     is deliberately NOT named [to_string]: the one thing you must never do is
     [Trusted.of_user (Untrusted.read x)], which re-wraps a tool result as
     trusted, bypassing [launder]. That is author self-sabotage the type system
     cannot prevent (of_user must accept some string); [read] is named to make
     the misuse legible at the call site. Use [launder] to cross the boundary. *)
end

type justification = string

type t
(* abstract; no public constructor from Untrusted except [launder] *)

val of_user : string -> t
(* Trust-assertion point: "this string IS the user's request." Part of the
   TCB — never feed it [Untrusted.read _]. *)

val of_static : string -> t
(* Trust-assertion point: "this string is author-controlled" (prompts, tool
   specs). TCB — never feed it untrusted bytes. *)

val launder : audit:(string -> unit) -> justification -> Untrusted.t -> t
(* The ONLY sanctioned bridge from untrusted to trusted. Calls [audit] with the
   justification as a side effect (wire it to a Note/trace at the call site) so
   every crossing is logged by construction, then returns the trusted text. *)

val to_string : t -> string
val concat : t list -> t
val ( ^^ ) : t -> t -> t
