open Test_util

module Ds = Datascript
module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json
module Sync = Sync_tx
module Codec_schema = Storage_codec

let expect_ok result =
  match result with
  | Ok value -> value
  | Error message -> failwith message

let schema =
  let one = { Codec_schema.default_schema_attr with Ds.indexed = true } in
  [
    ( "block/uuid"
    , {
        one with
        Ds.unique = Some Ds.Identity;
        value_type = Some Ds.UuidType;
      } );
    ("block/title", { one with Ds.value_type = Some Ds.StringType });
    ("block/parent", { one with Ds.value_type = Some Ds.RefType });
    ( "db/ident"
    , {
        one with
        Ds.unique = Some Ds.Identity;
        value_type = Some Ds.KeywordType;
      } );
    ( "block/tags"
    , {
        one with
        Ds.cardinality = Ds.Many;
        value_type = Some Ds.StringType;
      } );
  ]

let reference_db () =
  Ds.db_with
    [
      Ds.Add (Ds.Entity_id 1, "block/uuid", Ds.Uuid "stable-uuid");
      Ds.Add (Ds.Entity_id 2, "db/ident", Ds.Keyword "stable.ident");
      Ds.Add (Ds.Entity_id 3, "block/title", Ds.String "Opaque");
      Ds.Add (Ds.Entity_id 3, "block/tags", Ds.String "one");
      Ds.Add (Ds.Entity_id 3, "block/tags", Ds.String "two");
    ]
    (Ds.empty_db ~schema ())

let array values = Value.Array values

let stable_ref =
  array [ Value.Keyword "block/uuid"; Value.Uuid "stable-uuid" ]

let entity id attrs : Ds.tx_entity = { Ds.db_id = id; attrs }

let child title =
  entity None [ ("block/title", Ds.One_value (Ds.String title)) ]

let encode db tx = Sync.encode (fun v -> Ok v) db tx

let transaction_wire_preserves_local_ids_and_stable_parent_references () =
  let db = reference_db () in
  let wire =
    expect_ok
      (encode db
         [
           Ds.Add
             ( Ds.Lookup_ref ("block/uuid", Ds.Uuid "stable-uuid")
             , "block/title"
             , Ds.String "before" );
           Ds.Entity
             (entity (Some (Ds.Temp_id "pending/new"))
                [
                  ("block/uuid", Ds.One_value (Ds.Uuid "new"));
                  ("block/title", Ds.One_value (Ds.String "after"));
                  ( "block/parent"
                  , Ds.One_value
                      (Ds.Ref_to
                         (Ds.Lookup_ref
                            ("block/uuid", Ds.Uuid "stable-uuid"))) );
                ]);
         ])
  in
  check_eq
    (array
       [
         array
           [
             Value.Keyword "db/add";
             stable_ref;
             Value.Keyword "block/title";
             Value.String "before";
           ];
         Value.Map
           [
             (Value.Keyword "db/id", Value.String "pending/new");
             (Value.Keyword "block/uuid", Value.Uuid "new");
             (Value.Keyword "block/title", Value.String "after");
             (Value.Keyword "block/parent", stable_ref);
           ];
       ])
    (Codec.of_string wire)

let entity_reference_identity_and_fallbacks () =
  let db = reference_db () in
  List.iter
    (fun (reference, expected) ->
      check_eq expected (Sync.transit_of_entity_ref db reference))
    [
      (Ds.Entity_id 1, stable_ref);
      ( Ds.Entity_id 2
      , array [ Value.Keyword "db/ident"; Value.Keyword "stable.ident" ] );
      (Ds.Entity_id 3, Value.Int 3);
      (Ds.Entity_id 404, Value.Int 404);
      (Ds.Temp_id "temp", Value.String "temp");
      (Ds.CurrentTx, Value.Keyword "db/current-tx");
      (Ds.Ident "fn", Value.Keyword "fn");
      ( Ds.Lookup_ref ("block/title", Ds.String "Title")
      , array [ Value.Keyword "block/title"; Value.String "Title" ] );
    ];
  let opaque =
    match Ds.entity db (Ds.Entity_id 3) with
    | Some entity -> entity
    | None -> failwith "missing opaque entity"
  in
  check_eq None (Sync.lookup_value opaque "block/tags")

let every_datascript_value_has_a_sync_encoding () =
  let db = reference_db () in
  List.iter
    (fun (value, expected) ->
      check_eq expected (Sync.transit_of_value db value))
    [
      (Ds.Nil, Value.Null);
      (Ds.Int64 7L, Value.Int64 7L);
      (Ds.Float 1.5, Value.Float 1.5);
      (Ds.String "text", Value.String "text");
      (Ds.Symbol "symbol", Value.Symbol "symbol");
      (Ds.Bool true, Value.Bool true);
      (Ds.Keyword "keyword", Value.Keyword "keyword");
      (Ds.Uuid "uuid", Value.Uuid "uuid");
      (Ds.Instant 123L, Value.Date 123L);
      (Ds.Regex "a+", Value.Tagged ("regex", Value.String "a+"));
      (Ds.Ref 1, stable_ref);
      (Ds.List [ Ds.Int64 1L ], Value.List [ Value.Int64 1L ]);
      (Ds.Vector [ Ds.String "v" ], array [ Value.String "v" ]);
      ( Ds.Map [ (Ds.Keyword "k", Ds.Bool false) ]
      , Value.Map [ (Value.Keyword "k", Value.Bool false) ] );
      (Ds.Set [ Ds.Uuid "u" ], Value.Set [ Value.Uuid "u" ]);
      (Ds.Tuple [ Some (Ds.Int64 1L); None ], array [ Value.Int64 1L; Value.Null ]);
      (Ds.TxRef, Value.Keyword "db/current-tx");
      (Ds.Ref_to (Ds.Temp_id "ref"), Value.String "ref");
    ]

let nested_entity_cardinalities_are_preserved () =
  let nested = child "Child" in
  let wire =
    Value.Map [ (Value.Keyword "block/title", Value.String "Child") ]
  in
  let value =
    entity (Some (Ds.Temp_id "entity"))
      [
        ("one", Ds.One_value (Ds.Int64 1L));
        ("many", Ds.Many_values [ Ds.Int64 2L; Ds.Int64 3L ]);
        ("child", Ds.One_entity nested);
        ("children", Ds.Many_entities [ nested ]);
      ]
  in
  check_eq
    (Value.Map
       [
         (Value.Keyword "db/id", Value.String "entity");
         (Value.Keyword "one", Value.Int64 1L);
         (Value.Keyword "many", array [ Value.Int64 2L; Value.Int64 3L ]);
         (Value.Keyword "child", wire);
         (Value.Keyword "children", array [ wire ]);
       ])
    (Sync.transit_of_entity (reference_db ()) value)

let raw added value =
  Ds.Raw_datom
    {
      Ds.e = 1;
      a = "block/title";
      v = Ds.String value;
      tx = 1;
      added;
    }

let transaction_operations_preserve_all_operands () =
  let db = reference_db () in
  let reference = Ds.Lookup_ref ("block/uuid", Ds.Uuid "stable-uuid") in
  let attr = Value.Keyword "block/title" in
  let retract =
    array [ Value.Keyword "db.fn/retractAttribute"; stable_ref; attr ]
  in
  List.iter
    (fun (op, expected) ->
      check_eq (Ok expected) (Sync.transit_of_tx_op db op))
    [
      ( Ds.Retract (reference, "block/title", Some (Ds.String "Old"))
      , array
          [
            Value.Keyword "db/retract";
            stable_ref;
            attr;
            Value.String "Old";
          ] );
      (Ds.Retract (reference, "block/title", None), retract);
      (Ds.RetractAttr (reference, "block/title"), retract);
      ( Ds.RetractEntity reference
      , array [ Value.Keyword "db/retractEntity"; stable_ref ] );
      ( Ds.CompareAndSet
          (reference, "block/title", Some (Ds.String "Old"), Ds.String "New")
      , array
          [
            Value.Keyword "db.fn/cas";
            stable_ref;
            attr;
            Value.String "Old";
            Value.String "New";
          ] );
      ( Ds.CompareAndSet (reference, "block/title", None, Ds.String "New")
      , array
          [
            Value.Keyword "db.fn/cas";
            stable_ref;
            attr;
            Value.Null;
            Value.String "New";
          ] );
      ( Ds.Entity (child "Entity")
      , Value.Map [ (attr, Value.String "Entity") ] );
      ( raw true "Raw"
      , array
          [
            Value.Keyword "db/add";
            stable_ref;
            attr;
            Value.String "Raw";
          ] );
      ( raw false "Raw"
      , array
          [
            Value.Keyword "db/retract";
            stable_ref;
            attr;
            Value.String "Raw";
          ] );
      ( Ds.CallIdent (Ds.Ident "function", [ Ds.Int64 1L; Ds.String "x" ])
      , array
          [ Value.Keyword "function"; Value.Int64 1L; Value.String "x" ] );
    ];
  check_eq (array []) (Codec.of_string (expect_ok (encode db [])));
  List.iter
    (fun op ->
      check_eq (Error "transaction functions cannot be sent over sync")
        (Sync.transit_of_tx_op db op);
      check_eq (Error "transaction functions cannot be sent over sync")
        (encode db [ op ]))
    [
      Ds.InstallTxFn
        ( Ds.Ident "install"
        , fun _ _ -> failwith "sync must not execute transaction functions" );
      Ds.Call (fun _ -> failwith "sync must not execute transaction functions");
    ]

let encrypted_entity prefix =
  Ds.Entity
    (entity (Some (Ds.Temp_id "entity"))
       [
         ( "block/title"
         , Ds.One_value (Ds.String (prefix ^ "Root")) );
         ( "block/name"
         , Ds.Many_values
             [ Ds.String (prefix ^ "one"); Ds.String (prefix ^ "two") ] );
         ("child", Ds.One_entity (child (prefix ^ "Child")));
         ( "children"
         , Ds.Many_entities
             [ child (prefix ^ "A"); child (prefix ^ "B") ] );
       ])

let encryption_covers_protected_operands_and_nested_entities () =
  let reference = Ds.Temp_id "entity" in
  let encrypt value = Ok ("cipher:" ^ value) in
  List.iter
    (fun (op, expected) ->
      check_eq (Ok expected) (Sync.encrypt_tx_op encrypt op))
    [
      ( Ds.Add (reference, "block/title", Ds.String "Title")
      , Ds.Add (reference, "block/title", Ds.String "cipher:Title") );
      ( Ds.Add (reference, "block/name", Ds.String "name")
      , Ds.Add (reference, "block/name", Ds.String "cipher:name") );
      ( Ds.Add (reference, "block/order", Ds.String "a0")
      , Ds.Add (reference, "block/order", Ds.String "a0") );
      ( Ds.Retract (reference, "block/title", Some (Ds.String "Old"))
      , Ds.Retract
          (reference, "block/title", Some (Ds.String "cipher:Old")) );
      ( Ds.Retract (reference, "block/title", None)
      , Ds.Retract (reference, "block/title", None) );
      ( Ds.CompareAndSet
          (reference, "block/title", Some (Ds.String "Old"), Ds.String "New")
      , Ds.CompareAndSet
          ( reference
          , "block/title"
          , Some (Ds.String "cipher:Old")
          , Ds.String "cipher:New" ) );
      ( Ds.CompareAndSet (reference, "block/title", None, Ds.String "New")
      , Ds.CompareAndSet
          (reference, "block/title", None, Ds.String "cipher:New") );
      (encrypted_entity "", encrypted_entity "cipher:");
      (raw true "Raw", raw true "cipher:Raw");
    ];
  List.iter
    (fun op -> check_ok (Sync.encrypt_tx_op encrypt op))
    [
      Ds.Retract (reference, "block/title", None);
      Ds.RetractAttr (reference, "block/title");
      Ds.RetractEntity reference;
      Ds.CallIdent
        (Ds.Ident "function", [ Ds.String "plaintext argument" ]);
      Ds.InstallTxFn
        ( Ds.Ident "install"
        , fun _ _ ->
            failwith "encryption must not execute transaction functions" );
      Ds.Call
        (fun _ ->
          failwith "encryption must not execute transaction functions");
    ];
  check_error
    (Sync.encrypt_tx_op encrypt
       (Ds.Add (reference, "block/title", Ds.Int64 1L)))

let cases =
  [
    case "transaction wire preserves local ids and stable parent references"
      transaction_wire_preserves_local_ids_and_stable_parent_references;
    case "entity reference identity and fallbacks"
      entity_reference_identity_and_fallbacks;
    case "every datascript value has a sync encoding"
      every_datascript_value_has_a_sync_encoding;
    case "nested entity cardinalities are preserved"
      nested_entity_cardinalities_are_preserved;
    case "transaction operations preserve all operands"
      transaction_operations_preserve_all_operands;
    case "encryption covers protected operands and nested entities"
      encryption_covers_protected_operands_and_nested_entities;
  ]
