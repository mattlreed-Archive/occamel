(* Ported from eventsource-parser test/parse.test.ts + test/fixtures.ts at
   upstream commit 83db3dec52a3494e22ee7e6eb4e1349380f75e36 (v3.1.0, MIT).
   The upstream expectations are the oracle; adaptations are flagged inline
   and recorded in docs/ports/eventsource-parser.md. Fixture async delays are
   dropped (the parser is synchronous; only the chunk sequence matters). *)

open Occamel_wire

let opt = function None -> "-" | Some s -> Printf.sprintf "%S" s

let show_output : Eventsource.output -> string = function
  | Event { id; event_type; data } ->
      Printf.sprintf "Event{id=%s; type=%s; data=%S}" (opt id) (opt event_type) data
  | Retry n -> Printf.sprintf "Retry %d" n
  | Comment c -> Printf.sprintf "Comment %S" c
  | Parse_error (Invalid_retry { value; line }) ->
      Printf.sprintf "Invalid_retry{value=%S; line=%S}" value line
  | Parse_error (Unknown_field { field; value; line }) ->
      Printf.sprintf "Unknown_field{field=%S; value=%S; line=%S}" field value line
  | Parse_error (Buffer_limit_exceeded { limit }) ->
      Printf.sprintf "Buffer_limit_exceeded{limit=%d}" limit

let output_t : Eventsource.output Alcotest.testable =
  Alcotest.testable (Fmt.of_to_string show_output) ( = )

let outputs = Alcotest.(list output_t)

(* Feed a chunk sequence to a fresh parser; collect outputs in order. *)
let run ?max_buffer_size ?(consume = false) chunks =
  let t = Eventsource.create ?max_buffer_size () in
  let t, out =
    List.fold_left
      (fun (t, acc) chunk ->
        let t, out = Eventsource.feed t chunk in
        (t, acc @ out))
      (t, []) chunks
  in
  if consume then
    let _t, out' = Eventsource.reset ~consume:true t in
    out @ out'
  else out

let events_of out =
  List.filter (function Eventsource.Event _ -> true | _ -> false) out

let ev ?id ?typ data = Eventsource.Event { id; event_type = typ; data }
let check = Alcotest.check outputs

(* -- upstream: 'basic unnamed events stream' -- *)
let test_basic () =
  let chunks =
    [ "data: 0\n\n"; "data: 1\n\n"; "data: 2\n\n"; "data: 3\n\n"; "data: 4\n\n";
      "event: done\ndata: \xe2\x9c\x94\n\n" ]
  in
  check "basic"
    [ ev "0"; ev "1"; ev "2"; ev "3"; ev "4"; ev ~typ:"done" "\xe2\x9c\x94" ]
    (run chunks)

(* -- upstream: 'stream of `time` event names, unbalanced chunks' --
   Random split points, deterministic seed. *)
let test_unbalanced_chunks () =
  Random.self_init ();
  let messages =
    List.init 30 (fun i ->
        Printf.sprintf "id: %d\nevent: time\ndata: 2026-07-06T00:00:%02d.000Z\n\n" i i)
  in
  let chunks =
    List.concat_map
      (fun m ->
        let split = Random.int (String.length m) in
        [ String.sub m 0 split; String.sub m split (String.length m - split) ])
      messages
  in
  let expected =
    List.mapi
      (fun i _ ->
        ev
          ~id:(string_of_int i)
          ~typ:"time"
          (Printf.sprintf "2026-07-06T00:00:%02d.000Z" i))
      messages
  in
  check "unbalanced chunks" expected (run chunks)

(* -- upstream: 'stream of identified messages + retry interval' -- *)
let test_identified_retry () =
  let chunks =
    [ "retry: 50\nid: 1337\nevent: tick\ndata: 1337\n\n";
      "retry: 50\nid: 1338\nevent: tick\ndata: 1338\n\n" ]
  in
  check "identified + retry"
    [ Retry 50; ev ~id:"1337" ~typ:"tick" "1337";
      Retry 50; ev ~id:"1338" ~typ:"tick" "1338" ]
    (run chunks)

(* -- upstream: 'stream of "heartbeat" comments, unnamed events' -- *)
let test_heartbeats () =
  let heart = "\xe2\x99\xa5" in
  let chunks =
    List.concat_map
      (fun i ->
        [ ":  " ^ heart ^ "\n"; Printf.sprintf "data: %c\n\n" (Char.chr (65 + i)) ])
      [ 0; 1; 2; 3; 4 ]
    @ [ "event: done\ndata: \xe2\x9c\x94\n\n" ]
  in
  let out = run chunks in
  check "heartbeats"
    [ Comment (" " ^ heart); ev "A"; Comment (" " ^ heart); ev "B";
      Comment (" " ^ heart); ev "C"; Comment (" " ^ heart); ev "D";
      Comment (" " ^ heart); ev "E"; ev ~typ:"done" "\xe2\x9c\x94" ]
    out

(* -- upstream: 'stream of multi-line data events' -- *)
let test_multiline () =
  let chunks =
    [ "event: stock\n"; "data: YHOO\n"; "data: +2\n"; "data: 10\n\n";
      "event: stock\n"; "data: GOOG\n"; "data: -8\n"; "data: 1881\n\n";
      "event: done\ndata: \xe2\x9c\x94\n\n" ]
  in
  check "multiline"
    [ ev ~typ:"stock" "YHOO\n+2\n10"; ev ~typ:"stock" "GOOG\n-8\n1881";
      ev ~typ:"done" "\xe2\x9c\x94" ]
    (run chunks)

(* -- upstream: 'stream of multi-byte events' (subset; the split lands
   mid-UTF-8-rune here, a strictly harsher variant of upstream's split at 5
   UTF-16 code units) -- *)
let test_multibyte_split () =
  let lines =
    [ "Bl\xc3\xa5b\xc3\xa6rsyltet\xc3\xb8y m\xc3\xa5 da v\xc3\xa6re mulig \xc3\xa5 oppdrive?";
      "\xe4\xb8\x80\xe5\xae\x9a\xe8\x83\xbd\xe4\xb9\xb0\xe5\x88\xb0\xe8\x93\x9d\xe8\x8e\x93\xe6\x9e\x9c\xe9\x85\xb1\xe5\x90\x97\xef\xbc\x9f \xf0\x9f\x98\xb6\xe2\x80\x8d\xf0\x9f\x8c\xab\xef\xb8\x8f";
      "\xd7\x91\xd7\x98\xd7\x97 \xd7\x90\xd7\xa4\xd7\xa9\xd7\xa8 \xd7\x9c\xd7\x94\xd7\xa9\xd7\x99\xd7\x92 \xd7\xa8\xd7\x99\xd7\x91\xd7\xaa \xd7\x90\xd7\x95\xd7\x9b\xd7\x9e\xd7\xa0\xd7\x99\xd7\x95\xd7\xaa? \xf0\x9f\xab\xb1\xf0\x9f\x8f\xbb\xe2\x80\x8d\xf0\x9f\xab\xb2\xf0\x9f\x8f\xbc" ]
  in
  let chunks =
    List.concat
      (List.mapi
         (fun i line ->
           let id_chunk = Printf.sprintf "id: %d\n" i in
           if i mod 2 = 0 then
             (* split the data line at byte 5 — mid-rune for multibyte text *)
             [ id_chunk; "data:" ^ String.sub line 0 5 ^ "\n";
               "data:" ^ String.sub line 5 (String.length line - 5) ^ "\n\n" ]
           else [ id_chunk; "data:" ^ line ^ "\n\n" ])
         lines)
  in
  let expected =
    List.mapi
      (fun i line ->
        if i mod 2 = 0 then
          ev ~id:(string_of_int i)
            (String.sub line 0 5 ^ "\n" ^ String.sub line 5 (String.length line - 5))
        else ev ~id:(string_of_int i) line)
      lines
  in
  check "multibyte" expected (run chunks)

(* -- upstream: 'stream of multi-byte events with some empty lines thrown in' -- *)
let test_multibyte_empty_lines () =
  let cjk =
    "\xe6\x88\x91\xe7\x8f\xbe\xe5\x9c\xa8\xe9\x83\xbd\xe7\x9c\x8b\xe5\xaf\xa6\xe6\xb3\x81\xe4\xb8\x8d\xe7\x8e\xa9\xe9\x81\x8a\xe6\x88\xb2"
  in
  let chunks =
    [ "\n\n\n\nid: 1\ndata: " ^ cjk ^ "\n\n"; "event: done\ndata: \xe2\x9c\x94\n\n" ]
  in
  check "multibyte empty lines"
    [ ev ~id:"1" cjk; ev ~typ:"done" "\xe2\x9c\x94" ]
    (run chunks)

(* -- upstream: 'stream of leading bom' -- *)
let test_leading_bom () =
  let chunks =
    [ "\xef\xbb\xbfdata: bomful 1\n\n"; "data: bomless 2\n\n";
      "event: done\ndata: \xe2\x9c\x94\n\n" ]
  in
  check "leading bom"
    [ ev "bomful 1"; ev "bomless 2"; ev ~typ:"done" "\xe2\x9c\x94" ]
    (run chunks)

(* -- upstream: 'stream containing byte-order mark (multiple places)' --
   Only the BOM at the very start of the stream is stripped; a later one
   makes the line an unknown field, so its event is dropped.
   (Upstream's separate 'invalid bom' test feeds U+FEFF as a UTF-16 code
   unit, which has no distinct byte-level counterpart — N/A here, see
   provenance doc.) *)
let test_multi_bom () =
  let bom = "\xef\xbb\xbf" in
  let chunks =
    [ bom ^ "data: bomful 1\n\n"; bom ^ "data: bomful 2\n\n"; "data: bomless 3\n\n";
      "event: done\ndata: \xe2\x9c\x94\n\n" ]
  in
  let out = run chunks in
  check "multi bom events"
    [ ev "bomful 1"; ev "bomless 3"; ev ~typ:"done" "\xe2\x9c\x94" ]
    (events_of out);
  Alcotest.(check int)
    "bom mid-stream is an unknown field" 1
    (List.length
       (List.filter
          (function
            | Eventsource.Parse_error (Unknown_field { field; _ }) ->
                field = bom ^ "data"
            | _ -> false)
          out))

(* -- upstream: 'stream using carriage returns' -- *)
let test_carriage_returns () =
  let chunks =
    [ "data: dog\r"; "data: bark\r\r"; "data: cat\r"; "data: meow\r\r";
      "event: done\ndata: \xe2\x9c\x94\n\n" ]
  in
  check "CR"
    [ ev "dog\nbark"; ev "cat\nmeow"; ev ~typ:"done" "\xe2\x9c\x94" ]
    (run chunks)

(* -- upstream: 'stream using line feeds' -- *)
let test_line_feeds () =
  let chunks =
    [ "data: cow\n"; "data: moo\n\n"; "data: horse\n"; "data: neigh\n\n";
      "event: done\ndata: \xe2\x9c\x94\n\n" ]
  in
  check "LF"
    [ ev "cow\nmoo"; ev "horse\nneigh"; ev ~typ:"done" "\xe2\x9c\x94" ]
    (run chunks)

(* -- upstream: 'stream using carriage returns and line feeds' -- *)
let test_crlf () =
  let chunks =
    [ "data: sheep\r\n"; "data: bleat\r\n\r\n"; "data: pig\r\n"; "data: oink\r\n\r\n";
      "event: done\ndata: \xe2\x9c\x94\n\n" ]
  in
  check "CRLF"
    [ ev "sheep\nbleat"; ev "pig\noink"; ev ~typ:"done" "\xe2\x9c\x94" ]
    (run chunks)

(* -- upstream: 'stream with varying odd uses of comments' -- *)
let test_comments () =
  let chunks =
    [ ": Hello\n\n"; String.make 300 ':'; "\n";
      "data: First\n\n"; ": \xd0\x9f\xd0\xb5\xd1\x80\xd0\xb2\xd1\x8b\xd0\xb9";
      ": \xe7\xac\xac\xe4\xba\x8c"; "\n"; "data: Second\n\n" ]
    @ List.init 10 (fun _ -> ": Moop \n")
    @ [ ": \xd8\xab\xd8\xa7\xd9\x84\xd8\xab"; "\n"; "data: Third\n\n";
        ":\xe0\xb4\xa8\xe0\xb4\xbe\xe0\xb4\xb2"; "\n"; "data: Fourth\n\n";
        ": comment :"; "\n"; "data: Fifth\n\n";
        "event: done\ndata: \xe2\x9c\x94\n\n" ]
  in
  check "comment stream events"
    [ ev "First"; ev "Second"; ev "Third"; ev "Fourth"; ev "Fifth";
      ev ~typ:"done" "\xe2\x9c\x94" ]
    (events_of (run chunks))

(* -- upstream: 'stream with even more odd uses of comments' -- *)
let test_mixed_comments () =
  let long_string = String.make ((2 * 1024) + 1) 'x' in
  let chunks =
    [ "data:1\r\r:\x00\n:\r\ndata:2\n\n:"; long_string;
      "\rdata:3\n\n:data:fail\r:"; long_string; "\ndata:4\n\n"; "data:5" ]
  in
  check "mixed comments"
    [ ev "1"; ev "2"; ev "3"; ev "4" (* no trailing newline: '5' not emitted *) ]
    (events_of (run chunks))

(* -- upstream: 'stream with empty `event` field' -- *)
let test_empty_event_field () =
  let chunks =
    [ "event:\ndata: Hello 1\n\n"; "event:\n\n"; "event: done\ndata: \xe2\x9c\x94\n\n" ]
  in
  check "empty event field"
    [ ev "Hello 1"; ev ~typ:"done" "\xe2\x9c\x94" ]
    (run chunks)

(* -- upstream: 'stream with empty `retry` field' -- *)
let test_empty_retry () =
  let chunks =
    [ "retry: 500\nid: 1\ndata: \xf0\x9f\xa5\x8c\n\n";
      "id:2\nretry:\ndata:\xf0\x9f\xa7\xb9\n\n";
      "id: 3\ndata: \xe2\x9c\x85\n\n" ]
  in
  check "empty retry"
    [ Retry 500; ev ~id:"1" "\xf0\x9f\xa5\x8c";
      Parse_error (Invalid_retry { value = ""; line = "retry:" });
      ev ~id:"2" "\xf0\x9f\xa7\xb9"; ev ~id:"3" "\xe2\x9c\x85" ]
    (run chunks)

(* -- upstream: 'stream with oddly shaped data field' -- *)
let test_data_field_parsing () =
  check "odd data fields"
    [ ev ""; (* `data:` alone: empty-string data event, per spec footnote *)
      ev "\n"; (* `data\ndata`: colon-less lines append empty values *)
      ev "test" ]
    (events_of (run [ "data:\n\ndata\ndata\n\ndata:test\n\n" ]))

(* -- upstream: 'stream with cr separating chunks of same event' (issue #17) -- *)
let test_cr_split_across_chunks () =
  check "CR at chunk boundary"
    [ ev "A\nB\nC" ]
    (run [ "data: A\r\n"; "data: B\r"; "\n"; "data: C\r\n"; "\n" ])

(* -- upstream: 'stream with partially incorrect retry fields' -- *)
let test_partially_invalid_retry () =
  check "partially invalid retry"
    [ Retry 1000;
      Parse_error (Invalid_retry { value = "2000x"; line = "retry:2000x" });
      ev "x" ]
    (run [ "retry:1000\nretry:2000x\ndata:x\n\n" ])

(* -- upstream: 'stream with incorrect retry fields' -- *)
let test_invalid_retry_multichunk () =
  check "invalid retry mid-stream"
    [ Retry 500; ev "first";
      Parse_error (Invalid_retry { value = "50x"; line = "retry: 50x" });
      ev "second" ]
    (run [ "\nretry: 500\n\ndata: first\n\nretry: 50x\n\ndata: second\n\n" ])

(* -- upstream: 'stream with unknown fields in the stream' -- *)
let test_unknown_fields () =
  check "unknown fields"
    [ Parse_error (Unknown_field { field = " data"; value = ""; line = " data" });
      Parse_error (Unknown_field { field = "foobar"; value = "xxx"; line = "foobar:xxx" });
      Parse_error
        (Unknown_field { field = "justsometext"; value = ""; line = "justsometext" });
      Comment "thisisacommentyay";
      ev "abc\n\n123";
      ev ~typ:"done" "\xe2\x9c\x94" ]
    (run
       [ "data:abc\n data\ndata\nfoobar:xxx\njustsometext\n:thisisacommentyay\ndata:123\n\n";
         "event: done\ndata: \xe2\x9c\x94\n\n" ])

(* -- upstream: 'stream with huge data chunks' (adapted: same shape — one
   multi-megabyte multi-line event streamed in repeated chunks — verified by
   construction instead of a vendored sha256) -- *)
let test_huge_message () =
  let piece = "data: 0123456789abcdefghijklmnopqrstuvwxyz\n" in
  let reps = 120_000 (* ~5 MB *) in
  let t = Eventsource.create () in
  let t, out0 = Eventsource.feed t ": hello\n\n" in
  let t, outs =
    let rec go t acc i =
      if i = reps then (t, acc)
      else
        let t, out = Eventsource.feed t piece in
        go t (acc @ out) (i + 1)
    in
    go t [] 0
  in
  let _t, out1 = Eventsource.feed t "\n\n" in
  let all = out0 @ outs @ out1 in
  (match events_of all with
  | [ Event { data; _ } ] ->
      let line = "0123456789abcdefghijklmnopqrstuvwxyz" in
      let expected_len = (reps * (String.length line + 1)) - 1 in
      Alcotest.(check int) "huge event length" expected_len (String.length data);
      Alcotest.(check string) "huge event head" line (String.sub data 0 36);
      Alcotest.(check string)
        "huge event tail" ("\n" ^ line)
        (String.sub data (String.length data - 37) 37)
  | evs -> Alcotest.failf "expected exactly one event, got %d" (List.length evs));
  check "comment before huge event" [ Comment "hello" ]
    (List.filter (function Eventsource.Comment _ -> true | _ -> false) all)

(* -- upstream: reset()/consume tests -- *)
let json_body =
  {|{"error":"Internal Server Error","message":"The server could not process your request"}|}

let test_reset_without_consume () =
  check "no outputs without terminator" [] (run [ json_body ]);
  check "reset consume:false emits nothing" [] (run ~consume:false [ json_body ])

let test_reset_consume () =
  check "reset consume:true surfaces the non-SSE body"
    [ Parse_error
        (Unknown_field
           {
             field = {|{"error"|};
             value =
               {|"Internal Server Error","message":"The server could not process your request"}|};
             line = json_body;
           }) ]
    (run ~consume:true [ json_body ])

let test_invalid_via_newline () =
  check "newline-terminated non-SSE body"
    [ Parse_error
        (Unknown_field
           {
             field = {|{"error"|};
             value =
               {|"Internal Server Error","message":"The server could not process your request"}|};
             line = json_body;
           }) ]
    (run [ json_body ^ "\n" ])

let test_no_field_separator () =
  check "no field separator"
    [ Parse_error
        (Unknown_field
           {
             field = "Well, this is not what I expected";
             value = "";
             line = "Well, this is not what I expected";
           }) ]
    (run [ "Well, this is not what I expected\n" ])

(* -- upstream: maxBufferSize tests -- *)
let overflow limit = Eventsource.Parse_error (Buffer_limit_exceeded { limit })

let test_max_buffer_pending_overflow () =
  let t = Eventsource.create ~max_buffer_size:16 () in
  let t, out1 = Eventsource.feed t "short start" in
  check "under the limit" [] out1;
  let t, out2 = Eventsource.feed t " and now too long" in
  check "overflow on fragment accumulation" [ overflow 16 ] out2;
  Alcotest.(check bool) "terminated" true (Eventsource.is_terminated t)

let test_max_buffer_data_overflow () =
  let t = ref (Eventsource.create ~max_buffer_size:32 ()) in
  let all = ref [] in
  (try
     for i = 0 to 49 do
       let t', out = Eventsource.feed !t (Printf.sprintf "data: chunk-%d\n" i) in
       t := t';
       all := !all @ out;
       if Eventsource.is_terminated !t then raise Exit
     done
   with Exit -> ());
  check "single overflow error, no events" [ overflow 32 ] !all

(* Upstream throws on feed-after-overflow; the port's typed-state divergence:
   feeding a terminated parser is a no-op, reset restores it. *)
let test_max_buffer_feed_after_overflow () =
  let t = Eventsource.create ~max_buffer_size:8 () in
  let t, out = Eventsource.feed t "this is too long for the buffer" in
  check "overflow reported" [ overflow 8 ] out;
  let t, out = Eventsource.feed t "data: hello\n\n" in
  check "terminated parser drops input" [] out;
  Alcotest.(check bool) "still terminated" true (Eventsource.is_terminated t);
  let t, out = Eventsource.reset t in
  check "reset emits nothing" [] out;
  let _t, out = Eventsource.feed t "data: hello\n\n" in
  check "works after reset" [ ev "hello" ] out

let test_max_buffer_not_triggered () =
  let t = ref (Eventsource.create ~max_buffer_size:64 ()) in
  let all = ref [] in
  for i = 0 to 99 do
    let t', out = Eventsource.feed !t (Printf.sprintf "data: %d\n\n" i) in
    t := t';
    all := !all @ out
  done;
  Alcotest.(check int) "100 events" 100 (List.length (events_of !all));
  Alcotest.(check int) "no errors" 100 (List.length !all)

let test_max_buffer_unbounded_default () =
  check "unbounded by default" [] (run [ String.make 1_000_000 'x' ])

(* -- port addition: retry values that overflow [int] saturate -- *)
let test_retry_saturates () =
  check "retry saturation"
    [ Retry max_int ]
    (run [ "retry:99999999999999999999999999999\n" ])

(* -- port addition (qcheck): chunk-split invariance — the same byte stream
   fed under two arbitrary chunkings yields identical outputs. Streams with
   a leading BOM are excluded: upstream only strips a BOM wholly contained
   in the first chunk (documented quirk, mirrored by the port). -- *)
let gen_stream =
  let open QCheck.Gen in
  let value =
    oneof_weighted
      [ (6, string_size ~gen:(map Char.chr (int_range 32 126)) (int_bound 10));
        (1, return "\xe2\x9c\x94\xf0\x9f\x8c\xab");
        (1, return "\xff\xfe");
        (1, return "") ]
  in
  let line =
    oneof_weighted
      [ (6, map (fun v -> "data: " ^ v) value);
        (2, map (fun v -> "data:" ^ v) value);
        (2, map (fun v -> "event: " ^ v) value);
        (2, map (fun v -> "id: " ^ v) value);
        (1, map (fun v -> "retry: " ^ v) value);
        (1, map (fun n -> "retry: " ^ string_of_int n) (int_bound 10_000));
        (1, map (fun v -> ": " ^ v) value);
        (1, map (fun v -> "wat: " ^ v) value);
        (1, value);
        (2, return "") ]
  in
  let terminator = oneof_list [ "\n"; "\r"; "\r\n" ] in
  let* lines = list_size (int_bound 12) (pair line terminator) in
  let* trailing = oneof_weighted [ (3, return ""); (1, value) ] in
  let body = String.concat "" (List.map (fun (l, t) -> l ^ t) lines) in
  (* A CR directly before an unterminated tail is deferred-or-parsed
     depending on chunk boundaries (upstream-inherited quirk, see provenance
     doc) — exclude that shape from the invariance property. *)
  let stream =
    if trailing <> "" && body <> "" && body.[String.length body - 1] = '\r' then
      body ^ "\n" ^ trailing
    else body ^ trailing
  in
  (* avoid the BOM chunk-split quirk *)
  if String.length stream >= 3 && String.sub stream 0 3 = "\xef\xbb\xbf" then
    return ("x" ^ stream)
  else return stream

let gen_cuts stream =
  let open QCheck.Gen in
  let n = String.length stream in
  let* k = int_bound 6 in
  let* cuts = list_size (return k) (int_bound (max n 1)) in
  return (List.sort_uniq compare (List.filter (fun c -> c > 0 && c < n) cuts))

let split_at_cuts stream cuts =
  let n = String.length stream in
  let rec go start = function
    | [] -> if start >= n then [] else [ String.sub stream start (n - start) ]
    | c :: rest -> String.sub stream start (c - start) :: go c rest
  in
  go 0 cuts

let chunk_invariance_prop =
  let open QCheck in
  let gen =
    Gen.(
      let* stream = gen_stream in
      let* cuts_a = gen_cuts stream in
      let* cuts_b = gen_cuts stream in
      return (stream, cuts_a, cuts_b))
  in
  let print (stream, a, b) =
    Printf.sprintf "stream=%S cuts_a=[%s] cuts_b=[%s]" stream
      (String.concat ";" (List.map string_of_int a))
      (String.concat ";" (List.map string_of_int b))
  in
  Test.make ~count:2000 ~name:"chunk-split invariance"
    (make ~print gen)
    (fun (stream, cuts_a, cuts_b) ->
      run (split_at_cuts stream cuts_a) = run (split_at_cuts stream cuts_b))

let () =
  Alcotest.run "eventsource"
    [
      ( "parse (ported from upstream parse.test.ts)",
        [
          Alcotest.test_case "basic unnamed events" `Quick test_basic;
          Alcotest.test_case "unbalanced chunks" `Quick test_unbalanced_chunks;
          Alcotest.test_case "identified + retry" `Quick test_identified_retry;
          Alcotest.test_case "heartbeat comments" `Quick test_heartbeats;
          Alcotest.test_case "multi-line data" `Quick test_multiline;
          Alcotest.test_case "multibyte split mid-rune" `Quick test_multibyte_split;
          Alcotest.test_case "multibyte + empty lines" `Quick
            test_multibyte_empty_lines;
          Alcotest.test_case "leading BOM" `Quick test_leading_bom;
          Alcotest.test_case "BOM in multiple places" `Quick test_multi_bom;
          Alcotest.test_case "CR line endings" `Quick test_carriage_returns;
          Alcotest.test_case "LF line endings" `Quick test_line_feeds;
          Alcotest.test_case "CRLF line endings" `Quick test_crlf;
          Alcotest.test_case "odd comments" `Quick test_comments;
          Alcotest.test_case "mixed comments" `Quick test_mixed_comments;
          Alcotest.test_case "empty event field" `Quick test_empty_event_field;
          Alcotest.test_case "empty retry field" `Quick test_empty_retry;
          Alcotest.test_case "odd data fields" `Quick test_data_field_parsing;
          Alcotest.test_case "CR split across chunks (#17)" `Quick
            test_cr_split_across_chunks;
          Alcotest.test_case "partially invalid retry" `Quick
            test_partially_invalid_retry;
          Alcotest.test_case "invalid retry mid-stream" `Quick
            test_invalid_retry_multichunk;
          Alcotest.test_case "unknown fields" `Quick test_unknown_fields;
          Alcotest.test_case "huge message" `Slow test_huge_message;
          Alcotest.test_case "reset without consume" `Quick test_reset_without_consume;
          Alcotest.test_case "reset with consume" `Quick test_reset_consume;
          Alcotest.test_case "non-SSE body via newline" `Quick test_invalid_via_newline;
          Alcotest.test_case "no field separator" `Quick test_no_field_separator;
        ] );
      ( "max buffer size (§13.8)",
        [
          Alcotest.test_case "pending fragment overflow" `Quick
            test_max_buffer_pending_overflow;
          Alcotest.test_case "data buffer overflow" `Quick test_max_buffer_data_overflow;
          Alcotest.test_case "feed after overflow" `Quick
            test_max_buffer_feed_after_overflow;
          Alcotest.test_case "not triggered under limit" `Quick
            test_max_buffer_not_triggered;
          Alcotest.test_case "unbounded default" `Quick test_max_buffer_unbounded_default;
        ] );
      ( "port additions",
        [
          Alcotest.test_case "retry saturates at max_int" `Quick test_retry_saturates;
          Alcotest.test_case "chunk-split invariance (qcheck)" `Slow (fun () ->
              QCheck.Test.check_exn chunk_invariance_prop);
        ] );
    ]
