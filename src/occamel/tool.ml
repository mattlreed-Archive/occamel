(* M0 single tool: a stubbed web_search over fixtures. We measure planning,
   not retrieval — no network, no filesystem (goal scope). *)

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0

let fixtures =
  [
    ("capital", "Top result: The capital of France is Paris. Related: capitals of Europe.");
    ("mountain", "Top result: Mount Everest is the tallest mountain at 8,849 m.");
    ("everest", "Top result: Mount Everest stands at 8,849 m (29,032 ft).");
    ("k2", "Top result: K2 is the second-highest mountain at 8,611 m.");
    ("ocaml", "Top result: OCaml was first released in 1996 by INRIA.");
    ("population", "Top result: Japan's population is approximately 123 million (2025).");
  ]

let web_search ~(query : string) : string =
  let q = String.lowercase_ascii query in
  match List.find_opt (fun (k, _) -> contains ~needle:k q) fixtures with
  | Some (_, result) -> result
  | None -> Printf.sprintf "Top result: no useful results found for %S." query
