(* Toy interpreter for M0: executes straight-line Call/Return plans against
   the stubbed tool. Extract and If are valid *plans* (the eval judges them)
   but are not executable until the real interpreter lands (M3). *)

type outcome =
  | Returned of string
  | Unsupported of string  (* plan is valid but uses M3 features *)
  | Runtime_error of string

let eval_expr env = function
  | Plan.Lit v -> Ok v
  | Plan.Var name -> (
      match List.assoc_opt name env with
      | Some v -> Ok v
      | None -> Error (Printf.sprintf "unbound variable %S at runtime" name))

let run (plan : Plan.t) : outcome =
  let rec go env = function
    | [] -> Runtime_error "plan ended without return"
    | Plan.Return value :: _ -> (
        match eval_expr env value with
        | Ok v -> Returned v
        | Error e -> Runtime_error e)
    | Plan.Call { bind; tool = "web_search"; args } :: rest -> (
        match List.assoc_opt "query" (List.map (fun (n, v) -> (n, v)) args) with
        | None -> Runtime_error "web_search requires a \"query\" argument"
        | Some q -> (
            match eval_expr env q with
            | Error e -> Runtime_error e
            | Ok query -> go ((bind, Tool.web_search ~query) :: env) rest))
    | Plan.Call { tool; _ } :: _ ->
        Runtime_error (Printf.sprintf "no implementation for tool %S" tool)
    | Plan.Extract _ :: _ -> Unsupported "extract (M3)"
    | Plan.If _ :: _ -> Unsupported "if (M3)"
  in
  go [] plan
