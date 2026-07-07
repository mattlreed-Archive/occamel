(* Strict-mode runner (§6): plan (P-LLM, Trusted input) → admit → execute with
   the quarantined extractor → trace. Plus deterministic replay and the
   verified replay-into-live seam. The planner boundary is in the TYPE of
   [config.plan_with]: its input is Trusted.t, and there is no constructor from
   tool output to Trusted.t (§13.2). *)

type error =
  | Plan_backend of string
  | Plan_rejected of Strict.rejection list
  | Exec of Strict.exec_error

val error_to_string : error -> string

type config = {
  registry : Strict.registry;
  plan_with : Trusted.t -> (Plan.t, string) result;  (** the planner (P-LLM) *)
  extract_with : source:string -> question:string -> string;  (** quarantined extractor (Q-LLM) *)
  run_tool : tool:string -> args:(string * Strict.value) list -> (string, string) result;
  approve_plan : string -> bool;  (** whole-plan approval, shown the rendered graph once *)
}

val auto_approve_plan : string -> bool

val run : config -> Trusted.t -> (Strict.value, error) result * Trace.t

val run_with_replan :
  ?max_replans:int -> config -> Trusted.t -> (Strict.value, error) result * Trace.t
(** On a harness-generated Tool_error, revise the plan (§6.5). The planner sees
    ONLY a static note naming the failed tool — never the error string. *)

type replay_error =
  | Bad_trace of string
  | Replan_needed
  | Readmit_failed of Strict.rejection list
  | Exec_replay of Strict.exec_error

val replay : trace:Trace.t -> Strict.registry -> (Strict.value, replay_error) result
(** Pure deterministic replay: re-runs admission, answers tools/extractions
    from the trace, no live tools. *)

type live_error =
  | Integrity of string  (** unsigned / tampered / unreadable trace *)
  | Cut_exceeds_recording of { cut : int; recorded : int }
  | Truncated_prefix
  | Live_plan_denied
  | Replay of replay_error

val replay_then_live :
  path:string ->
  cut:int ->
  Strict.registry ->
  approve_plan:(string -> bool) ->
  live:Strict.exec_hooks ->
  (Strict.value, live_error) result
(** Replay the first [cut] tool calls from a VERIFIED trace, then execute live.
    Rejects unsigned/tampered traces; re-requests the whole-plan approval for
    the live tail; fails closed inside the replay window; recorded approvals
    authorize nothing live (§13.7). *)
