open Test_util

module Codec = Storage_codec
module Ds = Datascript
module Pset = Persistent_sorted_set
module Transit = Transit_native.Transit.Json
module Value = Transit_core.Json

let datom ?(added = false) value : Ds.datom =
  { e = 7; a = "block/title"; v = value; tx = 42; added }

let roundtrip payload =
  let content, addresses = Codec.encode None payload in
  check_eq payload (Codec.decode addresses content)

let metadata_field key node =
  match node with
  | Value.Map entries ->
    List.find_map
      (fun (entry_key, value) ->
        if entry_key = Value.Keyword key then Some value else None)
      entries
  | _ -> None

let compact_map_key_cache_is_not_shifted () =
  match
    Codec.decode None
      "{\"~:keys\":[[1,\"~:block/title\",\"One\",1],[2,\"^1\",\"Two\",1]]}"
  with
  | Ds.Storage_node (Pset.Leaf datoms) ->
    check_eq
      (List.map (fun (d : Ds.datom) -> d.a) datoms)
      [ "block/title"; "block/title" ]
  | _ -> fail "unexpected storage node"

let all_value_types_and_storage_nodes_roundtrip () =
  let values =
    [
      Ds.Nil;
      Ds.Bool false;
      Ds.String "text";
      Ds.Int 12;
      Ds.Float 1.5;
      Ds.Keyword "block/page";
      Ds.Uuid "00000000-0000-0000-0000-000000000007";
      Ds.Instant 123;
      Ds.Regex "a+";
      Ds.Symbol "x";
      Ds.Vector [ Ds.Int 1; Ds.Nil ];
      Ds.List [ Ds.String "item" ];
      Ds.Map [ (Ds.Keyword "x", Ds.Set [ Ds.Int 2 ]) ];
    ]
  in
  let datoms = List.map datom values in
  roundtrip (Ds.Storage_node (Pset.Leaf datoms));
  roundtrip (Ds.Storage_node (Pset.Branch (datoms, [ "3"; "4" ])));
  roundtrip
    (Ds.Storage_tail [ datoms; []; [ datom ~added:true (Ds.String "added") ] ])

let root () : Ds.storage_root =
  let schema : Ds.schema_attr =
    {
      Ds.cardinality = Ds.Many;
      unique = Some Ds.Identity;
      indexed = true;
      is_component = true;
      no_history = true;
      doc = Some "description";
      value_type = Some Ds.TupleType;
      tuple_attrs = Some [ "block/page"; "block/title" ];
      tuple_types =
        Some
          [
            Ds.RefType;
            Ds.StringType;
            Ds.KeywordType;
            Ds.NumberType;
            Ds.UuidType;
            Ds.InstantType;
            Ds.TupleType;
          ];
    }
  in
  {
    Ds.storage_schema = [ ("user/tuple", schema) ];
    storage_max_eid = 7;
    storage_max_tx = 42;
    storage_eavt = "3";
    storage_aevt = "4";
    storage_avet = "5";
    storage_duplicate_datoms = [ datom (Ds.String "duplicate") ];
    storage_max_addr = 6;
    storage_branching_factor = 32;
    storage_ref_type = Pset.Weak;
  }

let roots_and_index_metadata_roundtrip () =
  let root = root () in
  let index : Codec.storage_index_metadata = { count = 4; shift = 1 } in
  let metadata : Codec.storage_root_index_metadata =
    { eavt = index; aevt = index; avet = index }
  in
  let content, addresses =
    Codec.encode (Some metadata) (Ds.Storage_root root)
  in
  roundtrip (Ds.Storage_root root);
  roundtrip
    (Ds.Storage_root { root with Ds.storage_ref_type = Pset.Strong });
  check_eq addresses None;
  check_eq (Ds.Storage_root root) (Codec.decode None content);
  let decoded = Transit.of_string content in
  List.iter
    (fun key ->
      match metadata_field key decoded with
      | Some node ->
        check_eq (Some (Value.Int 4)) (metadata_field "count" node);
        check_eq (Some (Value.Int 1)) (metadata_field "shift" node)
      | None -> fail "missing index metadata")
    [ "eavt-metadata"; "aevt-metadata"; "avet-metadata" ]

let tuple_reference_normalization () =
  let content, _addresses =
    Codec.encode None
      (Ds.Storage_node
         (Pset.Leaf
            [
              datom ~added:true
                (Ds.Tuple [ Some (Ds.Ref 9); None ]);
            ]))
  in
  check_eq
    (Ds.Storage_node
       (Pset.Leaf
          [
            datom ~added:true
              (Ds.Vector [ Ds.Int 9; Ds.Nil ]);
          ]))
    (Codec.decode None content)

let raises_invalid_arg f =
  match f () with
  | exception Invalid_argument _ -> ()
  | _ -> fail "expected Invalid_argument"

let invalid_storage_is_rejected () =
  raises_invalid_arg (fun () ->
    Codec.encode None
      (Ds.Storage_node
         (Pset.Leaf
            [ datom ~added:true (Ds.Ref_to (Ds.Entity_id 1)) ]))
    |> ignore);
  raises_invalid_arg (fun () ->
    Codec.encode None
      (Ds.Storage_node (Pset.Branch ([], [ "invalid" ])))
    |> ignore);
  raises_invalid_arg (fun () ->
    Codec.decode (Some "{}") "{\"~:keys\":[]}" |> ignore);
  List.iter
    (fun raw ->
      raises_invalid_arg (fun () -> Codec.decode None raw |> ignore))
    [ "{\"~:keys\":[[1,\"block/title\",\"x\",1]]}"; "{\"~:schema\":{}}"; "null" ]

let cases =
  [
    case "compact map key cache is not shifted"
      compact_map_key_cache_is_not_shifted;
    case "all value types and storage nodes roundtrip"
      all_value_types_and_storage_nodes_roundtrip;
    case "roots and index metadata roundtrip"
      roots_and_index_metadata_roundtrip;
    case "tuple reference normalization" tuple_reference_normalization;
    case "invalid storage is rejected" invalid_storage_is_rejected;
  ]
