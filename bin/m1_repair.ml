(* M1 repair-loop measurement (goal item 4). Two arms, gemma4:12b only
   (the model with observed M0 failures):

   Arm A "repair":   original M0 prompt, Occamel.Repair with max_repairs=2.
   Arm B "exemplar": prompt + return-exemplar, NO repair (isolates the
                     exemplar's effect on first-shot validity).

   Writes docs/research/m0-raw/m1-repair-{a,b}.jsonl. *)

open Eval_common

let run_arm ~sw ~net ~clock ~label ~system ~with_repair oc =
  List.iter
    (fun (t : task) ->
      let config : Occamel_oai.Client.config =
        {
          base_url;
          model = gemma.model;
          temperature = Some gemma.temperature;
          top_p = Some gemma.top_p;
          max_tokens = Some 3000;
        }
      in
      let base_messages =
        Occamel_oai.Client.
          [
            { role = "system"; content = system };
            { role = "user"; content = t.prompt ^ gemma.user_suffix };
          ]
      in
      let ask ~extra =
        let messages =
          base_messages
          @ List.map (fun c -> Occamel_oai.Client.{ role = "user"; content = c }) extra
        in
        match
          Occamel_oai.Client.chat ~sw ~net config
            ~response_format:{ name = "plan"; strict = true; schema = Occamel.Plan.schema }
            ~messages ()
        with
        | Ok r -> Ok r.content
        | Error e -> Error e
      in
      let t0 = Eio.Time.now clock in
      let max_repairs = if with_repair then 2 else 0 in
      let result =
        Occamel.Repair.run ~max_repairs ~ask ~parse:Occamel.Plan.of_string
          ~schema:Occamel.Plan.schema ()
      in
      let ms = int_of_float ((Eio.Time.now clock -. t0) *. 1000.) in
      let errors_json errs =
        `List (List.map (fun e -> `String (Occamel.Codec.error_to_string e)) errs)
      in
      let record =
        match result with
        | Ok (plan, prior_errors) ->
            let checks = check_plan t plan in
            `Assoc
              [
                ("task", `String t.id);
                ("final_valid", `Bool true);
                ("first_try_valid", `Bool (prior_errors = []));
                ("repairs_used", `Int (List.length prior_errors));
                ("attempt_errors", errors_json prior_errors);
                ("checks", `Assoc (List.map (fun (k, v) -> (k, `Bool v)) checks));
                ("all_checks", `Bool (List.for_all snd checks));
                ("plan", Occamel.Plan.to_json plan);
                ("ms", `Int ms);
              ]
        | Error (`Unparseable errs) ->
            `Assoc
              [
                ("task", `String t.id);
                ("final_valid", `Bool false);
                ("first_try_valid", `Bool false);
                ("repairs_used", `Int (max 0 (List.length errs - 1)));
                ("attempt_errors", errors_json errs);
                ("ms", `Int ms);
              ]
        | Error (`Backend e) ->
            `Assoc
              [
                ("task", `String t.id);
                ("final_valid", `Bool false);
                ("backend_error", `String (Occamel_oai.Client.error_to_string e));
                ("ms", `Int ms);
              ]
      in
      output_string oc (Yojson.Safe.to_string record ^ "\n");
      flush oc;
      let tag =
        match result with
        | Ok (_, []) -> "ok"
        | Ok (_, errs) -> Printf.sprintf "REPAIRED(%d)" (List.length errs)
        | Error (`Unparseable _) -> "EXHAUSTED"
        | Error (`Backend _) -> "BACKEND-ERR"
      in
      Printf.printf "  [%s] %-14s %-12s %6dms\n%!" label t.id tag ms)
    tasks

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let out_dir = ensure_out_dir () in
  (match probe ~sw ~net gemma with
  | Ok (true, _) -> Printf.printf "probe ok (%s)\n%!" gemma.label
  | Ok (false, raw) ->
      Printf.printf "PROBE FAILED: %s\n%!" (String.sub raw 0 (min 120 (String.length raw)));
      exit 1
  | Error e ->
      Printf.printf "PROBE TRANSPORT FAILURE: %s\n%!" e;
      exit 1);
  let which = if Array.length Sys.argv > 1 then Sys.argv.(1) else "all" in
  if which = "all" || which = "a" then (
    let oc_a = open_out (Filename.concat out_dir "m1-repair-a.jsonl") in
    run_arm ~sw ~net ~clock ~label:"A:repair" ~system:system_prompt ~with_repair:true oc_a;
    close_out oc_a);
  if which = "all" || which = "b" then (
    let oc_b = open_out (Filename.concat out_dir "m1-repair-b.jsonl") in
    run_arm ~sw ~net ~clock ~label:"B:exemplar" ~system:(system_prompt ^ return_exemplar)
      ~with_repair:false oc_b;
    close_out oc_b)
