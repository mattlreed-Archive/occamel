(* §8 repair loop: validate → structured error → bounded re-prompt →
   `Unparseable as a variant the caller must handle.

   §13.8 is enforced by construction here: the repair message is built ONLY
   from the structured error (path + message) and the schema. The invalid
   payload is never echoed back to the model, and prior failed attempts are
   not accumulated into context beyond their error strings. Backend-agnostic:
   [ask] is any function that produces model text given extra repair
   messages; this module has no HTTP dependency. *)

type 'e failure =
  [ `Unparseable of Codec.error list  (* one error per failed attempt, in order *)
  | `Backend of 'e ]

let repair_message ~(schema : Yojson.Safe.t) (err : Codec.error) : string =
  Printf.sprintf
    "Your previous response was rejected by the validator and was NOT used. \
     Problem at %s: %s. Reply again with ONLY a JSON value conforming to \
     this schema:\n%s"
    err.Codec.path err.Codec.msg
    (Yojson.Safe.to_string schema)

(* Returns the parsed value plus the errors of the failed attempts that
   preceded it (empty list = first try succeeded). *)
let run ?(max_repairs = 2) ~(ask : extra:string list -> (string, 'e) result)
    ~(parse : string -> ('a, Codec.error) result) ~(schema : Yojson.Safe.t) () :
    ('a * Codec.error list, 'e failure) result =
  let rec go attempt errors extra =
    match ask ~extra with
    | Error e -> Error (`Backend e)
    | Ok content -> (
        match parse content with
        | Ok v -> Ok (v, List.rev errors)
        | Error err ->
            if attempt >= max_repairs then
              Error (`Unparseable (List.rev (err :: errors)))
            else
              go (attempt + 1) (err :: errors)
                (extra @ [ repair_message ~schema err ]))
  in
  go 0 [] []
