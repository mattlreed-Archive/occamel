(* M0 measurement runner: capability probe, then the 15-task planning eval,
   per model. Writes one JSONL record per task to docs/research/m0-raw/.
   Shared pieces (models, probe, prompt, tasks, checks) live in Eval_common. *)

open Eval_common

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let out_dir = ensure_out_dir () in
  List.iter
    (fun (m : mconf) ->
      Printf.printf "=== %s ===\n%!" m.label;
      match probe ~sw ~net m with
      | Error e -> Printf.printf "PROBE TRANSPORT FAILURE: %s — skipping model\n%!" e
      | Ok (false, raw) ->
          Printf.printf "PROBE FAILED (constraint not enforced): %s — skipping model\n%!"
            (String.sub raw 0 (min 120 (String.length raw)))
      | Ok (true, _) ->
          Printf.printf "probe ok: constraint enforced\n%!";
          let oc = open_out (Filename.concat out_dir (m.label ^ ".jsonl")) in
          List.iter
            (fun (t : task) ->
              let config : Occamel_oai.Client.config =
                {
                  base_url;
                  model = m.model;
                  temperature = Some m.temperature;
                  top_p = Some m.top_p;
                  max_tokens = Some 3000;
                }
              in
              let messages =
                Occamel_oai.Client.
                  [
                    { role = "system"; content = system_prompt };
                    { role = "user"; content = t.prompt ^ m.user_suffix };
                  ]
              in
              let t0 = Eio.Time.now clock in
              let result =
                Occamel_oai.Client.chat ~sw ~net config
                  ~response_format:
                    { name = "plan"; strict = true; schema = Occamel.Plan.schema }
                  ~messages ()
              in
              let ms = int_of_float ((Eio.Time.now clock -. t0) *. 1000.) in
              let record =
                match result with
                | Error e ->
                    `Assoc
                      [
                        ("task", `String t.id);
                        ("ok", `Bool false);
                        ("error", `String (Occamel_oai.Client.error_to_string e));
                        ("ms", `Int ms);
                      ]
                | Ok { content; usage } -> (
                    let usage_json =
                      match usage with
                      | Some u ->
                          `Assoc
                            [
                              ("prompt_tokens", `Int u.prompt_tokens);
                              ("completion_tokens", `Int u.completion_tokens);
                            ]
                      | None -> `Null
                    in
                    match Occamel.Plan.of_string content with
                    | Error perr ->
                        `Assoc
                          [
                            ("task", `String t.id);
                            ("ok", `Bool true);
                            ("schema_valid", `Bool false);
                            ("validate_error", `String (Occamel.Plan.error_to_string perr));
                            ("raw", `String content);
                            ("usage", usage_json);
                            ("ms", `Int ms);
                          ]
                    | Ok plan ->
                        let checks = check_plan t plan in
                        let exec =
                          match Occamel.Interp.run plan with
                          | Returned v ->
                              `Assoc [ ("kind", `String "returned"); ("value", `String v) ]
                          | Unsupported f ->
                              `Assoc [ ("kind", `String "unsupported"); ("feature", `String f) ]
                          | Runtime_error e ->
                              `Assoc [ ("kind", `String "runtime_error"); ("error", `String e) ]
                        in
                        `Assoc
                          [
                            ("task", `String t.id);
                            ("ok", `Bool true);
                            ("schema_valid", `Bool true);
                            ("checks", `Assoc (List.map (fun (k, v) -> (k, `Bool v)) checks));
                            ("all_checks", `Bool (List.for_all snd checks));
                            ("plan", Occamel.Plan.to_json plan);
                            ("exec", exec);
                            ("usage", usage_json);
                            ("ms", `Int ms);
                          ])
              in
              output_string oc (Yojson.Safe.to_string record ^ "\n");
              flush oc;
              let ok =
                match record with
                | `Assoc kvs -> (
                    match List.assoc_opt "all_checks" kvs with
                    | Some (`Bool true) -> "PASS"
                    | Some (`Bool false) -> "part"
                    | _ -> "FAIL")
                | _ -> "?"
              in
              Printf.printf "  %-14s %s %6dms\n%!" t.id ok ms)
            tasks;
          close_out oc)
    models
