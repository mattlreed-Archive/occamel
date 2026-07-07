(* Differential fuzz harness (design doc §13.10): run identical byte streams
   through the ORIGINAL eventsource-parser (TS, via node) and the OCaml port,
   and compare normalized output sequences.

   Usage:
     EVENTSOURCE_UPSTREAM=/path/to/eventsource-parser \
       dune exec --root . test/differential/diff_fuzz.exe -- [-n CASES] [-seed N]

   Requirements (offline once cloned): node >= 23 on PATH, and a clone of
   https://github.com/rexxars/eventsource-parser checked out at the pinned
   commit 83db3dec52a3494e22ee7e6eb4e1349380f75e36. Not part of the default
   test alias — see docs/ports/eventsource-parser.md for the recorded runs. *)

let pinned_commit = "83db3dec52a3494e22ee7e6eb4e1349380f75e36"

(* ---- case generation (QCheck.Gen) ---- *)

type case = { chunks : string list; max : int option; consume : bool }

open QCheck.Gen

let printable = map Char.chr (int_range 32 126)

(* Field values: printable ASCII, multibyte UTF-8, invalid UTF-8, empties. *)
let value =
  oneof_weighted
    [
      (6, string_size ~gen:printable (int_bound 12));
      (1, return "\xe2\x9c\x94 \xf0\x9f\x98\xb6\xe2\x80\x8d\xf0\x9f\x8c\xab\xef\xb8\x8f");
      (1, return "\xe6\x88\x91\xe7\x8f\xbe\xe5\x9c\xa8");
      (1, return "\xff\xfe\x80");
      (1, map (fun s -> s ^ "\x00" ^ s) (string_size ~gen:printable (int_bound 4)));
      (1, return "");
    ]

(* Structured SSE-shaped lines, valid and near-valid. *)
let sse_line =
  oneof_weighted
    [
      (8, map (fun v -> "data: " ^ v) value);
      (3, map (fun v -> "data:" ^ v) value);
      (2, map (fun v -> "event: " ^ v) value);
      (1, return "event:");
      (2, map (fun v -> "id: " ^ v) value);
      (1, map (fun v -> "id:" ^ v ^ "\x00") value);
      (2, map (fun n -> "retry: " ^ string_of_int n) (int_bound 100_000));
      (1, map (fun v -> "retry: " ^ v) value);
      (1, return "retry:");
      (1, return "retry: 99999999999999999999999999");
      (2, map (fun v -> ": " ^ v) value);
      (1, map (fun v -> ":" ^ v) value);
      (2, map (fun v -> "x-unknown: " ^ v) value);
      (1, value); (* bare line: unknown field / colon-less *)
      (1, oneof_list [ "data"; "event"; "id"; "retry"; ":"; "DATA: nope" ]);
      (3, return ""); (* blank line: dispatch *)
    ]

let terminator = oneof_weighted [ (5, return "\n"); (2, return "\r\n"); (2, return "\r") ]

let structured_stream =
  let* lines = list_size (int_bound 16) (pair sse_line terminator) in
  let* lead = oneof_weighted [ (8, return ""); (1, return "\xef\xbb\xbf"); (1, return "\xef\xbb") ] in
  let* trailing = oneof_weighted [ (3, return ""); (1, map (fun v -> "data: " ^ v) value); (1, value) ] in
  return (lead ^ String.concat "" (List.map (fun (l, t) -> l ^ t) lines) ^ trailing)

(* Adversarial fragments: truncation, interleaving, oversize, pathological
   line endings, BOMs mid-stream, NULs, invalid UTF-8. *)
let adversarial_stream =
  let fragment =
    oneof_weighted
      [
        (3, oneof_list
             [ "data"; "data:"; "dat"; "a:"; ":"; "::"; ":\x00"; "\x00"; "id:\x00x";
               "retry:"; "retry:12x"; "retry: 007"; "event:"; "ev"; "ent: x";
               "\xef\xbb\xbf"; "\xef"; "\xbb\xbf"; "\xff\xfe"; " "; "  :  ";
               "data\r"; "data\rdata"; ":\r"; "\r"; "\n"; "\r\n"; "\n\r"; "\r\r"; "\n\n" ]);
        (2, map (fun v -> "data: " ^ v) value);
        (1, map (fun n -> String.make (n + 200) 'x') (int_bound 3000));
        (1, map (fun n -> "data: " ^ String.make (n + 200) 'y') (int_bound 3000));
        (1, value);
      ]
  in
  map (String.concat "") (list_size (int_bound 24) fragment)

(* Byte soup biased toward SSE-significant bytes. *)
let byte_soup =
  let sse_byte =
    oneof_list
      [ 'd'; 'a'; 't'; 'e'; 'v'; 'n'; 'i'; 'r'; 'y'; ':'; ' '; '\n'; '\r';
        '\x00'; '\xef'; '\xbb'; '\xbf'; '0'; '5'; '9'; 'x'; '\xff' ]
  in
  string_size ~gen:(oneof_weighted [ (4, sse_byte); (1, map Char.chr (int_bound 255)) ]) (int_bound 80)

let stream =
  oneof_weighted [ (5, structured_stream); (3, adversarial_stream); (2, byte_soup) ]

(* Random chunk splits over the same byte stream, including byte-at-a-time. *)
let chunks_of stream =
  let n = String.length stream in
  let split_at cuts =
    let rec go start = function
      | [] -> if start >= n then [] else [ String.sub stream start (n - start) ]
      | c :: rest -> String.sub stream start (c - start) :: go c rest
    in
    go 0 (List.sort_uniq compare (List.filter (fun c -> c > 0 && c < n) cuts))
  in
  oneof_weighted
    [
      (2, return [ stream ]);
      (5, map split_at (list_size (int_bound 8) (int_bound (max n 1))));
      (1, return (List.init n (fun i -> String.make 1 stream.[i])));
    ]

let case_gen =
  let* stream = stream in
  let* chunks = chunks_of stream in
  let* max = oneof_weighted [ (7, return None); (3, map (fun m -> Some (m + 1)) (int_bound 100)) ] in
  let* consume = bool in
  return { chunks; max; consume }

(* ---- normalization (must match runner.mjs) ---- *)

let hex s =
  let b = Buffer.create (String.length s * 2) in
  String.iter (fun c -> Buffer.add_string b (Printf.sprintf "%02x" (Char.code c))) s;
  Buffer.contents b

let norm : Occamel_wire.Eventsource.output -> string = function
  | Event { id; event_type; data } ->
      Printf.sprintf "event %s %s %s"
        (match id with None -> "-" | Some s -> hex s)
        (match event_type with None -> "-" | Some s -> hex s)
        (hex data)
  | Retry n ->
      Printf.sprintf "retry %s"
        (if n > 1_000_000_000_000_000 then "BIG" else string_of_int n)
  | Comment c -> Printf.sprintf "comment %s" (hex c)
  | Parse_error (Invalid_retry { value; line }) ->
      Printf.sprintf "error invalid-retry %s %s" (hex value) (hex line)
  | Parse_error (Unknown_field { field; value; line }) ->
      Printf.sprintf "error unknown-field %s %s %s" (hex field) (hex value) (hex line)
  | Parse_error (Buffer_limit_exceeded _) -> "error max-buffer"

let run_port { chunks; max; consume } =
  let open Occamel_wire.Eventsource in
  let t = create ?max_buffer_size:max () in
  let t, out =
    List.fold_left
      (fun (t, acc) chunk ->
        let t, out = feed t chunk in
        (t, List.rev_append out acc))
      (t, []) chunks
  in
  let out =
    if consume then
      let _t, out' = reset ~consume:true t in
      List.rev_append out' out
    else out
  in
  List.rev_map norm out

(* ---- JSON plumbing (hex payloads only: no escaping subtleties) ---- *)

let case_to_json { chunks; max; consume } =
  `Assoc
    [
      ("chunks", `List (List.map (fun c -> `String (hex c)) chunks));
      ("max", match max with None -> `Null | Some m -> `Int m);
      ("consume", `Bool consume);
    ]

let show_case { chunks; max; consume } =
  Printf.sprintf "max=%s consume=%b chunks=[%s]"
    (match max with None -> "none" | Some m -> string_of_int m)
    consume
    (String.concat "; " (List.map (Printf.sprintf "%S") chunks))

(* ---- driver ---- *)

let () =
  let n_cases = ref 10_000 in
  let seed = ref 20260706 in
  let speclist =
    [
      ("-n", Arg.Set_int n_cases, "number of generated cases (default 10000)");
      ("-seed", Arg.Set_int seed, "PRNG seed (default 20260706)");
    ]
  in
  Arg.parse speclist (fun _ -> ()) "diff_fuzz [-n CASES] [-seed N]";
  let upstream =
    match Sys.getenv_opt "EVENTSOURCE_UPSTREAM" with
    | Some dir -> dir
    | None ->
        prerr_endline
          "EVENTSOURCE_UPSTREAM not set: point it at a clone of\n\
           https://github.com/rexxars/eventsource-parser pinned at commit\n\
           83db3dec52a3494e22ee7e6eb4e1349380f75e36.";
        exit 2
  in
  let parse_ts = Filename.concat upstream "src/parse.ts" in
  if not (Sys.file_exists parse_ts) then (
    Printf.eprintf "upstream source not found: %s\n" parse_ts;
    exit 2);
  (* Refuse to fuzz against the wrong oracle. *)
  let head_cmd =
    Printf.sprintf "git -C %s rev-parse HEAD" (Filename.quote upstream)
  in
  let ic = Unix.open_process_in head_cmd in
  let head = try input_line ic with End_of_file -> "" in
  ignore (Unix.close_process_in ic);
  if head <> pinned_commit then (
    Printf.eprintf "upstream clone at %s is at %s, expected pinned %s\n" upstream
      head pinned_commit;
    exit 2);

  let rand = Random.State.make [| !seed |] in
  let cases = List.init !n_cases (fun _ -> generate1 ~rand case_gen) in

  (* Feed all cases through the original implementation in one node run. *)
  let tmp_cases = Filename.temp_file "diff_fuzz_cases" ".jsonl" in
  let oc = open_out tmp_cases in
  List.iter
    (fun c ->
      Yojson.Basic.to_channel oc (case_to_json c);
      output_char oc '\n')
    cases;
  close_out oc;
  let tmp_out = Filename.temp_file "diff_fuzz_expected" ".jsonl" in
  (* runner.mjs sits beside the executable when copied by the dune rule;
     otherwise use the source path relative to the repo root. *)
  let runner =
    let beside = Filename.concat (Filename.dirname Sys.argv.(0)) "runner.mjs" in
    if Sys.file_exists beside then beside else "test/differential/runner.mjs"
  in
  let cmd =
    Printf.sprintf "node %s %s < %s > %s" (Filename.quote runner)
      (Filename.quote parse_ts) (Filename.quote tmp_cases) (Filename.quote tmp_out)
  in
  let rc = Sys.command cmd in
  if rc <> 0 then (
    Printf.eprintf "node runner failed (exit %d): %s\n" rc cmd;
    exit 2);

  let expected =
    let ic = open_in tmp_out in
    let rec go acc =
      match input_line ic with
      | line ->
          let outs =
            match Yojson.Basic.from_string line with
            | `List l -> List.map (function `String s -> s | _ -> assert false) l
            | _ -> assert false
          in
          go (outs :: acc)
      | exception End_of_file ->
          close_in ic;
          List.rev acc
    in
    go []
  in
  if List.length expected <> List.length cases then (
    Printf.eprintf "case/result count mismatch: %d cases, %d results\n"
      (List.length cases) (List.length expected);
    exit 2);

  (* Corpus shape stats, so a passing run is demonstrably non-vacuous. *)
  let events = ref 0
  and retries = ref 0
  and comments = ref 0
  and errors = ref 0
  and overflows = ref 0
  and empty_cases = ref 0 in
  let divergences = ref 0 in
  List.iter2
    (fun case exp ->
      let got = run_port case in
      if got = [] then incr empty_cases;
      List.iter
        (fun o ->
          match String.split_on_char ' ' o with
          | "event" :: _ -> incr events
          | "retry" :: _ -> incr retries
          | "comment" :: _ -> incr comments
          | "error" :: "max-buffer" :: _ -> incr overflows
          | "error" :: _ -> incr errors
          | _ -> ())
        got;
      if got <> exp then begin
        incr divergences;
        if !divergences <= 10 then begin
          Printf.printf "DIVERGENCE #%d\ncase: %s\n" !divergences (show_case case);
          Printf.printf "  upstream: [%s]\n" (String.concat " | " exp);
          Printf.printf "  port:     [%s]\n\n" (String.concat " | " got)
        end
      end)
    cases expected;
  Sys.remove tmp_cases;
  Sys.remove tmp_out;
  Printf.printf
    "corpus: %d events, %d retries, %d comments, %d field errors, %d overflows; %d/%d cases with no output\n"
    !events !retries !comments !errors !overflows !empty_cases !n_cases;
  Printf.printf "diff_fuzz: %d cases (seed %d) against upstream %s: %d divergences\n"
    !n_cases !seed
    (String.sub pinned_commit 0 12)
    !divergences;
  if !divergences > 0 then exit 1
