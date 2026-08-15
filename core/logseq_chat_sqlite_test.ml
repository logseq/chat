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

let () =
  with_temp_db (fun path ->
    let first_session = Logseq_chat_sqlite.open_session path in
    let first_model =
      Logseq_chat_model.create ~storage:(Logseq_chat_sqlite.storage first_session) ()
    in
    Logseq_chat_model.cache_local_message
      first_model
      ~uuid:"local-persisted"
      ~title:"Persisted offline capture"
      ~now:1_776_000_000_000;
    Logseq_chat_model.upsert_statuses
      first_model
      [ { uuid = "status-waiting"
        ; ident = Some "user.status/waiting"
        ; title = "Waiting"
        ; icon_type = Some "tabler-icon"
        ; icon_id = Some "clock"
        ; icon_color = Some "#7c3aed"
        }
      ];
    Logseq_chat_sqlite.close first_session;

    let second_session = Logseq_chat_sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Logseq_chat_sqlite.close second_session)
      (fun () ->
        let restored_model =
          Logseq_chat_model.create ~storage:(Logseq_chat_sqlite.storage second_session) ()
        in
        match Logseq_chat_model.read_block restored_model "local-persisted" with
        | None -> failwith "expected persisted block after reopening SQLite storage"
        | Some block ->
          assert_equal "title" "Persisted offline capture" block.title;
          assert_equal "sync status" "pending" block.sync_status;
          assert_bool
            "journal page id should be persisted"
            (String.length block.page_id >= 8
             && String.equal (String.sub block.page_id 0 8) "journal/");
          (match Logseq_chat_model.all_statuses restored_model with
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
    let first_store = Logseq_chat_sqlite.open_session path in
    let first_rpc =
      Logseq_chat_rpc.create ~storage:(Logseq_chat_sqlite.storage first_store) ()
    in
    ignore
      (Logseq_chat_rpc.call
         first_rpc
         {|{"apiVersion":1,"method":"dispatch","params":{"action":"send","payload":"{\"text\":\"Survives restart\",\"uuid\":\"local-restart\",\"now\":1776000000000}"}}|});
    Logseq_chat_sqlite.close first_store;

    let remote_block =
      Logseq_chat_model.
        { uuid = "remote-existing"
        ; kind = "block"
        ; title = "Existing server block"
        ; page_id = "journal/2026-04-13"
        ; parent_id = None
        ; order = None
        ; created_at = 1_776_000_000_001
        ; updated_at = 1_776_000_000_001
        ; sync_status = "synced"
        ; tags = []
        ; references = []
        ; status = None
        ; asset_type = None
        ; asset_size = None
        ; asset_checksum = None
        ; local_path = None
        }
    in
    let second_store = Logseq_chat_sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Logseq_chat_sqlite.close second_store)
      (fun () ->
        let second_rpc =
          Logseq_chat_rpc.create
            ~storage:(Logseq_chat_sqlite.storage second_store)
            ~graph_blocks:(fun () -> Some [ remote_block ])
            ()
        in
        Logseq_chat_model.upsert_journal_page
          second_rpc.model ~uuid:"journal/2026-04-13" ~journal_day:20260413;
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
          "persisted pending block should remain visible with an open graph"
          (List.mem "local-restart" uuids);
        assert_bool
          "server graph block should remain visible"
          (List.mem "remote-existing" uuids)))
;;

let () =
  with_temp_db (fun path ->
    let first_session = Logseq_chat_sqlite.open_session path in
    let catalog =
      {|{"graphs":[{"graph-id":"plain-graph","graph-name":"Sync 2","graph-e2ee?":false,"graph-ready-for-use?":true},{"graph-id":"encrypted-graph","graph-name":"Private","graph-e2ee?":true,"graph-ready-for-use?":false}]}|}
    in
    Logseq_chat_sqlite.store_string first_session ~address:"logseq-chat/graph-catalog/v1" catalog;
    Logseq_chat_sqlite.close first_session;

    let second_session = Logseq_chat_sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Logseq_chat_sqlite.close second_session)
      (fun () ->
        match
          Logseq_chat_sqlite.restore_string
            second_session
            ~address:"logseq-chat/graph-catalog/v1"
        with
        | Some restored ->
          assert_equal "graph catalog should use a dedicated SQLite value" catalog restored
        | None -> failwith "graph catalog was not restored from SQLite"))
;;

let () =
  with_temp_db (fun path ->
    let first_session = Logseq_chat_sqlite.open_session path in
    Logseq_chat_sqlite.store_string
      first_session
      ~address:"logseq-chat/graph-catalog/v1"
      {|{"graphs":[{"graph-id":"plain-graph","graph-name":"Sync 2","graph-e2ee?":false,"graph-ready-for-use?":true}]}|};
    Logseq_chat_sqlite.close first_session;

    let second_session = Logseq_chat_sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Logseq_chat_sqlite.close second_session)
      (fun () ->
        let rpc =
          Logseq_chat_rpc.create
            ~storage:(Logseq_chat_sqlite.storage second_session)
            ~load_graph_catalog:(fun () ->
              Logseq_chat_sqlite.restore_string
                second_session
                ~address:"logseq-chat/graph-catalog/v1")
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
