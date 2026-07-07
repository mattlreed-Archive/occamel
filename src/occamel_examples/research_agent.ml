(* The M0 research agent rewritten as a loop-mode agent (goal item 6).
   Everything at the model boundary is [@@deriving occamel] — the derived
   schema drives Ask, derived codecs drive tool serialization for traces.
   This module is the M1→M2 integration proof. *)

type search_args = { query : string [@doc "Web search query, 1-6 words"] }
[@@deriving occamel]

type search_results = { text : string } [@@deriving occamel]

type action =
  | Search of search_args
  | Answer of { text : string }
[@@deriving occamel]

let web_search : (search_args, search_results) Occamel.Loop.Tool_def.t =
  {
    name = "web_search";
    dangerous = false;
    args_schema = search_args_schema;
    encode_args = search_args_to_json;
    encode_result = search_results_to_json;
    decode_result = search_results_of_json;
    run = (fun { query } -> Ok { text = Occamel.Tool.web_search ~query });
  }

let system_prompt =
  {|You are a research assistant. At each turn, reply with ONLY a JSON action:
- {"kind":"search","value":{"query":"..."}} to run a web search
- {"kind":"answer","text":"..."} to give the final answer once you know it
Search at most twice, then answer.|}

(* Direct-style loop over typed actions — v0.6 design doc §6.6 verbatim. *)
let agent ~(question : string) () : string =
  let open Occamel.Loop in
  let rec go ctx steps =
    if steps >= 4 then "(gave up)"
    else
      match Effect.perform (Ask (ctx, action_typed)) with
      | Search args -> (
          Effect.perform (Note ("searching: " ^ args.query));
          match Effect.perform (Invoke (web_search, args)) with
          | Ok { text } -> go (Ctx.add_tool_result ctx ~tool:"web_search" text) (steps + 1)
          | Error e -> go (Ctx.add_tool_result ctx ~tool:"web_search" ("error: " ^ e)) (steps + 1))
      | Answer { text } -> text
  in
  go (Ctx.make ~system:system_prompt ~user:question) 0
