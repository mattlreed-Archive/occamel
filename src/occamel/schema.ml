(* Schema utilities for the T2 intersection dialect (§7.1) that occamel emits:
   object/required/additionalProperties, string/integer/number/boolean/null,
   enum, anyOf, array/items/minItems, minimum/maximum/minLength, description,
   default.

   [validate] is used by the §7.3 property tests ("to_json output validates
   against the derived schema") and later by capability probes. It validates
   OUR dialect only — it is not a general JSON Schema implementation.

   [complexity] is the documented heuristic behind the §7.1 compile-time
   warning. Score = optional fields (anyOf-with-null) count * 3
   + union fan-out beyond the first arm + nesting depth. The weights are
   guesses to be calibrated against real provider limits at M5; the intent is
   only to flag types that will likely trip combined-grammar limits. *)

type t = Yojson.Safe.t

let member name = function
  | `Assoc kvs -> List.assoc_opt name kvs
  | _ -> None

let rec validate (schema : t) (v : Yojson.Safe.t) : (unit, string) result =
  let ( let* ) = Result.bind in
  (* enum first: it constrains independently of type *)
  let* () =
    match member "enum" schema with
    | Some (`List allowed) ->
        if List.mem v allowed then Ok ()
        else Error (Printf.sprintf "value not in enum: %s" (Yojson.Safe.to_string v))
    | _ -> Ok ()
  in
  match member "anyOf" schema with
  | Some (`List arms) ->
      if List.exists (fun arm -> validate arm v = Ok ()) arms then Ok ()
      else Error "no anyOf arm matched"
  | _ -> (
      match member "type" schema with
      | Some (`String "string") -> (
          match v with
          | `String s -> (
              match member "minLength" schema with
              | Some (`Int n) when String.length s < n -> Error "string shorter than minLength"
              | _ -> Ok ())
          | _ -> Error "expected string")
      | Some (`String "integer") -> (
          match v with
          | `Int i ->
              let check name pred =
                match member name schema with
                | Some (`Int bound) when not (pred i bound) -> Error (name ^ " violated")
                | _ -> Ok ()
              in
              let* () = check "minimum" ( >= ) in
              check "maximum" ( <= )
          | _ -> Error "expected integer")
      | Some (`String "number") -> (
          match v with `Float _ | `Int _ -> Ok () | _ -> Error "expected number")
      | Some (`String "boolean") -> (
          match v with `Bool _ -> Ok () | _ -> Error "expected boolean")
      | Some (`String "null") -> (
          match v with `Null -> Ok () | _ -> Error "expected null")
      | Some (`String "array") -> (
          match v with
          | `List items -> (
              let* () =
                match member "minItems" schema with
                | Some (`Int n) when List.length items < n -> Error "fewer than minItems"
                | _ -> Ok ()
              in
              match member "items" schema with
              | Some item_schema ->
                  List.fold_left
                    (fun acc item -> let* () = acc in validate item_schema item)
                    (Ok ()) items
              | None -> Ok ())
          | _ -> Error "expected array")
      | Some (`String "object") -> (
          match v with
          | `Assoc kvs ->
              let props =
                match member "properties" schema with
                | Some (`Assoc props) -> props
                | _ -> []
              in
              let required =
                match member "required" schema with
                | Some (`List rs) ->
                    List.filter_map (function `String s -> Some s | _ -> None) rs
                | _ -> []
              in
              let additional =
                match member "additionalProperties" schema with
                | Some (`Bool b) -> b
                | _ -> true
              in
              let* () =
                List.fold_left
                  (fun acc r ->
                    let* () = acc in
                    if List.mem_assoc r kvs then Ok ()
                    else Error (Printf.sprintf "missing required field %S" r))
                  (Ok ()) required
              in
              List.fold_left
                (fun acc (k, value) ->
                  let* () = acc in
                  match List.assoc_opt k props with
                  | Some prop_schema -> validate prop_schema value
                  | None ->
                      if additional then Ok ()
                      else Error (Printf.sprintf "unexpected field %S" k))
                (Ok ()) kvs
          | _ -> Error "expected object")
      | _ -> Ok () (* no type constraint *))

let complexity (schema : t) : int =
  let rec go depth s =
    let self =
      match member "anyOf" s with
      | Some (`List arms) ->
          let is_null a = member "type" a = Some (`String "null") in
          let optional = List.exists is_null arms in
          let fanout = max 0 (List.length arms - 1) in
          (if optional then 3 else 0)
          + fanout
          + List.fold_left (fun acc a -> acc + go (depth + 1) a) 0 arms
      | _ -> (
          match member "type" s with
          | Some (`String "object") ->
              let props =
                match member "properties" s with Some (`Assoc p) -> p | _ -> []
              in
              1 + List.fold_left (fun acc (_, p) -> acc + go (depth + 1) p) 0 props
          | Some (`String "array") -> (
              match member "items" s with Some i -> 1 + go (depth + 1) i | None -> 1)
          | _ -> 0)
    in
    self + if depth > 4 then 2 else 0
  in
  go 0 schema

(* Warning threshold used by the ppx; a guess to calibrate at M5 (§7.1). *)
let warn_threshold = 24
