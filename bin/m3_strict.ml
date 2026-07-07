(* M3 strict-mode driver: plan (P-LLM, trusted prompt) -> admit -> execute
   with the quarantined extractor (Q-LLM) reading untrusted tool output ->
   trace. Record against Ollama, or replay a trace offline.

     m3_strict record <trace-file> [question]
     m3_strict replay <trace-file>

   The planner sees only Trusted.of_user/of_static; tool results reach only
   the Q-LLM. That split is enforced by the types, not by this driver. *)

let default_q = "Use web search to find the tallest mountain in the world, then answer with its name."

(* Same tool world as loop mode; web_search allows any provenance, so the
   research task always admits. A dangerous tool would carry a require_trusted
   policy; the strict test suite exercises that path directly. *)
let registry : Occamel.Strict.registry =
  Occamel.Strict.registry
    [ Occamel.Strict.tool ~name:"web_search" ~caps:[ Occamel.Strict.Net ]
        ~arg_schema:(Occamel.Strict.obj_schema [ ("query", "string") ]) () ]

let planner_prompt = Eval_common.system_prompt

let plan_with ~sw ~net (goal : Occamel.Trusted.t) : (Occamel.Plan.t, string) result =
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
    Occamel_oai.Client.
      [
        { role = "system"; content = planner_prompt };
        { role = "user"; content = Occamel.Trusted.to_string goal ^ Eval_common.qwen.user_suffix };
      ]
  in
  match
    Occamel_oai.Client.chat ~sw ~net config
      ~response_format:{ name = "plan"; strict = true; schema = Occamel.Plan.schema }
      ~messages ()
  with
  | Error e -> Error (Occamel_oai.Client.error_to_string e)
  | Ok r -> Result.map_error Occamel.Codec.error_to_string (Occamel.Plan.of_string r.content)

(* Quarantined extractor: reads untrusted source text, answers into free text.
   No tools available here by construction (it's just a chat call). *)
let extract_with ~sw ~net ~source ~question : string =
  let config : Occamel_oai.Client.config =
    {
      base_url = Eval_common.base_url;
      model = Eval_common.qwen.model;
      temperature = Some 0.0;
      top_p = None;
      max_tokens = Some 200;
    }
  in
  let messages =
    Occamel_oai.Client.
      [
        {
          role = "system";
          content =
            "You extract one fact from provided text. Answer concisely with "
            ^ "only the fact, no preamble.";
        };
        {
          role = "user";
          content =
            Printf.sprintf "Text:\n%s\n\nQuestion: %s%s" source question
              Eval_common.qwen.user_suffix;
        };
      ]
  in
  match Occamel_oai.Client.chat ~sw ~net config ~messages () with
  | Ok r -> String.trim r.content
  | Error e -> "extraction failed: " ^ Occamel_oai.Client.error_to_string e

let run_tool ~tool ~(args : (string * Occamel.Strict.value) list) : (string, string) result =
  match tool with
  | "web_search" -> (
      match List.assoc_opt "query" args with
      | Some v -> Ok (Occamel.Tool.web_search ~query:v.Occamel.Strict.data)
      | None -> Error "web_search needs a query")
  | other -> Error ("no such tool " ^ other)

let () =
  let mode = if Array.length Sys.argv > 1 then Sys.argv.(1) else "record" in
  let trace_file = if Array.length Sys.argv > 2 then Sys.argv.(2) else "strict.trace.jsonl" in
  let question = if Array.length Sys.argv > 3 then Sys.argv.(3) else default_q in
  match mode with
  | "record" ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let cfg : Occamel.Strict_run.config =
        {
          registry;
          plan_with = plan_with ~sw ~net;
          extract_with = extract_with ~sw ~net;
          run_tool;
          approve_plan = Occamel.Strict_run.auto_approve_plan;
        }
      in
      let result, trace = Occamel.Strict_run.run cfg (Occamel.Trusted.of_user question) in
      Occamel.Trace.save trace trace_file;
      (match result with
      | Ok v -> Printf.printf "answer: %s\nprovenance: %s\n" v.Occamel.Strict.data (Occamel.Prov.to_string v.Occamel.Strict.prov)
      | Error e -> Printf.printf "error: %s\n" (Occamel.Strict_run.error_to_string e));
      Printf.printf "trace: %s (%d events)\n" trace_file (List.length trace)
  | "replay" -> (
      match Occamel.Trace.load trace_file with
      | Error e -> Printf.printf "trace load failed: %s\n" e; exit 1
      | Ok trace -> (
          match Occamel.Strict_run.replay ~trace registry with
          | Ok v -> Printf.printf "replayed answer: %s\n" v.Occamel.Strict.data
          | Error e ->
              Printf.printf "replay error: %s\n"
                (match e with
                | Occamel.Strict_run.Bad_trace s -> "bad trace: " ^ s
                | Replan_needed -> "no recorded plan"
                | Readmit_failed _ -> "re-admission failed"
                | Exec_replay _ -> "exec replay failed");
              exit 1))
  | other -> Printf.printf "unknown mode %S\n" other; exit 1
