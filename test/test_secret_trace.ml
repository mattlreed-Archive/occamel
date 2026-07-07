(* M4: Secret.t hygiene (§13.9), trace redaction and HMAC integrity (§13.7). *)

module Se = Occamel.Secret
module Tr = Occamel.Trace

let () =
  (* Secret: redacted forms never reveal the plaintext; use is the only reader *)
  let s = Se.of_string "sk-supersecret-42" in
  assert (Se.redacted s <> "sk-supersecret-42");
  assert (not (String.length (Se.redacted s) > 0 && Se.redacted s = "sk-supersecret-42"));
  assert (Format.asprintf "%a" Se.pp s = Se.redacted s);
  assert (Se.use s (fun p -> p) = "sk-supersecret-42");
  (* stable fingerprint *)
  assert (Se.redacted s = Se.redacted (Se.of_string "sk-supersecret-42"));
  (* NOTE: there is deliberately no Se.to_string / yojson codec — attempting to
     serialize a Secret.t is a compile error (§13.9). Verified by construction:
     the .mli exposes only use/redacted/pp. *)

  (* Redaction at write time: a registered scrubber removes a token before it
     hits disk *)
  Tr.register_scrubber (fun s ->
      Str.global_replace (Str.regexp "sk-[A-Za-z0-9-]+") "<redacted>" s);
  let trace =
    [
      Tr.Note "using key sk-supersecret-42 now";
      Tr.Tool_call
        {
          tool = "http";
          args_schema_hash = "x";
          args = `Assoc [ ("auth", `String "Bearer sk-abc123") ];
          result = `String "ok";
          ms = 1;
        };
    ]
  in
  let file = Filename.temp_file "occ" ".trace" in
  Tr.save trace file;
  let raw = In_channel.with_open_text file In_channel.input_all in
  assert (not (Str.string_match (Str.regexp ".*sk-supersecret.*") raw 0));
  (* the scrubbed placeholder is present *)
  assert (
    let re = Str.regexp_string "<redacted>" in
    try ignore (Str.search_forward re raw 0); true with Not_found -> false);

  (* Integrity: with a key set, save signs and load verifies; a tamper is
     detected. Use Unix.putenv to set the key for this process. *)
  Unix.putenv "OCCAMEL_TRACE_KEY" "test-key";
  let signed = Filename.temp_file "occ" ".strace" in
  Tr.save [ Tr.Note "hello"; Tr.Note "world" ] signed;
  (match Tr.load_checked signed with
  | Ok (evs, Tr.Verified) -> assert (List.length evs = 2)
  | _ -> failwith "signed trace should verify");
  (* tamper: flip a byte in a data line *)
  let contents = In_channel.with_open_text signed In_channel.input_all in
  let tampered = Str.replace_first (Str.regexp "world") "w0rld" contents in
  Out_channel.with_open_text signed (fun oc -> Out_channel.output_string oc tampered);
  (match Tr.load_checked signed with
  | Error _ -> ()
  | Ok _ -> failwith "tampered trace must fail verification");

  Sys.remove file;
  Sys.remove signed;
  print_endline "all secret/trace tests passed"
