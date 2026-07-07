(* Provenance lattice (design doc §6.3). Every strict-mode binding carries a
   set of sources describing where its data came from. Sets join along both
   data flow (an expression's provenance is the union of its inputs') and
   control flow (everything executed inside a branch/loop whose scrutinee is
   untrusted gains a Branch/Loop source — §6.2, §13.2).

   Soundness rests on the planner/executor split: the plan itself cannot be
   injected (its author, the P-LLM, never saw untrusted bytes), so these
   tracked sources are the ONLY channel of attacker influence. *)

type site = string
(* a stable label for a plan location: a bind name or "stepN". Used to name a
   call site / extraction / branch condition in a source. *)

type source =
  | User  (* the original trusted request *)
  | Static  (* author-controlled constants (prompts, tool specs) *)
  | Tool_result of site
  | Extracted of { from : site; schema : string }
  | Branch of site  (* control-flow taint from a conditional/loop scrutinee *)

let compare_source (a : source) (b : source) = compare a b

module SS = Set.Make (struct
  type t = source

  let compare = compare_source
end)

type t = SS.t

let empty = SS.empty
let user = SS.singleton User
let static = SS.singleton Static
let tool_result site = SS.singleton (Tool_result site)
let extracted ~from ~schema = SS.singleton (Extracted { from; schema })
let of_list = SS.of_list
let to_list = SS.elements
let join = SS.union
let join_all = List.fold_left SS.union SS.empty
let add_branch site t = SS.add (Branch site) t

(* Trusted iff every source is User or Static. Any Tool_result / Extracted /
   Branch makes the value untrusted — attacker-influenceable. *)
let is_trusted (t : t) : bool =
  SS.for_all (function User | Static -> true | _ -> false) t

let source_to_string = function
  | User -> "user"
  | Static -> "static"
  | Tool_result s -> Printf.sprintf "tool_result(%s)" s
  | Extracted { from; schema } -> Printf.sprintf "extracted(%s:%s)" from schema
  | Branch s -> Printf.sprintf "branch(%s)" s

let to_string (t : t) : string =
  "{" ^ String.concat ", " (List.map source_to_string (to_list t)) ^ "}"

(* Stable JSON for traces (§9). *)
let to_json (t : t) : Yojson.Safe.t =
  `List (List.map (fun s -> `String (source_to_string s)) (to_list t))
