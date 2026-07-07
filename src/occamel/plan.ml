(* Plan DSL — M0 hand-written subset of design doc §5.2.
   Four step constructors over two expression constructors. The JSON schema is
   hand-written, inline, and depth-unrolled (no $ref/$defs; [If] bodies admit
   only non-[If] steps) per docs/research/m0-ollama-structured-outputs.md.
   Everything the backend returns is re-validated here — backend enforcement
   is never trusted (design doc §3.2.1). *)

type expr =
  | Var of string
  | Lit of string

type step =
  | Call of { bind : string; tool : string; args : (string * expr) list }
  | Extract of { bind : string; source : expr; question : string }
  | If of { cond : expr; then_ : step list; else_ : step list }
  | Return of expr

type t = step list

(* M0: single tool, fixed here. Post-M0 the enum comes from the registry (the
   proper design; deferred with the typed tool registry). web_search is the
   benign tool; send_message is the dangerous tool the M5 injection eval guards
   with a require_trusted policy on its recipient field. *)
let known_tools = [ "web_search"; "send_message" ]

type error = Codec.error

let error_to_string = Codec.error_to_string

(* ---------- JSON schema (what the backend is asked to enforce) ---------- *)

let schema : Yojson.Safe.t =
  let s v = `String v in
  let obj props required =
    `Assoc
      [
        ("type", s "object");
        ("properties", `Assoc props);
        ("required", `List (List.map (fun k -> s k) required));
        ("additionalProperties", `Bool false);
      ]
  in
  let string_ty = `Assoc [ ("type", s "string") ] in
  let nonempty_string = `Assoc [ ("type", s "string"); ("minLength", `Int 1) ] in
  let tag v = `Assoc [ ("type", s "string"); ("enum", `List [ s v ]) ] in
  let expr =
    `Assoc
      [
        ( "anyOf",
          `List
            [
              obj [ ("kind", tag "var"); ("name", nonempty_string) ] [ "kind"; "name" ];
              obj [ ("kind", tag "lit"); ("value", string_ty) ] [ "kind"; "value" ];
            ] );
      ]
  in
  let arg = obj [ ("name", nonempty_string); ("value", expr) ] [ "name"; "value" ] in
  let tool_enum =
    `Assoc [ ("type", s "string"); ("enum", `List (List.map (fun t -> s t) known_tools)) ]
  in
  let call =
    obj
      [
        ("op", tag "call");
        ("bind", nonempty_string);
        ("tool", tool_enum);
        ("args", `Assoc [ ("type", s "array"); ("items", arg) ]);
      ]
      [ "op"; "bind"; "tool"; "args" ]
  in
  let extract =
    obj
      [
        ("op", tag "extract");
        ("bind", nonempty_string);
        ("source", expr);
        ("question", nonempty_string);
      ]
      [ "op"; "bind"; "source"; "question" ]
  in
  let return_ = obj [ ("op", tag "return"); ("value", expr) ] [ "op"; "value" ] in
  (* Depth unrolled: steps inside an [if] cannot themselves be [if]. *)
  let inner_steps =
    `Assoc
      [
        ("type", s "array");
        ("items", `Assoc [ ("anyOf", `List [ call; extract; return_ ]) ]);
      ]
  in
  let if_ =
    obj
      [ ("op", tag "if"); ("cond", expr); ("then", inner_steps); ("else", inner_steps) ]
      [ "op"; "cond"; "then"; "else" ]
  in
  let steps =
    `Assoc
      [
        ("type", s "array");
        ("minItems", `Int 1);
        ("items", `Assoc [ ("anyOf", `List [ call; extract; if_; return_ ]) ]);
      ]
  in
  obj [ ("steps", steps) ] [ "steps" ]

(* ---------- Codec ---------- *)

let json_of_expr = function
  | Var name -> `Assoc [ ("kind", `String "var"); ("name", `String name) ]
  | Lit value -> `Assoc [ ("kind", `String "lit"); ("value", `String value) ]

let rec json_of_step = function
  | Call { bind; tool; args } ->
      `Assoc
        [
          ("op", `String "call");
          ("bind", `String bind);
          ("tool", `String tool);
          ( "args",
            `List
              (List.map
                 (fun (name, v) ->
                   `Assoc [ ("name", `String name); ("value", json_of_expr v) ])
                 args) );
        ]
  | Extract { bind; source; question } ->
      `Assoc
        [
          ("op", `String "extract");
          ("bind", `String bind);
          ("source", json_of_expr source);
          ("question", `String question);
        ]
  | If { cond; then_; else_ } ->
      `Assoc
        [
          ("op", `String "if");
          ("cond", json_of_expr cond);
          ("then", `List (List.map json_of_step then_));
          ("else", `List (List.map json_of_step else_));
        ]
  | Return value -> `Assoc [ ("op", `String "return"); ("value", json_of_expr value) ]

let to_json (plan : t) : Yojson.Safe.t =
  `Assoc [ ("steps", `List (List.map json_of_step plan)) ]

open Codec

let nonempty = Codec.nonempty_string

let expr_of_json path json =
  let* () = no_extra_fields path [ "kind"; "name"; "value" ] json in
  let* kind = field path "kind" json in
  let* kind = as_string (path ^ ".kind") kind in
  match kind with
  | "var" ->
      let* name = field path "name" json in
      let* name = nonempty (path ^ ".name") name in
      Ok (Var name)
  | "lit" ->
      let* value = field path "value" json in
      let* value = as_string (path ^ ".value") value in
      Ok (Lit value)
  | other -> err ~code:Bad_enum (path ^ ".kind") (Printf.sprintf "unknown expr kind %S" other)

let arg_of_json path json =
  let* () = no_extra_fields path [ "name"; "value" ] json in
  let* name = field path "name" json in
  let* name = nonempty (path ^ ".name") name in
  let* value = field path "value" json in
  let* value = expr_of_json (path ^ ".value") value in
  Ok (name, value)

let rec step_of_json ~allow_if path json =
  let* op = field path "op" json in
  let* op = as_string (path ^ ".op") op in
  match op with
  | "call" ->
      let* () = no_extra_fields path [ "op"; "bind"; "tool"; "args" ] json in
      let* bind = field path "bind" json in
      let* bind = nonempty (path ^ ".bind") bind in
      let* tool = field path "tool" json in
      let* tool = nonempty (path ^ ".tool") tool in
      let* () =
        if List.mem tool known_tools then Ok ()
        else err ~code:Bad_enum (path ^ ".tool") (Printf.sprintf "unknown tool %S" tool)
      in
      let* args = field path "args" json in
      let* args = as_list (path ^ ".args") args in
      let* args = map_result arg_of_json 0 (path ^ ".args") args in
      Ok (Call { bind; tool; args })
  | "extract" ->
      let* () = no_extra_fields path [ "op"; "bind"; "source"; "question" ] json in
      let* bind = field path "bind" json in
      let* bind = nonempty (path ^ ".bind") bind in
      let* source = field path "source" json in
      let* source = expr_of_json (path ^ ".source") source in
      let* question = field path "question" json in
      let* question = nonempty (path ^ ".question") question in
      Ok (Extract { bind; source; question })
  | "return" ->
      let* () = no_extra_fields path [ "op"; "value" ] json in
      let* value = field path "value" json in
      let* value = expr_of_json (path ^ ".value") value in
      Ok (Return value)
  | "if" when allow_if ->
      let* () = no_extra_fields path [ "op"; "cond"; "then"; "else" ] json in
      let* cond = field path "cond" json in
      let* cond = expr_of_json (path ^ ".cond") cond in
      let* then_ = field path "then" json in
      let* then_ = as_list (path ^ ".then") then_ in
      let* then_ = map_result (step_of_json ~allow_if:false) 0 (path ^ ".then") then_ in
      let* else_ = field path "else" json in
      let* else_ = as_list (path ^ ".else") else_ in
      let* else_ = map_result (step_of_json ~allow_if:false) 0 (path ^ ".else") else_ in
      Ok (If { cond; then_; else_ })
  | "if" -> err ~code:Bad_enum path "nested \"if\" is not allowed (schema is depth-unrolled)"
  | other -> err ~code:Bad_enum (path ^ ".op") (Printf.sprintf "unknown op %S" other)

(* Scoping: binds must be fresh, vars must be bound before use. After an [If],
   only names bound before it remain in scope (a branch may not have run). *)
let validate_scoping (plan : t) : (unit, error) result =
  let expr_ok path bound = function
    | Lit _ -> Ok ()
    | Var name ->
        if List.mem name bound then Ok ()
        else err ~code:Refinement_failed path (Printf.sprintf "variable %S used before being bound" name)
  in
  let bind_ok path bound name =
    if List.mem name bound then
      err ~code:Refinement_failed path (Printf.sprintf "name %S is already bound" name)
    else Ok ()
  in
  let rec go path i bound = function
    | [] -> Ok bound
    | step :: rest ->
        let p = Printf.sprintf "%s[%d]" path i in
        let* bound =
          match step with
          | Call { bind; args; _ } ->
              let* () = bind_ok p bound bind in
              let* () =
                map_result
                  (fun p' (_, v) -> expr_ok p' bound v)
                  0 (p ^ ".args") args
                |> Result.map ignore
              in
              Ok (bind :: bound)
          | Extract { bind; source; _ } ->
              let* () = bind_ok p bound bind in
              let* () = expr_ok (p ^ ".source") bound source in
              Ok (bind :: bound)
          | If { cond; then_; else_ } ->
              let* () = expr_ok (p ^ ".cond") bound cond in
              let* _ = go (p ^ ".then") 0 bound then_ in
              let* _ = go (p ^ ".else") 0 bound else_ in
              Ok bound
          | Return value ->
              let* () = expr_ok (p ^ ".value") bound value in
              Ok bound
        in
        go path (i + 1) bound rest
  in
  Result.map ignore (go "steps" 0 [] plan)

let of_json (json : Yojson.Safe.t) : (t, error) result =
  let* () = no_extra_fields "plan" [ "steps" ] json in
  let* steps = field "plan" "steps" json in
  let* steps = as_list "plan.steps" steps in
  let* () =
    if steps = [] then err ~code:Refinement_failed "plan.steps" "plan must not be empty"
    else Ok ()
  in
  let* plan = map_result (step_of_json ~allow_if:true) 0 "steps" steps in
  let* () = validate_scoping plan in
  Ok plan

(* Reuse Codec.of_string for the §13.8 size/depth guards and the
   Stack_overflow-safe parse. *)
let of_string (s : string) : (t, error) result = Codec.of_string ~of_json s
