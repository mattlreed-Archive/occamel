(* Shared JSON decoding helpers — the runtime that occamel-ppx generated code
   calls, and that hand-written codecs (Plan) build on. One error shape
   everywhere so the repair loop (§8) always has a structured error to work
   with. *)

(* [code] classifies a failure WITHOUT echoing payload bytes. [msg] may
   contain attacker/model-controlled fragments (a bad token, an unexpected
   key, an out-of-range value) and is for LOCAL use only — traces, logs,
   debugging. The model-facing repair prompt (§8/§13.8) is built from [code]
   + [path] + schema and never touches [msg]. See [safe_message]. *)
type code =
  | Invalid_json
  | Missing_field
  | Unexpected_field
  | Type_mismatch
  | Out_of_bounds
  | Bad_enum
  | Duplicate_field
  | Refinement_failed
  | Other

type error = { path : string; msg : string; code : code }

let error_to_string { path; msg; _ } = Printf.sprintf "%s: %s" path msg

(* Payload-free, model-safe rendering: only the structural path (derived from
   type/schema, never from payload contents) and a fixed category phrase. *)
let safe_message { path; code; _ } =
  let phrase =
    match code with
    | Invalid_json -> "the response was not valid JSON"
    | Missing_field -> "a required field is missing"
    | Unexpected_field -> "an object has a field not permitted by the schema"
    | Type_mismatch -> "a value has the wrong type"
    | Out_of_bounds -> "a numeric value is outside its allowed range"
    | Bad_enum -> "a value is not one of the permitted choices"
    | Duplicate_field -> "an object has a duplicate key"
    | Refinement_failed -> "a value failed a semantic constraint"
    | Other -> "the value did not conform to the schema"
  in
  Printf.sprintf "at %s: %s" path phrase

let err ?(code = Other) path msg : ('a, error) result = Error { path; msg; code }

(* Called by ppx-generated variant decoders. [value] goes into the LOCAL msg
   only; the model-facing safe_message ignores it (F1/§13.8). *)
let err_bad_enum path ~kind value : ('a, error) result =
  err ~code:Bad_enum path (Printf.sprintf "unknown %s %S" kind value)

let ( let* ) = Result.bind

let field path name = function
  | `Assoc kvs -> (
      match List.assoc_opt name kvs with
      | Some v -> Ok v
      | None ->
          err ~code:Missing_field path (Printf.sprintf "missing field %S" name))
  | _ -> err ~code:Type_mismatch path "expected an object"

let field_opt path name = function
  | `Assoc kvs -> Ok (List.assoc_opt name kvs)
  | _ -> err ~code:Type_mismatch path "expected an object"

let as_string path = function
  | `String v -> Ok v
  | _ -> err ~code:Type_mismatch path "expected a string"

let as_int path = function
  | `Int v -> Ok v
  | _ -> err ~code:Type_mismatch path "expected an integer"

let as_float path = function
  | `Float v -> Ok v
  | `Int v -> Ok (float_of_int v)
  | _ -> err ~code:Type_mismatch path "expected a number"

let as_bool path = function
  | `Bool v -> Ok v
  | _ -> err ~code:Type_mismatch path "expected a boolean"

let as_list path = function
  | `List v -> Ok v
  | _ -> err ~code:Type_mismatch path "expected an array"

let as_option parse path = function
  | `Null -> Ok None
  | v ->
      let* v = parse path v in
      Ok (Some v)

let nonempty_string path v =
  let* v = as_string path v in
  if String.length v = 0 then
    err ~code:Refinement_failed path "expected a non-empty string"
  else Ok v

let bounded_int ?min ?max path v =
  let* v = as_int path v in
  let check pred limit label =
    match limit with
    | Some l when not (pred v l) ->
        err ~code:Out_of_bounds path
          (Printf.sprintf "expected an integer %s %d, got %d" label l v)
    | _ -> Ok ()
  in
  let* () = check ( >= ) min ">=" in
  let* () = check ( <= ) max "<=" in
  Ok v

(* Rejects unknown keys AND duplicate keys (F5: first-wins decode must never
   disagree with an all-keys validator or a last-wins re-serializer). *)
let no_extra_fields path allowed = function
  | `Assoc kvs -> (
      match List.find_opt (fun (k, _) -> not (List.mem k allowed)) kvs with
      | Some (k, _) ->
          err ~code:Unexpected_field path (Printf.sprintf "unexpected field %S" k)
      | None ->
          let rec dup = function
            | [] -> Ok ()
            | (k, _) :: rest ->
                if List.mem_assoc k rest then
                  err ~code:Duplicate_field path (Printf.sprintf "duplicate field %S" k)
                else dup rest
          in
          dup kvs)
  | _ -> err ~code:Type_mismatch path "expected an object"

let map_result f i0 path xs =
  let rec go i acc = function
    | [] -> Ok (List.rev acc)
    | x :: rest ->
        let* y = f (Printf.sprintf "%s[%d]" path i) x in
        go (i + 1) (y :: acc) rest
  in
  go i0 [] xs

let list_of parse path v =
  let* items = as_list path v in
  map_result parse 0 path items

(* §3.3 refinement hook: run a user refinement after structural parsing. *)
let refine (refinement : 'a -> ('a, string) result) path (v : 'a) :
    ('a, error) result =
  match refinement v with
  | Ok v -> Ok v
  | Error msg -> err ~code:Refinement_failed path msg

(* §13.8 resource limits: cap input size and bracket-nesting depth BEFORE
   handing bytes to Yojson, whose recursive-descent parser stack-overflows on
   deep input (a hostile/compromised endpoint is in scope, §13.1). We also
   convert a Stack_overflow escaping Yojson into a structured error rather
   than letting it crash the agent. *)
let max_bytes = 4 * 1024 * 1024
let max_depth = 200

let depth_ok s =
  let d = ref 0 and ok = ref true and in_str = ref false and esc = ref false in
  String.iter
    (fun c ->
      if !in_str then (
        if !esc then esc := false
        else if c = '\\' then esc := true
        else if c = '"' then in_str := false)
      else
        match c with
        | '"' -> in_str := true
        | '[' | '{' ->
            incr d;
            if !d > max_depth then ok := false
        | ']' | '}' -> decr d
        | _ -> ())
    s;
  !ok

let of_string ~(of_json : Yojson.Safe.t -> ('a, error) result) (s : string) :
    ('a, error) result =
  if String.length s > max_bytes then
    err ~code:Invalid_json "$"
      (Printf.sprintf "response exceeds %d-byte limit" max_bytes)
  else if not (depth_ok s) then
    err ~code:Invalid_json "$"
      (Printf.sprintf "JSON nesting exceeds depth %d" max_depth)
  else
    match Yojson.Safe.from_string s with
    | json -> of_json json
    | exception Yojson.Json_error msg -> err ~code:Invalid_json "$" ("invalid JSON: " ^ msg)
    | exception Stack_overflow -> err ~code:Invalid_json "$" "JSON too deeply nested"
