(* Shared JSON decoding helpers — the runtime that occamel-ppx generated code
   calls, and that hand-written codecs (Plan) build on. One error shape
   everywhere so the repair loop (§8) always has a structured error to work
   with. *)

type error = { path : string; msg : string }

let error_to_string { path; msg } = Printf.sprintf "%s: %s" path msg

let err path msg : ('a, error) result = Error { path; msg }

let ( let* ) = Result.bind

let field path name = function
  | `Assoc kvs -> (
      match List.assoc_opt name kvs with
      | Some v -> Ok v
      | None -> err path (Printf.sprintf "missing field %S" name))
  | _ -> err path "expected an object"

let field_opt path name = function
  | `Assoc kvs -> Ok (List.assoc_opt name kvs)
  | _ -> err path "expected an object"

let as_string path = function
  | `String v -> Ok v
  | _ -> err path "expected a string"

let as_int path = function
  | `Int v -> Ok v
  | _ -> err path "expected an integer"

let as_float path = function
  | `Float v -> Ok v
  | `Int v -> Ok (float_of_int v)
  | _ -> err path "expected a number"

let as_bool path = function
  | `Bool v -> Ok v
  | _ -> err path "expected a boolean"

let as_list path = function
  | `List v -> Ok v
  | _ -> err path "expected an array"

let as_option parse path = function
  | `Null -> Ok None
  | v ->
      let* v = parse path v in
      Ok (Some v)

let nonempty_string path v =
  let* v = as_string path v in
  if String.length v = 0 then err path "expected a non-empty string" else Ok v

let bounded_int ?min ?max path v =
  let* v = as_int path v in
  let check pred limit label =
    match limit with
    | Some l when not (pred v l) ->
        err path (Printf.sprintf "expected an integer %s %d, got %d" label l v)
    | _ -> Ok ()
  in
  let* () = check ( >= ) min ">=" in
  let* () = check ( <= ) max "<=" in
  Ok v

let no_extra_fields path allowed = function
  | `Assoc kvs -> (
      match List.find_opt (fun (k, _) -> not (List.mem k allowed)) kvs with
      | Some (k, _) -> err path (Printf.sprintf "unexpected field %S" k)
      | None -> Ok ())
  | _ -> err path "expected an object"

let rec map_result f i path = function
  | [] -> Ok []
  | x :: rest ->
      let* y = f (Printf.sprintf "%s[%d]" path i) x in
      let* ys = map_result f (i + 1) path rest in
      Ok (y :: ys)

let list_of parse path v =
  let* items = as_list path v in
  map_result parse 0 path items

(* §3.3 refinement hook: run a user refinement after structural parsing. *)
let refine (refinement : 'a -> ('a, string) result) path (v : 'a) :
    ('a, error) result =
  match refinement v with Ok v -> Ok v | Error msg -> err path msg

let of_string ~(of_json : Yojson.Safe.t -> ('a, error) result) (s : string) :
    ('a, error) result =
  match Yojson.Safe.from_string s with
  | json -> of_json json
  | exception Yojson.Json_error msg -> err "$" ("invalid JSON: " ^ msg)
