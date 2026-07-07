(* M2 loop-mode driver: record a golden trace against local Ollama, or replay
   one offline.

     m2_agent record <trace-file> [question]
     m2_agent replay <trace-file> [question]

   The production [ask] adapts Occamel.Loop's callback to occamel-oai. *)

let question_default = "What year was OCaml first released?"

let production_ask ~sw ~net ctx ~name ~schema =
  let config : Occamel_oai.Client.config =
    {
      base_url = Eval_common.base_url;
      model = Eval_common.qwen.model;
      temperature = Some Eval_common.qwen.temperature;
      top_p = Some Eval_common.qwen.top_p;
      max_tokens = Some 2000;
    }
  in
  let messages =
    List.map
      (fun (m : Occamel.Loop.Ctx.message) ->
        (* qwen3 thinking off, per CLAUDE.md model guidance *)
        let content =
          if m.role = "user" then m.content ^ Eval_common.qwen.user_suffix else m.content
        in
        Occamel_oai.Client.{ role = m.role; content })
      ctx
  in
  match
    Occamel_oai.Client.chat ~sw ~net config
      ~response_format:{ name; strict = true; schema }
      ~messages ()
  with
  | Ok r -> Ok r.content
  | Error e -> Error (Occamel_oai.Client.error_to_string e)

let () =
  let mode = if Array.length Sys.argv > 1 then Sys.argv.(1) else "record" in
  let trace_file = if Array.length Sys.argv > 2 then Sys.argv.(2) else "trace.jsonl" in
  let question = if Array.length Sys.argv > 3 then Sys.argv.(3) else question_default in
  match mode with
  | "record" ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let result, trace =
        Occamel.Loop.run
          ~ask:(production_ask ~sw ~net)
          (Occamel_examples.Research_agent.agent ~question)
      in
      (match result with
      | Ok answer ->
          Occamel.Trace.save trace trace_file;
          Printf.printf "answer: %s\ntrace: %s (%d events)\n" answer trace_file
            (List.length trace)
      | Error (`Ask_backend e) -> Printf.printf "backend failure: %s\n" e
      | Error (`Unparseable errs) ->
          Printf.printf "repair exhausted after %d attempts\n" (List.length errs))
  | "replay" -> (
      match Occamel.Trace.load trace_file with
      | Error e ->
          Printf.printf "trace load failed: %s\n" e;
          exit 1
      | Ok trace -> (
          match
            Occamel.Loop.replay ~trace (Occamel_examples.Research_agent.agent ~question)
          with
          | Ok answer -> Printf.printf "replayed answer: %s\n" answer
          | Error `Trace_exhausted ->
              Printf.printf "replay: trace exhausted\n";
              exit 1
          | Error (`Mismatch m) ->
              Printf.printf "replay mismatch: %s\n" m;
              exit 1))
  | other ->
      Printf.printf "unknown mode %S (use record|replay)\n" other;
      exit 1
