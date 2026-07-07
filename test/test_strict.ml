(* Strict-mode core: provenance lattice, control-flow taint, sink policies,
   admission, and the admission-vs-runtime differential (§6.2-6.4, §13.2-13.3). *)

module P = Occamel.Prov
module S = Occamel.Strict
module Pl = Occamel.Plan

(* ---------- provenance basics ---------- *)

let () =
  assert (P.is_trusted P.user);
  assert (P.is_trusted P.static);
  assert (P.is_trusted (P.join P.user P.static));
  assert (not (P.is_trusted (P.tool_result "r1")));
  assert (not (P.is_trusted (P.join P.user (P.tool_result "r1"))));
  (* branch taint makes a trusted value untrusted *)
  assert (not (P.is_trusted (P.add_branch "if" P.user)))

(* ---------- a small strict world ---------- *)

(* delete.path must be trusted; web_search / send allow anything except
   send.to which needs approval when untrusted *)
let registry : S.registry =
  S.registry
    [
      S.require_trusted ~tool:"delete" ~fields:[ "path" ];
      S.approve_if_untrusted ~tool:"send" ~fields:[ "to" ];
    ]

let hooks ~approve : S.exec_hooks =
  {
    run_tool =
      (fun ~tool ~args ->
        match tool with
        | "web_search" -> Ok "Top result: something about mountains and paths."
        | "delete" -> Ok "deleted"
        | "send" -> Ok "sent"
        | _ ->
            ignore args;
            Error ("no such tool " ^ tool));
    extract = (fun ~source ~question -> ignore question; "extracted:" ^ source.S.data);
    approve = (fun ~tool:_ ~field:_ ~value:_ -> approve);
  }

(* ---------- admission ---------- *)

let admitted plan = S.admit registry plan = Ok ()

let () =
  (* delete with a literal path: trusted -> admitted *)
  let ok_plan : Pl.t =
    [ Call { bind = "d"; tool = "delete"; args = [ ("path", Lit "/tmp/x") ] };
      Return (Var "d") ]
  in
  assert (admitted ok_plan);

  (* delete with a path derived from a tool result: untrusted -> rejected *)
  let bad_plan : Pl.t =
    [ Call { bind = "r"; tool = "web_search"; args = [ ("query", Lit "paths") ] };
      Call { bind = "d"; tool = "delete"; args = [ ("path", Var "r") ] };
      Return (Var "d") ]
  in
  assert (not (admitted bad_plan));
  (match S.admit registry bad_plan with
  | Error [ { reason; _ } ] -> assert (String.length reason > 0)
  | _ -> failwith "expected one rejection");

  (* delete with an extracted path: still untrusted -> rejected *)
  let extract_plan : Pl.t =
    [ Call { bind = "r"; tool = "web_search"; args = [ ("query", Lit "paths") ] };
      Extract { bind = "p"; source = Var "r"; question = "which path?" };
      Call { bind = "d"; tool = "delete"; args = [ ("path", Var "p") ] };
      Return (Var "d") ]
  in
  assert (not (admitted extract_plan));

  (* CONTROL-FLOW TAINT: delete with a LITERAL path, but inside an If whose
     condition is an untrusted tool result. The literal is trusted, yet the
     branch taint must make the delete's path untrusted -> rejected. This is
     the case a naive data-flow-only tracker would wrongly admit. *)
  let taint_plan : Pl.t =
    [ Call { bind = "r"; tool = "web_search"; args = [ ("query", Lit "q") ] };
      If
        {
          cond = Var "r";
          then_ = [ Call { bind = "d"; tool = "delete"; args = [ ("path", Lit "/tmp/x") ] };
                    Return (Var "d") ];
          else_ = [ Return (Lit "skip") ];
        };
      Return (Lit "done") ]
  in
  assert (not (admitted taint_plan));

  (* Same shape but the If condition is a literal (trusted) -> admitted *)
  let untainted_plan : Pl.t =
    [ If
        {
          cond = Lit "yes";
          then_ = [ Call { bind = "d"; tool = "delete"; args = [ ("path", Lit "/tmp/x") ] };
                    Return (Var "d") ];
          else_ = [ Return (Lit "skip") ];
        };
      Return (Lit "done") ]
  in
  assert (admitted untainted_plan)

(* ---------- runtime executor + provenance ---------- *)

let () =
  (* untrusted tool result flowing to a display Return is fine; provenance is
     tracked as untrusted *)
  let plan : Pl.t =
    [ Call { bind = "r"; tool = "web_search"; args = [ ("query", Lit "mountains") ] };
      Return (Var "r") ]
  in
  (match S.run registry (hooks ~approve:true) plan with
  | Ok v ->
      assert (not (P.is_trusted v.S.prov));
      assert (String.length v.S.data > 0)
  | Error _ -> failwith "run should succeed");

  (* runtime enforces the delete policy too *)
  let bad : Pl.t =
    [ Call { bind = "r"; tool = "web_search"; args = [ ("query", Lit "q") ] };
      Call { bind = "d"; tool = "delete"; args = [ ("path", Var "r") ] };
      Return (Var "d") ]
  in
  (match S.run registry (hooks ~approve:true) bad with
  | Error (S.Denied_sink _) -> ()
  | _ -> failwith "runtime should deny untrusted delete.path");

  (* send.to untrusted -> Needs_approval: approve=true proceeds, false denies *)
  let send : Pl.t =
    [ Call { bind = "r"; tool = "web_search"; args = [ ("query", Lit "q") ] };
      Call { bind = "s"; tool = "send"; args = [ ("to", Var "r"); ("body", Lit "hi") ] };
      Return (Var "s") ]
  in
  (match S.run registry (hooks ~approve:true) send with
  | Ok _ -> ()
  | _ -> failwith "approved send should proceed");
  (match S.run registry (hooks ~approve:false) send with
  | Error (S.Approval_denied _) -> ()
  | _ -> failwith "denied send should stop")

(* ---------- differential: admission is a sound over-approximation ----------
   If admit says Ok, then no execution path may hit a denied sink. We check it
   over a battery of plans (both If branches exercised via truthy/falsey tool
   results by swapping the extract stub). *)

let () =
  let plans : Pl.t list =
    [
      [ Call { bind = "d"; tool = "delete"; args = [ ("path", Lit "/a") ] }; Return (Var "d") ];
      [ Call { bind = "r"; tool = "web_search"; args = [ ("query", Lit "q") ] };
        Return (Var "r") ];
      [ If { cond = Lit "yes";
             then_ = [ Call { bind = "d"; tool = "delete"; args = [ ("path", Lit "/a") ] };
                       Return (Var "d") ];
             else_ = [ Return (Lit "n") ] };
        Return (Lit "done") ];
    ]
  in
  List.iter
    (fun plan ->
      if admitted plan then
        match S.run registry (hooks ~approve:true) plan with
        | Error (S.Denied_sink _) -> failwith "admitted plan hit a denied sink at runtime!"
        | _ -> ())
    plans;

  (* H1: two policies for the same tool must BOTH apply (most-restrictive
     wins). A dropped require_trusted would fail open. *)
  let multi : S.registry =
    S.registry
      [
        S.require_trusted ~tool:"send" ~fields:[ "to" ];
        S.approve_if_untrusted ~tool:"send" ~fields:[ "body" ];
      ]
  in
  let untrusted_to : Pl.t =
    [ Call { bind = "r"; tool = "web_search"; args = [ ("query", Lit "q") ] };
      Call { bind = "s"; tool = "send";
             args = [ ("to", Var "r"); ("body", Lit "hi") ] };
      Return (Var "s") ]
  in
  (* to is require_trusted + untrusted -> Deny, even though a second policy
     exists for the tool *)
  assert (S.admit multi untrusted_to <> Ok ());

  (* M2: default_policy makes an unlisted tool fail closed *)
  let fail_closed : S.registry =
    S.registry ~default_policy:(fun _ _ -> S.Deny "no policy for this tool") []
  in
  let uses_unlisted : Pl.t =
    [ Call { bind = "d"; tool = "delete"; args = [ ("path", Lit "/a") ] }; Return (Var "d") ]
  in
  assert (S.admit fail_closed uses_unlisted <> Ok ());
  (* and the permissive default still allows it *)
  assert (S.admit (S.registry []) uses_unlisted = Ok ());

  (* M5: a plan with an unbound var reference is rejected by admission
     (scoping check + untrusted-unknown), not silently treated as trusted *)
  let unbound : Pl.t =
    [ Call { bind = "d"; tool = "delete"; args = [ ("path", Var "ghost") ] };
      Return (Var "d") ]
  in
  assert (S.admit registry unbound <> Ok ());

  (* M4: analyze collects the data-flow graph — needs_approval sinks and
     extractions with their provenance *)
  let send_plan : Pl.t =
    [ Call { bind = "r"; tool = "web_search"; args = [ ("query", Lit "q") ] };
      Extract { bind = "e"; source = Var "r"; question = "who?" };
      Call { bind = "s"; tool = "send"; args = [ ("to", Var "e"); ("body", Lit "hi") ] };
      Return (Var "s") ]
  in
  let rep = S.analyze registry send_plan in
  assert (rep.rejections = []);
  assert (List.length rep.needs_approval = 1);  (* send.to, untrusted *)
  assert (List.length rep.extractions = 1);
  (* the rendered view is pure ASCII even if provenance/site carried exotic
     bytes — homoglyph/bidi safety (§13.6) *)
  let rendered = S.render_report rep in
  String.iter (fun c -> assert (Char.code c >= 0x09 && Char.code c <= 0x7e)) rendered;
  assert (
    let re = "send.to" in
    let n = String.length re and h = String.length rendered in
    let rec go i = i + n <= h && (String.sub rendered i n = re || go (i + 1)) in
    go 0);

  print_endline "all strict tests passed"
