type t = { plaintext : string }

let of_env name =
  match Sys.getenv_opt name with
  | Some v when String.length v > 0 -> Some { plaintext = v }
  | _ -> None

let of_string s = { plaintext = s }
let use t f = f t.plaintext

let redacted t =
  (* first 6 hex of an md5 fingerprint identifies which secret without
     revealing it; the value itself never appears *)
  Printf.sprintf "<secret:%s>" (String.sub (Digest.to_hex (Digest.string t.plaintext)) 0 6)

let pp fmt t = Format.pp_print_string fmt (redacted t)
