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

let save (trace : t) (path : string) : unit =
  let oc = open_out path in
  List.iter (fun e -> output_string oc (Yojson.Safe.to_string (json_of_event e) ^ "\n")) trace;
  close_out oc

let load (path : string) : (t, string) result =
  let ic = open_in path in
  let rec go acc =
    match input_line ic with
    | line ->
        if String.trim line = "" then go acc
        else (
          match Yojson.Safe.from_string line with
          | exception Yojson.Json_error m ->
              close_in ic;
              Error ("trace: invalid JSON line: " ^ m)
          | json -> (
              match event_of_json json with
              | Ok e -> go (e :: acc)
              | Error m ->
                  close_in ic;
                  Error m))
    | exception End_of_file ->
        close_in ic;
        Ok (List.rev acc)
  in
  go []
