let assert_bool label value =
  if not value then failwith label
;;

let assert_equal label expected actual =
  if not (String.equal expected actual)
  then
    failwith
      (Printf.sprintf "%s: expected %S, got %S" label expected actual)
;;

let with_temp_db f =
  let path = Filename.temp_file "logseq-chat-sqlite-test" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () -> f path)
;;

let transit_field key entries =
  List.assoc_opt (Transit_core.Json.Keyword key) entries
;;

let () =
  with_temp_db (fun path ->
    let session = Logseq_chat_lg_core_native.logseq_chat_sqlite_open_session path in
    Fun.protect
      ~finally:(fun () -> Logseq_chat_lg_core_native.logseq_chat_sqlite_close session)
      (fun () ->
        Logseq_chat_lg_core_native.logseq_chat_sqlite_store_string session "metadata" "value";
        let encoded =
          match Logseq_chat_lg_core_native.logseq_chat_sqlite_restore_raw session "metadata" with
          | Some encoded -> encoded
          | None -> failwith "versioned metadata value was not stored"
        in
        match Transit_native.Transit.Json.of_string encoded with
        | Transit_core.Json.Map entries ->
          (match transit_field "format-version" entries, transit_field "value-type" entries with
           | Some (Transit_core.Json.Int 1), Some (Transit_core.Json.Keyword "string") -> ()
           | _ -> failwith "metadata value is missing its versioned Transit envelope")
        | _ -> failwith "metadata value is not a Transit map"))
;;

let () =
  with_temp_db (fun path ->
    let session = Logseq_chat_lg_core_native.logseq_chat_sqlite_open_session path in
    Fun.protect
      ~finally:(fun () -> Logseq_chat_lg_core_native.logseq_chat_sqlite_close session)
      (fun () ->
        Logseq_chat_lg_core_native.logseq_chat_sqlite_store_raw session
          (List.to_seq,
           [ Rrbvec.of_list [ "legacy"; Marshal.to_string "old" [] ]
           ; Rrbvec.of_list
               [ "future"
               ; {|["^ ","~:format-version",2,"~:value-type","~:string","~:value","future"]|}
               ]
           ]);
        assert_bool
          "legacy Marshal metadata should be treated as a cache miss"
          (Option.is_none (Logseq_chat_lg_core_native.logseq_chat_sqlite_restore_string session "legacy"));
        assert_bool
          "unknown metadata versions should be treated as a cache miss"
          (Option.is_none (Logseq_chat_lg_core_native.logseq_chat_sqlite_restore_string session "future"))))
;;

let () =
  with_temp_db (fun path ->
    let session = Logseq_chat_lg_core_native.logseq_chat_sqlite_open_session path in
    Fun.protect
      ~finally:(fun () -> Logseq_chat_lg_core_native.logseq_chat_sqlite_close session)
      (fun () ->
        let storage = Logseq_chat_lg_core_native.logseq_chat_sqlite_storage session in
        storage.storage_store [ "tail", Datascript.Storage_tail [] ];
        let encoded =
          match Logseq_chat_lg_core_native.logseq_chat_sqlite_restore_raw session "tail" with
          | Some encoded -> encoded
          | None -> failwith "DataScript storage value was not stored"
        in
        (match Transit_native.Transit.Json.of_string encoded with
         | Transit_core.Json.Map entries ->
           (match transit_field "format-version" entries, transit_field "value-type" entries with
            | Some (Transit_core.Json.Int 1),
              Some (Transit_core.Json.Keyword "datascript-storage") -> ()
            | _ -> failwith "DataScript value is missing its versioned Transit envelope")
         | _ -> failwith "DataScript value is not a Transit map");
        Logseq_chat_lg_core_native.logseq_chat_sqlite_store_raw session
          (List.to_seq,
           [ Rrbvec.of_list [ "legacy-tail"; Marshal.to_string (Datascript.Storage_tail []) [] ] ]);
        assert_bool
          "legacy Marshal DataScript values should be treated as a cache miss"
          (Option.is_none (storage.storage_restore "legacy-tail"))))
;;

let () =
  with_temp_db (fun path ->
    let first_session = Logseq_chat_lg_core_native.logseq_chat_sqlite_open_session path in
    let first_model =
      (Logseq_chat_lg_core_native.logseq_chat_cache_model_create (Some ((Logseq_chat_lg_core_native.logseq_chat_sqlite_storage first_session))))
    in
    (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_message (first_model) ("local-persisted") ("Persisted offline capture") (1_776_000_000_000));
    (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_statuses (first_model) (List.to_seq, ([ { uuid = "status-waiting"
        ; ident = Some "user.status/waiting"
        ; title = "Waiting"
        ; icon_type = Some "tabler-icon"
        ; icon_id = Some "clock"
        ; icon_color = Some "#7c3aed"
        }
      ])));
    Logseq_chat_lg_core_native.logseq_chat_sqlite_close first_session;

    let second_session = Logseq_chat_lg_core_native.logseq_chat_sqlite_open_session path in
    Fun.protect
      ~finally:(fun () -> Logseq_chat_lg_core_native.logseq_chat_sqlite_close second_session)
      (fun () ->
        let restored_model =
          (Logseq_chat_lg_core_native.logseq_chat_cache_model_create (Some ((Logseq_chat_lg_core_native.logseq_chat_sqlite_storage second_session))))
        in
        match Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block restored_model "local-persisted" with
        | None -> failwith "expected persisted block after reopening SQLite storage"
        | Some block ->
          assert_equal "title" "Persisted offline capture" block.title;
          assert_equal "sync status" "pending" block.sync_status;
          assert_bool
            "journal page id should be persisted"
            (String.length block.page_id >= 8
             && String.equal (String.sub block.page_id 0 8) "journal/");
          (match (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_all_statuses (restored_model))) with
           | [ status ] ->
             assert_equal "custom status title" "Waiting" status.title;
             assert_equal
               "custom status color"
               "#7c3aed"
               (Option.value status.icon_color ~default:"")
           | statuses ->
             failwith
               (Printf.sprintf "expected one persisted custom status, got %d" (List.length statuses)))))
;;

let () =
  with_temp_db (fun path ->
    let first_store = Logseq_chat_lg_core_native.logseq_chat_sqlite_open_session path in
    let first_rpc =
      Logseq_chat_rpc.create ~storage:(Logseq_chat_lg_core_native.logseq_chat_sqlite_storage first_store) ()
    in
    ignore
      (Logseq_chat_rpc.call
         first_rpc
         {|{"apiVersion":1,"method":"dispatch","params":{"action":"send","payload":"{\"text\":\"Survives restart\",\"uuid\":\"local-restart\",\"now\":1776000000000}"}}|});
    Logseq_chat_lg_core_native.logseq_chat_sqlite_close first_store;

    let remote_block =
      Logseq_chat_lg_core_native.
        { uuid = "remote-existing"
        ; title = "Existing server block"
        ; page_id = "journal/2026-04-13"
        ; parent_id = None
        ; order = None
        ; created_at = 1_776_000_000_001
        ; updated_at = 1_776_000_000_001
        ; sync_status = "synced"
        ; tags = []
        ; references = []
        ; breadcrumbs = []
        ; status = None
        ; is_asset = false
        ; asset_type = None
        ; asset_size = None
        ; asset_checksum = None
        ; local_path = None
        ; journal = None
        }
    in
    let second_store = Logseq_chat_lg_core_native.logseq_chat_sqlite_open_session path in
    Fun.protect
      ~finally:(fun () -> Logseq_chat_lg_core_native.logseq_chat_sqlite_close second_store)
      (fun () ->
        let second_rpc =
          Logseq_chat_rpc.create
            ~storage:(Logseq_chat_lg_core_native.logseq_chat_sqlite_storage second_store)
            ~graph_blocks:(fun () -> Some [ remote_block ])
            ()
        in
        (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_journal_page (second_rpc.model) ("journal/2026-04-13") (20260413) "");
        let response =
          Logseq_chat_rpc.call
            second_rpc
            {|{"apiVersion":1,"method":"snapshot","params":{}}|}
          |> Yojson.Basic.from_string
        in
        let blocks =
          match response with
          | `Assoc fields ->
            (match List.assoc_opt "result" fields with
             | Some (`Assoc result) ->
               (match List.assoc_opt "blocks" result with
                | Some (`List blocks) -> blocks
                | _ -> failwith "restart snapshot is missing blocks")
             | _ -> failwith "restart snapshot is missing result")
          | _ -> failwith "restart snapshot is not an object"
        in
        let uuids =
          List.filter_map
            (function
              | `Assoc fields ->
                (match List.assoc_opt "uuid" fields with
                 | Some (`String uuid) -> Some uuid
                 | _ -> None)
              | _ -> None)
            blocks
        in
        assert_bool
          "legacy pending blocks must not leak outside the open graph projection"
          (not (List.mem "local-restart" uuids));
        assert_bool
          "server graph block should remain visible"
          (List.mem "remote-existing" uuids)))
;;

let () =
  with_temp_db (fun path ->
    let first_session = Logseq_chat_lg_core_native.logseq_chat_sqlite_open_session path in
    let catalog =
      {|{"graphs":[{"graph-id":"plain-graph","graph-name":"Sync 2","graph-e2ee?":false,"graph-ready-for-use?":true},{"graph-id":"encrypted-graph","graph-name":"Private","graph-e2ee?":true,"graph-ready-for-use?":false}]}|}
    in
    Logseq_chat_lg_core_native.logseq_chat_sqlite_store_string first_session "logseq-chat/graph-catalog/v1" catalog;
    Logseq_chat_lg_core_native.logseq_chat_sqlite_close first_session;

    let second_session = Logseq_chat_lg_core_native.logseq_chat_sqlite_open_session path in
    Fun.protect
      ~finally:(fun () -> Logseq_chat_lg_core_native.logseq_chat_sqlite_close second_session)
      (fun () ->
        match
          Logseq_chat_lg_core_native.logseq_chat_sqlite_restore_string
            second_session
            "logseq-chat/graph-catalog/v1"
        with
        | Some restored ->
          assert_equal "graph catalog should use a dedicated SQLite value" catalog restored
        | None -> failwith "graph catalog was not restored from SQLite"))
;;

let () =
  with_temp_db (fun path ->
    let first_session = Logseq_chat_lg_core_native.logseq_chat_sqlite_open_session path in
    Logseq_chat_lg_core_native.logseq_chat_sqlite_store_string
      first_session
      "logseq-chat/graph-catalog/v1"
      {|{"graphs":[{"graph-id":"plain-graph","graph-name":"Sync 2","graph-e2ee?":false,"graph-ready-for-use?":true}]}|};
    Logseq_chat_lg_core_native.logseq_chat_sqlite_close first_session;

    let second_session = Logseq_chat_lg_core_native.logseq_chat_sqlite_open_session path in
    Fun.protect
      ~finally:(fun () -> Logseq_chat_lg_core_native.logseq_chat_sqlite_close second_session)
      (fun () ->
        let rpc =
          Logseq_chat_rpc.create
            ~storage:(Logseq_chat_lg_core_native.logseq_chat_sqlite_storage second_session)
            ~load_graph_catalog:(fun () ->
              Logseq_chat_lg_core_native.logseq_chat_sqlite_restore_string
                second_session
                "logseq-chat/graph-catalog/v1")
            ()
        in
        let response =
          Logseq_chat_rpc.call
            rpc
            {|{"apiVersion":1,"method":"dispatch","params":{"action":"configure","payload":"{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-graph\",\"token\":\"\"}"}}|}
          |> Yojson.Basic.from_string
        in
        match response with
        | `Assoc fields ->
          (match List.assoc_opt "result" fields with
           | Some (`Assoc result) ->
             (match List.assoc_opt "graphName" result, List.assoc_opt "graphs" result with
              | Some (`String "Sync 2"), Some (`List [ _ ]) -> ()
              | _ -> failwith "RPC did not restore the selected graph from the cached catalog")
           | _ -> failwith "cached graph RPC response is missing result")
        | _ -> failwith "cached graph RPC response is not an object"))
;;

let () =
  with_temp_db (fun source_path ->
    with_temp_db (fun destination_path ->
      let source = Logseq_chat_lg_core_native.logseq_chat_sqlite_open_session source_path in
      let destination = Logseq_chat_lg_core_native.logseq_chat_sqlite_open_session destination_path in
      Fun.protect
        ~finally:(fun () ->
          Logseq_chat_lg_core_native.logseq_chat_sqlite_close source;
          Logseq_chat_lg_core_native.logseq_chat_sqlite_close destination)
        (fun () ->
          let catalog = {|{"graphs":[]}|} in
          Logseq_chat_lg_core_native.logseq_chat_sqlite_store_string
            source
            "logseq-chat/graph-catalog/v1"
            catalog;
          let legacy_model =
            (Logseq_chat_lg_core_native.logseq_chat_cache_model_create (Some ((Logseq_chat_lg_core_native.logseq_chat_sqlite_storage source))))
          in
          (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_asset (legacy_model) ("legacy-asset") ("photo.jpg") ("jpg") (4) ("abcd") ("Assets/photo.jpg") (1) None);
          Logseq_chat_lg_core_native.logseq_chat_sqlite_migrate_datascript_storage source destination;
          let migrated =
            (Logseq_chat_lg_core_native.logseq_chat_cache_model_create (Some ((Logseq_chat_lg_core_native.logseq_chat_sqlite_storage destination))))
          in
          assert_bool
            "legacy optimistic data should migrate into the graph projection"
            (List.length (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_pending_blocks (migrated))) = 1);
          let emptied_source =
            (Logseq_chat_lg_core_native.logseq_chat_cache_model_create (Some ((Logseq_chat_lg_core_native.logseq_chat_sqlite_storage source))))
          in
          assert_bool
            "legacy optimistic data should be removed from app-level storage"
            ((Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_pending_blocks (emptied_source))) = []);
          assert_bool
            "graph catalog metadata should remain in app-level storage"
            (Logseq_chat_lg_core_native.logseq_chat_sqlite_restore_string
               source
               "logseq-chat/graph-catalog/v1"
             = Some catalog))))
;;
