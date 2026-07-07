(* Typed trace events (§9). Every event carries the schema hash of what
   produced it; replay fails loudly on hash mismatch — "the same tool/type"
   across runs is verified, not assumed.

   §13.7 note: this module is serialization only. Replay-into-live safety
   (integrity verification, re-running approvals) is the replay handler's
   job (Loop.replay re-checks hashes and context; signatures/redaction land
   in M4). *)

type event =
  | Ask_response of {
      ctx_hash : string;
      schema_name : string;
      schema_hash : string;
      content : string;  (* raw model output; re-parsed on replay *)
    }
  (* strict-mode events (§9). Plan is stored via Plan.to_json. *)
  | Plan_generated of { prompt_hash : string; plan : Yojson.Safe.t }
  | Plan_admitted of { verdict : string (* "ok" | reasons joined *) }
  | Extraction of {
      site : string;
      question : string;
      source_hash : string;
      output : string;
      prov : Yojson.Safe.t;
    }
  | Tool_call of {
      tool : string;
      args_schema_hash : string;
      args : Yojson.Safe.t;
      result : Yojson.Safe.t;
      ms : int;
    }
  | Tool_failed of {
      tool : string;
      args_schema_hash : string;
      args : Yojson.Safe.t;
      error : string;
    }
  | Approval of { tool : string; decision : string }
  | Note of string

type t = event list

let json_of_event : event -> Yojson.Safe.t = function
  | Ask_response { ctx_hash; schema_name; schema_hash; content } ->
      `Assoc
        [
          ("event", `String "ask");
          ("ctx_hash", `String ctx_hash);
          ("schema_name", `String schema_name);
          ("schema_hash", `String schema_hash);
          ("content", `String content);
        ]
  | Tool_call { tool; args_schema_hash; args; result; ms } ->
      `Assoc
        [
          ("event", `String "tool");
          ("tool", `String tool);
          ("args_schema_hash", `String args_schema_hash);
          ("args", args);
          ("result", result);
          ("ms", `Int ms);
        ]
  | Tool_failed { tool; args_schema_hash; args; error } ->
      `Assoc
        [
          ("event", `String "tool_failed");
          ("tool", `String tool);
          ("args_schema_hash", `String args_schema_hash);
          ("args", args);
          ("error", `String error);
        ]
  | Approval { tool; decision } ->
      `Assoc
        [ ("event", `String "approval"); ("tool", `String tool); ("decision", `String decision) ]
  | Plan_generated { prompt_hash; plan } ->
      `Assoc
        [ ("event", `String "plan"); ("prompt_hash", `String prompt_hash); ("plan", plan) ]
  | Plan_admitted { verdict } ->
      `Assoc [ ("event", `String "admitted"); ("verdict", `String verdict) ]
  | Extraction { site; question; source_hash; output; prov } ->
      `Assoc
        [
          ("event", `String "extraction");
          ("site", `String site);
          ("question", `String question);
          ("source_hash", `String source_hash);
          ("output", `String output);
          ("prov", prov);
        ]
  | Note text -> `Assoc [ ("event", `String "note"); ("text", `String text) ]

let event_of_json (json : Yojson.Safe.t) : (event, string) result =
  let str k =
    match Schema.member k json with
    | Some (`String s) -> Ok s
    | _ -> Error (Printf.sprintf "trace event: missing string %S" k)
  in
  let ( let* ) = Result.bind in
  let* kind = str "event" in
  match kind with
  | "ask" ->
      let* ctx_hash = str "ctx_hash" in
      let* schema_name = str "schema_name" in
      let* schema_hash = str "schema_hash" in
      let* content = str "content" in
      Ok (Ask_response { ctx_hash; schema_name; schema_hash; content })
  | "tool" ->
      let* tool = str "tool" in
      let* args_schema_hash = str "args_schema_hash" in
      let args = Option.value ~default:`Null (Schema.member "args" json) in
      let result = Option.value ~default:`Null (Schema.member "result" json) in
      let ms = match Schema.member "ms" json with Some (`Int n) -> n | _ -> 0 in
      Ok (Tool_call { tool; args_schema_hash; args; result; ms })
  | "tool_failed" ->
      let* tool = str "tool" in
      let* args_schema_hash = str "args_schema_hash" in
      let args = Option.value ~default:`Null (Schema.member "args" json) in
      let* error = str "error" in
      Ok (Tool_failed { tool; args_schema_hash; args; error })
  | "approval" ->
      let* tool = str "tool" in
      let* decision = str "decision" in
      Ok (Approval { tool; decision })
  | "plan" ->
      let* prompt_hash = str "prompt_hash" in
      let plan = Option.value ~default:`Null (Schema.member "plan" json) in
      Ok (Plan_generated { prompt_hash; plan })
  | "admitted" ->
      let* verdict = str "verdict" in
      Ok (Plan_admitted { verdict })
  | "extraction" ->
      let* site = str "site" in
      let* question = str "question" in
      let* source_hash = str "source_hash" in
      let* output = str "output" in
      let prov = Option.value ~default:`Null (Schema.member "prov" json) in
      Ok (Extraction { site; question; source_hash; output; prov })
  | "note" ->
      let* text = str "text" in
      Ok (Note text)
  | other -> Error (Printf.sprintf "trace event: unknown kind %S" other)

(* ---------- redaction (§13.7) ---------- *)

(* User-registered scrubbers run over every string field at WRITE time, so
   secrets/PII never hit disk. Secret.t values are unserializable by
   construction (§13.9), but free strings (tool args/results, extraction
   output) can still carry sensitive data; scrubbers are the defense. *)
let scrubbers : (string -> string) list ref = ref []
let register_scrubber f = scrubbers := f :: !scrubbers
let scrub s = List.fold_left (fun s f -> f s) s !scrubbers

let rec scrub_json : Yojson.Safe.t -> Yojson.Safe.t = function
  | `String s -> `String (scrub s)
  | `List l -> `List (List.map scrub_json l)
  | `Assoc kvs -> `Assoc (List.map (fun (k, v) -> (k, scrub_json v)) kvs)
  | other -> other

let redact_event (e : event) : event =
  match e with
  | Ask_response r -> Ask_response { r with content = scrub r.content }
  | Tool_call r -> Tool_call { r with args = scrub_json r.args; result = scrub_json r.result }
  | Tool_failed r -> Tool_failed { r with args = scrub_json r.args; error = scrub r.error }
  | Extraction r ->
      (* M4-review M2: scrub prov too, not just output/question *)
      Extraction { r with output = scrub r.output; question = scrub r.question; prov = scrub_json r.prov }
  | Note s -> Note (scrub s)
  (* M4-review M2: the plan embeds Lit values and the goal-derived prompt —
     trusted != non-sensitive (a user goal may contain PII). Scrub it and the
     verdict, so "every string field" is actually true. *)
  | Plan_generated r -> Plan_generated { r with plan = scrub_json r.plan }
  | Plan_admitted r -> Plan_admitted { verdict = scrub r.verdict }
  | Approval _ as e -> e

(* ---------- integrity (§13.7, retires F4 integrity half) ----------
   An HMAC over the exact serialized event lines. Written as a trailing
   "#sig <hex>" line; verified before events are handed back on load. Keyed
   (not the unkeyed MD5 that F4 flagged) — a tamperer without the key cannot
   forge it. Key from OCCAMEL_TRACE_KEY; if unset, traces are written unsigned
   and load accepts them (dev default) but reports [Unsigned]. *)

let hmac ~key (payload : string) : string =
  (* HMAC-MD5 via Digest — sufficient for tamper-evidence of a local artifact;
     swap to a real MAC lib when one is a dep. Block size 64. *)
  let block = 64 in
  let key = if String.length key > block then Digest.string key else key in
  let key = key ^ String.make (block - String.length key) '\000' in
  let xor pad = String.map (fun c -> Char.chr (Char.code c lxor pad)) key in
  let ipad = xor 0x36 and opad = xor 0x5c in
  Digest.to_hex (Digest.string (opad ^ Digest.string (ipad ^ payload)))

let trace_key () = Sys.getenv_opt "OCCAMEL_TRACE_KEY"

let save (trace : t) (path : string) : unit =
  let lines =
    List.map (fun e -> Yojson.Safe.to_string (json_of_event (redact_event e))) trace
  in
  let payload = String.concat "\n" lines in
  let oc = open_out path in
  List.iter (fun l -> output_string oc (l ^ "\n")) lines;
  (match trace_key () with
  | Some key -> output_string oc ("#sig " ^ hmac ~key payload ^ "\n")
  | None -> ());
  close_out oc

type integrity = Verified | Unsigned | Bad_signature

let load_checked (path : string) : (t * integrity, string) result =
  let ic = open_in path in
  let data_lines = ref [] and sig_line = ref None in
  (try
     while true do
       let line = input_line ic in
       if String.length line >= 5 && String.sub line 0 5 = "#sig " then
         sig_line := Some (String.sub line 5 (String.length line - 5))
       else if String.trim line <> "" then data_lines := line :: !data_lines
     done
   with End_of_file -> ());
  close_in ic;
  let data_lines = List.rev !data_lines in
  let integrity =
    match (!sig_line, trace_key ()) with
    | Some s, Some key ->
        if String.equal s (hmac ~key (String.concat "\n" data_lines)) then Verified
        else Bad_signature
    (* L3: a key is configured but the trace carries no signature — treat as
       tampered (a strip-to-downgrade), not silently Unsigned. An attacker
       can't forge a sig, so there's no downside; Unsigned now means only
       "no key configured at all". *)
    | None, Some _ -> Bad_signature
    | _, None -> Unsigned
  in
  if integrity = Bad_signature then Error "trace: signature verification failed (tampered?)"
  else
    let rec parse acc = function
      | [] -> Ok (List.rev acc, integrity)
      | line :: rest -> (
          match Yojson.Safe.from_string line with
          | exception Yojson.Json_error m -> Error ("trace: invalid JSON line: " ^ m)
          | json -> (
              match event_of_json json with
              | Ok e -> parse (e :: acc) rest
              | Error m -> Error m))
    in
    parse [] data_lines

let load (path : string) : (t, string) result =
  Result.map fst (load_checked path)

(* Strict loader for integrity-sensitive callers (e.g. any future
   replay-into-live): REQUIRES a valid signature. Rejects both a tampered
   trace and an unsigned one — closing the strip-the-signature downgrade where
   an attacker removes #sig to turn Verified into silently-accepted Unsigned.
   Needs OCCAMEL_TRACE_KEY set. *)
let load_verified (path : string) : (t, string) result =
  match load_checked path with
  | Ok (t, Verified) -> Ok t
  | Ok (_, Unsigned) -> Error "trace: unsigned (integrity required)"
  | Ok (_, Bad_signature) | Error _ -> Error "trace: signature verification failed"
