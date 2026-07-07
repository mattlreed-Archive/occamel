(* Strict mode (§6.2–§6.4): the plan interpreter, provenance-tracking executor,
   sink policies, and plan admission. Two interpreters that must agree —
   [analyze] (static, admission) and [run] (dynamic) — sharing the provenance
   formulas so they can't diverge; the differential test guards it. *)

type value = { data : string; prov : Prov.t }

(* ── capabilities (§13.3) ── *)
type cap = Fs_read | Fs_write | Net | Exec
val cap_to_string : cap -> string
val all_caps : cap list

(* ── sink policies (§6.3) ── *)
type verdict = Allow | Deny of string | Needs_approval
type field_policy = string -> Prov.t -> verdict

val allow_all : field_policy
val require_trusted : fields:string list -> field_policy
val approve_if_untrusted : fields:string list -> field_policy
val combine : field_policy list -> field_policy
(** Combine field rules by most-restrictive (Deny > Needs_approval > Allow) —
    no rule silently dropped. *)

(* ── tool specs and registry (§13.3 + §3.3) ──
   [tool_spec] and [registry] are abstract: build them with [tool]/[registry].
   A tool with no spec cannot be called (default-deny). *)
type tool_spec
type registry

val tool :
  name:string ->
  ?caps:cap list ->
  ?arg_schema:Schema.t ->
  ?policy:field_policy ->
  ?refine:((string * value) list -> (unit, string) result) ->
  unit -> tool_spec

val obj_schema : (string * string) list -> Schema.t
(** A closed object arg-schema from (field, json-type) pairs. *)

val registry :
  ?granted:cap list -> ?extraction_schemas:(string * Schema.t) list ->
  tool_spec list -> registry

(* ── admission (§6.4) ── *)
type rejection = { site : Prov.site; reason : string }

type sink_summary = {
  s_site : Prov.site;
  s_tool : string;
  s_field : string;
  s_prov : Prov.t;
  s_verdict : verdict;
}

type report = {
  rejections : rejection list;
  needs_approval : sink_summary list;
  extractions : (Prov.site * string * Prov.t) list;
  lints : string list;  (** advisory §13.2 channel-width warnings *)
}

val analyze : registry -> Plan.t -> report
(** The single static walk: rejections + approval sinks + extractions + lints. *)

val admit : registry -> Plan.t -> (unit, rejection list) result
(** The boolean face of [analyze]. *)

val render_report : report -> string
(** The whole-plan approval view (§13.6) — truncation- and
    homoglyph/bidi/control-safe. *)

(* ── runtime executor (§6.2) ── *)
type exec_error =
  | Denied_sink of { site : Prov.site; reason : string }
  | Tool_error of { tool : string; error : string }
  | Approval_denied of { site : Prov.site; reason : string }
  | Unbound of string
  | No_return

type exec_hooks = {
  run_tool : tool:string -> args:(string * value) list -> (string, string) result;
  extract : source:value -> question:string -> string;
  approve : tool:string -> field:string -> value:value -> bool;
}

val run : registry -> exec_hooks -> Plan.t -> (value, exec_error) result
