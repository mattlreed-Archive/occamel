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

(* ---------- sink policies (§6.3) ---------- *)

type verdict = Allow | Deny of string | Needs_approval

(* A policy answers: may THIS tool's THIS field receive a value of this
   provenance? Registered per tool; the default for an unlisted field is
   [default]. Guarded fields name the provenance requirement explicitly. *)
type policy = {
  tool : string;
  field_policy : string -> Prov.t -> verdict;  (* field name, provenance *)
}

let default_field_policy (_ : string) (_ : Prov.t) : verdict = Allow

(* Convenience: require trusted provenance for the named fields, allow the
   rest. The workhorse for tools like delete/send. *)
let require_trusted ~tool ~fields : policy =
  {
    tool;
    field_policy =
      (fun field prov ->
        if List.mem field fields then
          if Prov.is_trusted prov then Allow
          else Deny (Printf.sprintf "%s.%s requires trusted provenance, got %s" tool field
                       (Prov.to_string prov))
        else Allow);
  }

(* Require approval (not outright deny) for named fields carrying untrusted
   provenance — the escalation path. *)
let approve_if_untrusted ~tool ~fields : policy =
  {
    tool;
    field_policy =
      (fun field prov ->
        if List.mem field fields && not (Prov.is_trusted prov) then Needs_approval
        else Allow);
  }

type registry = {
  policies : policy list;
  default_policy : (string -> Prov.t -> verdict) option;
  (* verdict for a tool with NO matching policy. None => Allow (permissive, the
     M3 default). Set to a deny/approve function for fail-closed registries
     (partial mitigation for the §13.3 capability axis, deferred to M4): a
     newly added dangerous tool whose policy the author forgot is then denied,
     not silently opened. *)
}

let registry ?default_policy policies = { policies; default_policy }

(* H1 fix: combine ALL policies matching a tool, taking the most restrictive
   verdict (Deny > Needs_approval > Allow). Returning only the first match
   silently dropped the rest — a dropped require_trusted is a fail-open of the
   flagship control. *)
let most_restrictive a b =
  match (a, b) with
  | Deny r, _ -> Deny r
  | _, Deny r -> Deny r
  | Needs_approval, _ | _, Needs_approval -> Needs_approval
  | Allow, Allow -> Allow

let field_verdict (reg : registry) (tool : string) (field : string) (prov : Prov.t) :
    verdict =
  match List.filter (fun p -> p.tool = tool) reg.policies with
  | [] -> (
      match reg.default_policy with Some d -> d field prov | None -> Allow)
  | ps ->
      List.fold_left
        (fun acc p -> most_restrictive acc (p.field_policy field prov))
        Allow ps

(* ---------- static provenance walk / admission (§6.4) ---------- *)

(* Worst-case provenance for each binding, computed WITHOUT running anything.
   Every sink policy is evaluated here; a plan that would be denied at step k
   is rejected at admission with a structured reason. This walk and the
   runtime walk (below) are two implementations of the same lattice — the
   test suite differentially checks they agree. *)

type rejection = { site : Prov.site; reason : string }

let admit (reg : registry) (plan : Plan.t) : (unit, rejection list) result =
  let rejections = ref [] in
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
  (* check a Call's fields against the sink policy. The effective provenance of
     an argument is its data-flow provenance joined with the branch taint of
     the context executing it — a trusted literal inside an untrusted branch is
     still attacker-influenced (§6.2). *)
  let check_call env ~branch_taint ~site ~tool ~args =
    List.iter
      (fun (field, e) ->
        let prov = Prov.join branch_taint (prov_of_expr env e) in
        match field_verdict reg tool field prov with
        | Allow | Needs_approval -> ()
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
        | Plan.Extract { bind; source; _ } ->
            let src_prov = prov_of_expr env source in
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
        | Plan.Return e ->
            (* display sink: any provenance allowed *)
            let _ = prov_of_expr env e in
            env)
      env steps
  in
  (* M5: run the scoping check ourselves — don't rely on the plan having come
     through Plan.of_json. A scoping violation is an admission rejection. *)
  match Plan.validate_scoping plan with
  | Error e -> Error [ { site = e.Codec.path; reason = e.Codec.msg } ]
  | Ok () -> (
      let _ = walk [] ~branch_taint:Prov.empty plan in
      match List.rev !rejections with [] -> Ok () | rs -> Error rs)

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
            (* sink policy at execution, on the actual values. Effective
               provenance joins the branch taint (§6.2), matching admission. *)
            let* () =
              List.fold_left
                (fun acc (field, (v : value)) ->
                  let* () = acc in
                  let eff_prov = Prov.join branch_taint v.prov in
                  match field_verdict reg tool field eff_prov with
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
        | Plan.Extract { bind; source; question } ->
            let* src = value_of_expr env source in
            let data = hooks.extract ~source:src ~question in
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
        | Plan.Return e ->
            let* v = value_of_expr env e in
            (* a value returned from inside a tainted branch carries that taint
               in its reported provenance (accuracy for traces / M4 approval) *)
            Ok (Some { v with prov = Prov.join branch_taint v.prov }, env))
  in
  let* result, _ = walk [] ~branch_taint:Prov.empty plan in
  match result with Some v -> Ok v | None -> Error No_return
