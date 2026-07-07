(* [@@deriving occamel] tests: qcheck round-trip laws (§7.3) plus unit cases
   for attributes, defaults, refinement, and rejection paths.

   Law 1: of_json (to_json x) = Ok x
   Law 2: Schema.validate schema (to_json x) = Ok ()
   Generators produce only values satisfying the types' declared invariants
   (bounds, refinements) — to_json is not a validator (§3.3: the choke point
   is parse-side). *)

type color = Red | Green | Blue [@@deriving occamel]

type search_args = {
  query : string; [@doc "Search query, 1-6 words"]
  max_results : int; [@default 5] [@min 1] [@max 10]
  site : string option;
}
[@@deriving occamel]

type action =
  | Search of search_args
  | Note of { text : string; important : bool }
  | Done
[@@deriving occamel]

type tags = { labels : string list; primary : color } [@@deriving occamel]

type username = { name : string }
[@@deriving
  occamel
    ~parse:
      (fun u ->
        if u.name <> "" && String.lowercase_ascii u.name = u.name then Ok u
        else Error "name must be non-empty lowercase")]

(* ---------- generators ---------- *)

open QCheck

let gen_str = Gen.(string_size ~gen:(char_range 'a' 'z') (0 -- 8))
let gen_color = Gen.oneof_list [ Red; Green; Blue ]

let gen_search_args =
  Gen.(
    map3
      (fun query max_results site -> { query; max_results; site })
      gen_str (1 -- 10)
      (option gen_str))

let gen_action =
  Gen.(
    oneof
      [
        map (fun a -> Search a) gen_search_args;
        map2 (fun text important -> Note { text; important }) gen_str bool;
        return Done;
      ])

let gen_tags =
  Gen.(map2 (fun labels primary -> { labels; primary }) (list_size (0 -- 5) gen_str) gen_color)

let gen_username =
  Gen.map (fun name -> { name }) Gen.(string_size ~gen:(char_range 'a' 'z') (1 -- 8))

(* ---------- laws ---------- *)

let roundtrip name arb of_json to_json =
  Test.make ~count:1000 ~name:(name ^ " roundtrip") arb (fun x ->
      of_json (to_json x) = Ok x)

let validates name arb schema to_json =
  Test.make ~count:1000 ~name:(name ^ " schema-validates") arb (fun x ->
      Occamel.Schema.validate schema (to_json x) = Ok ())

let tests =
  [
    roundtrip "color" (make gen_color) color_of_json color_to_json;
    validates "color" (make gen_color) color_schema color_to_json;
    roundtrip "search_args" (make gen_search_args) search_args_of_json search_args_to_json;
    validates "search_args" (make gen_search_args) search_args_schema search_args_to_json;
    roundtrip "action" (make gen_action) action_of_json action_to_json;
    validates "action" (make gen_action) action_schema action_to_json;
    roundtrip "tags" (make gen_tags) tags_of_json tags_to_json;
    validates "tags" (make gen_tags) tags_schema tags_to_json;
    roundtrip "username" (make gen_username) username_of_json username_to_json;
  ]

(* ---------- unit cases ---------- *)

let expect_error what = function
  | Ok _ -> failwith (what ^ ": expected Error")
  | Error (_ : Occamel.Codec.error) -> ()

let json s = Yojson.Safe.from_string s

let () =
  List.iter QCheck.Test.check_exn tests;

  (* [@default]: missing field takes the default *)
  (match search_args_of_json (json {|{"query":"x","site":null}|}) with
  | Ok { max_results = 5; _ } -> ()
  | _ -> failwith "default not applied");

  (* [@min]/[@max] enforced at parse time *)
  expect_error "bounds"
    (search_args_of_json (json {|{"query":"x","max_results":50,"site":null}|}));

  (* additionalProperties: extra field rejected *)
  expect_error "extra field"
    (search_args_of_json (json {|{"query":"x","max_results":3,"site":null,"zzz":1}|}));

  (* unknown variant kind rejected *)
  expect_error "unknown kind" (action_of_json (json {|{"kind":"launch_missiles"}|}));

  (* option: null decodes to None *)
  (match search_args_of_json (json {|{"query":"x","max_results":3,"site":null}|}) with
  | Ok { site = None; _ } -> ()
  | _ -> failwith "null option");

  (* nullary-variant enum encodes as a bare string *)
  assert (color_to_json Green = `String "green");
  expect_error "bad enum value" (color_of_json (json {|"purple"|}));

  (* ~parse refinement runs inside of_json *)
  expect_error "refinement" (username_of_json (json {|{"name":"BigMatt"}|}));
  (match username_of_json (json {|{"name":"matt"}|}) with
  | Ok { name = "matt" } -> ()
  | _ -> failwith "refinement accept");

  (* schema metadata: [@doc] lands as description; [@default] as default *)
  let props =
    match Occamel.Schema.member "properties" search_args_schema with
    | Some (`Assoc p) -> p
    | _ -> failwith "no properties"
  in
  (match List.assoc "query" props with
  | `Assoc kvs -> assert (List.assoc "description" kvs = `String "Search query, 1-6 words")
  | _ -> failwith "query schema");
  (match List.assoc "max_results" props with
  | `Assoc kvs ->
      assert (List.assoc "minimum" kvs = `Int 1);
      assert (List.assoc "maximum" kvs = `Int 10);
      assert (List.assoc "default" kvs = `Int 5)
  | _ -> failwith "max_results schema");

  (* F1/§13.8: safe_message must never contain payload bytes. Feed a sentinel
     through every echoing channel and assert it is absent from safe_message
     (while error_to_string, the local form, may contain it). *)
  let sentinel = "INJECT_ME_42" in
  let safe_of r =
    match r with Ok _ -> "" | Error e -> Occamel.Codec.safe_message e
  in
  let contains_sentinel s =
    let n = String.length sentinel and h = String.length s in
    let rec go i = i + n <= h && (String.sub s i n = sentinel || go (i + 1)) in
    go 0
  in
  (* unexpected field name *)
  assert (
    not
      (contains_sentinel
         (safe_of
            (search_args_of_json
               (json (Printf.sprintf {|{"query":"x","max_results":1,"site":null,"%s":1}|} sentinel))))));
  (* unknown enum value *)
  assert (
    not
      (contains_sentinel
         (safe_of (action_of_json (json (Printf.sprintf {|{"kind":"%s"}|} sentinel))))));
  (* invalid JSON echoes the offending token in msg but not safe_message *)
  (match Occamel.Codec.of_string ~of_json:action_of_json (sentinel ^ "@@@") with
  | Error e ->
      assert (not (contains_sentinel (Occamel.Codec.safe_message e)))
  | Ok _ -> failwith "should not parse");

  (* F2/§13.8: pathological nesting is rejected structurally, no crash *)
  (match Occamel.Codec.of_string ~of_json:action_of_json (String.make 100000 '[') with
  | Error _ -> ()
  | Ok _ -> failwith "deep nesting should be rejected");

  (* F5: duplicate keys rejected *)
  expect_error "duplicate key"
    (search_args_of_json (json {|{"query":"a","query":"b","max_results":1,"site":null}|}));

  (* §13.2 channel width: an enum is a narrow channel, a free string is open *)
  (match Occamel.Schema.channel_width color_schema with
  | Occamel.Schema.Bits b -> assert (b > 1.0 && b < 2.0)  (* log2 3 ≈ 1.58 *)
  | Unbounded -> failwith "enum should be bounded");
  (match Occamel.Schema.channel_width search_args_schema with
  | Occamel.Schema.Unbounded -> ()  (* contains a free string field *)
  | Bits _ -> failwith "free-string record should be unbounded");
  (* the lint fires only for untrusted data into an unbounded schema reaching a sink *)
  assert (
    Occamel.Schema.extraction_lint ~from_untrusted:true ~reaches_sink:true search_args_schema
    <> None);
  assert (
    Occamel.Schema.extraction_lint ~from_untrusted:true ~reaches_sink:true color_schema = None);
  assert (
    Occamel.Schema.extraction_lint ~from_untrusted:false ~reaches_sink:true search_args_schema
    = None);

  (* M4-review M1: an object that permits additional properties is an OPEN
     channel, not zero bits — under-reporting would hide an injection channel *)
  let open_obj = Yojson.Safe.from_string {|{"type":"object","properties":{}}|} in
  assert (Occamel.Schema.channel_width open_obj = Occamel.Schema.Unbounded);
  let narrow_but_open =
    Yojson.Safe.from_string
      {|{"type":"object","properties":{"flag":{"type":"boolean"}}}|}
  in
  assert (Occamel.Schema.channel_width narrow_but_open = Occamel.Schema.Unbounded);
  let closed_bool =
    Yojson.Safe.from_string
      {|{"type":"object","properties":{"flag":{"type":"boolean"}},"additionalProperties":false}|}
  in
  (match Occamel.Schema.channel_width closed_bool with
  | Occamel.Schema.Bits b -> assert (b = 1.0)
  | Unbounded -> failwith "closed bool-only object should be 1 bit");

  print_endline "all derive tests passed"
