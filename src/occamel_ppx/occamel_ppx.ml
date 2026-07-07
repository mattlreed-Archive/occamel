(* [@@deriving occamel] — design doc §7.1/§3.1.

   For [type t = ...] generates [schema], [of_json], [of_json_at], [to_json]
   (for [type foo], [foo_schema] etc.). Schemas target the T2 intersection
   dialect: objects with all fields required + additionalProperties:false;
   variants as tagged unions on a "kind" discriminant (all-nullary variants
   become plain string enums); [option] as anyOf [T, null] with the field
   still required.

   Attributes: [@doc "..."] -> description; [@default e] -> codec default on
   missing field (+ schema "default" when e is a literal); [@min n]/[@max n]
   on int fields -> minimum/maximum + runtime bounds check.

   Deriver option: [@@deriving occamel ~parse:f] with
   [f : t -> (t, string) result] — the §3.3 refinement, run after structural
   parsing inside of_json.

   Unsupported (compile error per §7.1): recursive types, GADTs, tuples,
   functions, multi-argument constructors, parameterized types. The error
   suggests a restructure or (for recursion) the hand-written/T1 route.

   Complexity warning (§7.1): a structural heuristic mirroring
   Occamel.Schema.complexity, emitted as [@@@ocaml.ppwarning] when the score
   exceeds Schema.warn_threshold (24). Warning only, never an error. *)

open Ppxlib
module Ast = Ast_builder.Default

let attr_doc =
  Attribute.declare "occamel.doc" Attribute.Context.label_declaration
    Ast_pattern.(single_expr_payload (estring __))
    Fun.id

let attr_default =
  Attribute.declare "occamel.default" Attribute.Context.label_declaration
    Ast_pattern.(single_expr_payload __)
    Fun.id

let attr_min =
  Attribute.declare "occamel.min" Attribute.Context.label_declaration
    Ast_pattern.(single_expr_payload (eint __))
    Fun.id

let attr_max =
  Attribute.declare "occamel.max" Attribute.Context.label_declaration
    Ast_pattern.(single_expr_payload (eint __))
    Fun.id

let unsupported ~loc what =
  Location.raise_errorf ~loc
    "occamel: %s is not representable in the T2 schema dialect (design doc \
     \xC2\xA77.1). Restructure the type (records + plain variants of \
     string/int/float/bool/option/list/named types), or keep a hand-written \
     schema and target a T1 backend."
    what

let names_of td =
  match td.ptype_name.txt with
  | "t" -> ("schema", "of_json", "of_json_at", "to_json")
  | n -> (n ^ "_schema", n ^ "_of_json", n ^ "_of_json_at", n ^ "_to_json")

let derived_names_of_lident ~loc (lid : Longident.t) =
  let mk suffix =
    match lid with
    | Lident "t" -> Longident.Lident suffix
    | Lident n -> Longident.Lident (n ^ "_" ^ suffix)
    | Ldot (m, "t") -> Longident.Ldot (m, suffix)
    | Ldot (m, n) -> Longident.Ldot (m, n ^ "_" ^ suffix)
    | Lapply _ -> unsupported ~loc "a functor application type"
  in
  ( Ast.pexp_ident ~loc { txt = mk "schema"; loc },
    Ast.pexp_ident ~loc { txt = mk "of_json_at"; loc },
    Ast.pexp_ident ~loc { txt = mk "to_json"; loc } )

(* schema / decoder / encoder expressions for a core type.
   decoder : string -> Yojson.Safe.t -> (τ, Occamel.Codec.error) result
   encoder : τ -> Yojson.Safe.t *)
let rec conv ~loc (ct : core_type) : expression * expression * expression =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "string"; _ }, []) ->
      ( [%expr `Assoc [ ("type", `String "string") ]],
        [%expr Occamel.Codec.as_string],
        [%expr fun v -> `String v] )
  | Ptyp_constr ({ txt = Lident "int"; _ }, []) ->
      ( [%expr `Assoc [ ("type", `String "integer") ]],
        [%expr Occamel.Codec.as_int],
        [%expr fun v -> `Int v] )
  | Ptyp_constr ({ txt = Lident "float"; _ }, []) ->
      ( [%expr `Assoc [ ("type", `String "number") ]],
        [%expr Occamel.Codec.as_float],
        [%expr fun v -> `Float v] )
  | Ptyp_constr ({ txt = Lident "bool"; _ }, []) ->
      ( [%expr `Assoc [ ("type", `String "boolean") ]],
        [%expr Occamel.Codec.as_bool],
        [%expr fun v -> `Bool v] )
  | Ptyp_constr ({ txt = Lident "option"; _ }, [ inner ]) ->
      let s, d, e = conv ~loc inner in
      ( [%expr `Assoc [ ("anyOf", `List [ [%e s]; `Assoc [ ("type", `String "null") ] ]) ]],
        [%expr Occamel.Codec.as_option [%e d]],
        [%expr function None -> `Null | Some v -> [%e e] v] )
  | Ptyp_constr ({ txt = Lident "list"; _ }, [ inner ]) ->
      let s, d, e = conv ~loc inner in
      ( [%expr `Assoc [ ("type", `String "array"); ("items", [%e s]) ]],
        [%expr Occamel.Codec.list_of [%e d]],
        [%expr fun vs -> `List (List.map [%e e] vs)] )
  | Ptyp_constr ({ txt = lid; loc = lloc }, []) ->
      let s, d, e = derived_names_of_lident ~loc:lloc lid in
      (s, d, e)
  | Ptyp_constr (_, _ :: _) -> unsupported ~loc "a parameterized type"
  | Ptyp_tuple _ -> unsupported ~loc "a tuple"
  | Ptyp_arrow _ -> unsupported ~loc "a function type"
  | Ptyp_var _ -> unsupported ~loc "a type variable"
  | _ -> unsupported ~loc "this type form"

(* Layer [@min]/[@max] onto an int field's schema + decoder. *)
let apply_int_bounds ~loc (ld : label_declaration) (s, d, e) =
  let min = Attribute.get attr_min ld and max = Attribute.get attr_max ld in
  match (min, max) with
  | None, None -> (s, d, e)
  | _ ->
      (match ld.pld_type.ptyp_desc with
      | Ptyp_constr ({ txt = Lident "int"; _ }, []) -> ()
      | _ ->
          Location.raise_errorf ~loc:ld.pld_loc
            "occamel: [@min]/[@max] only apply to int fields");
      let opt_kv name = function
        | Some n ->
            [%expr [ ([%e Ast.estring ~loc name], `Int [%e Ast.eint ~loc n]) ]]
        | None -> [%expr []]
      in
      let s =
        [%expr
          Occamel.Schema.with_kvs [%e s]
            ([%e opt_kv "minimum" min] @ [%e opt_kv "maximum" max])]
      in
      let opt_arg = function
        | Some n -> [%expr Some [%e Ast.eint ~loc n]]
        | None -> [%expr None]
      in
      let d =
        [%expr
          fun path v ->
            Occamel.Codec.bounded_int ?min:[%e opt_arg min] ?max:[%e opt_arg max]
              path v]
      in
      (s, d, e)

(* Best-effort schema "default": only when the default expr is a literal. *)
let literal_default_json ~loc (e : expression) : expression option =
  match e.pexp_desc with
  | Pexp_constant (Pconst_string (s, _, _)) ->
      Some [%expr `String [%e Ast.estring ~loc s]]
  | Pexp_constant (Pconst_integer (i, None)) ->
      Some [%expr `Int [%e Ast.eint ~loc (int_of_string i)]]
  | Pexp_construct ({ txt = Lident (("true" | "false") as b); _ }, None) ->
      Some [%expr `Bool [%e Ast.ebool ~loc (bool_of_string b)]]
  | _ -> None

let field_schema ~loc (ld : label_declaration) =
  let s, _, _ = apply_int_bounds ~loc ld (conv ~loc ld.pld_type) in
  let extras =
    (match Attribute.get attr_doc ld with
    | Some doc -> [ [%expr ("description", `String [%e Ast.estring ~loc doc]) ] ]
    | None -> [])
    @
    match Attribute.get attr_default ld with
    | Some e -> (
        match literal_default_json ~loc e with
        | Some j -> [ [%expr ("default", [%e j]) ] ]
        | None -> [])
    | None -> []
  in
  match extras with
  | [] -> s
  | kvs -> [%expr Occamel.Schema.with_kvs [%e s] [%e Ast.elist ~loc kvs]]

(* Build: `Assoc [("type",`String "object"); ("properties", ...); ...] *)
let object_schema ~loc (props : (string * expression) list) =
  let prop_kvs =
    Ast.elist ~loc
      (List.map
         (fun (name, s) -> [%expr ([%e Ast.estring ~loc name], [%e s])])
         props)
  in
  let required =
    Ast.elist ~loc
      (List.map (fun (name, _) -> [%expr `String [%e Ast.estring ~loc name]]) props)
  in
  [%expr
    `Assoc
      [
        ("type", `String "object");
        ("properties", `Assoc [%e prop_kvs]);
        ("required", `List [%e required]);
        ("additionalProperties", `Bool false);
      ]]

(* Decoder body for a record-shaped field list: binds every field then Ok expr.
   [allowed_extra] lets variants admit the "kind" discriminant. *)
let record_decoder ~loc ?(allowed_extra = []) (lds : label_declaration list)
    (finish : expression) =
  let allowed =
    Ast.elist ~loc
      (List.map (fun s -> Ast.estring ~loc s) allowed_extra
      @ List.map (fun ld -> Ast.estring ~loc ld.pld_name.txt) lds)
  in
  let body =
    List.fold_right
      (fun ld acc ->
        let _, d, _ = apply_int_bounds ~loc ld (conv ~loc ld.pld_type) in
        let name = ld.pld_name.txt in
        let ename = Ast.estring ~loc name in
        let get =
          match Attribute.get attr_default ld with
          | Some default ->
              [%expr
                Result.bind (Occamel.Codec.field_opt path [%e ename] json)
                  (function
                  | None -> Ok [%e default]
                  | Some v -> [%e d] (path ^ "." ^ [%e ename]) v)]
          | None ->
              [%expr
                Result.bind (Occamel.Codec.field path [%e ename] json)
                  ([%e d] (path ^ "." ^ [%e ename]))]
        in
        [%expr
          Result.bind [%e get]
            [%e
              Ast.pexp_fun ~loc Nolabel None
                (Ast.pvar ~loc ("f_" ^ name))
                acc]])
      lds finish
  in
  [%expr
    fun path json ->
      Result.bind (Occamel.Codec.no_extra_fields path [%e allowed] json)
        (fun () -> [%e body])]

let record_finish ~loc (lds : label_declaration list) build =
  build
    (List.map
       (fun ld ->
         ( { txt = Longident.Lident ld.pld_name.txt; loc },
           Ast.evar ~loc ("f_" ^ ld.pld_name.txt) ))
       lds)

let record_encoder_kvs ~loc ?(extra = []) (lds : label_declaration list)
    (project : label_declaration -> expression) =
  Ast.elist ~loc
    (extra
    @ List.map
        (fun ld ->
          let _, _, e = conv ~loc ld.pld_type in
          [%expr
            ([%e Ast.estring ~loc ld.pld_name.txt], [%e e] [%e project ld])])
        lds)

(* ---------- complexity heuristic (mirrors Occamel.Schema.complexity) ---------- *)

let rec ct_score depth (ct : core_type) =
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "option"; _ }, [ inner ]) ->
      3 + ct_score (depth + 1) inner
  | Ptyp_constr ({ txt = Lident "list"; _ }, [ inner ]) ->
      1 + ct_score (depth + 1) inner
  | _ -> if depth > 4 then 2 else 0

let td_score (td : type_declaration) =
  match td.ptype_kind with
  | Ptype_record lds -> 1 + List.fold_left (fun a ld -> a + ct_score 1 ld.pld_type) 0 lds
  | Ptype_variant cds ->
      max 0 (List.length cds - 1)
      + List.fold_left
          (fun a cd ->
            a
            +
            match cd.pcd_args with
            | Pcstr_record lds ->
                1 + List.fold_left (fun a ld -> a + ct_score 2 ld.pld_type) 0 lds
            | Pcstr_tuple cts -> List.fold_left (fun a c -> a + ct_score 2 c) 0 cts)
          0 cds
  | _ -> 0

(* ---------- recursion check ---------- *)

let check_not_recursive ~loc rec_flag tds =
  match really_recursive rec_flag tds with
  | Nonrecursive -> ()
  | Recursive ->
      Location.raise_errorf ~loc
        "occamel: recursive types are not representable in the T2 schema \
         dialect (design doc \xC2\xA77.1). Hand-write a depth-unrolled schema \
         (see Plan), or wait for the T1/GBNF backend."

(* ---------- per-type generation ---------- *)

let gen_record ~loc td lds =
  let schema =
    object_schema ~loc
      (List.map (fun ld -> (ld.pld_name.txt, field_schema ~loc ld)) lds)
  in
  let finish =
    [%expr Ok [%e record_finish ~loc lds (fun fs -> Ast.pexp_record ~loc fs None)]]
  in
  let decoder = record_decoder ~loc lds finish in
  let kvs =
    record_encoder_kvs ~loc lds (fun ld ->
        Ast.pexp_field ~loc [%expr v]
          { txt = Longident.Lident ld.pld_name.txt; loc })
  in
  let encoder = [%expr fun v -> `Assoc [%e kvs]] in
  ignore td;
  (schema, decoder, encoder)

let kind_of_constructor (cd : constructor_declaration) =
  String.lowercase_ascii cd.pcd_name.txt

let gen_variant ~loc td (cds : constructor_declaration list) =
  let all_nullary =
    List.for_all (fun cd -> cd.pcd_args = Pcstr_tuple []) cds
  in
  let kinds = List.map kind_of_constructor cds in
  let () =
    let sorted = List.sort_uniq String.compare kinds in
    if List.length sorted <> List.length kinds then
      Location.raise_errorf ~loc
        "occamel: two constructors of %s lowercase to the same tag"
        td.ptype_name.txt
  in
  if all_nullary then (
    let enum =
      Ast.elist ~loc (List.map (fun k -> [%expr `String [%e Ast.estring ~loc k]]) kinds)
    in
    let schema = [%expr `Assoc [ ("type", `String "string"); ("enum", `List [%e enum]) ]] in
    let decode_arms =
      List.map
        (fun cd ->
          Ast.case
            ~lhs:(Ast.ppat_constant ~loc (Pconst_string (kind_of_constructor cd, loc, None)))
            ~guard:None
            ~rhs:
              [%expr
                Ok
                  [%e
                    Ast.pexp_construct ~loc
                      { txt = Longident.Lident cd.pcd_name.txt; loc }
                      None]])
        cds
      @ [
          Ast.case ~lhs:(Ast.pvar ~loc "other") ~guard:None
            ~rhs:
              [%expr
                Occamel.Codec.err path (Printf.sprintf "unknown value %S" other)];
        ]
    in
    let decoder =
      [%expr
        fun path json ->
          Result.bind (Occamel.Codec.as_string path json)
            [%e Ast.pexp_function_cases ~loc decode_arms]]
    in
    let encode_arms =
      List.map
        (fun cd ->
          Ast.case
            ~lhs:
              (Ast.ppat_construct ~loc
                 { txt = Longident.Lident cd.pcd_name.txt; loc }
                 None)
            ~guard:None
            ~rhs:[%expr `String [%e Ast.estring ~loc (kind_of_constructor cd)]])
        cds
    in
    let encoder = Ast.pexp_function_cases ~loc encode_arms in
    (schema, decoder, encoder))
  else
    (* tagged union on "kind" *)
    let arm_schema cd =
      let kind_prop =
        ( "kind",
          [%expr
            `Assoc
              [
                ("type", `String "string");
                ("enum", `List [ `String [%e Ast.estring ~loc (kind_of_constructor cd)] ]);
              ]] )
      in
      match cd.pcd_args with
      | Pcstr_tuple [] -> object_schema ~loc [ kind_prop ]
      | Pcstr_record lds ->
          object_schema ~loc
            (kind_prop
            :: List.map (fun ld -> (ld.pld_name.txt, field_schema ~loc ld)) lds)
      | Pcstr_tuple [ ct ] ->
          let s, _, _ = conv ~loc ct in
          object_schema ~loc [ kind_prop; ("value", s) ]
      | Pcstr_tuple _ ->
          Location.raise_errorf ~loc:cd.pcd_loc
            "occamel: multi-argument constructor %s — use an inline record"
            cd.pcd_name.txt
    in
    let schema =
      [%expr
        `Assoc [ ("anyOf", `List [%e Ast.elist ~loc (List.map arm_schema cds)]) ]]
    in
    let decode_arm cd =
      let cname = { txt = Longident.Lident cd.pcd_name.txt; loc } in
      let rhs =
        match cd.pcd_args with
        | Pcstr_tuple [] ->
            [%expr
              Result.bind
                (Occamel.Codec.no_extra_fields path [ "kind" ] json)
                (fun () -> Ok [%e Ast.pexp_construct ~loc cname None])]
        | Pcstr_record lds ->
            let finish =
              [%expr
                Ok
                  [%e
                    Ast.pexp_construct ~loc cname
                      (Some
                         (record_finish ~loc lds (fun fs ->
                              Ast.pexp_record ~loc fs None)))]]
            in
            [%expr [%e record_decoder ~loc ~allowed_extra:[ "kind" ] lds finish] path json]
        | Pcstr_tuple [ ct ] ->
            let _, d, _ = conv ~loc ct in
            [%expr
              Result.bind
                (Occamel.Codec.no_extra_fields path [ "kind"; "value" ] json)
                (fun () ->
                  Result.bind (Occamel.Codec.field path "value" json)
                    (fun v ->
                      Result.bind ([%e d] (path ^ ".value") v) (fun v ->
                          Ok [%e Ast.pexp_construct ~loc cname (Some [%expr v])])))]
        | Pcstr_tuple _ -> assert false (* rejected in arm_schema *)
      in
      Ast.case
        ~lhs:(Ast.ppat_constant ~loc (Pconst_string (kind_of_constructor cd, loc, None)))
        ~guard:None ~rhs
    in
    let decoder =
      [%expr
        fun path json ->
          Result.bind (Occamel.Codec.field path "kind" json) (fun k ->
              Result.bind (Occamel.Codec.as_string (path ^ ".kind") k)
                [%e
                  Ast.pexp_function_cases ~loc
                    (List.map decode_arm cds
                    @ [
                        Ast.case ~lhs:(Ast.pvar ~loc "other") ~guard:None
                          ~rhs:
                            [%expr
                              Occamel.Codec.err (path ^ ".kind")
                                (Printf.sprintf "unknown kind %S" other)];
                      ])])]
    in
    let encode_arm cd =
      let cname = { txt = Longident.Lident cd.pcd_name.txt; loc } in
      let ekind =
        [%expr ("kind", `String [%e Ast.estring ~loc (kind_of_constructor cd)])]
      in
      match cd.pcd_args with
      | Pcstr_tuple [] ->
          Ast.case
            ~lhs:(Ast.ppat_construct ~loc cname None)
            ~guard:None
            ~rhs:[%expr `Assoc [ [%e ekind] ]]
      | Pcstr_record lds ->
          let pat =
            Ast.ppat_construct ~loc cname
              (Some
                 (Ast.ppat_record ~loc
                    (List.map
                       (fun ld ->
                         ( { txt = Longident.Lident ld.pld_name.txt; loc },
                           Ast.pvar ~loc ("f_" ^ ld.pld_name.txt) ))
                       lds)
                    Closed))
          in
          let kvs =
            record_encoder_kvs ~loc ~extra:[ ekind ] lds (fun ld ->
                Ast.evar ~loc ("f_" ^ ld.pld_name.txt))
          in
          Ast.case ~lhs:pat ~guard:None ~rhs:[%expr `Assoc [%e kvs]]
      | Pcstr_tuple [ ct ] ->
          let _, _, e = conv ~loc ct in
          Ast.case
            ~lhs:(Ast.ppat_construct ~loc cname (Some (Ast.pvar ~loc "v")))
            ~guard:None
            ~rhs:[%expr `Assoc [ [%e ekind]; ("value", [%e e] v) ]]
      | Pcstr_tuple _ -> assert false
    in
    let encoder = Ast.pexp_function_cases ~loc (List.map encode_arm cds) in
    (schema, decoder, encoder)

let gen_td ~loc ~parse (td : type_declaration) : structure =
  (match td.ptype_params with
  | [] -> ()
  | _ -> unsupported ~loc "a parameterized type");
  let schema_n, of_json_n, of_json_at_n, to_json_n = names_of td in
  let schema, decoder, encoder =
    match td.ptype_kind with
    | Ptype_record lds -> gen_record ~loc td lds
    | Ptype_variant cds -> gen_variant ~loc td cds
    | Ptype_abstract -> (
        match td.ptype_manifest with
        | Some ct -> conv ~loc ct
        | None -> unsupported ~loc "an abstract type")
    | Ptype_open -> unsupported ~loc "an open type"
  in
  let refined_decoder =
    match parse with
    | None -> decoder
    | Some f ->
        [%expr
          fun path json ->
            Result.bind ([%e decoder] path json) (Occamel.Codec.refine [%e f] path)]
  in
  let warn =
    let score = td_score td in
    if score > 24 then
      [
        Ast.pstr_attribute ~loc
          {
            attr_name = { txt = "ocaml.ppwarning"; loc };
            attr_payload =
              PStr
                [
                  Ast.pstr_eval ~loc
                    (Ast.estring ~loc
                       (Printf.sprintf
                          "occamel: type %s has estimated grammar complexity \
                           %d (> 24); it may exceed provider strict-schema \
                           limits. Prefer required-with-default over option \
                           fields, or use a T1 backend. (design doc \
                           \xC2\xA77.1)"
                          td.ptype_name.txt score))
                    [];
                ];
            attr_loc = loc;
          };
      ]
    else []
  in
  warn
  @ [
      [%stri let [%p Ast.pvar ~loc schema_n] : Yojson.Safe.t = [%e schema]];
      [%stri
        let [%p Ast.pvar ~loc of_json_at_n] = [%e refined_decoder]];
      [%stri
        let [%p Ast.pvar ~loc of_json_n] =
         fun json -> [%e Ast.evar ~loc of_json_at_n] "$" json];
      [%stri let [%p Ast.pvar ~loc to_json_n] = [%e encoder]];
    ]

let str_gen ~ctxt (rec_flag, tds) parse =
  let loc = Expansion_context.Deriver.derived_item_loc ctxt in
  check_not_recursive ~loc rec_flag tds;
  List.concat_map (gen_td ~loc ~parse) tds

let deriver =
  Deriving.add "occamel"
    ~str_type_decl:
      (Deriving.Generator.V2.make
         Deriving.Args.(empty +> arg "parse" __)
         str_gen)
