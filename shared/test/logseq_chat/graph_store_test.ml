open Test_util

module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json
module Ds = Datascript

let expect_ok result =
  match result with
  | Ok value -> value
  | Error message -> failwith message

let with_store f =
  let path = Filename.temp_file "logseq-chat-graph" ".sqlite" in
  Sys.remove path;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun candidate ->
          if Sys.file_exists candidate then Sys.remove candidate)
        [ path; Graph_store.staging_path path ])
    (fun () -> f path)

let keyword name = Value.Keyword name

let kv pairs = Value.Map (List.map (fun (k, v) -> (keyword k, v)) pairs)

let fixture_rows () =
  let root =
    kv
      [
        ( "schema"
        , kv
            [
              ("block/uuid", kv [ ("db/valueType", keyword "db.type/uuid") ]);
              ("block/parent", kv [ ("db/valueType", keyword "db.type/ref") ]);
              ( "block/tags"
              , kv
                  [
                    ("db/valueType", keyword "db.type/ref");
                    ("db/cardinality", keyword "db.cardinality/many");
                  ] );
              ("block/type", kv [ ("db/valueType", keyword "db.type/keyword") ]);
              ("block/created-at", Value.Map []);
              ("block/properties", Value.Map []);
            ] );
        ("max-eid", Value.Int 12);
        ("max-tx", Value.Int 536870930);
        ("eavt", Value.Int 2);
        ("aevt", Value.Int 3);
        ("avet", Value.Int 4);
        ("max-addr", Value.Int 4);
        ("branching-factor", Value.Int 512);
        ("ref-type", keyword "soft");
      ]
  in
  let tx = Value.Int 536870930 in
  let datom entity attr value =
    Value.Array [ Value.Int entity; keyword attr; value; tx ]
  in
  let node =
    kv
      [
        ( "keys"
        , Value.Array
            [
              datom 10 "block/created-at"
                (Value.Int64 1723012345678L);
              datom 10 "block/parent" (Value.Int 11);
              datom 10 "block/properties"
                (Value.Map [ (keyword "priority", keyword "A") ]);
              datom 10 "block/tags" (Value.Int 11);
              datom 10 "block/tags" (Value.Int 12);
              datom 10 "block/type" (keyword "whiteboard");
              datom 10 "block/uuid"
                (Value.Tagged
                   ("u", Value.String "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8"));
            ] );
      ]
  in
  List.map
    (fun (addr, value) : Snapshot.snapshot_row ->
       {
         Snapshot.addr;
         content = Codec.to_string ~mode:Codec.Verbose value;
         addresses = None;
       })
    [ (0, root); (1, Value.Array []); (2, node); (3, node); (4, node) ]

let activate path rows =
  ignore (expect_ok (Graph_store.begin_import path));
  ignore (expect_ok (Graph_store.append_rows path rows));
  ignore (expect_ok (Graph_store.activate path))

let values db attr =
  List.map
    (fun (d : Ds.datom) -> d.Ds.v)
    (List.of_seq (Ds.Db.datoms db Ds.Eavt ~e:10 ~a:attr ()))

let staging_activation_preserves_content_and_sql_null () =
  with_store (fun path ->
    ignore (Graph_store.storage path);
    ignore (expect_ok (Graph_store.append_rows path []));
    check (not (Sys.file_exists (Graph_store.staging_path path)));
    check
      (match Graph_store.activate path with
       | Error _ -> true
       | Ok _ -> false);
    let root =
      "[\"^ \",\"~:schema\",[\"^ \",\"~:block/title\",[\"^ \
       \",\"~:db/valueType\",\"~:db.type/string\"]]]"
    in
    let node = "[\"^ \",\"~:keys\",[]]" in
    activate path
      [
        { Snapshot.addr = 0; content = root; addresses = None };
        { Snapshot.addr = 1; content = "[]"; addresses = None };
        { Snapshot.addr = 7; content = node; addresses = Some "[3,4]" };
      ];
    check (not (Sys.file_exists (Graph_store.staging_path path)));
    check_eq (Some (root, None)) (expect_ok (Graph_store.read_row path 0));
    check_eq (Some (node, Some "[3,4]"))
      (expect_ok (Graph_store.read_row path 7)))

let typed_restore_and_writable_connection_persist () =
  with_store (fun path ->
    activate path (fixture_rows ());
    let db = expect_ok (Graph_store.restore_db path) in
    check_eq
      [ Ds.Uuid "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" ]
      (values db "block/uuid");
    check_eq [ Ds.Ref 11 ] (values db "block/parent");
    check_eq [ Ds.Keyword "whiteboard" ] (values db "block/type");
    check_eq [ Ds.Int 1723012345678 ] (values db "block/created-at");
    check_eq [ Ds.Map [ (Ds.Keyword "priority", Ds.Keyword "A") ] ]
      (values db "block/properties");
    check_eq [ Ds.Ref 11; Ds.Ref 12 ] (values db "block/tags");
    let tags =
      List.assoc_opt "block/tags" (Ds.schema db)
    in
    check_eq (Some Ds.Many)
      (match tags with
       | Some attr -> Some attr.Ds.cardinality
       | None -> None);
    check_eq (Some Ds.RefType)
      (match tags with
       | Some attr -> attr.Ds.value_type
       | None -> None);
    let conn = expect_ok (Graph_store.restore_conn path) in
    ignore
      (Ds.transact_conn conn
         [ Ds.Add (Ds.Entity_id 10, "block/type", Ds.Keyword "page") ]);
    check_eq [ Ds.Keyword "page" ]
      (values (expect_ok (Graph_store.restore_db path)) "block/type"))

let snapshot_reader_isolation_and_write_invalidation () =
  with_store (fun path ->
    let rows = fixture_rows () in
    activate path rows;
    let storage = Graph_store.storage path in
    let original = storage.Ds.storage_restore "2" in
    activate path
      (List.map
         (fun (row : Snapshot.snapshot_row) ->
            {
              row with
              Snapshot.content =
                Str.global_replace
                  (Str.regexp_string "whiteboard") "canvas" row.content;
            })
         rows);
    let current = Graph_store.storage path in
    check (original <> current.Ds.storage_restore "2");
    check (original = storage.Ds.storage_restore "2");
    (match original with
     | Some node -> current.Ds.storage_store [ ("2", node) ]
     | None -> failwith "fixture node missing");
    check (original = current.Ds.storage_restore "2");
    current.Ds.storage_delete [ "2" ];
    check_eq None (current.Ds.storage_restore "2");
    Gc.full_major ())

let cases =
  [
    case "staging activation preserves content and sql null"
      staging_activation_preserves_content_and_sql_null;
    case "typed restore and writable connection persist"
      typed_restore_and_writable_connection_persist;
    case "snapshot reader isolation and write invalidation"
      snapshot_reader_isolation_and_write_invalidation;
  ]
