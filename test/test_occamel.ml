(* Plan DSL tests: codec round-trip, validation rejections, interpreter. *)

let ok = function Ok v -> v | Error e -> failwith (Occamel.Plan.error_to_string e)

let expect_error what = function
  | Ok _ -> failwith (what ^ ": expected an error, got Ok")
  | Error (_ : Occamel.Plan.error) -> ()

let sample : Occamel.Plan.t =
  [
    Call
      {
        bind = "r1";
        tool = "web_search";
        args = [ ("query", Occamel.Plan.Lit "capital of France") ];
      };
    Extract { bind = "e1"; source = Var "r1"; question = "Which city?" };
    If
      {
        cond = Var "e1";
        then_ = [ Return (Var "e1") ];
        else_ = [ Return (Lit "unknown") ];
      };
    Return (Var "e1");
  ]

let () =
  (* Round trip *)
  let json = Occamel.Plan.to_json sample in
  let back = ok (Occamel.Plan.of_json json) in
  assert (back = sample);

  (* Unbound variable is rejected *)
  expect_error "unbound var"
    (Occamel.Plan.of_string
       {|{"steps":[{"op":"return","value":{"kind":"var","name":"nope"}}]}|});

  (* Unknown tool is rejected *)
  expect_error "unknown tool"
    (Occamel.Plan.of_string
       {|{"steps":[{"op":"call","bind":"r","tool":"shell","args":[]},
          {"op":"return","value":{"kind":"var","name":"r"}}]}|});

  (* Duplicate bind is rejected *)
  expect_error "duplicate bind"
    (Occamel.Plan.of_string
       {|{"steps":[
          {"op":"call","bind":"r","tool":"web_search","args":[]},
          {"op":"call","bind":"r","tool":"web_search","args":[]},
          {"op":"return","value":{"kind":"var","name":"r"}}]}|});

  (* Nested if is rejected (depth-unrolled schema) *)
  expect_error "nested if"
    (Occamel.Plan.of_string
       {|{"steps":[
          {"op":"call","bind":"r","tool":"web_search","args":[]},
          {"op":"if","cond":{"kind":"var","name":"r"},
           "then":[{"op":"if","cond":{"kind":"var","name":"r"},"then":[],"else":[]}],
           "else":[]},
          {"op":"return","value":{"kind":"lit","value":"x"}}]}|});

  (* Empty plan is rejected *)
  expect_error "empty plan" (Occamel.Plan.of_string {|{"steps":[]}|});

  (* Vars bound in an if-branch do NOT survive the branch *)
  expect_error "branch-bound var escapes"
    (Occamel.Plan.of_string
       {|{"steps":[
          {"op":"call","bind":"r","tool":"web_search","args":[]},
          {"op":"if","cond":{"kind":"var","name":"r"},
           "then":[{"op":"extract","bind":"x","source":{"kind":"var","name":"r"},"question":"?"}],
           "else":[]},
          {"op":"return","value":{"kind":"var","name":"x"}}]}|});

  (* Interpreter: straight-line call/return works against the stub *)
  let straight : Occamel.Plan.t =
    [
      Call
        {
          bind = "r1";
          tool = "web_search";
          args = [ ("query", Occamel.Plan.Lit "capital of France") ];
        };
      Return (Var "r1");
    ]
  in
  (match Occamel.Interp.run straight with
  | Returned s -> assert (String.length s > 0)
  | _ -> failwith "interp: expected Returned");

  (* Interpreter: extract is Unsupported in M0, not an error *)
  (match Occamel.Interp.run sample with
  | Unsupported _ -> ()
  | _ -> failwith "interp: expected Unsupported for extract");

  print_endline "all plan tests passed"
