open Test_util

module Ds = Datascript
module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json
module Bootstrap = Graph_bootstrap
module Ops = Pending_ops
module Projection = Pending_projection
module Storage_codec = Storage_codec

let expect_ok result =
  match result with
  | Ok value -> value
  | Error message -> failwith message

let canonical_db encrypted =
  expect_ok
    (Bootstrap.database "625e5ba9-fa25-4385-ad8b-f47d0f844387" encrypted
       (fun value -> Ok ("encrypted:" ^ value)))

let one_value db reference attr =
  match Ds.entity db reference with
  | Some entity ->
    (match Ds.entity_attr entity attr with
     | Some (Ds.One_value value) -> Some value
     | _ -> None)
  | None -> None

let kv_value db ident =
  match Ds.entid db "db/ident" (Ds.Keyword ident) with
  | Some eid -> one_value db (Ds.Entity_id eid) "kv/value"
  | None -> None

let transit_field name input =
  match input with
  | Value.Map entries ->
    List.find_map
      (fun (key, value) ->
        if key = Value.Keyword name then Some value else None)
      entries
  | _ -> None

let index_metadata index root =
  let metadata =
    match transit_field (index ^ "-metadata") root with
    | Some value -> value
    | None -> Value.Null
  in
  List.map
    (fun field ->
      match transit_field field metadata with
      | Some (Value.Int value) -> value
      | _ -> failwith ("missing " ^ index ^ " metadata " ^ field))
    [ "count"; "shift" ]

let encryption_is_optional_and_stops_at_first_failure () =
  let calls = ref 0 in
  let encrypt _ =
    incr calls;
    Error "encryption unavailable"
  in
  ignore (expect_ok (Bootstrap.database "plain" false encrypt));
  check_eq 0 !calls;
  check_eq (Error "encryption unavailable")
    (Bootstrap.database "encrypted" true encrypt);
  check_eq 1 !calls

let snapshots_roundtrip_all_datoms_and_schema () =
  List.iter
    (fun encrypted ->
      let db = canonical_db encrypted in
      let rows = expect_ok (Bootstrap.snapshot_rows db) in
      let storage = Ds.memory_storage () in
      storage.Ds.storage_store
        (List.map
           (fun (row : Snapshot.snapshot_row) ->
             ( string_of_int row.addr
             , Storage_codec.decode row.addresses row.content ))
           rows);
      match Ds.restore storage with
      | Some restored ->
        check_eq (Ds.schema db) (Ds.schema restored);
        check_eq
          (List.of_seq (Ds.Db.datoms db Ds.Eavt ()))
          (List.of_seq (Ds.Db.datoms restored Ds.Eavt ()))
      | None -> failwith "database was not restored")
    [ false; true ]

let prepared_file_has_complete_frames_and_checksum () =
  let prepared =
    expect_ok
      (Bootstrap.prepare "prepared" false (fun _ ->
         failwith "plaintext snapshot must not encrypt"))
  in
  Fun.protect
    ~finally:(fun () -> Sys.remove prepared.Bootstrap.file_path)
    (fun () ->
      let channel = open_in_bin prepared.file_path in
      let wire =
        Fun.protect
          ~finally:(fun () -> close_in_noerr channel)
          (fun () ->
            really_input_string channel (in_channel_length channel))
      in
      let parser = Snapshot.create_parser (2 * 1024 * 1024) in
      let rows = expect_ok (Snapshot.feed parser wire) in
      ignore (expect_ok (Snapshot.finish_parser parser));
      check_eq prepared.row_count (List.length rows);
      check_eq "0000000000000000" prepared.checksum)

let built_in_catalog_and_graph_metadata () =
  let started = int_of_float (Unix.gettimeofday () *. 1000.0) in
  let db = canonical_db false in
  check (List.length (List.of_seq (Ds.Db.datoms db Ds.Aevt ~a:"db/ident" ())) > 45);
  List.iter
    (fun ident ->
      match Ds.entid db "db/ident" (Ds.Keyword ident) with
      | Some eid ->
        check_eq (Some (Ds.Bool true))
          (one_value db (Ds.Entity_id eid) "logseq.property/built-in?")
      | None -> failwith ("missing built-in " ^ ident))
    [
      "logseq.class/Root";
      "logseq.class/Tag";
      "logseq.class/Property";
      "logseq.class/Page";
      "logseq.class/Journal";
      "logseq.class/Task";
      "logseq.class/Card";
      "logseq.class/Asset";
      "logseq.class/Code-block";
      "logseq.class/Quote-block";
      "logseq.class/Math-block";
    ];
  List.iter
    (fun name ->
      check
        (not
           (List.is_empty
              (List.of_seq
                 (Ds.Db.datoms db Ds.Aevt ~a:"block/name" ~v:(Ds.String name)
                    ())))))
    [ "$$$favorites"; "$$$views"; "recycle" ];
  check_eq
    (Some (Ds.Uuid "625e5ba9-fa25-4385-ad8b-f47d0f844387"))
    (kv_value db "logseq.kv/graph-uuid");
  check_eq (Some (Ds.Bool true)) (kv_value db "logseq.kv/graph-remote?");
  check_eq (Some (Ds.Bool false)) (kv_value db "logseq.kv/graph-rtc-e2ee?");
  (match kv_value db "logseq.kv/graph-created-at" with
   | Some (Ds.Int timestamp) -> check (timestamp >= started)
   | _ -> failwith "missing graph creation timestamp");
  check
    (kv_value db "logseq.kv/local-graph-uuid"
    <> kv_value (canonical_db false) "logseq.kv/local-graph-uuid")

let encryption_preserves_schema_and_protects_text () =
  let plain = canonical_db false in
  let encrypted = canonical_db true in
  check_eq (Ds.schema plain) (Ds.schema encrypted);
  List.iter
    (fun db ->
      let schema = Ds.schema db in
      List.iter
        (fun (attr, cardinality) ->
          match List.assoc_opt attr schema with
          | Some installed ->
            check_eq cardinality installed.Ds.cardinality;
            check_eq (Some Ds.RefType) installed.value_type
          | None -> failwith ("missing schema " ^ attr))
        [
          ("block/tags", Ds.Many);
          ("logseq.property.class/extends", Ds.Many);
          ("logseq.property/status", Ds.One);
        ])
    [ plain; encrypted ];
  List.iter
    (fun attr ->
      List.iter
        (fun (datom : Ds.datom) ->
          match datom.v with
          | Ds.String value ->
            check (String.starts_with ~prefix:"encrypted:" value)
          | _ -> failwith "encrypted text is not a string")
        (List.of_seq (Ds.Db.datoms encrypted Ds.Aevt ~a:attr ())))
    [ "block/title"; "block/name" ]

let fresh_graph_accepts_tag_creation () =
  let operation : Ops.pending_operation =
    {
      Ops.operation_id = "create-tag";
      base_t = 0;
      state = Ops.Queued;
      intent =
        Ops.Create_tag
          {
            Ops.uuid = "10000000-0000-0000-0000-000000000001";
            title = "Card";
            created_at = 1;
          };
    }
  in
  let projected =
    Projection.build 0 (canonical_db false) [ operation ]
  in
  check_eq (Some Ops.Applied)
    (List.find_map
       (fun (id, state) ->
         if id = "create-tag" then Some state else None)
       projected.statuses);
  check
    (Ds.entid projected.db "block/uuid"
       (Ds.Uuid "10000000-0000-0000-0000-000000000001")
    <> None)

let snapshot_index_metadata_and_framing () =
  let db = canonical_db false in
  let rows = expect_ok (Bootstrap.snapshot_rows db) in
  let root_row =
    match
      List.find_opt
        (fun (row : Snapshot.snapshot_row) -> row.addr = 0)
        rows
    with
    | Some row -> row
    | None -> failwith "missing root"
  in
  let root = Codec.of_string root_row.Snapshot.content in
  let eavt_count, eavt_shift =
    match index_metadata "eavt" root with
    | [ count; shift ] -> (count, shift)
    | _ -> failwith "eavt metadata"
  in
  let aevt_count, aevt_shift =
    match index_metadata "aevt" root with
    | [ count; shift ] -> (count, shift)
    | _ -> failwith "aevt metadata"
  in
  let avet_count, avet_shift =
    match index_metadata "avet" root with
    | [ count; shift ] -> (count, shift)
    | _ -> failwith "avet metadata"
  in
  let datom_count = List.length (List.of_seq (Ds.Db.datoms db Ds.Eavt ())) in
  let parser = Snapshot.create_parser (2 * 1024 * 1024) in
  check
    (List.exists
       (fun (row : Snapshot.snapshot_row) -> row.addr = 1)
       rows);
  check_eq datom_count eavt_count;
  check_eq datom_count aevt_count;
  check (avet_count > 0 && avet_count <= datom_count);
  check (eavt_shift > 0);
  check (aevt_shift > 0);
  check (avet_shift >= 0);
  check_eq (List.length rows)
    (List.length
       (expect_ok (Snapshot.feed parser (Bootstrap.frame_rows rows))));
  ignore (expect_ok (Snapshot.finish_parser parser))

let empty_index_metadata () =
  let db =
    Ds.empty_db ~schema:Bootstrap.native_schema
      ~storage:(Ds.memory_storage ()) ()
  in
  let rows = expect_ok (Bootstrap.snapshot_rows db) in
  let root_row =
    match
      List.find_opt
        (fun (row : Snapshot.snapshot_row) -> row.addr = 0)
        rows
    with
    | Some row -> row
    | None -> failwith "missing root"
  in
  let root = Codec.of_string root_row.Snapshot.content in
  List.iter
    (fun index -> check_eq [ 0; 0 ] (index_metadata index root))
    [ "eavt"; "aevt"; "avet" ]

let cases =
  [
    case "encryption is optional and stops at first failure"
      encryption_is_optional_and_stops_at_first_failure;
    case "snapshots roundtrip all datoms and schema"
      snapshots_roundtrip_all_datoms_and_schema;
    case "prepared file has complete frames and checksum"
      prepared_file_has_complete_frames_and_checksum;
    case "built-in catalog and graph metadata"
      built_in_catalog_and_graph_metadata;
    case "encryption preserves schema and protects text"
      encryption_preserves_schema_and_protects_text;
    case "fresh graph accepts tag creation" fresh_graph_accepts_tag_creation;
    case "snapshot index metadata and framing"
      snapshot_index_metadata_and_framing;
    case "empty index metadata" empty_index_metadata;
  ]
