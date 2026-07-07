(* Loop-mode record/replay tests — fully offline. A scripted [ask] plays the
   model; we record a trace, replay it deterministically, and verify that
   every divergence class fails loudly (§9). Also exercises the approval
   handler on a dangerous tool, including the denied path. *)

module L = Occamel.Loop
module R = Occamel_examples.Research_agent

let scripted responses =
  let remaining = ref responses in
  fun _ctx ~name:_ ~schema:_ ->
    match !remaining with
    | [] -> Error "script exhausted"
    | r :: rest ->
        remaining := rest;
        Ok r

let search_json = {|{"kind":"search","value":{"query":"ocaml release year"}}|}
let answer_json = {|{"kind":"answer","text":"1996"}|}

let () =
  (* --- record with a scripted model --- *)
  let result, trace =
    L.run ~ask:(scripted [ search_json; answer_json ]) (R.agent ~question:"When was OCaml released?")
  in
  (match result with
  | Ok "1996" -> ()
  | Ok other -> failwith ("unexpected answer: " ^ other)
  | Error _ -> failwith "run failed");
  assert (List.length trace = 4) (* ask, note, tool, ask *);

  (* --- trace survives serialization --- *)
  let file = Filename.temp_file "occamel" ".trace.jsonl" in
  Occamel.Trace.save trace file;
  let trace' =
    match Occamel.Trace.load file with Ok t -> t | Error e -> failwith e
  in
  Sys.remove file;
  assert (trace' = trace);

  (* --- deterministic replay --- *)
  (match L.replay ~trace:trace' (R.agent ~question:"When was OCaml released?") with
  | Ok "1996" -> ()
  | _ -> failwith "replay failed");

  (* --- divergence: different question => ctx hash mismatch, loud --- *)
  (match L.replay ~trace:trace' (R.agent ~question:"Something else entirely?") with
  | Error (`Mismatch m) when String.length m > 0 -> ()
  | _ -> failwith "expected ctx-hash mismatch");

  (* --- divergence: tampered tool args, loud --- *)
  let tampered =
    List.map
      (function
        | Occamel.Trace.Tool_call r ->
            Occamel.Trace.Tool_call
              { r with args = `Assoc [ ("query", `String "evil query") ] }
        | e -> e)
      trace'
  in
  (match L.replay ~trace:tampered (R.agent ~question:"When was OCaml released?") with
  | Error (`Mismatch _) -> ()
  | _ -> failwith "expected args mismatch");

  (* --- divergence: schema hash drift, loud --- *)
  let drifted =
    List.map
      (function
        | Occamel.Trace.Ask_response r ->
            Occamel.Trace.Ask_response { r with schema_hash = "0000" }
        | e -> e)
      trace'
  in
  (match L.replay ~trace:drifted (R.agent ~question:"When was OCaml released?") with
  | Error (`Mismatch _) -> ()
  | _ -> failwith "expected schema-hash mismatch");

  (* --- approval handler on a dangerous tool, approved and denied --- *)
  let delete : (R.search_args, R.search_results) L.Tool_def.t =
    { R.web_search with name = "delete_everything"; dangerous = true }
  in
  let call_dangerous () =
    match Effect.perform (L.Invoke (delete, { R.query = "all of it" })) with
    | Ok r -> "ran: " ^ r.R.text
    | Error e -> e
  in
  let approved_result, approved_trace =
    L.run ~ask:(scripted []) ~approve:(fun _ -> L.Approved) call_dangerous
  in
  (match approved_result with
  | Ok s when String.length s > 4 && String.sub s 0 4 = "ran:" -> ()
  | _ -> failwith "approved dangerous tool should run");
  (match L.replay ~trace:approved_trace call_dangerous with
  | Ok _ -> ()
  | _ -> failwith "replay of approved dangerous call failed");

  let denied_result, denied_trace =
    L.run ~ask:(scripted [])
      ~approve:(fun view ->
        assert (view.tool = "delete_everything");
        L.Denied "not today")
      call_dangerous
  in
  (match denied_result with
  | Ok "approval denied: not today" -> ()
  | _ -> failwith "denied dangerous tool should surface denial");
  (match L.replay ~trace:denied_trace call_dangerous with
  | Ok "approval denied: not today" -> ()
  | _ -> failwith "replay of denied dangerous call failed");

  (* --- §13.6 truncation-safe rendering --- *)
  let long = String.make 5000 'x' in
  let view = L.view_of_args ~tool:"t" (`Assoc [ ("body", `String long) ]) in
  (match view.fields with
  | [ ("body", rendered) ] ->
      assert (String.length rendered < 300);
      assert (String.length rendered >= 2 && String.sub rendered 0 1 = "<")
  | _ -> failwith "render");

  (* --- §13.6 homoglyph/bidi/control escaping (F3): a bidi override and a
         non-ASCII homoglyph must NOT survive into the rendered field --- *)
  let bidi = "/etc/\xe2\x80\xaepasswd" (* U+202E RIGHT-TO-LEFT OVERRIDE *) in
  let view = L.view_of_args ~tool:"rm" (`Assoc [ ("path", `String bidi) ]) in
  (match view.fields with
  | [ ("path", rendered) ] ->
      String.iter (fun c -> assert (Char.code c >= 0x20 && Char.code c <= 0x7e)) rendered;
      (* the escaped bytes of U+202E appear literally *)
      assert (
        let re = "\\xe2\\x80\\xae" in
        let n = String.length re and h = String.length rendered in
        let rec go i = i + n <= h && (String.sub rendered i n = re || go (i + 1)) in
        go 0)
  | _ -> failwith "bidi render");

  print_endline "all replay tests passed"
