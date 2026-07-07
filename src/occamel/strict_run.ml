(* Strict-mode runner (design doc §6): plan (P-LLM, trusted input only) ->
   admit -> execute with provenance -> trace. Plus deterministic replay for
   CI (§9). The privilege boundary is in the TYPE of [plan_with]: its input is
   Trusted.t, and there is no constructor from tool output to Trusted.t
   (§13.2), so a tool result cannot reach the planner even by mistake.

   The executor is Strict.run; this module supplies its hooks — backed by real
   tools/extractor in production, or by the recorded trace in replay. *)

type error =
  | Plan_backend of string
  | Plan_rejected of Strict.rejection list
  | Exec of Strict.exec_error

let error_to_string = function
  | Plan_backend s -> "planner backend: " ^ s
  | Plan_rejected rs ->
      "plan rejected: "
      ^ String.concat "; " (List.map (fun (r : Strict.rejection) -> r.reason) rs)
  | Exec e -> (
      match e with
      | Strict.Denied_sink { site; reason } -> Printf.sprintf "denied sink at %s: %s" site reason
      | Strict.Tool_error { tool; error } -> Printf.sprintf "tool %s: %s" tool error
      | Strict.Approval_denied { site; _ } -> "approval denied at " ^ site
      | Strict.Unbound n -> "unbound " ^ n
      | Strict.No_return -> "plan did not return")

let hash s = Digest.to_hex (Digest.string s)

type config = {
  registry : Strict.registry;
  (* planner: trusted prompt -> a plan (or backend error) *)
  plan_with : Trusted.t -> (Plan.t, string) result;
  (* quarantined extractor: reads untrusted source data, answers the question *)
  extract_with : source:string -> question:string -> string;
  (* real tool implementations *)
  run_tool : tool:string -> args:(string * Strict.value) list -> (string, string) result;
  approve : tool:string -> field:string -> value:Strict.value -> bool;
}

(* Production run: generate, admit, execute; emit a trace throughout. *)
let run (cfg : config) (goal : Trusted.t) : (Strict.value, error) result * Trace.t =
  let events = ref [] in
  let emit e = events := e :: !events in
  let finish r = (r, List.rev !events) in
  match cfg.plan_with goal with
  | Error e -> finish (Error (Plan_backend e))
  | Ok plan ->
      emit
        (Trace.Plan_generated
           { prompt_hash = hash (Trusted.to_string goal); plan = Plan.to_json plan });
      (match Strict.admit cfg.registry plan with
      | Error rs ->
          emit
            (Trace.Plan_admitted
               { verdict = String.concat "; " (List.map (fun (r : Strict.rejection) -> r.reason) rs) });
          finish (Error (Plan_rejected rs))
      | Ok () ->
          emit (Trace.Plan_admitted { verdict = "ok" });
          (* hooks that record as they run *)
          let hooks : Strict.exec_hooks =
            {
              run_tool =
                (fun ~tool ~args ->
                  let args_json =
                    `Assoc (List.map (fun (f, (v : Strict.value)) -> (f, `String v.data)) args)
                  in
                  let r = cfg.run_tool ~tool ~args in
                  (match r with
                  | Ok result ->
                      emit
                        (Trace.Tool_call
                           {
                             tool;
                             args_schema_hash = "strict";
                             args = args_json;
                             result = `String result;
                             ms = 0;
                           })
                  | Error e ->
                      emit
                        (Trace.Tool_failed
                           { tool; args_schema_hash = "strict"; args = args_json; error = e }));
                  r);
              extract =
                (fun ~source ~question ->
                  let out = cfg.extract_with ~source:source.Strict.data ~question in
                  emit
                    (Trace.Extraction
                       {
                         site = "extract";
                         question;
                         source_hash = hash source.Strict.data;
                         output = out;
                         prov = Prov.to_json source.Strict.prov;
                       });
                  out);
              approve =
                (fun ~tool ~field ~value ->
                  let ok = cfg.approve ~tool ~field ~value in
                  emit (Trace.Approval { tool; decision = (if ok then "approved" else "denied:" ^ field) });
                  ok);
            }
          in
          finish (Result.map_error (fun e -> Exec e) (Strict.run cfg.registry hooks plan)))

(* ---------- deterministic replay (§9) ----------
   Re-runs the recorded plan through admission and execution, but answers every
   tool call and extraction from the trace. Fails loudly if the recorded plan
   no longer admits, or the recorded outputs are consumed out of order.

   Same security note as Loop.replay (F4/§13.7): PURE replay — no live tool
   runs, recorded approvals are replayed not re-prompted. Not a path to live
   execution until M4 adds signing + an approval re-prompt seam. *)

type replay_error =
  | Bad_trace of string
  | Replan_needed  (* trace has no recorded plan *)
  | Readmit_failed of Strict.rejection list
  | Exec_replay of Strict.exec_error

let replay ~(trace : Trace.t) (registry : Strict.registry) :
    (Strict.value, replay_error) result =
  let plan_json =
    List.find_map (function Trace.Plan_generated { plan; _ } -> Some plan | _ -> None) trace
  in
  match plan_json with
  | None -> Error Replan_needed
  | Some pj -> (
      match Plan.of_json pj with
      | Error e -> Error (Bad_trace (Codec.error_to_string e))
      | Ok plan -> (
          (* replay re-runs admission — a tampered plan that no longer admits
             must not execute (§13.7) *)
          match Strict.admit registry plan with
          | Error rs -> Error (Readmit_failed rs)
          | Ok () ->
              (* queues of recorded tool results and extractions, consumed in order *)
              let tools =
                List.filter_map
                  (function
                    | Trace.Tool_call { result = `String r; _ } -> Some (Ok r)
                    | Trace.Tool_failed { error; _ } -> Some (Error error)
                    | _ -> None)
                  trace
                |> ref
              in
              let extracts =
                List.filter_map
                  (function Trace.Extraction { output; _ } -> Some output | _ -> None)
                  trace
                |> ref
              in
              let approvals =
                List.filter_map
                  (function
                    | Trace.Approval { decision; _ } ->
                        Some (String.length decision >= 8 && String.sub decision 0 8 = "approved")
                    | _ -> None)
                  trace
                |> ref
              in
              let pop r =
                match !r with [] -> None | x :: rest -> r := rest; Some x
              in
              let hooks : Strict.exec_hooks =
                {
                  run_tool = (fun ~tool ~args:_ ->
                    match pop tools with Some r -> r | None -> Error ("replay: no recorded result for " ^ tool));
                  extract = (fun ~source:_ ~question:_ ->
                    match pop extracts with Some o -> o | None -> "");
                  approve = (fun ~tool:_ ~field:_ ~value:_ ->
                    match pop approvals with Some b -> b | None -> true);
                }
              in
              Result.map_error (fun e -> Exec_replay e) (Strict.run registry hooks plan)))
