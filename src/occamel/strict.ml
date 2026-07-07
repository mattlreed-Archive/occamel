(* Strict mode (design doc §6.2–§6.4): the plan interpreter, the provenance-
   tracking executor, sink policies, and plan admission.

   The plan AST is Plan.t (Call/Extract/If/Return over Var/Lit), reused from
   M0. What strict mode adds: every runtime binding carries Prov.t; every
   capability-bearing sink is checked against a policy before execution; and
   the whole thing is analyzed statically (admission) before anything runs.

   M3 scope note: Foreach (§5.2) is deferred to M3b — it needs a list-valued
   runtime model the current string-valued environment doesn't have, and its
   taint story (loop-var provenance joins the iterated source) is mechanically
   the If case. Deferring keeps the security core — the part the thesis rests
   on — clean rather than rushing the one construct where taint matters most.
   Tracked in docs/research/m3-notes.md; the design doc §5.2/§11 already list
   it, so no doc change, just a scoped-in-M3b note. *)

(* ---------- runtime values ---------- *)

type value = { data : string; prov : Prov.t }

(* ---------- capabilities (§13.3, Item 1) ---------- *)

type cap = Fs_read | Fs_write | Net | Exec

let cap_to_string = function
  | Fs_read -> "fs_read" | Fs_write -> "fs_write" | Net -> "net" | Exec -> "exec"

let all_caps = [ Fs_read; Fs_write; Net; Exec ]

(* ---------- sink policies (§6.3) ---------- *)

type verdict = Allow | Deny of string | Needs_approval

(* H1 (M3 review): combine verdicts by most-restrictive (Deny > Needs_approval
   > Allow), so a guarding policy is never silently dropped. *)
let most_restrictive a b =
  match (a, b) with
  | Deny r, _ -> Deny r
  | _, Deny r -> Deny r
  | Needs_approval, _ | _, Needs_approval -> Needs_approval
  | Allow, Allow -> Allow

type field_policy = string -> Prov.t -> verdict

let allow_all : field_policy = fun _ _ -> Allow

(* Require trusted provenance for the named fields. *)
let require_trusted ~fields : field_policy =
 fun field prov ->
  if List.mem field fields then
    if Prov.is_trusted prov then Allow
    else Deny (Printf.sprintf "%s requires trusted provenance, got %s" field (Prov.to_string prov))
  else Allow

(* Escalate to approval for named fields carrying untrusted provenance. *)
let approve_if_untrusted ~fields : field_policy =
 fun field prov ->
  if List.mem field fields && not (Prov.is_trusted prov) then Needs_approval else Allow

let combine (ps : field_policy list) : field_policy =
 fun field prov -> List.fold_left (fun acc p -> most_restrictive acc (p field prov)) Allow ps

(* ---------- tool spec (§13.3 + §3.3, Items 1+2) ----------
   Every tool a plan may call declares its capability footprint, an object
   arg-schema (field names + types), a per-field sink policy, and an optional
   semantic refinement (§3.3, e.g. "path inside workspace"). A tool with no
   spec cannot be called — no silent Allow. *)
type tool_spec = {
  ts_name : string;
  ts_caps : cap list;
  ts_arg_schema : Schema.t;  (* object schema, or `Null for "no typed args" *)
  ts_policy : field_policy;
  ts_refine : (string * value) list -> (unit, string) result;
}

let tool ~name ?(caps = []) ?(arg_schema = `Null) ?(policy = allow_all)
    ?(refine = fun _ -> Ok ()) () : tool_spec =
  { ts_name = name; ts_caps = caps; ts_arg_schema = arg_schema; ts_policy = policy; ts_refine = refine }

(* helper: an object arg-schema from (field, json-type) pairs, closed *)
let obj_schema (fields : (string * string) list) : Schema.t =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc (List.map (fun (f, ty) -> (f, `Assoc [ ("type", `String ty) ])) fields));
      ("required", `List (List.map (fun (f, _) -> `String f) fields));
      ("additionalProperties", `Bool false);
    ]

type registry = {
  specs : tool_spec list;
  granted : cap list;
  extraction_schemas : (string * Schema.t) list;  (* named Extract schemas (Item 3) *)
}

(* granted defaults to all capabilities (convenience); a fail-closed registry
   passes ~granted explicitly so a tool's caps ⊄ granted is denied. *)
let registry ?(granted = all_caps) ?(extraction_schemas = []) specs =
  { specs; granted; extraction_schemas }

(* channel width of a named extraction schema; a None ref or an unknown name is
   an unbounded (free-text) channel — the honest default (§13.2). *)
let extraction_width (reg : registry) (schema : string option) : Schema.width =
  match schema with
  | None -> Schema.Unbounded
  | Some name -> (
      match List.assoc_opt name reg.extraction_schemas with
      | Some s -> Schema.channel_width s
      | None -> Schema.Unbounded)

let spec_of (reg : registry) (tool : string) : tool_spec option =
  List.find_opt (fun s -> s.ts_name = tool) reg.specs

(* declared field names for a tool's arg schema (for the field-name consistency
   check at admission) *)
let declared_fields (s : tool_spec) : string list option =
  match s.ts_arg_schema with
  | `Assoc _ -> (
      match Schema.member "properties" s.ts_arg_schema with
      | Some (`Assoc props) -> Some (List.map fst props)
      | _ -> None)
  | _ -> None

(* ---------- static provenance walk / admission (§6.4) ---------- *)

(* Worst-case provenance for each binding, computed WITHOUT running anything.
   Every sink policy is evaluated here; a plan that would be denied at step k
   is rejected at admission with a structured reason. This walk and the
   runtime walk (below) are two implementations of the same lattice — the
   test suite differentially checks they agree. *)

type rejection = { site : Prov.site; reason : string }

(* A guarded sink the plan reaches, with the provenance that flows into it —
   the raw material for the whole-plan approval view (§6.4 step 3, §13.6). *)
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
  extractions : (Prov.site * string * Prov.t) list;  (* site, question, source prov *)
  lints : string list;  (* advisory §13.2 channel-width warnings *)
}

(* analyze: the single static walk. Records every rejection, every
   Needs_approval sink, and every extraction with its source provenance, plus
   advisory channel-width lints (Item 3/§13.2). [admit] is the boolean face. *)
let analyze (reg : registry) (plan : Plan.t) : report =
  let rejections = ref [] and approvals = ref [] and extractions = ref [] in
  let lints = ref [] in
  (* extraction bind -> its declared schema name (for width lookup) *)
  let ext_schema : (Prov.site, string option) Hashtbl.t = Hashtbl.create 8 in
  let reject site reason = rejections := { site; reason } :: !rejections in
  (* M5 fix: an unbound var is treated as UNTRUSTED, not empty/trusted, so
     admission is sound even if a caller hands us a plan that skipped
     Plan.of_json's scoping check. We also run that check ourselves below. *)
  let prov_of_expr env : Plan.expr -> Prov.t = function
    | Plan.Lit _ -> Prov.static
    | Plan.Var name -> (
        match List.assoc_opt name env with
        | Some p -> p
        | None -> Prov.tool_result ("?unbound:" ^ name))
  in
  (* check a Call against its tool spec: the tool must be registered (no silent
     Allow), its capabilities must be granted (§13.3), its fields must be
     declared by the arg schema (§3.3 field-name consistency), and each field's
     effective provenance (data flow joined with branch taint, §6.2) must pass
     the sink policy. *)
  let check_call env ~branch_taint ~site ~tool ~args =
    match spec_of reg tool with
    | None -> reject site (Printf.sprintf "no tool spec for %S (default-deny)" tool)
    | Some spec ->
        (* LOW footgun (review): a capability-bearing tool MUST declare a closed
           arg schema, else the §3.3 choke point (field-name + value validation)
           is skipped and a field-keyed policy can be dodged via an undeclared
           field. Fail closed. *)
        (if spec.ts_caps <> [] && declared_fields spec = None then
           reject site (Printf.sprintf "%s is capability-bearing but declares no arg schema" tool));
        (* Item 1: capability footprint must be granted *)
        List.iter
          (fun c ->
            if not (List.mem c reg.granted) then
              reject site (Printf.sprintf "%s needs ungranted capability %s" tool (cap_to_string c)))
          spec.ts_caps;
        (* Item 2: every Call field must be declared by the arg schema *)
        (match declared_fields spec with
        | Some fields ->
            List.iter
              (fun (field, _) ->
                if not (List.mem field fields) then
                  reject site (Printf.sprintf "%s.%s is not a declared argument" tool field))
              args
        | None -> ());
        let capability_bearing = spec.ts_caps <> [] in
        (* sink policy on each field's effective provenance *)
        List.iter
          (fun (field, e) ->
            let prov = Prov.join branch_taint (prov_of_expr env e) in
            (* Item 3/§13.2 channel-width lint (advisory): an untrusted value
               reaching a capability sink, derived from an unbounded-width
               extraction, is a warning — narrow the extraction schema. *)
            (if capability_bearing && not (Prov.is_trusted prov) then
               List.iter
                 (fun from ->
                   match Hashtbl.find_opt ext_schema from with
                   | Some schema_ref when extraction_width reg schema_ref = Schema.Unbounded ->
                       lints :=
                         Printf.sprintf
                           "%s.%s receives unbounded-width extraction %S; narrow its schema (sec 13.2)"
                           tool field from
                         :: !lints
                   | _ -> ())
                 (Prov.extracted_froms prov));
            match spec.ts_policy field prov with
            | Allow -> ()
            | Needs_approval ->
                approvals :=
                  { s_site = site; s_tool = tool; s_field = field; s_prov = prov;
                    s_verdict = Needs_approval }
                  :: !approvals
            | Deny reason -> reject site reason)
          args
  in
  (* walk a step list; returns the env extended with its top-level binds.
     branch_taint is added to every binding produced inside a tainted branch. *)
  let rec walk env ~branch_taint steps =
    List.fold_left
      (fun env step ->
        match step with
        | Plan.Call { bind; tool; args } ->
            check_call env ~branch_taint ~site:bind ~tool ~args;
            (bind, Prov.join branch_taint (Prov.tool_result bind)) :: env
        | Plan.Extract { bind; source; schema; question } ->
            let src_prov = prov_of_expr env source in
            Hashtbl.replace ext_schema bind schema;
            extractions := (bind, question, Prov.join branch_taint src_prov) :: !extractions;
            let p =
              Prov.join branch_taint
                (Prov.join src_prov (Prov.extracted ~from:bind ~schema:"extract"))
            in
            (bind, p) :: env
        | Plan.If { cond; then_; else_ } ->
            let cond_prov = prov_of_expr env cond in
            (* control-flow taint: if the condition is untrusted, everything
               executed in either branch is attacker-influenced (§6.2) *)
            let taint =
              if Prov.is_trusted cond_prov then branch_taint
              else Prov.add_branch "if" (Prov.join branch_taint cond_prov)
            in
            let _ = walk env ~branch_taint:taint then_ in
            let _ = walk env ~branch_taint:taint else_ in
            (* branch-bound names don't escape (enforced by Plan scoping), so
               env is unchanged after the If *)
            env
        | Plan.Foreach { bind; over; body } ->
            (* per-element taint: iterating over untrusted data means both the
               loop variable and the loop body are attacker-influenced (in
               count and content) — same as the If case, applied to the body
               (§6.2, M3b). The loop var inherits [over]'s provenance. *)
            let over_prov = prov_of_expr env over in
            let taint =
              if Prov.is_trusted over_prov then branch_taint
              else Prov.add_branch "foreach" (Prov.join branch_taint over_prov)
            in
            let elem_prov = Prov.join taint over_prov in
            let _ = walk ((bind, elem_prov) :: env) ~branch_taint:taint body in
            (* body binds (incl. [bind]) don't escape the loop *)
            env
        | Plan.Return e ->
            (* display sink: any provenance allowed *)
            let _ = prov_of_expr env e in
            env)
      env steps
  in
  (* M5: run the scoping check ourselves — don't rely on the plan having come
     through Plan.of_json. A scoping violation is a rejection. *)
  (match Plan.validate_scoping plan with
  | Error e -> reject e.Codec.path e.Codec.msg
  | Ok () -> ignore (walk [] ~branch_taint:Prov.empty plan));
  {
    rejections = List.rev !rejections;
    needs_approval = List.rev !approvals;
    extractions = List.rev !extractions;
    lints = List.rev !lints;
  }

let admit (reg : registry) (plan : Plan.t) : (unit, rejection list) result =
  match (analyze reg plan).rejections with [] -> Ok () | rs -> Error rs

(* Whole-plan approval view (§13.6): canonical, truncation-safe, and
   homoglyph/bidi/control-safe — every non-printable-ASCII byte escaped, so the
   approver reads exactly the sinks and provenance that will execute. One
   informed decision over the data-flow graph, not N mid-run prompts. *)
let escape_ascii (s : string) : string =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      let code = Char.code c in
      if code >= 0x20 && code <= 0x7e && c <> '\\' then Buffer.add_char b c
      else Buffer.add_string b (Printf.sprintf "\\x%02x" code))
    s;
  Buffer.contents b

let render_report (rep : report) : string =
  let b = Buffer.create 256 in
  let add fmt = Printf.ksprintf (Buffer.add_string b) fmt in
  add "Plan requires approval:\n";
  List.iter
    (fun s ->
      add "  - %s.%s (at %s) receives %s data\n" (escape_ascii s.s_tool)
        (escape_ascii s.s_field) (escape_ascii s.s_site)
        (if Prov.is_trusted s.s_prov then "trusted" else "UNTRUSTED");
      add "      provenance: %s\n" (escape_ascii (Prov.to_string s.s_prov)))
    rep.needs_approval;
  if rep.extractions <> [] then add "Extractions (quarantined reads):\n";
  List.iter
    (fun (site, q, prov) ->
      add "  - %s asks %S of %s data\n" (escape_ascii site) (escape_ascii q)
        (if Prov.is_trusted prov then "trusted" else "untrusted"))
    rep.extractions;
  if rep.lints <> [] then add "Channel-width warnings (sec 13.2):\n";
  List.iter (fun l -> add "  ! %s\n" (escape_ascii l)) rep.lints;
  Buffer.contents b

(* ---------- runtime executor (§6.2) ---------- *)

(* Mirrors [admit] but on real values. Extract and tool execution are supplied
   by the caller as effects (see Strict_run); here we take plain functions so
   the interpreter core stays effect- and HTTP-free and directly testable. *)

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

let run (reg : registry) (hooks : exec_hooks) (plan : Plan.t) :
    (value, exec_error) result =
  let ( let* ) = Result.bind in
  let value_of_expr env : Plan.expr -> (value, exec_error) result = function
    | Plan.Lit s -> Ok { data = s; prov = Prov.static }
    | Plan.Var name -> (
        match List.assoc_opt name env with
        | Some v -> Ok v
        | None -> Error (Unbound name))
  in
  let rec walk env ~branch_taint steps : (value option * (string * value) list, exec_error) result
      =
    match steps with
    | [] -> Ok (None, env)
    | step :: rest -> (
        match step with
        | Plan.Call { bind; tool; args } ->
            let* arg_vals =
              List.fold_right
                (fun (field, e) acc ->
                  let* acc = acc in
                  let* v = value_of_expr env e in
                  Ok ((field, v) :: acc))
                args (Ok [])
            in
            let* spec =
              match spec_of reg tool with
              | Some s -> Ok s
              | None -> Error (Denied_sink { site = bind; reason = "no tool spec (default-deny)" })
            in
            (* Item 1: capabilities granted *)
            let* () =
              List.fold_left
                (fun acc c ->
                  let* () = acc in
                  if List.mem c reg.granted then Ok ()
                  else Error (Denied_sink { site = bind; reason = "ungranted capability " ^ cap_to_string c }))
                (Ok ()) spec.ts_caps
            in
            (* Item 2: typed-arg validation (values vs the arg schema) + §3.3
               refinement, the single choke point before the tool sees args *)
            let* () =
              match spec.ts_arg_schema with
              | `Null -> Ok ()
              | schema ->
                  let obj = `Assoc (List.map (fun (f, (v : value)) -> (f, `String v.data)) arg_vals) in
                  (match Schema.validate schema obj with
                  | Ok () -> Ok ()
                  | Error m -> Error (Denied_sink { site = bind; reason = "arg schema: " ^ m }))
            in
            let* () =
              match spec.ts_refine arg_vals with
              | Ok () -> Ok ()
              | Error m -> Error (Denied_sink { site = bind; reason = "arg refine: " ^ m })
            in
            (* sink policy at execution, on the actual values. Effective
               provenance joins the branch taint (§6.2), matching admission. *)
            let* () =
              List.fold_left
                (fun acc (field, (v : value)) ->
                  let* () = acc in
                  let eff_prov = Prov.join branch_taint v.prov in
                  match spec.ts_policy field eff_prov with
                  | Allow -> Ok ()
                  | Deny reason -> Error (Denied_sink { site = bind; reason })
                  | Needs_approval ->
                      if hooks.approve ~tool ~field ~value:{ v with prov = eff_prov } then Ok ()
                      else
                        Error
                          (Approval_denied
                             { site = bind; reason = Printf.sprintf "%s.%s" tool field }))
                (Ok ()) arg_vals
            in
            let* result =
              match hooks.run_tool ~tool ~args:arg_vals with
              | Ok r -> Ok r
              | Error e -> Error (Tool_error { tool; error = e })
            in
            let v = { data = result; prov = Prov.join branch_taint (Prov.tool_result bind) } in
            walk ((bind, v) :: env) ~branch_taint rest
        | Plan.Extract { bind; source; schema; question } ->
            let* src = value_of_expr env source in
            let data = hooks.extract ~source:src ~question in
            (* Item 3: if the extraction is typed, the output must conform to
               the schema — bounds the channel at runtime even if the extractor
               wasn't constrained-decoded. *)
            let* () =
              match schema with
              | None -> Ok ()
              | Some name -> (
                  match List.assoc_opt name reg.extraction_schemas with
                  | None -> Ok ()  (* unknown schema name: nothing to enforce *)
                  | Some s -> (
                      match Schema.validate s (`String data) with
                      | Ok () -> Ok ()
                      | Error m ->
                          Error (Denied_sink { site = bind; reason = "extraction schema: " ^ m })))
            in
            let prov =
              Prov.join branch_taint
                (Prov.join src.prov (Prov.extracted ~from:bind ~schema:"extract"))
            in
            walk ((bind, { data; prov }) :: env) ~branch_taint rest
        | Plan.If { cond; then_; else_ } ->
            let* c = value_of_expr env cond in
            let taint =
              if Prov.is_trusted c.prov then branch_taint
              else Prov.add_branch "if" (Prov.join branch_taint c.prov)
            in
            (* evidence semantics: non-empty, not obviously negative -> then *)
            let truthy =
              let d = String.lowercase_ascii (String.trim c.data) in
              d <> "" && d <> "no" && d <> "false" && d <> "not released"
            in
            let branch = if truthy then then_ else else_ in
            let* branch_result, _ = walk env ~branch_taint:taint branch in
            (match branch_result with
            | Some v -> Ok (Some v, env)  (* branch returned; whole plan done *)
            | None -> walk env ~branch_taint rest)
        | Plan.Foreach { bind; over; body } ->
            let* ov = value_of_expr env over in
            let taint =
              if Prov.is_trusted ov.prov then branch_taint
              else Prov.add_branch "foreach" (Prov.join branch_taint ov.prov)
            in
            (* [over]'s data is a JSON array; iterate its string elements. A
               non-array is a runtime error. *)
            let* elements =
              match Yojson.Safe.from_string ov.data with
              | `List xs ->
                  Ok (List.map (function `String s -> s | j -> Yojson.Safe.to_string j) xs)
              | _ -> Error (Tool_error { tool = "foreach"; error = "over is not a JSON list" })
              | exception _ -> Error (Tool_error { tool = "foreach"; error = "over is not valid JSON" })
            in
            (* run the body per element; a body Return ends the whole plan
               (first element that returns wins) *)
            let rec iter = function
              | [] -> Ok (None, env)
              | elem :: more ->
                  let elem_v = { data = elem; prov = Prov.join taint ov.prov } in
                  let* r, _ = walk ((bind, elem_v) :: env) ~branch_taint:taint body in
                  (match r with Some v -> Ok (Some v, env) | None -> iter more)
            in
            let* r, _ = iter elements in
            (match r with Some v -> Ok (Some v, env) | None -> walk env ~branch_taint rest)
        | Plan.Return e ->
            let* v = value_of_expr env e in
            (* a value returned from inside a tainted branch carries that taint
               in its reported provenance (accuracy for traces / M4 approval) *)
            Ok (Some { v with prov = Prov.join branch_taint v.prov }, env))
  in
  let* result, _ = walk [] ~branch_taint:Prov.empty plan in
  match result with Some v -> Ok v | None -> Error No_return
