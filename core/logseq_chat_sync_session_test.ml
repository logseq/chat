module Transit = Transit_native.Transit.Json
module Session = Logseq_chat_sync_session
module Checkpoint = Logseq_chat_sync_session

let fail label message = failwith (label ^ ": " ^ message)

let contains text needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) text 0);
    true
  with Not_found -> false
;;

let expect_ok label = function
  | Ok value -> value
  | Error message -> fail label message
;;

let frame value =
  let payload = Transit.to_string ~mode:Transit.Verbose value in
  let length = String.length payload in
  let prefix =
    String.init 4 (fun index ->
      Char.chr ((length lsr ((3 - index) * 8)) land 0xff))
  in
  prefix ^ payload
;;

let fixture_wire ?(title = "Local title") () =
  let schema =
    Transit.Map
      [ ( Transit.Keyword "block/title"
        , Transit.Map
            [ Transit.Keyword "db/valueType", Transit.Keyword "db.type/string" ] )
      ]
  in
  let root =
    Transit.Map
      [ Transit.Keyword "schema", schema
      ; Transit.Keyword "max-eid", Transit.Int 1
      ; Transit.Keyword "max-tx", Transit.Int 536870913
      ; Transit.Keyword "eavt", Transit.Int 2
      ; Transit.Keyword "aevt", Transit.Int 3
      ; Transit.Keyword "avet", Transit.Int 4
      ; Transit.Keyword "max-addr", Transit.Int 4
      ; Transit.Keyword "branching-factor", Transit.Int 512
      ; Transit.Keyword "ref-type", Transit.Keyword "soft"
      ]
  in
  let leaf =
    Transit.Map
      [ ( Transit.Keyword "keys"
        , Transit.Array
            [ Transit.Array
                [ Transit.Int 1
                ; Transit.Keyword "block/title"
                ; Transit.String title
                ; Transit.Int 536870913
                ]
            ] )
      ]
  in
  let row addr content =
    Transit.Array [ Transit.Int addr; Transit.String content; Transit.Null ]
  in
  frame
    (Transit.Array
       [ row 0 (Transit.to_string ~mode:Transit.Verbose root)
       ; row 1 (Transit.to_string ~mode:Transit.Verbose (Transit.Array []))
       ; row 2 (Transit.to_string ~mode:Transit.Verbose leaf)
       ; row 3 (Transit.to_string ~mode:Transit.Verbose leaf)
       ; row 4 (Transit.to_string ~mode:Transit.Verbose leaf)
       ])
;;

let write_file path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)
;;

let () =
  let metadata =
    expect_ok
      "decode metadata"
      (Session.decode_snapshot_metadata
         {|{"ok":true,"key":"stream/graph-1.snapshot","url":"https://sync.example/sync/graph-1/snapshot/stream","content-encoding":"gzip","t":48192,"schema-version":"65.33","row-count":5}|})
  in
  if metadata.baseline_t <> 48192 || metadata.row_count <> 5
  then fail "metadata" "cursor or row count changed";
  if metadata.content_encoding <> Some "gzip"
  then fail "metadata" "content encoding changed";

  let active_path = Filename.temp_file "logseq-chat-session" ".sqlite" in
  let checkpoint_path = Filename.temp_file "logseq-chat-session" ".checkpoint" in
  let download_path = Filename.temp_file "logseq-chat-session" ".snapshot" in
  Sys.remove active_path;
  Sys.remove checkpoint_path;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun path -> if Sys.file_exists path then Sys.remove path)
        [ active_path
        ; active_path ^ ".import"
        ; checkpoint_path
        ; checkpoint_path ^ ".tmp"
        ; download_path
        ])
    (fun () ->
      write_file download_path (fixture_wire ());
      let result =
        expect_ok
          "import snapshot"
          (Session.import_snapshot_file
             ~graph_id:"graph-1"
             ~active_path
             ~checkpoint_path
             ~metadata
             ~download_path
             ())
      in
      if result.applied_server_t <> 48192
      then fail "import cursor" "baseline cursor changed";
      ignore (expect_ok "restore active graph" (Logseq_chat_lg_core_native.logseq_chat_graph_store_restore_db active_path));
      (match expect_ok "load checkpoint" (Checkpoint.load_checkpoint checkpoint_path) with
       | Some checkpoint when checkpoint.applied_server_t = 48192 -> ()
       | _ -> fail "checkpoint" "activated snapshot cursor was not saved");

      let original_root =
        expect_ok "read original root" (Logseq_chat_lg_core_native.logseq_chat_graph_store_read_row active_path 0)
      in
      write_file download_path "\000\000\000\010broken";
      (match
         Session.import_snapshot_file
           ~graph_id:"graph-1"
           ~active_path
           ~checkpoint_path
           ~metadata
           ~download_path
           ()
       with
       | Error _ -> ()
       | Ok _ -> fail "corrupt snapshot" "invalid stream was activated");
      let root_after_failure =
        expect_ok "read root after failure" (Logseq_chat_lg_core_native.logseq_chat_graph_store_read_row active_path 0)
      in
      if root_after_failure <> original_root
      then fail "atomic import" "failed import replaced the active graph";
      (match expect_ok "checkpoint after failure" (Checkpoint.load_checkpoint checkpoint_path) with
       | Some checkpoint when checkpoint.applied_server_t = 48192 -> ()
       | _ -> fail "atomic checkpoint" "failed import changed the cursor");

      let conn = expect_ok "restore sync connection" (Logseq_chat_lg_core_native.logseq_chat_graph_store_restore_conn active_path) in
      let state =
        Logseq_chat_sync_session.create_state
          ~graph_id:"graph-1"
          ~schema_version:"65.33"
          ~applied_server_t:48192
      in
      let change : Logseq_chat_lg_core_native.sync_change_set =
        { format_version = 1
        ; graph_id = "graph-1"
        ; schema_version = "65.33"
        ; t_before = 48192
        ; t = 48193
        ; upserts = []
        ; deleted = []
        ; operation_ids = []
        }
      in
      expect_ok
        "apply authoritative event"
        (Session.apply_change_set ~conn ~checkpoint_path state change);
      if Logseq_chat_sync_session.applied_server_t state <> 48193
      then fail "event cursor" "successful WebSocket event did not advance state";
      match expect_ok "event checkpoint" (Checkpoint.load_checkpoint checkpoint_path) with
      | Some checkpoint when checkpoint.applied_server_t = 48193 -> ()
      | _ -> fail "event checkpoint" "successful WebSocket event did not persist cursor")
;;

let () =
  let active_path = Filename.temp_file "logseq-chat-encrypted-import" ".sqlite" in
  let checkpoint_path = Filename.temp_file "logseq-chat-encrypted-import" ".checkpoint" in
  let download_path = Filename.temp_file "logseq-chat-encrypted-import" ".snapshot" in
  Sys.remove active_path;
  Sys.remove checkpoint_path;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun path -> if Sys.file_exists path then Sys.remove path)
        [ active_path; active_path ^ ".import"; checkpoint_path; checkpoint_path ^ ".tmp"; download_path ])
    (fun () ->
      write_file download_path (fixture_wire ~title:"cipher:Private title" ());
      let metadata : Session.snapshot_metadata =
        { url = "https://sync.example/snapshot"
        ; content_encoding = None
        ; baseline_t = 9
        ; schema_version = "65.33"
        ; row_count = 5
        }
      in
      let decrypt value =
        if String.starts_with ~prefix:"cipher:" value
        then Ok (String.sub value 7 (String.length value - 7))
        else Error "expected encrypted snapshot title"
      in
      ignore
        (expect_ok
           "import encrypted snapshot as local plaintext"
           (Session.import_snapshot_file
              ~decrypt_protected:decrypt
              ~graph_id:"encrypted-graph"
              ~active_path
              ~checkpoint_path
              ~metadata
              ~download_path
              ()));
      let db = expect_ok "restore local plaintext snapshot" (Logseq_chat_lg_core_native.logseq_chat_graph_store_restore_db active_path) in
      (match Datascript.datoms db Datascript.Aevt ~a:"block/title" () |> List.of_seq with
      | [ { Datascript.v = Datascript.String "Private title"; _ } ] -> ()
      | _ -> fail "encrypted snapshot" "ciphertext was persisted in local DataScript");
      Logseq_chat_lg_core_native.logseq_chat_graph_store_list_stored_addresses active_path
      |> List.iter (fun addr ->
        match expect_ok "read local snapshot row" (Logseq_chat_lg_core_native.logseq_chat_graph_store_read_row active_path addr) with
        | Some (content, _) when contains content "cipher:Private title" ->
          fail "encrypted snapshot" "obsolete ciphertext row remained in local SQLite"
        | _ -> ()))
;;

let () =
  let open Datascript in
  let one ?value_type () =
    { unique = None
    ; cardinality = One
    ; value_type
    ; indexed = false
    ; is_component = false
    ; no_history = false
    ; doc = None
    ; tuple_attrs = None
    ; tuple_types = None
    }
  in
  let schema =
    [ "block/uuid", one ~value_type:UuidType ()
    ; "block/title", one ~value_type:StringType ()
    ; "logseq.property/built-in?", one ()
    ]
  in
  let db =
    Datascript.empty_db ~schema ()
    |> Datascript.db_with
         [ Add (Entity_id 1, "block/title", String "cipher:Private title")
         ; Add
             ( Entity_id 2
             , "block/uuid"
             , Uuid "00000002-0000-0000-0000-000000000001" )
         ; Add (Entity_id 2, "block/title", String "cipher:Card")
         ]
  in
  let decrypt value =
    if String.starts_with ~prefix:"cipher:" value
    then Ok (String.sub value 7 (String.length value - 7))
    else Error "expected encrypted snapshot title"
  in
  let plaintext =
    expect_ok
      "preserve canonical built-in titles in encrypted snapshots"
      (Session.plaintext_snapshot_db decrypt db)
  in
  let title eid =
    Datascript.datoms plaintext Datascript.Eavt ~e:eid ~a:"block/title" ()
    |> Seq.find_map (fun datom ->
      match datom.Datascript.v with
      | String value -> Some value
      | _ -> None)
  in
  if title 1 <> Some "Private title"
  then fail "encrypted snapshot" "user title was not decrypted";
  if title 2 <> Some "Card"
  then fail "encrypted snapshot" "legacy encrypted built-in title was not decrypted"
;;
