module Untrusted = struct
  type t = string

  let of_tool_result s = s
  let read s = s
end

type justification = string
type t = string

let of_user s = s
let of_static s = s

let launder ~audit (j : justification) (u : Untrusted.t) : t =
  audit j;
  Untrusted.read u

let to_string s = s
let concat = String.concat ""
let ( ^^ ) a b = a ^ b
