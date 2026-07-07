module Untrusted = struct
  type t = string

  let of_tool_result s = s
  let to_string s = s
end

type justification = string
type t = string

let of_user s = s
let of_static s = s
let launder j (u : Untrusted.t) : t * justification = (Untrusted.to_string u, j)
let to_string s = s
let concat = String.concat ""
let ( ^^ ) a b = a ^ b
