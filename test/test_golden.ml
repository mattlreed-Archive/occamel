(* Golden-trace replay — fully OFFLINE (§9). Loads a trace recorded once
   against local Ollama (test/golden/research.trace.jsonl, committed) and
   replays the SAME loop-mode agent against it deterministically. CI never
   touches the network; a model/schema change that breaks replay is a visible
   test failure, not a silent drift. *)

module L = Occamel.Loop
module R = Occamel_examples.Research_agent

let question = "Use web search to find the tallest mountain in the world, then answer with its name."
let trace_path = "golden/research.trace.jsonl"

let () =
  let trace =
    match Occamel.Trace.load trace_path with
    | Ok t -> t
    | Error e -> failwith ("could not load golden trace: " ^ e)
  in
  assert (List.length trace > 0);

  (* Deterministic replay reproduces the recorded run. *)
  let answer =
    match L.replay ~trace (R.agent ~question) with
    | Ok a -> a
    | Error `Trace_exhausted -> failwith "golden replay: trace exhausted"
    | Error (`Mismatch m) -> failwith ("golden replay mismatch: " ^ m)
  in
  assert (String.length answer > 0);

  (* Replaying twice is identical (no hidden state). *)
  let answer2 =
    match L.replay ~trace (R.agent ~question) with Ok a -> a | _ -> failwith "second replay"
  in
  assert (answer = answer2);

  (* A different question diverges the context and MUST fail loudly. *)
  (match L.replay ~trace (R.agent ~question:"totally different question") with
  | Error (`Mismatch _) -> ()
  | _ -> failwith "golden replay should reject a diverged agent");

  Printf.printf "golden replay ok: %s\n" answer
