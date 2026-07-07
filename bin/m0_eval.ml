(* M0 measurement runner: capability probe, then the 15-task planning eval,
   per model. Writes one JSONL record per task to docs/research/m0-raw/. *)

(* 127.0.0.1, not localhost: eio resolves localhost to ::1 first and does not
   fall back across address families; Ollama binds IPv4 only. A real quirk
   for the §B.1 table. *)
let base_url = "http://127.0.0.1:11434/v1"

type mconf = {
  label : string;
  model : string;
  temperature : float;
  top_p : float;
  user_suffix : string;  (* qwen3: " /no_think" *)
}

let models =
  [
    {
      label = "qwen3-14b-nothink";
      model = "qwen3:14b";
      temperature = 0.7;
      top_p = 0.8;
      user_suffix = " /no_think";
    };
    {
      label = "gemma4-12b";
      model = "gemma4:12b";
      temperature = 1.0;
      top_p = 0.95;
      user_suffix = "";
    };
  ]

(* ---------- Capability probe (goal step 3) ----------
   A schema the model cannot satisfy by chance: an arbitrary sentinel enum on
   an off-topic prompt. If enforcement is off, a free answer to the prompt
   will not be exactly {"magic":"xyzzy-4242"}. *)

let probe_schema : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ( "properties",
        `Assoc [ ("magic", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "xyzzy-4242" ]) ]) ] );
      ("required", `List [ `String "magic" ]);
      ("additionalProperties", `Bool false);
    ]

let probe ~sw ~net (m : mconf) : (bool * string, string) result =
  let config : Occamel_oai.Client.config =
    {
      base_url;
      model = m.model;
      temperature = Some 0.0;
      top_p = None;
      max_tokens = Some 500;
    }
  in
  let messages =
    [
      Occamel_oai.Client.
        { role = "user"; content = "Introduce yourself in one short sentence." ^ m.user_suffix };
    ]
  in
  match
    Occamel_oai.Client.chat ~sw ~net config
      ~response_format:{ name = "probe"; strict = true; schema = probe_schema }
      ~messages ()
  with
  | Error e -> Error (Occamel_oai.Client.error_to_string e)
  | Ok { content; _ } -> (
      match Yojson.Safe.from_string content with
      | exception _ -> Ok (false, content)
      | `Assoc [ ("magic", `String "xyzzy-4242") ] -> Ok (true, content)
      | _ -> Ok (false, content))

(* ---------- Planner prompt ---------- *)

let system_prompt =
  {|You are a planner. Reply with ONLY a JSON plan matching the required schema.

Available tool:
  web_search(query: string) -> search results text

Plan semantics — a plan is a list of steps executed in order:
  call:    invoke a tool and bind its result to a fresh name.
  extract: pull one specific piece of information out of a previously bound
           value; bind it to a fresh name.
  if:      cond names a previously bound value treated as yes/no evidence;
           execute then or else. No nested if.
  return:  finish with a value (a bound variable or a literal string).

Rules: bind a name before referencing it; never reuse a bind name; variables
bound inside an if branch are NOT visible after the if; use as few steps as
the task needs; the last executed step must be a return.

Example — task: "What is the capital of Italy?"
{"steps":[
 {"op":"call","bind":"r1","tool":"web_search",
  "args":[{"name":"query","value":{"kind":"lit","value":"capital of Italy"}}]},
 {"op":"extract","bind":"cap","source":{"kind":"var","name":"r1"},
  "question":"What is the capital city?"},
 {"op":"return","value":{"kind":"var","name":"cap"}}]}

Example — task: "Return the word ping without searching."
{"steps":[{"op":"return","value":{"kind":"lit","value":"ping"}}]}|}

(* ---------- Tasks (goal step 5) ---------- *)

type task = {
  id : string;
  prompt : string;
  needs_ops : string list;  (* op kinds a sensible plan must use *)
  keywords : string list;   (* at least one must appear in some query/lit *)
  min_calls : int;
}

let tasks =
  [
    (* easy: single search *)
    { id = "t01-mountain"; prompt = "What is the tallest mountain in the world? Use web search.";
      needs_ops = [ "call"; "return" ]; keywords = [ "mountain"; "tallest" ]; min_calls = 1 };
    { id = "t02-ceo"; prompt = "Find the current CEO of Anthropic.";
      needs_ops = [ "call"; "return" ]; keywords = [ "anthropic"; "ceo" ]; min_calls = 1 };
    { id = "t03-ocaml"; prompt = "What year was OCaml first released?";
      needs_ops = [ "call"; "return" ]; keywords = [ "ocaml" ]; min_calls = 1 };
    { id = "t04-nosearch"; prompt = "Answer directly without searching: return the string 'hello world'.";
      needs_ops = [ "return" ]; keywords = [ "hello world" ]; min_calls = 0 };
    (* medium: search + extract *)
    { id = "t05-population"; prompt = "Find the population of Japan and extract just the number.";
      needs_ops = [ "call"; "extract"; "return" ]; keywords = [ "japan"; "population" ]; min_calls = 1 };
    { id = "t06-book"; prompt = "Who wrote 'The Selfish Gene'? Extract the author's name from search results.";
      needs_ops = [ "call"; "extract"; "return" ]; keywords = [ "selfish gene" ]; min_calls = 1 };
    { id = "t07-ethanol"; prompt = "Search for the boiling point of ethanol; extract the temperature in Celsius.";
      needs_ops = [ "call"; "extract"; "return" ]; keywords = [ "ethanol"; "boiling" ]; min_calls = 1 };
    (* multi-call *)
    { id = "t08-compare"; prompt = "Compare the heights of Mount Everest and K2: search for each separately, then return both heights.";
      needs_ops = [ "call"; "return" ]; keywords = [ "everest"; "k2" ]; min_calls = 2 };
    { id = "t09-langs"; prompt = "Find the first-release years of OCaml and of Haskell using one search per language, and return both years.";
      needs_ops = [ "call"; "return" ]; keywords = [ "ocaml"; "haskell" ]; min_calls = 2 };
    { id = "t10-capitals"; prompt = "Get the capital of Spain and the capital of Portugal (separate searches) and return them.";
      needs_ops = [ "call"; "return" ]; keywords = [ "spain"; "portugal" ]; min_calls = 2 };
    (* conditional *)
    { id = "t11-eiffel"; prompt = "Search whether the Eiffel Tower is taller than 300 meters. If it is, return 'tall'; otherwise return 'short'.";
      needs_ops = [ "call"; "if"; "return" ]; keywords = [ "eiffel" ]; min_calls = 1 };
    { id = "t12-rust2"; prompt = "Find out whether Rust 2.0 has been released. If yes, extract the release date and return it; otherwise return 'not released'.";
      needs_ops = [ "call"; "if"; "return" ]; keywords = [ "rust" ]; min_calls = 1 };
    { id = "t13-weather"; prompt = "Search tomorrow's weather forecast for Paris. If it mentions rain, return 'umbrella', else return 'no umbrella'.";
      needs_ops = [ "call"; "if"; "return" ]; keywords = [ "paris"; "weather" ]; min_calls = 1 };
    (* chained dependency *)
    { id = "t14-moon"; prompt = "Search for Jupiter's largest moon and extract its name. Then search for that moon's diameter and return the diameter.";
      needs_ops = [ "call"; "extract"; "return" ]; keywords = [ "jupiter"; "moon" ]; min_calls = 2 };
    { id = "t15-paper"; prompt = "Find the lead author of the paper 'Defeating Prompt Injections by Design', then search for that author's affiliation and return it.";
      needs_ops = [ "call"; "extract"; "return" ]; keywords = [ "defeating prompt injections" ]; min_calls = 2 };
  ]

(* ---------- Plan checks ---------- *)

let rec ops_of_step (s : Occamel.Plan.step) : string list =
  match s with
  | Call _ -> [ "call" ]
  | Extract _ -> [ "extract" ]
  | Return _ -> [ "return" ]
  | If { then_; else_; _ } ->
      "if" :: (List.concat_map ops_of_step then_ @ List.concat_map ops_of_step else_)

let rec lits_of_step (s : Occamel.Plan.step) : string list =
  let lit = function Occamel.Plan.Lit v -> [ v ] | Var _ -> [] in
  match s with
  | Call { args; _ } -> List.concat_map (fun (_, v) -> lit v) args
  | Extract { source; question; _ } -> question :: lit source
  | Return v -> lit v
  | If { cond; then_; else_ } ->
      lit cond @ List.concat_map lits_of_step then_ @ List.concat_map lits_of_step else_

let contains ~needle haystack =
  let needle = String.lowercase_ascii needle and h = String.lowercase_ascii haystack in
  let n = String.length needle and hl = String.length h in
  let rec go i = i + n <= hl && (String.sub h i n = needle || go (i + 1)) in
  n = 0 || go 0

let check_plan (t : task) (plan : Occamel.Plan.t) : (string * bool) list =
  let ops = List.concat_map ops_of_step plan in
  let lits = lits_of_step |> fun f -> List.concat_map f plan in
  let has_needed = List.for_all (fun o -> List.mem o ops) t.needs_ops in
  let calls = List.length (List.filter (( = ) "call") ops) in
  let keyword_hit =
    t.keywords = []
    || List.exists (fun kw -> List.exists (fun l -> contains ~needle:kw l) lits) t.keywords
  in
  [
    ("uses_needed_ops", has_needed);
    ("min_calls", calls >= t.min_calls);
    ("on_topic", keyword_hit);
  ]

(* ---------- Runner ---------- *)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let out_dir = "docs/research/m0-raw" in
  (try Unix.mkdir "docs" 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir "docs/research" 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir out_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  List.iter
    (fun (m : mconf) ->
      Printf.printf "=== %s ===\n%!" m.label;
      (* Step 3: probe first; a silently dropped constraint aborts this model. *)
      (match probe ~sw ~net m with
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
                          | Returned v -> `Assoc [ ("kind", `String "returned"); ("value", `String v) ]
                          | Unsupported f -> `Assoc [ ("kind", `String "unsupported"); ("feature", `String f) ]
                          | Runtime_error e -> `Assoc [ ("kind", `String "runtime_error"); ("error", `String e) ]
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
          close_out oc))
    models
