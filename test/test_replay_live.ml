(* Item 5: replay-into-live approval seam (§13.7). Offline. *)

module SR = Occamel.Strict_run
module St = Occamel.Strict
module Pl = Occamel.Plan
module Tr = Occamel.Trace
module T = Occamel.Trusted

(* a plan: search (benign) then send (dangerous, require_trusted to). We record
   a run, then replay-into-live and check the seam. *)
let ws = St.tool ~name:"web_search" ~caps:[ St.Net ] ~arg_schema:(St.obj_schema [ ("query", "string") ]) ()
let send = St.tool ~name:"send_message" ~caps:[ St.Net ]
    ~arg_schema:(St.obj_schema [ ("to", "string"); ("body", "string") ])
    ~policy:(St.approve_if_untrusted ~fields:[ "to" ]) ()
let registry = St.registry [ ws; send ]

let plan : Pl.t =
  [ Call { bind = "r"; tool = "web_search"; args = [ ("query", Lit "who") ] };
    Call { bind = "s"; tool = "send_message"; args = [ ("to", Lit "alice@x.com"); ("body", Lit "hi") ] };
    Return (Var "s") ]

let cfg ~sends : SR.config =
  {
    registry;
    plan_with = (fun _ -> Ok plan);
    extract_with = (fun ~source:_ ~question:_ -> "");
    run_tool =
      (fun ~tool ~args ->
        (match tool with
        | "send_message" ->
            let g f = match List.assoc_opt f args with Some (v : St.value) -> v.data | None -> "" in
            sends := (g "to") :: !sends
        | _ -> ());
        Ok (tool ^ "-ok"));
    approve_plan = SR.auto_approve_plan;
  }

let () =
  Unix.putenv "OCCAMEL_TRACE_KEY" "k5";
  (* record a signed trace *)
  let rec_sends = ref [] in
  let _res, trace = SR.run (cfg ~sends:rec_sends) (T.of_user "go") in
  let path = Filename.temp_file "occ" ".strace" in
  Tr.save trace path;

  (* integrity required: an unsigned copy is rejected *)
  let unsigned = Filename.temp_file "occ" ".strace" in
  Unix.putenv "OCCAMEL_TRACE_KEY" "";  (* save without a key => unsigned *)
  Tr.save trace unsigned;
  Unix.putenv "OCCAMEL_TRACE_KEY" "k5";
  let live_sends = ref [] in
  let live_hooks : St.exec_hooks =
    {
      run_tool =
        (fun ~tool ~args ->
          (match tool with
          | "send_message" ->
              let g f = match List.assoc_opt f args with Some (v : St.value) -> v.data | None -> "" in
              live_sends := (g "to") :: !live_sends
          | _ -> ());
          Ok (tool ^ "-LIVE"));
      extract = (fun ~source:_ ~question:_ -> "");
      approve = (fun ~tool:_ ~field:_ ~value:_ -> true);
    }
  in
  (match SR.replay_then_live ~path:unsigned ~cut:1 registry ~approve_plan:(fun _ -> true) ~live:live_hooks with
  | Error (SR.Integrity _) -> ()
  | _ -> failwith "unsigned trace must be rejected by replay_then_live");

  (* cut=1: replay the first tool call (web_search) from the trace, run the
     send LIVE. The live send should fire (live hook records it). *)
  live_sends := [];
  (match SR.replay_then_live ~path ~cut:1 registry ~approve_plan:(fun _ -> true) ~live:live_hooks with
  | Ok _ -> assert (!live_sends = [ "alice@x.com" ])  (* send ran live *)
  | Error _ -> failwith "verified replay_then_live should succeed");

  (* a tampered trace (flip a byte) is rejected *)
  let c = In_channel.with_open_text path In_channel.input_all in
  let tampered = Str.replace_first (Str.regexp "alice") "evilx" c in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc tampered);
  (match SR.replay_then_live ~path ~cut:1 registry ~approve_plan:(fun _ -> true) ~live:live_hooks with
  | Error (SR.Integrity _) -> ()
  | _ -> failwith "tampered trace must be rejected");

  Sys.remove path; Sys.remove unsigned;

  (* the heart of the seam: a send whose recipient is UNTRUSTED (needs
     approval). Record with approval granted; then replay-into-live past the
     cut with the LIVE approver DENYING — the recorded approval must NOT
     authorize the live send. *)
  let plan2 : Pl.t =
    [ Call { bind = "r"; tool = "web_search"; args = [ ("query", Lit "addr") ] };
      Call { bind = "s"; tool = "send_message"; args = [ ("to", Var "r"); ("body", Lit "hi") ] };
      Return (Var "s") ]
  in
  let cfg2 sends : SR.config =
    { (cfg ~sends) with plan_with = (fun _ -> Ok plan2) }
  in
  let rs2 = ref [] in
  let _r2, trace2 = SR.run (cfg2 rs2) (T.of_user "go") in
  let p2 = Filename.temp_file "occ" ".strace" in
  Tr.save trace2 p2;
  let denied_sends = ref [] in
  let deny_hooks : St.exec_hooks =
    { live_hooks with
      run_tool =
        (fun ~tool ~args ->
          (match tool with
          | "send_message" ->
              let g f = match List.assoc_opt f args with Some (v : St.value) -> v.data | None -> "" in
              denied_sends := (g "to") :: !denied_sends
          | _ -> ());
          Ok "live");
      approve = (fun ~tool:_ ~field:_ ~value:_ -> false)  (* live approver DENIES *) }
  in
  (match SR.replay_then_live ~path:p2 ~cut:1 registry ~approve_plan:(fun _ -> true) ~live:deny_hooks with
  | Error (SR.Replay (SR.Exec_replay (St.Approval_denied _))) -> assert (!denied_sends = [])
  | Ok _ -> failwith "live send must be blocked by the denying live approver"
  | Error _ -> failwith "expected approval-denied, not another error");

  (* MEDIUM-1: denying the whole-plan approval for the live tail stops the run
     before any live sink; no live send occurs *)
  denied_sends := [];
  (match SR.replay_then_live ~path:p2 ~cut:1 registry ~approve_plan:(fun _ -> false)
           ~live:{ deny_hooks with approve = (fun ~tool:_ ~field:_ ~value:_ -> true) } with
  | Error SR.Live_plan_denied -> assert (!denied_sends = [])
  | _ -> failwith "denied whole-plan approval must stop the live continuation");

  (* HIGH: cut exceeding the recorded tool count is rejected (no confused
     deputy where a live call is gated by a replayed approval) *)
  (match SR.replay_then_live ~path:p2 ~cut:99 registry ~approve_plan:(fun _ -> true) ~live:deny_hooks with
  | Error (SR.Cut_exceeds_recording _) -> ()
  | _ -> failwith "cut beyond the recording must be rejected");
  Sys.remove p2;

  print_endline "all replay-live tests passed"
