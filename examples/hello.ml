(* The smallest end-to-end taste of Occamel's core idea:
   *OCaml types are the single source of truth for the model boundary.*

   Run it offline (no model, no network):   dune exec examples/hello.exe

   Read it top to bottom — it's five steps, ~30 lines. *)

(* ── 1. Define the model's action space as an ordinary variant. ──────────────
   This is the ONLY place the shape is written down. Everything else is
   derived from it. [@@deriving occamel] is the ppx that does the deriving. *)
type action =
  | Search of { query : string [@doc "1-6 words"] }
  | Answer of { text : string }
[@@deriving occamel]

let () =
  (* ── 2. The ppx derived a JSON schema FROM the type. ──────────────────────
     In production this schema is handed to the model's decoder, which then
     *cannot* emit a token sequence outside it. One source of truth: change the
     type, the schema (and the codec below) change with it. *)
  Printf.printf "Derived schema (constrains the model's output):\n%s\n\n"
    (Yojson.Safe.pretty_to_string action_schema);

  (* ── 3. Pretend the (schema-constrained) model replied. ───────────────────
     Because generation was constrained, this string is guaranteed well-shaped.
     We still re-validate at the boundary — Occamel never trusts the backend. *)
  let model_reply = {|{"kind":"search","query":"tallest mountain"}|} in

  (* ── 4. Parse the reply into a TYPED value at the boundary. ───────────────
     [action_of_json] and the size/depth-guarded [Codec.of_string] were also
     derived. The result is a `(action, error) result` — a real OCaml value,
     not a dictionary of strings. *)
  match Occamel.Codec.of_string ~of_json:action_of_json model_reply with
  | Error e ->
      Printf.printf "boundary rejected the reply: %s\n" (Occamel.Codec.error_to_string e)
  (* ── 5. Handle it with an exhaustive match — the payoff. ──────────────────
     Delete the `Answer` case and this program will NOT COMPILE. The compiler
     forces you to handle every action the model can choose. That is the whole
     bet: the model→program boundary is checked at compile time. *)
  | Ok (Search { query }) -> Printf.printf "model chose to SEARCH for: %s\n" query
  | Ok (Answer { text }) -> Printf.printf "model chose to ANSWER: %s\n" text
