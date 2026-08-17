open Datascript

module Transit = Transit_native.Transit.Json

let fail label = failwith label

let one ?unique ?value_type () =
  { cardinality = One
  ; unique
  ; indexed = true
  ; is_component = false
  ; no_history = false
  ; doc = None
  ; value_type
  ; tuple_attrs = None
  ; tuple_types = None
  }
;;

let schema =
  [ "block/uuid", one ~unique:Identity ~value_type:UuidType ()
  ; "block/title", one ~value_type:StringType ()
  ; "block/parent", one ~value_type:RefType ()
  ]
;;

let () =
  let conn = create_conn ~schema () in
  ignore
    (transact_conn
       conn
       [ Entity
           { db_id = Some (Temp_id "source")
           ; attrs =
               [ "block/uuid", One_value (Uuid "source")
               ; "block/title", One_value (String "hello")
               ]
           }
       ]);
  let db = conn_db conn in
  let tx =
    [ Add (Lookup_ref ("block/uuid", Uuid "source"), "block/title", String "before")
    ; Entity
        { db_id = Some (Temp_id "pending/new")
        ; attrs =
            [ "block/uuid", One_value (Uuid "new")
            ; "block/title", One_value (String "after")
            ; ( "block/parent"
              , One_value (Ref_to (Lookup_ref ("block/uuid", Uuid "source"))) )
            ]
        }
    ]
  in
  let wire =
    match Logseq_chat_sync_tx.encode db tx with
    | Ok wire -> wire
    | Error message -> fail message
  in
  match Transit.of_string wire with
  | Transit.Array
      [ Transit.Array
          [ Transit.Keyword "db/add"
          ; Transit.Array [ Transit.Keyword "block/uuid"; Transit.Uuid "source" ]
          ; Transit.Keyword "block/title"
          ; Transit.String "before"
          ]
      ; Transit.Map inserted
      ] ->
    (match List.assoc_opt (Transit.Keyword "db/id") inserted with
     | Some (Transit.String "pending/new") -> ()
     | _ -> fail "insert must retain its transaction-local temp id");
    (match List.assoc_opt (Transit.Keyword "block/parent") inserted with
     | Some (Transit.Array [ Transit.Keyword "block/uuid"; Transit.Uuid "source" ]) -> ()
     | _ -> fail "insert references must use a stable lookup ref")
  | _ -> fail "outliner transaction must encode as one Transit transaction vector"
;;

let () =
  let db =
    empty_db ~schema ()
    |> db_with [ Add (Entity_id 99, "block/title", String "Opaque") ]
  in
  if Logseq_chat_sync_tx.transit_of_entity_ref db (Entity_id 99) <> Transit.Int 99
  then fail "numeric entity refs without a stable identity must remain numeric"
;;

let many ?value_type () =
  { (one ?value_type ()) with cardinality = Many }
;;

let reference_db () =
  let schema =
    schema
    @ [ "db/ident", one ~unique:Identity ~value_type:KeywordType ()
      ; "block/tags", many ~value_type:StringType ()
      ]
  in
  empty_db ~schema ()
  |> db_with
       [ Add (Entity_id 1, "block/uuid", Uuid "stable-uuid")
       ; Add (Entity_id 2, "db/ident", Keyword "stable.ident")
       ; Add (Entity_id 3, "block/title", String "Opaque")
       ; Add (Entity_id 3, "block/tags", String "one")
       ; Add (Entity_id 3, "block/tags", String "two")
       ]
;;

let assert_transit label expected actual =
  if expected <> actual then fail label
;;

let encoded_op db operation =
  match Logseq_chat_sync_tx.transit_of_tx_op db operation with
  | Ok value -> value
  | Error message -> fail message
;;

let () =
  let db = reference_db () in
  let module Sync = Logseq_chat_sync_tx in
  assert_transit
    "entity id prefers a UUID lookup ref"
    (Transit.Array [ Transit.Keyword "block/uuid"; Transit.Uuid "stable-uuid" ])
    (Sync.transit_of_entity_ref db (Entity_id 1));
  assert_transit
    "entity id falls back to an ident lookup ref"
    (Transit.Array [ Transit.Keyword "db/ident"; Transit.Keyword "stable.ident" ])
    (Sync.transit_of_entity_ref db (Entity_id 2));
  assert_transit "opaque entity stays numeric" (Transit.Int 3)
    (Sync.transit_of_entity_ref db (Entity_id 3));
  assert_transit "missing entity stays numeric" (Transit.Int 404)
    (Sync.transit_of_entity_ref db (Entity_id 404));
  assert_transit "temp id stays textual" (Transit.String "temp")
    (Sync.transit_of_entity_ref db (Temp_id "temp"));
  assert_transit "current tx entity ref stays symbolic" (Transit.Keyword "db/current-tx")
    (Sync.transit_of_entity_ref db CurrentTx);
  assert_transit "ident stays a keyword" (Transit.Keyword "fn")
    (Sync.transit_of_entity_ref db (Ident "fn"));
  assert_transit
    "lookup ref recursively encodes its value"
    (Transit.Array [ Transit.Keyword "block/title"; Transit.String "Title" ])
    (Sync.transit_of_entity_ref db (Lookup_ref ("block/title", String "Title")));
  let opaque =
    match entity db (Entity_id 3) with Some entity -> entity | None -> fail "opaque entity missing"
  in
  if Sync.lookup_value opaque "block/tags" <> None
  then fail "multi-valued attrs are not scalar lookup values"
;;

let () =
  let db = reference_db () in
  let module Sync = Logseq_chat_sync_tx in
  let cases =
    [ Nil, Transit.Null
    ; Int 7, Transit.Int 7
    ; Float 1.5, Transit.Float 1.5
    ; String "text", Transit.String "text"
    ; Symbol "symbol", Transit.Symbol "symbol"
    ; Bool true, Transit.Bool true
    ; Keyword "keyword", Transit.Keyword "keyword"
    ; Uuid "uuid", Transit.Uuid "uuid"
    ; Instant 123, Transit.Date 123L
    ; Regex "a+", Transit.Tagged ("regex", Transit.String "a+")
    ; ( Ref 1
      , Transit.Array [ Transit.Keyword "block/uuid"; Transit.Uuid "stable-uuid" ] )
    ; List [ Int 1 ], Transit.List [ Transit.Int 1 ]
    ; Vector [ String "v" ], Transit.Array [ Transit.String "v" ]
    ; ( Map [ Keyword "k", Bool false ]
      , Transit.Map [ Transit.Keyword "k", Transit.Bool false ] )
    ; Set [ Uuid "u" ], Transit.Set [ Transit.Uuid "u" ]
    ; Tuple [ Some (Int 1); None ], Transit.Array [ Transit.Int 1; Transit.Null ]
    ; TxRef, Transit.Keyword "db/current-tx"
    ; Ref_to (Temp_id "ref"), Transit.String "ref"
    ]
  in
  List.iter
    (fun (value, expected) ->
      assert_transit "every Datascript value has a sync encoding" expected
        (Sync.transit_of_value db value))
    cases
;;

let () =
  let db = reference_db () in
  let module Sync = Logseq_chat_sync_tx in
  let child =
    { db_id = None
    ; attrs = [ "block/title", One_value (String "Child") ]
    }
  in
  let entity =
    { db_id = Some (Temp_id "entity")
    ; attrs =
        [ "one", One_value (Int 1)
        ; "many", Many_values [ Int 2; Int 3 ]
        ; "child", One_entity child
        ; "children", Many_entities [ child ]
        ]
    }
  in
  assert_transit
    "nested transaction entities retain every cardinality"
    (Transit.Map
       [ Transit.Keyword "db/id", Transit.String "entity"
       ; Transit.Keyword "one", Transit.Int 1
       ; Transit.Keyword "many", Transit.Array [ Transit.Int 2; Transit.Int 3 ]
       ; ( Transit.Keyword "child"
         , Transit.Map [ Transit.Keyword "block/title", Transit.String "Child" ] )
       ; ( Transit.Keyword "children"
         , Transit.Array
             [ Transit.Map [ Transit.Keyword "block/title", Transit.String "Child" ] ] )
       ])
    (Sync.transit_of_entity db entity)
;;

let () =
  let db = reference_db () in
  let module Sync = Logseq_chat_sync_tx in
  let entity_ref = Lookup_ref ("block/uuid", Uuid "stable-uuid") in
  let ref_wire = Transit.Array [ Transit.Keyword "block/uuid"; Transit.Uuid "stable-uuid" ] in
  assert_transit
    "retract value encodes all operands"
    (Transit.Array
       [ Transit.Keyword "db/retract"; ref_wire; Transit.Keyword "block/title"; Transit.String "Old" ])
    (encoded_op db (Retract (entity_ref, "block/title", Some (String "Old"))));
  let retract_attr =
    Transit.Array
      [ Transit.Keyword "db.fn/retractAttribute"; ref_wire; Transit.Keyword "block/title" ]
  in
  assert_transit "retract without value becomes retractAttribute" retract_attr
    (encoded_op db (Retract (entity_ref, "block/title", None)));
  assert_transit "explicit retractAttribute uses the same wire form" retract_attr
    (encoded_op db (RetractAttr (entity_ref, "block/title")));
  assert_transit
    "retract entity encodes its stable ref"
    (Transit.Array [ Transit.Keyword "db/retractEntity"; ref_wire ])
    (encoded_op db (RetractEntity entity_ref));
  assert_transit
    "compare-and-set includes an expected value"
    (Transit.Array
       [ Transit.Keyword "db.fn/cas"; ref_wire; Transit.Keyword "block/title"
       ; Transit.String "Old"; Transit.String "New" ])
    (encoded_op db
       (CompareAndSet
          (entity_ref, "block/title", Some (String "Old"), String "New")));
  assert_transit
    "compare-and-set represents a missing expected value as null"
    (Transit.Array
       [ Transit.Keyword "db.fn/cas"; ref_wire; Transit.Keyword "block/title"
       ; Transit.Null; Transit.String "New" ])
    (encoded_op db (CompareAndSet (entity_ref, "block/title", None, String "New")));
  assert_transit
    "entity transaction delegates to entity encoding"
    (Transit.Map [ Transit.Keyword "block/title", Transit.String "Entity" ])
    (encoded_op db
       (Entity { db_id = None; attrs = [ "block/title", One_value (String "Entity") ] }));
  let raw added =
    Raw_datom { e = 1; a = "block/title"; v = String "Raw"; tx = 1; added }
  in
  assert_transit
    "added raw datom becomes db/add"
    (Transit.Array
       [ Transit.Keyword "db/add"; ref_wire; Transit.Keyword "block/title"; Transit.String "Raw" ])
    (encoded_op db (raw true));
  assert_transit
    "retracted raw datom becomes db/retract"
    (Transit.Array
       [ Transit.Keyword "db/retract"; ref_wire; Transit.Keyword "block/title"; Transit.String "Raw" ])
    (encoded_op db (raw false));
  assert_transit
    "call-ident keeps its function ref and arguments"
    (Transit.Array [ Transit.Keyword "function"; Transit.Int 1; Transit.String "x" ])
    (encoded_op db (CallIdent (Ident "function", [ Int 1; String "x" ])));
  let rejected =
    [ InstallTxFn (Ident "install", (fun _ _ -> [])); Call (fun _ -> []) ]
    |> List.for_all (fun operation ->
      Sync.transit_of_tx_op db operation
      = Error "transaction functions cannot be sent over sync")
  in
  if not rejected then fail "executable transaction functions must be rejected";
  (match Sync.encode db [] with
   | Ok wire ->
     assert_transit "empty transaction remains an empty vector" (Transit.Array [])
       (Transit.of_string wire)
   | Error message -> fail message);
  if
    Sync.encode db [ InstallTxFn (Ident "install", (fun _ _ -> [])) ]
    <> Error "transaction functions cannot be sent over sync"
  then fail "encode must stop on an unsupported transaction function"
;;

let () =
  let module Sync = Logseq_chat_sync_tx in
  let encrypt value = Ok ("cipher:" ^ value) in
  let expect label expected operation =
    match Sync.encrypt_tx_op encrypt operation with
    | Ok actual when actual = expected -> ()
    | Ok _ -> fail label
    | Error message -> fail (label ^ ": " ^ message)
  in
  let entity_ref = Temp_id "entity" in
  expect
    "add encrypts a protected title"
    (Add (entity_ref, "block/title", String "cipher:Title"))
    (Add (entity_ref, "block/title", String "Title"));
  expect
    "add encrypts a protected name"
    (Add (entity_ref, "block/name", String "cipher:name"))
    (Add (entity_ref, "block/name", String "name"));
  expect
    "unprotected values remain plaintext"
    (Add (entity_ref, "block/order", String "a0"))
    (Add (entity_ref, "block/order", String "a0"));
  expect
    "retract encrypts its protected value"
    (Retract (entity_ref, "block/title", Some (String "cipher:Old")))
    (Retract (entity_ref, "block/title", Some (String "Old")));
  expect
    "valueless retract remains structural"
    (Retract (entity_ref, "block/title", None))
    (Retract (entity_ref, "block/title", None));
  expect
    "compare-and-set encrypts old and new protected values"
    (CompareAndSet
       ( entity_ref
       , "block/title"
       , Some (String "cipher:Old")
       , String "cipher:New" ))
    (CompareAndSet (entity_ref, "block/title", Some (String "Old"), String "New"));
  expect
    "compare-and-set preserves a missing expected value"
    (CompareAndSet (entity_ref, "block/title", None, String "cipher:New"))
    (CompareAndSet (entity_ref, "block/title", None, String "New"));
  let child title =
    { db_id = None; attrs = [ "block/title", One_value (String title) ] }
  in
  expect
    "entity encryption covers scalar, many, and nested protected values"
    (Entity
       { db_id = Some entity_ref
       ; attrs =
           [ "block/title", One_value (String "cipher:Root")
           ; "block/name", Many_values [ String "cipher:one"; String "cipher:two" ]
           ; "child", One_entity (child "cipher:Child")
           ; "children", Many_entities [ child "cipher:A"; child "cipher:B" ]
           ]
       })
    (Entity
       { db_id = Some entity_ref
       ; attrs =
           [ "block/title", One_value (String "Root")
           ; "block/name", Many_values [ String "one"; String "two" ]
           ; "child", One_entity (child "Child")
           ; "children", Many_entities [ child "A"; child "B" ]
           ]
       });
  expect
    "raw datom encryption follows its attribute"
    (Raw_datom
       { e = 1; a = "block/title"; v = String "cipher:Raw"; tx = 1; added = true })
    (Raw_datom { e = 1; a = "block/title"; v = String "Raw"; tx = 1; added = true });
  let passthrough =
    [ Retract (entity_ref, "block/title", None)
    ; RetractAttr (entity_ref, "block/title")
    ; RetractEntity entity_ref
    ; CallIdent (Ident "function", [ String "plaintext argument" ])
    ; InstallTxFn (Ident "install", (fun _ _ -> []))
    ; Call (fun _ -> [])
    ]
  in
  List.iter
    (fun operation ->
      match Sync.encrypt_tx_op encrypt operation with
      | Ok _ -> ()
      | Error _ -> fail "structural and function operations must not be rewritten")
    passthrough;
  (match Sync.encrypt_tx_op encrypt (Add (entity_ref, "block/title", Int 1)) with
   | Error _ -> ()
   | Ok _ -> fail "protected non-string values must fail closed")
;;
