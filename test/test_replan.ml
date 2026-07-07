(* M4 replan-on-Tool_error (§6.5), offline with a mock planner.
   The planner returns a plan using a tool that fails; on the revised (still
   trusted) goal it returns a plan using a working tool. We assert: replan
   recovers, and the planner is only ever handed trusted text (no tool content,
   no error string). *)

module SR = Occamel.Strict_run
module St = Occamel.Strict
module Pl = Occamel.Plan
module T = Occamel.Trusted

let registry = St.registry []

(* a planner that inspects the (trusted) goal text: first attempt uses a
   failing tool; once the goal carries the revision note, it uses web_search *)
let seen_goals = ref []

let plan_with (goal : T.t) : (Pl.t, string) result =
  let g = T.to_string goal in
  seen_goals := g :: !seen_goals;
  let contains sub =
    let n = String.length sub and h = String.length g in
    let rec go i = i + n <= h && (String.sub g i n = sub || go (i + 1)) in
    go 0
  in
  if contains "Revision" then
    Ok [ Pl.Call { bind = "r"; tool = "web_search"; args = [ ("query", Lit "mountains") ] };
         Pl.Return (Var "r") ]
  else
    Ok [ Pl.Call { bind = "r"; tool = "flaky"; args = [ ("q", Lit "x") ] }; Pl.Return (Var "r") ]

let run_tool ~tool ~args:_ : (string, string) result =
  match tool with
  | "web_search" -> Ok "Top result: Everest."
  | "flaky" -> Error "upstream timeout"  (* harness-generated failure *)
  | other -> Error ("no tool " ^ other)

let cfg : SR.config =
  {
    registry;
    plan_with;
    extract_with = (fun ~source:_ ~question:_ -> "");
    run_tool;
    approve_plan = SR.auto_approve_plan;
  }

let () =
  (* without replan, the flaky tool fails the run *)
  (match fst (SR.run cfg (T.of_user "find the tallest mountain")) with
  | Error (SR.Exec (St.Tool_error { tool = "flaky"; _ })) -> ()
  | _ -> failwith "expected flaky tool error");

  (* with replan, the planner revises to web_search and succeeds *)
  seen_goals := [];
  (match fst (SR.run_with_replan ~max_replans:1 cfg (T.of_user "find the tallest mountain")) with
  | Ok v -> assert (String.length v.St.data > 0)
  | _ -> failwith "replan should recover");

  (* the planner saw two goals, both containing only the user text and the
     STATIC revision note — never the tool error string "upstream timeout" *)
  assert (List.length !seen_goals = 2);
  List.iter
    (fun g ->
      let contains sub =
        let n = String.length sub and h = String.length g in
        let rec go i = i + n <= h && (String.sub g i n = sub || go (i + 1)) in
        go 0
      in
      assert (not (contains "upstream timeout")))
    !seen_goals;

  (* a denied sink is NOT replanned (only transient tool failures are) *)
  let deny_reg = St.registry [ St.require_trusted ~tool:"web_search" ~fields:[ "query" ] ] in
  let deny_planner (_ : T.t) : (Pl.t, string) result =
    (* query derived from a prior tool result => untrusted => denied *)
    Ok [ Pl.Call { bind = "a"; tool = "src"; args = [ ("q", Lit "x") ] };
         Pl.Call { bind = "r"; tool = "web_search"; args = [ ("query", Var "a") ] };
         Pl.Return (Var "r") ]
  in
  let deny_cfg = { cfg with registry = deny_reg; plan_with = deny_planner;
                   run_tool = (fun ~tool:_ ~args:_ -> Ok "x") } in
  let calls = ref 0 in
  let counting = { deny_cfg with plan_with = (fun g -> incr calls; deny_planner g) } in
  (match fst (SR.run_with_replan ~max_replans:3 counting (T.of_user "go")) with
  | Error (SR.Plan_rejected _) -> ()  (* rejected at admission, not replanned *)
  | Error (SR.Exec (St.Denied_sink _)) -> ()
  | _ -> failwith "denied sink should not be silently recovered");
  assert (!calls = 1);  (* no replan attempts for a non-transient failure *)

  print_endline "all replan tests passed"
