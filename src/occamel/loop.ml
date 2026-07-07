(* Loop mode (§6.6): the conventional observe-act loop, kept honest by types.
   Effects here, handlers below. Core stays HTTP-free — the production model
   call arrives as the [ask] callback; occamel-oai (or anything else) supplies
   it at the edge.

   Security posture per §13: loop mode has NO architectural injection
   resistance — Ctx.t may contain tool results, and every subsequent action
   is attacker-influenceable. What it does get: the approval handler on
   dangerous tools with truncation-safe rendering (§13.6), the §8 repair
   discipline on every Ask, and traces whose replay re-verifies schema
   hashes and context hashes (§9, §13.7). *)

module Ctx = struct
  type message = { role : string; content : string }
  type t = message list

  let make ~system ~user =
    [ { role = "system"; content = system }; { role = "user"; content = user } ]

  let add_user (ctx : t) content = ctx @ [ { role = "user"; content } ]

  (* Tool output enters the context marked as data. This is presentation, not
     a security boundary (§6.6) — the honest claim is "labeled", not "safe". *)
  let add_tool_result (ctx : t) ~tool content =
    ctx @ [ { role = "user"; content = Printf.sprintf "[%s result]\n%s" tool content } ]

  let hash (ctx : t) =
    Digest.to_hex
      (Digest.string (String.concat "\x00" (List.map (fun m -> m.role ^ ":" ^ m.content) ctx)))
end

module Tool_def = struct
  type ('a, 'r) t = {
    name : string;
    dangerous : bool;
    args_schema : Yojson.Safe.t;
    encode_args : 'a -> Yojson.Safe.t;
    encode_result : 'r -> Yojson.Safe.t;
    decode_result : Yojson.Safe.t -> ('r, Codec.error) result;
    run : 'a -> ('r, string) result;
  }
end

type approval = Approved | Denied of string

type approval_view = { tool : string; fields : (string * string) list }

type _ Effect.t +=
  | Ask : Ctx.t * 'a Schema.typed -> 'a Effect.t
  | Invoke : ('a, 'r) Tool_def.t * 'a -> ('r, string) result Effect.t
  | Note : string -> unit Effect.t
  | Approve : approval_view -> approval Effect.t

(* §13.6: exact values, truncation-safe AND homoglyph/bidi/control-safe.
   Escape every byte outside printable ASCII (0x20-0x7E) as \xHH — this
   neutralizes bidi overrides (U+202E), zero-width and format characters, and
   non-ASCII homoglyphs by construction, so the approver reads exactly what
   will execute. Escaping first makes the value pure ASCII, so truncating the
   escaped form can never split a UTF-8 sequence. *)
let escape_ascii (s : string) : string =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      let code = Char.code c in
      if code >= 0x20 && code <= 0x7e && c <> '\\' then Buffer.add_char b c
      else Buffer.add_string b (Printf.sprintf "\\x%02x" code))
    s;
  Buffer.contents b

let render_field (k : string) (v : Yojson.Safe.t) : string * string =
  let raw = Yojson.Safe.to_string v in
  let safe = escape_ascii raw in
  if String.length safe <= 200 then (k, safe)
  else
    (* hash the RAW bytes so the fingerprint identifies the real value *)
    ( k,
      Printf.sprintf "<%d bytes, md5:%s> %s..." (String.length raw)
        (Digest.to_hex (Digest.string raw))
        (String.sub safe 0 80) )

let view_of_args ~tool (args_json : Yojson.Safe.t) : approval_view =
  let fields =
    match args_json with
    | `Assoc kvs -> List.map (fun (k, v) -> render_field k v) kvs
    | other -> [ render_field "args" other ]
  in
  { tool; fields }

type run_error =
  [ `Ask_backend of string  (* transport/HTTP failure surfaced from ask *)
  | `Unparseable of Codec.error list  (* §8 repair exhausted *) ]

(* ---------- production handler ---------- *)

let run (type out)
    ~(ask : Ctx.t -> name:string -> schema:Yojson.Safe.t -> (string, string) result)
    ?(approve : approval_view -> approval = fun _ -> Approved) ?(max_repairs = 2)
    (agent : unit -> out) : (out, run_error) result * Trace.t =
  let events = ref [] in
  let emit e = events := e :: !events in
  let result =
    Effect.Deep.match_with agent ()
      {
        retc = (fun v -> Ok v);
        exnc = (fun e -> raise e);
        effc =
          (fun (type b) (eff : b Effect.t) ->
            match eff with
            | Ask (ctx, typed) ->
                Some
                  (fun (k : (b, _) Effect.Deep.continuation) ->
                    let last = ref "" in
                    let ask_fn ~extra =
                      let ctx' = List.fold_left Ctx.add_user ctx extra in
                      match ask ctx' ~name:typed.Schema.name ~schema:typed.Schema.schema with
                      | Ok content ->
                          last := content;
                          Ok content
                      | Error e -> Error e
                    in
                    match
                      Repair.run ~max_repairs ~ask:ask_fn ~parse:typed.Schema.parse
                        ~schema:typed.Schema.schema ()
                    with
                    | Ok (v, _repair_errors) ->
                        emit
                          (Trace.Ask_response
                             {
                               ctx_hash = Ctx.hash ctx;
                               schema_name = typed.Schema.name;
                               schema_hash = Schema.hash typed.Schema.schema;
                               content = !last;
                             });
                        Effect.Deep.continue k v
                    | Error (`Backend e) -> Error (`Ask_backend e)
                    | Error (`Unparseable errs) -> Error (`Unparseable errs))
            | Invoke (tool, args) ->
                Some
                  (fun (k : (b, _) Effect.Deep.continuation) ->
                    let args_json = tool.Tool_def.encode_args args in
                    let args_schema_hash = Schema.hash tool.Tool_def.args_schema in
                    let proceed () =
                      let t0 = Unix.gettimeofday () in
                      let res = tool.Tool_def.run args in
                      let ms = int_of_float ((Unix.gettimeofday () -. t0) *. 1000.) in
                      (match res with
                      | Ok r ->
                          emit
                            (Trace.Tool_call
                               {
                                 tool = tool.Tool_def.name;
                                 args_schema_hash;
                                 args = args_json;
                                 result = tool.Tool_def.encode_result r;
                                 ms;
                               })
                      | Error e ->
                          emit
                            (Trace.Tool_failed
                               {
                                 tool = tool.Tool_def.name;
                                 args_schema_hash;
                                 args = args_json;
                                 error = e;
                               }));
                      Effect.Deep.continue k res
                    in
                    if tool.Tool_def.dangerous then (
                      match approve (view_of_args ~tool:tool.Tool_def.name args_json) with
                      | Approved ->
                          emit
                            (Trace.Approval
                               { tool = tool.Tool_def.name; decision = "approved" });
                          proceed ()
                      | Denied reason ->
                          emit
                            (Trace.Approval
                               { tool = tool.Tool_def.name; decision = "denied:" ^ reason });
                          Effect.Deep.continue k (Error ("approval denied: " ^ reason)))
                    else proceed ())
            | Note text ->
                Some
                  (fun (k : (b, _) Effect.Deep.continuation) ->
                    emit (Trace.Note text);
                    Effect.Deep.continue k ())
            | Approve view ->
                Some
                  (fun (k : (b, _) Effect.Deep.continuation) ->
                    let decision = approve view in
                    emit
                      (Trace.Approval
                         {
                           tool = view.tool;
                           decision =
                             (match decision with
                             | Approved -> "approved"
                             | Denied r -> "denied:" ^ r);
                         });
                    Effect.Deep.continue k decision)
            | _ -> None);
      }
  in
  (result, List.rev !events)

(* ---------- replay handler (§9) ----------
   Answers every effect from the recorded trace; fails loudly on any
   divergence: schema-hash or ctx-hash mismatch, different tool, different
   args, trace exhaustion. Deterministic tests of nondeterministic systems.

   SECURITY (F4, §13.7): this is PURE replay — no live tool ever runs, and a
   recorded approval is REPLAYED, not re-prompted. That is safe only because
   nothing here authorizes a real side effect. Do NOT build "replay to event k,
   then go live" (§9 time-travel) on this function: replay-into-live must first
   verify a keyed signature over the trace and re-invoke the approval handler
   (and, in strict mode, admission). Both are M4 work; hashes here are unkeyed
   MD5 and integrity-only against accidental drift, not tampering. *)

type replay_error =
  [ `Trace_exhausted
  | `Mismatch of string ]

let replay (type out) ~(trace : Trace.t) (agent : unit -> out) :
    (out, replay_error) result =
  let remaining = ref trace in
  let next () =
    match !remaining with
    | [] -> None
    | e :: rest ->
        remaining := rest;
        Some e
  in
  let mismatch fmt = Printf.ksprintf (fun s -> Error (`Mismatch s)) fmt in
  Effect.Deep.match_with agent ()
    {
      retc = (fun v -> Ok v);
      exnc = (fun e -> raise e);
      effc =
        (fun (type b) (eff : b Effect.t) ->
          match eff with
          | Ask (ctx, typed) ->
              Some
                (fun (k : (b, _) Effect.Deep.continuation) ->
                  match next () with
                  | None -> Error `Trace_exhausted
                  | Some (Trace.Ask_response r) ->
                      if r.schema_name <> typed.Schema.name then
                        mismatch "ask: schema name %S, recorded %S" typed.Schema.name
                          r.schema_name
                      else if r.schema_hash <> Schema.hash typed.Schema.schema then
                        mismatch "ask %S: schema hash changed since recording"
                          typed.Schema.name
                      else if r.ctx_hash <> Ctx.hash ctx then
                        mismatch "ask %S: context diverged from recording" typed.Schema.name
                      else (
                        match typed.Schema.parse r.content with
                        | Ok v -> Effect.Deep.continue k v
                        | Error e ->
                            mismatch "ask %S: recorded content no longer parses: %s"
                              typed.Schema.name (Codec.error_to_string e))
                  | Some _ -> mismatch "expected an ask event")
          | Invoke (tool, args) ->
              Some
                (fun (k : (b, _) Effect.Deep.continuation) ->
                  let answer_from_tool_event = function
                    | Trace.Tool_call r ->
                        if r.tool <> tool.Tool_def.name then
                          mismatch "invoke: tool %S, recorded %S" tool.Tool_def.name r.tool
                        else if r.args_schema_hash <> Schema.hash tool.Tool_def.args_schema
                        then mismatch "invoke %S: args schema changed since recording" r.tool
                        else if r.args <> tool.Tool_def.encode_args args then
                          mismatch "invoke %S: args diverged from recording" r.tool
                        else (
                          match tool.Tool_def.decode_result r.result with
                          | Ok res -> Effect.Deep.continue k (Ok res)
                          | Error e ->
                              mismatch "invoke %S: recorded result no longer decodes: %s"
                                r.tool (Codec.error_to_string e))
                    | Trace.Tool_failed r ->
                        if r.tool <> tool.Tool_def.name then
                          mismatch "invoke: tool %S, recorded failure of %S"
                            tool.Tool_def.name r.tool
                        else Effect.Deep.continue k (Error r.error)
                    | _ -> mismatch "expected a tool event"
                  in
                  match next () with
                  | None -> Error `Trace_exhausted
                  | Some (Trace.Approval a) ->
                      (* dangerous-tool path: approval precedes the tool event;
                         a denial has no tool event at all *)
                      if a.tool <> tool.Tool_def.name then
                        mismatch "invoke: approval for %S, expected %S" a.tool
                          tool.Tool_def.name
                      else if a.decision = "approved" then (
                        match next () with
                        | Some e -> answer_from_tool_event e
                        | None -> Error `Trace_exhausted)
                      else
                        let reason =
                          match String.index_opt a.decision ':' with
                          | Some i ->
                              String.sub a.decision (i + 1)
                                (String.length a.decision - i - 1)
                          | None -> a.decision
                        in
                        Effect.Deep.continue k (Error ("approval denied: " ^ reason))
                  | Some e -> answer_from_tool_event e)
          | Note _ ->
              Some
                (fun (k : (b, _) Effect.Deep.continuation) ->
                  match next () with
                  | Some (Trace.Note _) -> Effect.Deep.continue k ()
                  | None -> Error `Trace_exhausted
                  | Some _ -> mismatch "expected a note event")
          | Approve view ->
              Some
                (fun (k : (b, _) Effect.Deep.continuation) ->
                  match next () with
                  | Some (Trace.Approval a) ->
                      if a.tool <> view.tool then
                        mismatch "approve: %S, recorded %S" view.tool a.tool
                      else if a.decision = "approved" then Effect.Deep.continue k Approved
                      else
                        Effect.Deep.continue k
                          (Denied
                             (match String.index_opt a.decision ':' with
                             | Some i ->
                                 String.sub a.decision (i + 1)
                                   (String.length a.decision - i - 1)
                             | None -> a.decision))
                  | None -> Error `Trace_exhausted
                  | Some _ -> mismatch "expected an approval event")
          | _ -> None);
    }
