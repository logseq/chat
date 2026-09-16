open Yojson.Basic

module LG = Logseq_chat_lg_core_native

let assoc name fields = List.assoc_opt name fields

let required_assoc name fields =
  match assoc name fields with
  | Some (`Assoc value) -> value
  | _ -> failwith ("missing object field: " ^ name)
;;

let required_list name fields =
  match assoc name fields with
  | Some (`List value) -> value
  | _ -> failwith ("missing list field: " ^ name)
;;

let required_first_assoc name fields =
  match required_list name fields with
  | `Assoc value :: _ -> value
  | _ -> failwith ("missing object in list field: " ^ name)
;;

let required_string name fields =
  match assoc name fields with
  | Some (`String value) -> value
  | _ -> failwith ("missing string field: " ^ name)
;;

let required_int name fields =
  match assoc name fields with
  | Some (`Int value) -> value
  | _ -> failwith ("missing int field: " ^ name)
;;

let required_bool name fields =
  match assoc name fields with
  | Some (`Bool value) -> value
  | _ -> failwith ("missing bool field: " ^ name)
;;

let assert_equal label expected actual =
  if not (String.equal expected actual)
  then
    failwith
      (Printf.sprintf "%s: expected %S, got %S" label expected actual)
;;

let assert_int_equal label expected actual =
  if expected <> actual
  then
    failwith
      (Printf.sprintf "%s: expected %d, got %d" label expected actual)
;;

let contains text fragment =
  try
    ignore (Str.search_forward (Str.regexp_string fragment) text 0);
    true
  with Not_found -> false
;;

let encrypted_graph_catalog =
  {|{"graphs":[{"graph-id":"encrypted-1","graph-name":"Private","graph-e2ee?":true,"graph-ready-for-use?":true}]}|}
;;

let plain_graph_catalog =
  {|{"graphs":[{"graph-id":"plain-1","graph-name":"Plain","graph-e2ee?":false,"graph-ready-for-use?":true}]}|}
;;

let configure_plain_graph session =
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"configure","payload":"{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}"}}|})
;;

let configure_encrypted_graph session =
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"configure","payload":"{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"\",\"token\":\"access\"}"}}|})
;;

let pending_request response =
  match from_string response with
  | `Assoc fields ->
    let result = required_assoc "result" fields in
    (match assoc "pendingSyncRequest" result with
     | Some (`Assoc request) -> Some request
     | Some `Null | None -> None
     | Some _ -> failwith "pendingSyncRequest must be an object or null")
  | _ -> failwith "pending sync should return an RPC response"
;;





let () =
  let parent =
    Logseq_chat_lg_core_native.
      { uuid = "page-parent"; title = "Parent"; page_id = "selected-page"
      ; parent_id = Some "selected-page"; order = Some "a0"; created_at = 1; updated_at = 1
      ; sync_status = "synced"; tags = []; references = []; breadcrumbs = []
      ; status = None; is_asset = false; asset_type = None; asset_size = None
      ; asset_checksum = None; local_path = None; journal = None
      }
  in
  let projected = ref [ parent ] in
  let stage (operation : Logseq_chat_lg_core_native.pending_operation) =
    (match operation.intent with
     | Create_asset
         { uuid; title; page_uuid; parent_uuid; order; created_at; asset_type;
           asset_size; asset_checksum } ->
       projected :=
         !projected
         @ [ Logseq_chat_lg_core_native.
               { uuid; title; page_id = page_uuid; parent_id = Some parent_uuid
               ; order = Some order; created_at; updated_at = created_at
               ; sync_status = "pending"; tags = []; references = []; breadcrumbs = []
               ; status = None; is_asset = true; asset_type = Some asset_type
               ; asset_size = Some asset_size; asset_checksum = Some asset_checksum
               ; local_path = None; journal = None
               }
           ]
     | _ -> failwith "asset projection must stage Create_asset");
    Ok ()
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 5)
      ~graph_page_blocks:(fun page_id ->
        if String.equal page_id "selected-page" then Some !projected else Some [])
      ~stage_operation:stage
      ~prepare_operation:(fun operation ->
        Ok
          ( (Logseq_chat_lg_core_native.logseq_chat_pending_ops_outliner_op
               operation.Logseq_chat_lg_core_native.intent)
          , "[]" ))
      ()
  in
  configure_plain_graph session;
  session.selected_sidebar_page <-
    Some Logseq_chat_lg_core_native.{ uuid = "selected-page"; title = "Selected page" };
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"visible-asset\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"page-parent\"}"}}|}
    |> from_string
  in
  let fields = match response with `Assoc fields -> fields | _ -> failwith "missing RPC response" in
  let result = required_assoc "result" fields in
  let rows = required_list "outlinerRows" result in
  if
    not
      (List.exists
         (function
           | `Assoc fields ->
             let block = required_assoc "block" fields in
             String.equal (required_string "uuid" block) "visible-asset"
           | _ -> false)
         rows)
  then failwith "targeted local asset must appear immediately on a selected page"
;;



let () =
  let imported = ref None in
  let session =
    Logseq_chat_rpc.create
      ~import_snapshot:(fun payload ->
        imported := Some payload;
        Ok ())
      ()
  in
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"importSnapshot","payload":"snapshot-payload"}}|}
    |> from_string
  in
  (match response with
   | `Assoc fields ->
     (match assoc "ok" fields with
      | Some (`Bool true) -> ()
      | _ -> failwith "importSnapshot should return success")
   | _ -> failwith "importSnapshot should return an RPC response");
  if !imported <> Some "snapshot-payload"
  then failwith "importSnapshot did not call the native importer"
;;

let () =
  let authoritative =
    Logseq_chat_lg_core_native.
      { uuid = "restored-journal-block"
      ; title = "Restored from the graph snapshot"
      ; page_id = "journal-page"
      ; parent_id = Some "journal-page"
      ; order = Some "a0"
      ; created_at = 1_776_000_000_000
      ; updated_at = 1_776_000_000_000
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
      ; journal = Some ("Aug 15th, 2026", 20260815)
      }
  in
  let graph_blocks_calls = ref 0 in
  let graph_sidebar_pages_calls = ref 0 in
  let session =
    Logseq_chat_rpc.create
      ~open_graph:(fun _payload -> Ok ())
      ~graph_blocks:(fun () ->
        incr graph_blocks_calls;
        Some [ authoritative ])
      ~graph_sidebar_pages:(fun () ->
        incr graph_sidebar_pages_calls;
        Some Logseq_chat_lg_core_native.{ favorites = Rrbvec.of_list []; recent_pages = Rrbvec.of_list [] })
      ()
  in
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"openGraph","payload":"{}"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    assert_int_equal
      "openGraph reads its visible journal projection once"
      1
      !graph_blocks_calls;
    assert_int_equal
      "openGraph reads sidebar autocomplete pages once"
      1
      !graph_sidebar_pages_calls;
    let blocks = required_assoc "result" fields |> required_list "blocks" in
    (match blocks with
     | [ `Assoc block ] ->
       assert_equal
         "restored graph block uuid"
         "restored-journal-block"
         (required_string "uuid" block);
       assert_int_equal "restored graph journal day" 20260815 (required_int "journalDay" block)
     | _ -> failwith "openGraph should expose restored journal blocks without a local model copy")
  | _ -> failwith "openGraph should return an RPC response"
;;

let assert_dispatch_block action payload expected_uuid =
  let session = Logseq_chat_rpc.create () in
  let request =
    `Assoc
      [ "apiVersion", `Int 1
      ; "method", `String "dispatch"
      ; "params", `Assoc [ "action", `String action; "payload", `String payload ]
      ]
    |> to_string
  in
  match Logseq_chat_rpc.call session request |> from_string with
  | `Assoc fields ->
    let blocks = required_assoc "result" fields |> required_list "blocks" in
    (match blocks with
     | `Assoc block :: _ ->
       assert_equal (action ^ " uuid") expected_uuid (required_string "uuid" block)
     | _ -> failwith (action ^ " should return one optimistic block"))
  | _ -> failwith (action ^ " should return an RPC response")
;;

let () =
  assert_dispatch_block
    "sendTask"
    {|{"text":"Follow up","uuid":"task-local","now":1776000000000,"status":{"uuid":"status-waiting","ident":"user.status/waiting","title":"Waiting","iconType":"tabler-icon","iconId":"clock"}}|}
    "task-local";
  assert_dispatch_block
    "addAsset"
    {|{"uuid":"asset-local","title":"photo.jpg","now":1776000000001,"assetType":"jpg","assetSize":2048,"assetChecksum":"abc","localPath":"/documents/photo.jpg"}|}
    "asset-local"
;;

let () =
  let session = Logseq_chat_rpc.create () in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_upsert_blocks (session.model) (List.to_seq, ([ Logseq_chat_lg_core_native.
        { uuid = "editing-block"; title = "Editing"; page_id = "target-page"
        ; parent_id = Some "target-page"; order = None; created_at = 1; updated_at = 1
        ; sync_status = "synced"; tags = []; references = []; breadcrumbs = []
        ; status = None; is_asset = false; asset_type = None; asset_size = None
        ; asset_checksum = None; local_path = None; journal = None
        }
    ])) (1));
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"targeted-asset\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"editing-block\"}"}}|});
  let asset = Option.get (Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block session.model "targeted-asset") in
  assert_equal "RPC targeted asset page" "target-page" asset.page_id;
  assert_equal "RPC targeted asset parent" "editing-block" (Option.get asset.parent_id)
;;

let () =
  let target =
    Logseq_chat_lg_core_native.
      { uuid = "editing-block"; title = "Editing"; page_id = "local-page"
      ; parent_id = Some "local-page"; order = None; created_at = 1; updated_at = 1
      ; sync_status = "synced"; tags = []; references = []; breadcrumbs = []
      ; status = None; is_asset = false; asset_type = None; asset_size = None
      ; asset_checksum = None; local_path = None; journal = None
      }
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~graph_blocks:(fun () -> Some [ target ])
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"targeted-upload\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"editing-block\"}"}}|});
  let request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
    |> Option.get
  in
  let url = required_string "url" request in
  assert_equal
    "targeted asset raw URL uses its stable block UUID"
    "http://127.0.0.1:8787/assets/plain-1/targeted-upload.m4a"
    url
;;

let () =
  let session =
    Logseq_chat_rpc.create ~load_graph_catalog:(fun () -> Some plain_graph_catalog) ()
  in
  configure_plain_graph session;
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"shared-image\",\"title\":\"IMG_0002\",\"now\":2,\"assetType\":\"image/jpeg\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"Assets/shared-IMG_0002.JPG\"}"}}|}
    |> from_string
  in
  (match response with
   | `Assoc fields ->
     let result = required_assoc "result" fields in
     if not (required_bool "isOutlinerPatch" result)
     then failwith "shared assets must insert into the visible journal incrementally";
     (match required_list "outlinerRowSplices" result with
      | [ `Assoc splice ] ->
        (match required_list "rows" splice with
         | [ `Assoc row ] ->
           assert_equal
             "shared asset row"
             "shared-image"
             (required_assoc "block" row |> required_string "uuid")
         | _ -> failwith "shared asset patch must insert one visible row")
      | _ -> failwith "shared asset patch must contain one bounded row splice")
   | _ -> failwith "shared asset should return an RPC response");
  let asset = Option.get (Logseq_chat_lg_core_native.logseq_chat_cache_model_read_block session.model "shared-image") in
  assert_equal "shared asset stores normalized type" "jpeg" (Option.get asset.asset_type);
  let request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
    |> Option.get
  in
  let url = required_string "url" request in
  assert_equal
    "shared asset upload uses its normalized extension"
    "http://127.0.0.1:8787/assets/plain-1/shared-image.jpeg"
    url;
  assert_equal
    "shared asset upload content type"
    "image/jpeg"
    (required_string "contentType" request)
;;

let () =
  let session = Logseq_chat_rpc.create () in
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"configure","payload":"{\"baseUrl\":\"https://api.example\",\"graphId\":\"plain-1\",\"token\":\"\"}"}}|});
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"offline-shared-image\",\"title\":\"IMG_0002.JPG\",\"now\":2,\"assetType\":\"image/jpeg\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"Assets/shared-IMG_0002.JPG\"}"}}|});
  let request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
  in
  if Option.is_some request
  then failwith "pending asset sync must wait for authenticated configuration";
  configure_plain_graph session;
  let authenticated_request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
  in
  if Option.is_none authenticated_request
  then failwith "pending asset sync must resume after authenticated configuration"
;;

let () =
  let applied = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~apply_sync_event:(fun payload ->
        applied := payload :: !applied;
        Ok ())
      ()
  in
  let started =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"startWebSocket"}}|}
    |> from_string
  in
  let applied_response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"applySyncEvent","payload":"wire-event"}}|}
    |> from_string
  in
  let stopped =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"stopWebSocket"}}|}
    |> from_string
  in
  let assert_ok label = function
    | `Assoc fields ->
      (match assoc "ok" fields with
       | Some (`Bool true) -> ()
       | _ -> failwith (label ^ " should succeed"))
    | _ -> failwith (label ^ " should return an RPC response")
  in
  assert_ok "startWebSocket" started;
  assert_ok "applySyncEvent" applied_response;
  assert_ok "stopWebSocket" stopped;
  if !applied <> [ "wire-event" ]
  then failwith "applySyncEvent should apply exactly one WebSocket event"
;;

let () =
  let authoritative_blocks = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~apply_sync_event:(fun _event ->
        authoritative_blocks :=
          [ Logseq_chat_lg_core_native.
              { uuid = "local-self-echo"
              ; title = "Synced capture"
              ; page_id = "journal/2026-08-15"
              ; parent_id = None
              ; order = None
              ; created_at = 1_776_000_000_000
              ; updated_at = 1_776_000_000_000
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
          ];
        Ok ())
      ~graph_blocks:(fun () -> Some !authoritative_blocks)
      ()
  in
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"send","payload":"{\"text\":\"Synced capture\",\"uuid\":\"local-self-echo\",\"now\":1776000000000}"}}|});
  if List.length (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_pending_blocks (session.model))) <> 1
  then failwith "local capture should start pending";
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"applySyncEvent","payload":"self-echo"}}|});
  if (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_pending_blocks (session.model))) <> []
  then failwith "authoritative WebSocket self-echo should clear local pending state"
;;

let () =
  let authoritative_blocks = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~graph_blocks:(fun () -> Some !authoritative_blocks)
      ()
  in
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"synced-asset\",\"title\":\"photo.png\",\"now\":1776000000001,\"assetType\":\"png\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/photo.png\"}"}}|});
  ignore (Logseq_chat_lg_core_native.logseq_chat_cache_model_mark_block_synced (session.model) ("synced-asset"));
  authoritative_blocks :=
    [ Logseq_chat_lg_core_native.
        { uuid = "synced-asset"
        ; title = "photo.png"
        ; page_id = "journal/2026-08-15"
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
        ; journal = Some ("Aug 15th, 2026", 20260815)
        }
    ];
  let response =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"clearRelated"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    let blocks = required_assoc "result" fields |> required_list "blocks" in
    (match blocks with
     | [ `Assoc block ] ->
       assert_equal
         "synced asset local path"
         "/documents/photo.png"
         (required_string "localPath" block)
     | _ -> failwith "authoritative asset should remain visible with local metadata")
  | _ -> failwith "snapshot should return an RPC response"
;;

let () =
  let session = Logseq_chat_rpc.create () in
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"sendTask","payload":"{\"text\":\"Follow up\",\"uuid\":\"task-status-local\",\"now\":1776000000000,\"status\":{\"uuid\":\"todo\",\"ident\":\"logseq.property/status.todo\",\"title\":\"Todo\"}}"}}|});
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"updateBlockStatus","payload":"{\"uuid\":\"task-status-local\",\"status\":{\"uuid\":\"custom-waiting\",\"ident\":\"user.status/waiting\",\"title\":\"Waiting\",\"iconType\":\"tabler-icon\",\"iconId\":\"clock\",\"iconColor\":\"#7c3aed\"}}"}}|}
  in
  match from_string response with
  | `Assoc fields ->
    let result = required_assoc "result" fields in
    (match required_list "blocks" result with
     | [ `Assoc block ] ->
       let status = required_assoc "status" block in
       assert_equal "updated task status uuid" "custom-waiting" (required_string "uuid" status);
       assert_equal
         "updated task status color"
         "#7c3aed"
         (required_string "color" (required_assoc "icon" status))
     | _ -> failwith "updateBlockStatus should return the updated task")
  | _ -> failwith "updateBlockStatus should return an RPC response"
;;

let remote_block uuid title =
  Logseq_chat_lg_core_native.
    { uuid
    ; title
    ; page_id = "page"
    ; parent_id = Some "page"
    ; order = Some "a0"
    ; created_at = 1
    ; updated_at = 1
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
;;

let () =
  let session =
    Logseq_chat_rpc.create ~apply_sync_event:(fun _ -> Error "sync schema mismatch") ()
  in
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"applySyncEvent","payload":"remote-change"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    let error = required_assoc "error" fields in
    assert_equal
      "schema mismatch recovery code"
      "snapshot_required"
      (required_string "code" error)
  | _ -> failwith "schema mismatch should request a fresh snapshot"
;;

let () =
  (* Receiving authoritative sync while the inline editor is active must not
     cancel editing or hide the remote change. *)
  let authoritative = ref [ remote_block "editing-sync" "Local draft"; remote_block "remote-sync" "Before" ] in
  let session =
    Logseq_chat_rpc.create
      ~graph_blocks:(fun () -> Some !authoritative)
      ~apply_sync_event:(fun _ ->
        authoritative := [ remote_block "editing-sync" "Local draft"; remote_block "remote-sync" "After" ];
        Ok ())
      ()
  in
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"outlinerEvent","payload":"{\"type\":\"tapBlock\",\"uuid\":\"editing-sync\"}"}}|});
  let synced =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"applySyncEvent","payload":"remote-change"}}|}
    |> from_string
  in
  match synced with
  | `Assoc fields ->
    let result = required_assoc "result" fields in
    let editing = required_assoc "editing" (required_assoc "outlinerState" result) in
    assert_equal "sync preserves active editor" "editing-sync" (required_string "uuid" editing);
    let rows = required_list "outlinerRows" result in
    if not
         (List.exists
            (function
              | `Assoc row ->
                (match List.assoc_opt "block" row with
                 | Some (`Assoc block) ->
                   List.assoc_opt "uuid" block = Some (`String "remote-sync")
                   && List.assoc_opt "title" block = Some (`String "After")
                 | _ -> false)
              | _ -> false)
            rows)
    then
      failwith
        ("sync received while editing must update the visible projection: "
         ^ Yojson.Basic.to_string synced)
  | _ -> failwith "applySyncEvent while editing should return a snapshot"
;;

let prepare_test_operation operation =
  Ok
    ( (Logseq_chat_lg_core_native.logseq_chat_pending_ops_outliner_op
         operation.Logseq_chat_lg_core_native.intent)
    , "[]" )
;;

let () =
  (* A local capture must enter the projected graph before any network work.
     Journal home, node views, and inline editing must query that same state. *)
  let page : Logseq_chat_lg_core_native.entity_summary = Logseq_chat_lg_core_native.{ uuid = "journal-page"; title = "Aug 23rd, 2026" } in
  let projected =
    ref
      [ { (remote_block "world" "World") with
          Logseq_chat_lg_core_native.page_id = page.uuid
        ; parent_id = Some page.uuid
        ; journal = Some (page.title, 20260823)
        }
      ]
  in
  let staged = ref [] in
  let stage (operation : Logseq_chat_lg_core_native.pending_operation) =
    staged := !staged @ [ operation ];
    (match operation.intent with
     | Insert_block { uuid; title; page_uuid; parent_uuid; order; created_at } ->
       projected :=
         !projected
         @ [ Logseq_chat_lg_core_native.
               { uuid; title; page_id = page_uuid; parent_id = Some parent_uuid
               ; order = Some order; created_at; updated_at = created_at
               ; sync_status = "pending"; tags = []; references = []; breadcrumbs = []
               ; status = None; is_asset = false; asset_type = None; asset_size = None
               ; asset_checksum = None; local_path = None
               ; journal = Some (page.title, 20260823)
               }
           ]
     | _ -> failwith "plain capture must stage an insert-block operation");
    Ok ()
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 5)
      ~journal_page_id:(fun ~journal_day:_ -> Some page.uuid)
      ~graph_blocks:(fun () -> Some !projected)
      ~graph_page_blocks:(fun uuid ->
        Some (List.filter (fun block -> String.equal block.Logseq_chat_lg_core_native.page_id uuid) !projected))
      ~graph_node_destination:(fun uuid ->
        if String.equal uuid page.uuid then Some (page, false) else None)
      ~stage_operation:stage
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  let captured =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"send","payload":"{\"text\":\"hello\",\"uuid\":\"local-hello\",\"now\":1787469000000}"}}|}
    |> from_string
  in
  (match !staged with
   | [ { Logseq_chat_lg_core_native.intent = Insert_block { uuid = "local-hello"; _ }; _ } ] -> ()
   | _ -> failwith "plain local capture was not staged in the projected graph");
  (match captured with
   | `Assoc fields ->
     let blocks = required_assoc "result" fields |> required_list "blocks" in
     if not (List.exists (function
       | `Assoc block -> assoc "uuid" block = Some (`String "local-hello")
       | _ -> false) blocks)
     then failwith "journal home did not read the projected local capture"
   | _ -> failwith "plain capture should return a snapshot");
  let opened =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"openNode","payload":"{\"uuid\":\"journal-page\"}"}}|}
    |> from_string
  in
  (match opened with
   | `Assoc fields ->
     let route = required_assoc "result" fields |> required_first_assoc "nodeRoutes" in
     let blocks = required_list "blocks" route in
     if not (List.exists (function
       | `Assoc block -> assoc "uuid" block = Some (`String "local-hello")
       | _ -> false) blocks)
     then failwith "journal node did not read the projected local capture"
   | _ -> failwith "opening the projected journal should succeed");
  let tapped =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"outlinerEvent","payload":"{\"type\":\"tapBlock\",\"uuid\":\"local-hello\"}"}}|}
    |> from_string
  in
  match tapped with
  | `Assoc fields ->
    let route = required_assoc "result" fields |> required_first_assoc "nodeRoutes" in
    let editing = required_assoc "outlinerState" route |> required_assoc "editing" in
    assert_equal "projected local block remains editable" "local-hello" (required_string "uuid" editing)
  | _ -> failwith "tapping the projected local block should start editing"
;;

let () =
  (* Child insertion has the same local-first contract as capture: the staged
     projection is the only source read by the returned snapshot and editor. *)
  let page : Logseq_chat_lg_core_native.entity_summary = Logseq_chat_lg_core_native.{ uuid = "child-page"; title = "Child page" } in
  let parent =
    { (remote_block "child-parent" "Parent") with
      Logseq_chat_lg_core_native.page_id = page.uuid
    ; parent_id = Some page.uuid
    ; order = Some "a0"
    }
  in
  let projected = ref [ parent ] in
  let staged = ref [] in
  let stage (operation : Logseq_chat_lg_core_native.pending_operation) =
    staged := !staged @ [ operation ];
    (match operation.intent with
     | Insert_block { uuid; title; page_uuid; parent_uuid; order; created_at } ->
       projected :=
         !projected
         @ [ Logseq_chat_lg_core_native.
               { uuid; title; page_id = page_uuid; parent_id = Some parent_uuid
               ; order = Some order; created_at; updated_at = created_at
               ; sync_status = "pending"; tags = []; references = []; breadcrumbs = []
               ; status = None; is_asset = false; asset_type = None; asset_size = None
               ; asset_checksum = None; local_path = None; journal = None
               }
           ]
     | _ -> failwith "addChildBlock must stage an insert-block operation");
    Ok ()
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 5)
      ~graph_blocks:(fun () -> Some !projected)
      ~graph_page_blocks:(fun uuid ->
        Some (List.filter (fun block -> String.equal block.Logseq_chat_lg_core_native.page_id uuid) !projected))
      ~stage_operation:stage
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  let added =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"addChildBlock","payload":"{\"uuid\":\"local-child\",\"title\":\"Child\",\"parentId\":\"child-parent\",\"now\":10}"}}|}
    |> from_string
  in
  (match !staged with
   | [ { Logseq_chat_lg_core_native.intent =
           Insert_block { uuid = "local-child"; page_uuid = "child-page";
                          parent_uuid = "child-parent"; _ }
       ; _ } ] -> ()
   | _ -> failwith "local child was not staged in the projected graph");
  (match added with
   | `Assoc fields ->
     let blocks = required_assoc "result" fields |> required_list "blocks" in
     if not (List.exists (function
       | `Assoc block -> assoc "uuid" block = Some (`String "local-child")
       | _ -> false) blocks)
     then failwith "child snapshot did not read the projected insertion"
   | _ -> failwith "addChildBlock should return a snapshot")
;;

let () =
  (* Once a graph runtime is present, legacy Model contents must never leak
     into UI reads. Otherwise journals and node views can disagree. *)
  let projected = remote_block "projected-only" "Projected" in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~graph_blocks:(fun () -> Some [ projected ])
      ()
  in
  (Logseq_chat_lg_core_native.logseq_chat_cache_model_cache_local_message (session.model) ("legacy-only") ("Must not leak") (10));
  configure_plain_graph session;
  let snapshot =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"configure","payload":"{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}"}}|}
    |> from_string
  in
  match snapshot with
  | `Assoc fields ->
    let blocks = required_assoc "result" fields |> required_list "blocks" in
    if List.exists (function
      | `Assoc block -> assoc "uuid" block = Some (`String "legacy-only")
      | _ -> false) blocks
    then failwith "snapshot leaked a block outside the projection database"
  | _ -> failwith "configure should return a projected snapshot"
;;

let () =
  let staged = ref [] in
  let target =
    { (remote_block "editing-block" "Editing") with
      Logseq_chat_lg_core_native.page_id = "target-page"
    ; parent_id = Some "target-page"
    ; order = Some "a0"
    }
  in
  let projected = ref [ target ] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 41)
      ~graph_blocks:(fun () -> Some !projected)
      ~authoritative_graph_blocks:(fun () -> Some [ target ])
      ~journal_page_id:(fun ~journal_day:_ -> Some "journal-page")
      ~stage_operation:(fun operation ->
        staged := !staged @ [ operation ];
        (match operation.Logseq_chat_lg_core_native.intent with
         | Create_asset { uuid; title; _ } ->
           projected := [target; { (remote_block uuid title) with is_asset = true }]
         | _ -> ());
        Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"2f659891-3fbc-492c-8943-9e08de2ed949\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"editing-block\"}"}}|});
  (match !staged with
   | [ { Logseq_chat_lg_core_native.state = Applied
       ; intent = Create_asset { uuid = "2f659891-3fbc-492c-8943-9e08de2ed949"; _ }
       ; _ } ] -> ()
   | _ -> failwith "local asset must enter projection before its raw upload");
  let upload =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
    |> Option.get
  in
  assert_equal "plain asset raw method" "PUT" (required_string "method" upload);
  assert_equal
    "plain asset raw URL"
    "http://127.0.0.1:8787/assets/plain-1/2f659891-3fbc-492c-8943-9e08de2ed949.m4a"
    (required_string "url" upload);
  let tx_request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":1,\"status\":200,\"body\":\"{\\\"ok\\\":true}\",\"error\":null}"}}|}
    |> pending_request
    |> Option.get
  in
  assert_equal
    "plain asset datom URL"
    "http://127.0.0.1:8787/sync/plain-1/tx/batch"
    (required_string "url" tx_request);
  let txs = required_assoc "bodyObject" tx_request |> required_list "txs" in
  (match txs with
   | [ `Assoc tx ] ->
     assert_equal "asset batch transaction ID is its stable UUID"
       "2f659891-3fbc-492c-8943-9e08de2ed949" (required_string "tx-id" tx)
   | _ -> failwith "asset batch must contain one transaction");
  (match !staged with
   | [ { Logseq_chat_lg_core_native.state = Applied; _ }
     ; { state = Queued
       ; intent = Create_asset { uuid; page_uuid; parent_uuid; order; _ }
       ; _ } ] ->
     assert_equal "plain asset UUID" "2f659891-3fbc-492c-8943-9e08de2ed949" uuid;
     assert_equal "plain asset page" "target-page" page_uuid;
     assert_equal "plain asset parent" "editing-block" parent_uuid;
     if String.equal order "" then failwith "plain asset must have an outliner order"
   | _ -> failwith "plain asset upload must stage one durable asset datom operation")
;;

let () =
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 41)
      ~journal_page_id:(fun ~journal_day:_ -> Some "journal-page")
      ~stage_operation:(fun operation ->
        staged := operation :: !staged;
        Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"retry-asset\",\"title\":\"photo.png\",\"now\":2,\"assetType\":\"png\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/photo.png\"}"}}|});
  let first =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":1,\"status\":null,\"body\":null,\"error\":\"offline\"}"}}|});
  (match !staged with
   | [ { Logseq_chat_lg_core_native.state = Applied
       ; intent = Create_asset { uuid = "retry-asset"; _ }
       ; _ } ] -> ()
   | _ -> failwith "failed raw upload must keep only its local asset projection");
  let retry =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  assert_equal "failed raw asset upload retries the same URL"
    (required_string "url" first)
    (required_string "url" retry)
;;

let () =
  let staged = ref [] in
  let existing =
    { (remote_block "existing-journal-block" "Existing") with
      Logseq_chat_lg_core_native.page_id = "journal-page"
    ; parent_id = Some "journal-page"
    ; order = Some "a0"
    }
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some encrypted_graph_catalog)
      ~graph_unlocked:(fun ~graph_id:_ -> true)
      ~sync_cursor:(fun () -> Some 91)
      ~graph_blocks:(fun () -> Some [ existing ])
      ~journal_page_id:(fun ~journal_day:_ -> Some "journal-page")
      ~stage_operation:(fun operation ->
        staged := !staged @ [ operation ];
        Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_encrypted_graph session;
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"selectGraph","payload":"encrypted-1"}}|});
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"send","payload":"{\"text\":\"Encrypted capture\",\"uuid\":\"encrypted-capture\",\"now\":1776000000000}"}}|});
  (match !staged with
   | [ { Logseq_chat_lg_core_native.intent =
           Insert_block { uuid; title; page_uuid; parent_uuid; order; _ }
       ; _
       } ] ->
     assert_equal "encrypted capture uuid" "encrypted-capture" uuid;
     assert_equal "encrypted capture title" "Encrypted capture" title;
     assert_equal "encrypted capture page" "journal-page" page_uuid;
     assert_equal "encrypted capture parent" "journal-page" parent_uuid;
     if String.compare order "a0" <= 0
     then failwith "encrypted capture must append after the last journal block"
   | _ -> failwith "encrypted capture must stage one persistent insert operation");
  let request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
    |> Option.get
  in
  assert_equal
    "encrypted capture tx URL"
    "http://127.0.0.1:8787/sync/encrypted-1/tx/batch"
    (required_string "url" request);
  if contains (required_string "url" request) "/capture"
  then failwith "encrypted captures must never use the semantic capture API"
;;

let dispatch_outliner session payload =
  let request =
    `Assoc
      [ "apiVersion", `Int 1
      ; "method", `String "dispatch"
      ; ( "params"
        , `Assoc
            [ "action", `String "outlinerEvent"
            ; "payload", `String (to_string payload)
            ] )
      ]
    |> to_string
  in
  match Logseq_chat_rpc.call session request |> from_string with
  | `Assoc fields when required_bool "ok" fields -> required_assoc "result" fields
  | `Assoc fields ->
    let error = required_assoc "error" fields in
    failwith ("outliner event failed: " ^ required_string "message" error)
  | _ -> failwith "outliner event should return an RPC response"
;;

let () =
  let parent = remote_block "parent-window" "Parent" in
  let child =
    { (remote_block "child-window" "Child") with
      Logseq_chat_lg_core_native.parent_id = Some parent.uuid
    }
  in
  let assert_state_preserved label event =
    let session =
      Logseq_chat_rpc.create
        ~graph_blocks:(fun () -> Some [ parent; child ])
        ~load_older_journals:(fun () -> ())
        ~has_older_journals:(fun () -> true)
        ()
    in
    let before = dispatch_outliner session event |> required_assoc "outlinerState" in
    let after =
      match
        Logseq_chat_rpc.call session
          {|{"apiVersion":1,"method":"dispatch","params":{"action":"loadOlderJournals"}}|}
        |> from_string
      with
      | `Assoc fields -> required_assoc "result" fields |> required_assoc "outlinerState"
      | _ -> failwith "loadOlderJournals should return an RPC response"
    in
    if before <> after then failwith (label ^ " must survive journal pagination")
  in
  assert_state_preserved
    "editing state"
    (`Assoc [ "type", `String "tapBlock"; "uuid", `String child.uuid ]);
  assert_state_preserved
    "selection state"
    (`Assoc [ "type", `String "longPressBlock"; "uuid", `String child.uuid ]);
  assert_state_preserved
    "zoom state"
    (`Assoc [ "type", `String "zoomIn"; "uuid", `String parent.uuid ])
;;

let () =
  let session =
    Logseq_chat_rpc.create
      ~graph_blocks:(fun () -> Some [ remote_block "editable" "Hello" ])
      ()
  in
  let tapped =
    dispatch_outliner session (`Assoc [ "type", `String "tapBlock"; "uuid", `String "editable" ])
  in
  let editing = required_assoc "editing" (required_assoc "outlinerState" tapped) in
  assert_equal "outliner editing uuid" "editable" (required_string "uuid" editing);
  assert_equal "outliner editing title" "Hello" (required_string "title" editing);
  let commands = required_list "outlinerCommands" tapped in
  if commands <> [] then failwith "tap should not run a platform effect";
  let changed =
    dispatch_outliner
      session
      (`Assoc
        [ "type", `String "textChanged"
        ; "title", `String "Hello [[Pro"
        ; "caretUTF16Offset", `Int 11
        ])
  in
  let state = required_assoc "outlinerState" changed in
  let editing = required_assoc "editing" state in
  assert_equal "outliner draft is owned by core" "Hello [[Pro" (required_string "title" editing);
  let autocomplete = required_assoc "autocomplete" state in
  assert_equal "outliner autocomplete kind" "node" (required_string "kind" autocomplete);
  assert_equal "outliner autocomplete query" "Pro" (required_string "query" autocomplete)
;;

let () =
  let tag : Logseq_chat_lg_core_native.entity_summary = Logseq_chat_lg_core_native.{ uuid = "tag-uuid"; title = "Project" } in
  let session =
    Logseq_chat_rpc.create
      ~graph_blocks:(fun () -> Some [ remote_block "tag-editable" "Hello" ])
      ~graph_tag_pages:(fun () -> Some [ tag ])
      ()
  in
  ignore
    (dispatch_outliner
       session
       (`Assoc [ "type", `String "tapBlock"; "uuid", `String "tag-editable" ]));
  let response =
    dispatch_outliner
      session
      (`Assoc [ "type", `String "toolbar"; "action", `String "tag" ])
  in
  match required_list "outlinerAutocompleteCandidates" response with
  | [ `Assoc candidate ] ->
    assert_equal "tag candidate label" "Project" (required_string "label" candidate);
    assert_equal "tag candidate canonical value" "tag-uuid" (required_string "value" candidate)
  | _ -> failwith "tag autocomplete must be populated from graph Tag entities"
;;

let () =
  let staged = ref [] in
  let projected = ref [ remote_block "bounded-save" "Before" ] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 91)
      ~graph_blocks:(fun () -> Some !projected)
      ~stage_operation:(fun operation ->
        staged := operation :: !staged;
        (match operation.Logseq_chat_lg_core_native.intent with
         | Save_title { uuid; title; _ } ->
           projected :=
             List.map
               (fun (block : Logseq_chat_lg_core_native.block) ->
                 if String.equal block.uuid uuid then { block with title } else block)
               !projected
         | _ -> ());
        Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  ignore
    (dispatch_outliner
       session
       (`Assoc [ "type", `String "tapBlock"; "uuid", `String "bounded-save" ]));
  ignore
    (dispatch_outliner
       session
       (`Assoc
         [ "type", `String "textChanged"
         ; "title", `String "After"
         ; "caretUTF16Offset", `Int 5
         ]));
  let saved =
    dispatch_outliner
      session
      (`Assoc [ "type", `String "saveEditing" ])
  in
  if not (required_bool "isOutlinerPatch" saved)
  then failwith "saving an edited title must return a bounded patch";
  (match required_list "blocks" saved with
   | [ `Assoc block ] ->
     assert_equal "bounded saved block" "After" (required_string "title" block);
     if required_list "outlinerRows" saved <> []
        || required_list "outlinerRowSplices" saved <> []
     then failwith "a title save must update the existing row by block id"
   | _ -> failwith "a title save patch must contain exactly one block");
  let state = required_assoc "outlinerState" saved in
  (match List.assoc_opt "editing" state with
   | Some (`Assoc editing) ->
     assert_equal "autosave keeps editing" "bounded-save" (required_string "uuid" editing)
   | _ -> failwith "autosave must keep the block in editing mode");
  if List.length !staged <> 1 then failwith "idle autosave must stage one title save";
  ignore
    (dispatch_outliner session (`Assoc [ "type", `String "saveEditing" ]));
  if List.length !staged <> 1
  then failwith "a staged title must become the editing session's new expected title"
;;

let () =
  let staged = ref [] in
  let selected_block = remote_block "selected" "Selected" in
  let unrelated_tail =
    match LG.logseq_chat_fractional_order_n_between (Some "a0") None 100 with
    | Error message -> failwith message
    | Ok orders ->
      List.mapi
        (fun index order ->
          { (remote_block ("delete-tail-" ^ string_of_int index) "Unrelated") with
            Logseq_chat_lg_core_native.order = Some order
          })
        (Rrbvec.to_list orders)
  in
  let projected = ref (selected_block :: unrelated_tail) in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 91)
      ~graph_blocks:(fun () -> Some !projected)
      ~stage_operation:(fun operation ->
        staged := !staged @ [ operation ];
        (match operation.Logseq_chat_lg_core_native.intent with
         | Delete_blocks { uuids } ->
           (let uuids = Rrbvec.to_list uuids in
            projected :=
              (List.filter
                 (fun (block : Logseq_chat_lg_core_native.block) ->
                    not (List.exists (String.equal block.uuid) uuids)) (!projected)))
         | _ -> ());
        Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  let selected =
    dispatch_outliner
      session
      (`Assoc [ "type", `String "longPressBlock"; "uuid", `String "selected" ])
  in
  let state = required_assoc "outlinerState" selected in
  (match required_list "selectedBlockIds" state with
   | [ `String "selected" ] -> ()
   | _ -> failwith "long press selection must be owned by the core");
  let command = required_first_assoc "outlinerCommands" selected in
  assert_equal "long press haptic" "haptic" (required_string "type" command);
  ignore
    (dispatch_outliner
       session
       (`Assoc [ "type", `String "toolbar"; "action", `String "delete" ]));
  let confirmed = dispatch_outliner session (`Assoc [ "type", `String "confirmDelete" ]) in
  (match !staged with
   | [ { Logseq_chat_lg_core_native.base_t = 91
       ; intent = Delete_blocks { uuids }
       ; _ } ] when Rrbvec.to_list uuids = ["selected"] -> ()
   | _ -> failwith "confirmed outliner delete must stage one semantic operation");
  if not (required_bool "isOutlinerPatch" confirmed)
  then failwith "confirmed delete must use a bounded patch";
  if required_list "blocks" confirmed <> [] || required_list "outlinerRows" confirmed <> []
  then failwith "confirmed delete must not serialize unrelated page blocks";
  (match required_list "deletedBlockIds" confirmed with
   | [ `String "selected" ] -> ()
   | _ -> failwith "confirmed delete patch must name only the deleted block");
  (match required_list "outlinerRowSplices" confirmed with
   | [ `Assoc splice ]
     when required_int "start" splice = 0
          && required_int "deleteCount" splice = 1
          && required_list "rows" splice = [] -> ()
   | _ -> failwith "confirmed delete must remove one bounded row range");
  let selected_ids =
    required_assoc "outlinerState" confirmed |> required_list "selectedBlockIds"
  in
  if selected_ids <> [] then failwith "confirmed delete must clear core selection"
;;

let () =
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 92)
      ~graph_blocks:(fun () -> Some [ remote_block "task" "Task" ])
      ~stage_operation:(fun operation -> staged := !staged @ [ operation ]; Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  ignore
    (dispatch_outliner
       session
       (`Assoc
         [ "type", `String "setTaskStatus"
         ; "uuid", `String "task"
         ; "statusIdent", `String "user.status/waiting"
         ]));
  match !staged with
  | [ { Logseq_chat_lg_core_native.base_t = 92
      ; intent =
          Set_property
            { uuid = "task"; attr = "logseq.property/status"; expected = None;
              value = Some (Ref_ident "user.status/waiting") }
      ; _ } ] -> ()
  | _ -> failwith "outliner task status must stage a semantic property operation"
;;

let () =
  let parent = remote_block "parent" "Parent" in
  let child =
    { (remote_block "child" "Child") with
      Logseq_chat_lg_core_native.parent_id = Some "parent"
    }
  in
  let sibling =
    { (remote_block "sibling" "Sibling") with
      Logseq_chat_lg_core_native.order = Some "a1"
    }
  in
  let session =
    Logseq_chat_rpc.create
      ~graph_blocks:(fun () -> Some [ child; sibling; parent ])
      ()
  in
  let collapsed =
    dispatch_outliner
      session
      (`Assoc [ "type", `String "toggleCollapsed"; "uuid", `String "parent" ])
  in
  if required_list "outlinerRows" collapsed <> []
  then failwith "collapse must not return a full row projection";
  (match required_list "outlinerRowSplices" collapsed with
   | [ `Assoc splice ] ->
     if required_int "start" splice <> 0 || required_int "deleteCount" splice <> 2
     then failwith "collapse must replace only the parent and hidden child";
     (match required_list "rows" splice with
      | [ `Assoc parent_row ] ->
     assert_equal
       "collapsed first row"
       "parent"
       (required_assoc "block" parent_row |> required_string "uuid");
     if not (required_bool "isCollapsed" parent_row)
     then failwith "collapsed row must expose reducer state"
      | _ -> failwith "collapse splice must insert only the collapsed parent")
   | _ -> failwith "collapse must return one bounded row splice");
  let zoomed =
    dispatch_outliner
      session
      (`Assoc [ "type", `String "zoomIn"; "uuid", `String "parent" ])
  in
  if
    (required_assoc "outlinerState" zoomed
     |> required_list "zoomedBlockIds"
     |> List.map (function `String value -> value | _ -> failwith "zoom path must contain strings"))
    <> [ "parent" ]
  then failwith "zoom snapshot must expose the full native navigation path";
  (match required_list "outlinerRowSplices" zoomed with
   | [ `Assoc splice ]
     when required_int "start" splice = 1
          && required_int "deleteCount" splice = 1
          && required_list "rows" splice = [] -> ()
   | _ -> failwith "zoom must remove only rows outside the selected subtree")
;;

let () =
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_blocks:(fun () -> Some [ remote_block "remote" "Old" ])
      ~stage_operation:(fun operation -> staged := !staged @ [ operation ]; Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  let response =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"updateBlock","payload":"{\"uuid\":\"remote\",\"operationId\":\"op-title\",\"expectedTitle\":\"Old\",\"title\":\"Pending\",\"status\":null}"}}|}
    |> from_string
  in
  (match response with
   | `Assoc fields when required_bool "ok" fields -> ()
   | _ -> failwith "projected graph update should be staged");
  (match !staged with
   | [ { Logseq_chat_lg_core_native.operation_id = "op-title"
       ; base_t = 42
       ; intent = Save_title { uuid = "remote"; expected_title = "Old"; title = "Pending" }
       ; _ } ] -> ()
   | _ -> failwith "updateBlock did not stage a semantic save-title intent");
  let request =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  assert_equal "semantic update method" "POST" (required_string "method" request);
  let body = required_assoc "bodyObject" request in
  assert_int_equal "semantic update cursor" 42 (required_int "t-before" body);
  let entry = required_first_assoc "txs" body in
  assert_equal "semantic update operation id" "op-title" (required_string "tx-id" entry);
  assert_equal "semantic update op" "save-block" (required_string "outliner-op" entry)
;;

let () =
  let restore_stage_calls = ref 0 in
  let pending_operations () =
    List.init 200 (fun index ->
        Logseq_chat_lg_core_native.
        { operation_id = "restored-" ^ string_of_int index
        ; base_t = 42
        ; state = Queued
        ; intent =
            Save_title
              { uuid = "remote"
              ; expected_title = "Old"
              ; title = "Pending " ^ string_of_int index
              }
        })
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_blocks:(fun () -> Some [ remote_block "remote" "Old" ])
      ~stage_operation:(fun _operation ->
        incr restore_stage_calls;
        Ok ())
      ~prepare_operation:prepare_test_operation
      ~pending_operations
      ()
  in
  configure_plain_graph session;
  let request =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
  in
  if Option.is_none request then failwith "restored operations must remain syncable";
  assert_int_equal
    "durable operations are not restaged one by one during startup"
    0
    !restore_stage_calls
;;

let () =
  let operation operation_id title =
    Logseq_chat_lg_core_native.
      { operation_id
      ; base_t = 42
      ; state = Queued
      ; intent = Save_title { uuid = "remote"; expected_title = "Old"; title }
      }
  in
  let stale = operation "stale-head" "Stale" in
  let valid = operation "valid-after-stale" "Valid" in
  let pending = ref [ stale; valid ] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_blocks:(fun () -> Some [ remote_block "remote" "Old" ])
      ~stage_operation:(fun _ -> Ok ())
      ~prepare_operation:(fun operation ->
          if String.equal operation.Logseq_chat_lg_core_native.operation_id "stale-head"
        then Error "block no longer exists"
        else prepare_test_operation operation)
      ~pending_operations:(fun () -> !pending)
      ()
  in
  configure_plain_graph session;
  let blocked =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
  in
  if Option.is_some blocked then failwith "stale head should wait for graph reconciliation";
  pending := [ valid ];
  let request =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
    |> function
    | Some request -> request
    | None -> failwith "reconciled queue must advance past a stale head"
  in
  let entry = required_assoc "bodyObject" request |> required_first_assoc "txs" in
  assert_equal
    "reconciled queue advances to the next valid offline edit"
    "valid-after-stale"
    (required_string "tx-id" entry)
;;

let () =
  let pending =
    Logseq_chat_lg_core_native.
      { operation_id = "bounded-pending"
      ; base_t = 42
      ; state = Queued
      ; intent = Save_title { uuid = "remote"; expected_title = "Old"; title = "Pending" }
      }
  in
  let blocks =
    remote_block "remote" "Old"
    :: List.init 500 (fun index ->
      remote_block ("tail-" ^ string_of_int index) ("Tail " ^ string_of_int index))
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_blocks:(fun () -> Some blocks)
      ~stage_operation:(fun _ -> Ok ())
      ~prepare_operation:prepare_test_operation
      ~pending_operations:(fun () -> [ pending ])
      ()
  in
  configure_plain_graph session;
  let response =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
  in
  let result =
    match from_string response with
    | `Assoc fields -> required_assoc "result" fields
    | _ -> failwith "pending sync response must be an object"
  in
  if
    assoc "isPendingSyncPatch" result <> Some (`Bool true)
    || required_list "blocks" result <> []
    || String.length response >= 5_000
  then failwith "pending sync returns a bounded state patch"
;;

let () =
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_blocks:(fun () -> Some [ remote_block "remote" "Old" ])
      ~stage_operation:(fun operation -> staged := !staged @ [ operation ]; Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"updateBlock","payload":"{\"uuid\":\"remote\",\"operationId\":\"op-accepted\",\"expectedTitle\":\"Old\",\"title\":\"Pending\",\"status\":null}"}}|});
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|});
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":1,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/batch/ok\\\",\\\"t\\\":44}\",\"error\":null}"}}|});
  match List.rev !staged with
  | { Logseq_chat_lg_core_native.operation_id = "op-accepted"; state = Accepted 44; _ } :: _ -> ()
  | _ -> failwith "semantic completion must persist the accepted server cursor"
;;

let () =
  let staged = ref [] in
  let stage operation =
    staged :=
      List.filter
        (fun pending ->
          not
            (String.equal
               pending.Logseq_chat_lg_core_native.operation_id
               operation.Logseq_chat_lg_core_native.operation_id))
        !staged
      @ [ operation ];
    Ok ()
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_blocks:(fun () -> Some [ remote_block "remote" "Old" ])
      ~stage_operation:stage
      ~prepare_operation:prepare_test_operation
      ~pending_operations:(fun () ->
        List.filter
          (fun (operation : Logseq_chat_lg_core_native.pending_operation) ->
             match operation.state with
            | Queued | Retryable | Submitted -> true
            | Accepted _ | Applied | Conflicted _ -> false)
          !staged)
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"updateBlock","payload":"{\"uuid\":\"remote\",\"operationId\":\"first-after-response\",\"expectedTitle\":\"Old\",\"title\":\"First\",\"status\":null}"}}|});
  let first_request =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  let completion =
    match
      Logseq_chat_rpc.call session
        (Printf.sprintf
           {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":%d,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/batch/ok\\\",\\\"t\\\":43}\",\"error\":null}"}}|}
           (required_int "id" first_request))
      |> from_string
    with
    | `Assoc fields -> required_assoc "result" fields
    | _ -> failwith "pending sync completion must be an object"
  in
  assert_int_equal
    "HTTP acceptance does not advance the applied replay cursor"
    42
    (required_int "appliedServerT" completion);
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"updateBlock","payload":"{\"uuid\":\"remote\",\"operationId\":\"second-after-response\",\"expectedTitle\":\"First\",\"title\":\"Second\",\"status\":null}"}}|});
  let second_request =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  assert_int_equal
    "a successful batch response advances the next pump before its WebSocket echo"
    43
    (required_assoc "bodyObject" second_request |> required_int "t-before")
;;

let () =
  (* A batch acceptance can advance the transport cursor before WebSocket sync advances
     the authoritative graph. New edits must still stage against the graph
     runtime cursor while their request chains from the accepted cursor. *)
  let source = remote_block "accepted-before-sse" "First" in
  let staged = ref [] in
  let stage (operation : Logseq_chat_lg_core_native.pending_operation) =
    (match operation.state with
     | (Queued | Applied) when operation.base_t <> 42 ->
       Error "operation was created against a stale server cursor"
     | _ ->
       staged :=
         List.filter
           (fun (pending : Logseq_chat_lg_core_native.pending_operation) ->
             not (String.equal pending.operation_id operation.operation_id))
           !staged
         @ [ operation ];
       Ok ())
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_blocks:(fun () -> Some [ source ])
      ~stage_operation:stage
      ~prepare_operation:prepare_test_operation
      ~pending_operations:(fun () ->
        List.filter
          (fun (operation : Logseq_chat_lg_core_native.pending_operation) ->
             match operation.state with
            | Queued | Retryable | Submitted -> true
            | Accepted _ | Applied | Conflicted _ -> false)
          !staged)
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"updateBlock","payload":"{\"uuid\":\"accepted-before-sse\",\"operationId\":\"accepted-first\",\"expectedTitle\":\"First\",\"title\":\"Updated\",\"status\":null}"}}|});
  let request =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  ignore
    (Logseq_chat_rpc.call session
       (Printf.sprintf
          {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":%d,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/batch/ok\\\",\\\"t\\\":43}\",\"error\":null}"}}|}
          (required_int "id" request)));
  List.iter
    (fun (action, payload) ->
      let response =
        Logseq_chat_rpc.call session
          (to_string (`Assoc
             [ "apiVersion", `Int 1; "method", `String "dispatch"
             ; "params", `Assoc [ "action", `String action; "payload", `String payload ] ]))
        |> from_string
      in
      match response with
      | `Assoc fields when List.assoc_opt "ok" fields = Some (`Bool true) -> ()
      | _ -> failwith ("capture after acceptance must use the local cursor: " ^ to_string response))
    [ "send", {|{"text":"After acceptance","uuid":"capture-after-acceptance","now":1788000000000}|}
    ; "sendTask", {|{"text":"Task after acceptance","uuid":"task-after-acceptance","now":1788000000001,"status":{"uuid":"todo","ident":"logseq.property/status.todo","title":"Todo"}}|}
    ; "addAsset", {|{"uuid":"2f659891-3fbc-492c-8943-9e08de2ed949","title":"photo.jpg","now":1788000000002,"assetType":"jpg","assetSize":4,"assetChecksum":"abcd","localPath":"Assets/photo.jpg","targetBlockId":"accepted-before-sse"}|} ];
  ignore
    (dispatch_outliner
       session
       (`Assoc [ "type", `String "tapBlock"; "uuid", `String source.uuid ]));
  ignore
    (dispatch_outliner
       session
       (`Assoc [ "type", `String "returnPressed"; "uuid", `String source.uuid ]));
  match List.rev !staged with
  | { Logseq_chat_lg_core_native.state = Queued; base_t = 42; _ } :: _ -> ()
  | _ -> failwith "post-acceptance outliner edits must use the authoritative cursor"
;;

let () =
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_blocks:(fun () -> Some [ remote_block "remote" "Old" ])
      ~stage_operation:(fun operation -> staged := !staged @ [ operation ]; Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"updateBlock","payload":"{\"uuid\":\"remote\",\"operationId\":\"op-rejected\",\"expectedTitle\":\"Old\",\"title\":\"Pending\",\"status\":null}"}}|});
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|});
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":1,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/reject\\\",\\\"reason\\\":\\\"stale\\\",\\\"t\\\":43}\",\"error\":null}"}}|});
  match List.rev !staged with
  | { Logseq_chat_lg_core_native.operation_id = "op-rejected"; state = Retryable; _ } :: _ -> ()
  | _ -> failwith "a tx/reject response must remain retryable despite HTTP 200"
;;

let () =
  let persisted = ref [] in
  let stage (operation : Logseq_chat_lg_core_native.pending_operation) =
    persisted :=
      List.filter
        (fun pending ->
          not
            (String.equal
               pending.Logseq_chat_lg_core_native.operation_id
               operation.Logseq_chat_lg_core_native.operation_id))
        !persisted
      @ [ operation ];
    Ok ()
  in
  let pending_operations () =
    List.filter
      (fun (operation : Logseq_chat_lg_core_native.pending_operation) ->
         match operation.state with
        | Queued | Retryable | Submitted -> true
        | Accepted _ | Applied | Conflicted _ -> false)
      !persisted
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_blocks:(fun () -> Some [ remote_block "remote" "Old" ])
      ~stage_operation:stage
      ~prepare_operation:prepare_test_operation
      ~pending_operations
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"updateBlock","payload":"{\"uuid\":\"remote\",\"operationId\":\"op-retry\",\"expectedTitle\":\"Old\",\"title\":\"Pending\",\"status\":null}"}}|});
  let first =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  let first_id = required_int "id" first in
  ignore
    (Logseq_chat_rpc.call session
       (Printf.sprintf
          {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":%d,\"status\":null,\"body\":null,\"error\":\"offline\"}"}}|}
          first_id));
  (match !persisted with
   | [ { Logseq_chat_lg_core_native.operation_id = "op-retry"; state = Retryable; _ } ] -> ()
   | _ -> failwith "failed semantic transport must remain retryable in durable storage");
  let retried =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  let entry = required_assoc "bodyObject" retried |> required_first_assoc "txs" in
  assert_equal
    "semantic retry preserves the idempotency key"
    "op-retry"
    (required_string "tx-id" entry)
;;

let () =
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 77)
      ~graph_blocks:(fun () -> Some [ remote_block "delete-me" "Delete me" ])
      ~stage_operation:(fun operation -> staged := !staged @ [ operation ]; Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  let response =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"deleteBlock","payload":"{\"uuid\":\"delete-me\",\"operationId\":\"op-delete\",\"expectedServerT\":77}"}}|}
    |> from_string
  in
  (match response with
   | `Assoc fields when required_bool "ok" fields -> ()
   | _ -> failwith "deleteBlock should stage a guarded delete");
  (match !staged with
   | [ { Logseq_chat_lg_core_native.operation_id = "op-delete"
       ; base_t = 77
       ; intent = Delete_blocks { uuids }
       ; _ } ] when Rrbvec.to_list uuids = ["delete-me"] -> ()
   | _ -> failwith "deleteBlock did not stage a semantic delete-blocks intent");
  let request =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  assert_equal "guarded delete method" "POST" (required_string "method" request);
  let body = required_assoc "bodyObject" request in
  assert_int_equal "guarded delete expected t" 77 (required_int "t-before" body);
  let entry = required_first_assoc "txs" body in
  assert_equal "guarded delete operation id" "op-delete" (required_string "tx-id" entry);
  assert_equal "guarded delete op" "delete-blocks" (required_string "outliner-op" entry)
;;

let () =
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_blocks:(fun () -> Some [ remote_block "source" "hello world" ])
      ~stage_operation:(fun operation -> staged := !staged @ [ operation ]; Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  let response =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"splitBlock","payload":"{\"uuid\":\"source\",\"operationId\":\"op-split\",\"expectedServerT\":42,\"expectedTitle\":\"hello world\",\"before\":\"hello\",\"after\":\" world\",\"newUuid\":\"new\",\"newOrder\":\"a1\",\"createdAt\":100}"}}|}
    |> from_string
  in
  (match response with
   | `Assoc fields when required_bool "ok" fields -> ()
   | _ -> failwith "splitBlock should stage one atomic semantic intent");
  (match !staged with
   | [ { Logseq_chat_lg_core_native.operation_id = "op-split"
       ; intent = Split_block
           { uuid = "source"; expected_title = "hello world"; before = "hello";
             after = " world"; new_uuid = "new"; new_order = "a1"; created_at = 100 }
       ; _ } ] -> ()
   | _ -> failwith "splitBlock did not stage the expected semantic intent");
  let request =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  assert_equal "split request method" "POST" (required_string "method" request);
  let entry =
    required_assoc "bodyObject" request |> required_first_assoc "txs"
  in
  assert_equal "split operation identity" "op-split" (required_string "tx-id" entry);
  assert_equal "split outliner op" "split-block" (required_string "outliner-op" entry)
;;

let () =
  let persisted = ref [] in
  let stage (operation : Logseq_chat_lg_core_native.pending_operation) =
    persisted :=
      List.filter
        (fun current ->
           current.Logseq_chat_lg_core_native.operation_id <> operation.operation_id)
        !persisted
      @ [ operation ];
    Ok ()
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_blocks:(fun () -> Some [ remote_block "source" "Old" ])
      ~stage_operation:stage
      ~prepare_operation:prepare_test_operation
      ~pending_operations:(fun () ->
        List.filter
          (fun (operation : Logseq_chat_lg_core_native.pending_operation) ->
             match operation.state with
            | Queued | Retryable | Submitted -> true
            | Accepted _ | Applied | Conflicted _ -> false)
          !persisted)
      ()
  in
  configure_plain_graph session;
  List.iter
    (fun operation -> ignore (stage operation))
    [ Logseq_chat_lg_core_native.
        { operation_id = "first"
        ; base_t = 42
        ; state = Queued
        ; intent = Save_title { uuid = "source"; expected_title = "Old"; title = "First" }
        }
    ; { operation_id = "second"
      ; base_t = 42
      ; state = Queued
      ; intent = Save_title { uuid = "source"; expected_title = "First"; title = "Second" }
      }
    ];
  let first =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  let completion =
    Logseq_chat_rpc.call session
      (Printf.sprintf
         {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":%d,\"status\":200,\"body\":\"{\\\"t\\\":43}\",\"error\":null}"}}|}
         (required_int "id" first))
    |> pending_request
  in
  match completion with
  | Some request ->
    let entry = required_assoc "bodyObject" request |> required_first_assoc "txs" in
    assert_equal
      "accepted optimistic edits immediately release the next queued operation"
      "second"
      (required_string "tx-id" entry)
  | None -> failwith "accepted optimistic edit left the dependent queue waiting for a snapshot"
;;

let () =
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 43)
      ~graph_blocks:(fun () -> Some [ remote_block "previous" "hello"; remote_block "source" " world" ])
      ~stage_operation:(fun operation -> staged := !staged @ [ operation ]; Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  let response =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"mergeBackward","payload":"{\"uuid\":\"source\",\"operationId\":\"op-merge\",\"expectedServerT\":43,\"expectedTitle\":\" world\",\"title\":\" world\",\"previousUuid\":\"previous\",\"expectedPreviousTitle\":\"hello\"}"}}|}
    |> from_string
  in
  (match response with
   | `Assoc fields when required_bool "ok" fields -> ()
   | _ -> failwith "mergeBackward should stage one atomic semantic intent");
  (match !staged with
   | [ { Logseq_chat_lg_core_native.operation_id = "op-merge"
       ; intent = Merge_backward
           { uuid = "source"; expected_title = " world"; title = " world"; previous_uuid = "previous";
             expected_previous_title = "hello"; merged_title = None }
       ; _ } ] -> ()
   | _ -> failwith "mergeBackward did not stage the expected semantic intent")
;;

let () =
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 50)
      ~graph_blocks:(fun () -> Some [ remote_block "first" "First"; remote_block "second" "Second" ])
      ~stage_operation:(fun operation -> staged := !staged @ [ operation ]; Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  let response =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"moveBlocks","payload":"{\"operationId\":\"op-move-batch\",\"expectedServerT\":50,\"moves\":[{\"uuid\":\"first\",\"pageUuid\":\"page\",\"parentUuid\":\"target\",\"order\":\"a0\"},{\"uuid\":\"second\",\"pageUuid\":\"page\",\"parentUuid\":\"target\",\"order\":\"a1\"}]}"}}|}
    |> from_string
  in
  (match response with
   | `Assoc fields when required_bool "ok" fields -> ()
   | _ -> failwith "moveBlocks should stage one batch intent");
  (match !staged with
   | [ { Logseq_chat_lg_core_native.intent = Move_blocks { moves }; _ } ] ->
     (match Rrbvec.to_list moves with
      | [first; second] ->
        assert_equal "first moved block" "first" first.uuid;
        assert_equal "second moved block" "second" second.uuid
      | _ -> failwith "moveBlocks must preserve both moves")
   | _ -> failwith "moveBlocks did not stage one batch intent");
  let entry =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
    |> required_assoc "bodyObject" |> required_first_assoc "txs"
  in
  assert_equal "batch move transport" "move-blocks" (required_string "outliner-op" entry)
;;

let () =
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 51)
      ~graph_blocks:(fun () -> Some [ remote_block "first" "First"; remote_block "second" "Second" ])
      ~stage_operation:(fun operation -> staged := !staged @ [ operation ]; Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"deleteBlocks","payload":"{\"operationId\":\"op-delete-batch\",\"expectedServerT\":51,\"uuids\":[\"second\",\"first\",\"first\"]}"}}|});
  match !staged with
  | [ { Logseq_chat_lg_core_native.intent = Delete_blocks { uuids }; _ } ]
    when Rrbvec.to_list uuids = ["first"; "second"] -> ()
  | _ -> failwith "deleteBlocks must stage one deduplicated batch intent"
;;

let () =
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 88)
      ~graph_blocks:(fun () -> Some [ remote_block "task" "Task" ])
      ~stage_operation:(fun operation -> staged := !staged @ [ operation ]; Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"updateBlockStatus","payload":"{\"uuid\":\"task\",\"operationId\":\"op-status\",\"expectedStatusUuid\":null,\"status\":{\"uuid\":\"doing\",\"title\":\"Doing\"}}"}}|});
  (match !staged with
   | [ { Logseq_chat_lg_core_native.operation_id = "op-status"
       ; intent = Set_property
           { uuid = "task"; attr = "logseq.property/status";
             expected = None; value = Some (Ref_uuid "doing") }
       ; _ } ] -> ()
   | _ -> failwith "updateBlockStatus did not stage a typed property intent");
  let request =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  assert_equal "semantic status method" "POST" (required_string "method" request);
  let entry =
    required_assoc "bodyObject" request |> required_first_assoc "txs"
  in
  assert_equal "semantic status operation id" "op-status" (required_string "tx-id" entry);
  assert_equal "semantic status op" "save-block" (required_string "outliner-op" entry)
;;

let () =
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> None)
      ~graph_blocks:(fun () -> Some [ remote_block "delete-me" "Delete me" ])
      ~stage_operation:(fun _ -> failwith "delete without cursor must not stage")
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  let response =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"deleteBlock","payload":"{\"uuid\":\"delete-me\",\"operationId\":\"op-delete\",\"expectedServerT\":77}"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    let error = required_assoc "error" fields in
    assert_equal "missing cursor delete error" "stale_server_cursor" (required_string "code" error)
  | _ -> failwith "missing cursor delete should return an RPC error"
;;

let () =
  let authoritative =
    Logseq_chat_lg_core_native.
      { uuid = "offline-edit"
      ; title = "Server title"
      ; page_id = "journal/2026-08-15"
      ; parent_id = None
      ; order = None
      ; created_at = 1_776_000_000_000
      ; updated_at = 1_776_000_000_000
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
  let projected = ref [ authoritative ] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 5)
      ~graph_blocks:(fun () -> Some !projected)
      ~stage_operation:(fun operation ->
          (match operation.Logseq_chat_lg_core_native.intent with
         | Save_title { uuid; title; _ } ->
           projected :=
             List.map
               (fun (block : Logseq_chat_lg_core_native.block) ->
                 if String.equal block.uuid uuid
                 then { block with title; sync_status = "pending" }
                 else block)
               !projected
         | _ -> failwith "offline edit must stage Save_title");
        Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"updateBlock","payload":"{\"uuid\":\"offline-edit\",\"operationId\":\"offline-edit-op\",\"expectedTitle\":\"Server title\",\"title\":\"Edited offline\"}"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    let blocks = required_assoc "result" fields |> required_list "blocks" in
    (match blocks with
     | [ `Assoc block ] ->
       assert_equal "offline edited title" "Edited offline" (required_string "title" block);
       assert_equal "offline edited sync status" "pending" (required_string "syncStatus" block)
     | _ -> failwith "offline edit should remain visible over the authoritative block")
  | _ -> failwith "offline edit should return an RPC response"
;;

let () =
  let source = remote_block "source" "Hello" in
  let unrelated_tail =
    match LG.logseq_chat_fractional_order_n_between (Some "a0") None 100 with
    | Error message -> failwith message
    | Ok orders ->
      List.mapi
        (fun index order ->
          { (remote_block ("unrelated-" ^ string_of_int index) "Unrelated") with
            Logseq_chat_lg_core_native.order = Some order
          })
        (Rrbvec.to_list orders)
  in
  let projected = ref (source :: unrelated_tail) in
  let server_t = ref 42 in
  let authoritative = Hashtbl.create 8 in
  let prepare_calls = ref 0 in
  Hashtbl.add authoritative "source" ();
  let find_projected uuid =
    List.find_opt
      (fun (block : Logseq_chat_lg_core_native.block) -> String.equal block.uuid uuid)
      !projected
  in
  let replace_projected uuid update =
    projected :=
      List.map
        (fun (block : Logseq_chat_lg_core_native.block) ->
          if String.equal block.uuid uuid then update block else block)
        !projected
  in
  let stage operation =
    (match operation.Logseq_chat_lg_core_native.intent with
     | Split_block { uuid; before; after; new_uuid; new_order; created_at; _ } ->
       replace_projected uuid (fun block -> { block with title = before });
       let original = Option.get (find_projected uuid) in
       projected :=
         !projected
         @ [ { original with
               uuid = new_uuid
             ; title = after
             ; order = Some new_order
             ; created_at
             ; updated_at = created_at
             } ]
     | Merge_backward { uuid; previous_uuid; title; _ } ->
       let previous = Option.get (find_projected previous_uuid) in
       replace_projected previous_uuid (fun block -> { block with title = previous.title ^ title });
       projected :=
         List.filter
           (fun (block : Logseq_chat_lg_core_native.block) -> not (String.equal block.uuid uuid))
           !projected
     | _ -> ());
    Ok ()
  in
  let prepare operation =
    incr prepare_calls;
    let exists uuid = Hashtbl.mem authoritative uuid in
    let dependencies_exist =
      match operation.Logseq_chat_lg_core_native.intent with
      | Split_block { uuid; _ } -> exists uuid
      | Merge_backward { uuid; previous_uuid; _ } -> exists uuid && exists previous_uuid
      | _ -> true
    in
    if dependencies_exist
    then prepare_test_operation operation
    else Error "block no longer exists"
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some !server_t)
      ~graph_blocks:(fun () -> Some !projected)
      ~stage_operation:stage
      ~prepare_operation:prepare
      ()
  in
  let assert_bounded_structural_patch label response =
    if not (required_bool "isOutlinerPatch" response)
    then failwith (label ^ " must use an outliner patch");
    if required_list "outlinerRows" response <> []
    then failwith (label ^ " must not serialize the whole row projection");
    if List.length (required_list "blocks" response) > 2
    then failwith (label ^ " must include only changed blocks");
    match required_list "outlinerRowSplices" response with
    | [ `Assoc splice ] ->
      if List.length (required_list "rows" splice) > 2
      then failwith (label ^ " row splice grew with the unrelated page tail")
    | _ -> failwith (label ^ " must describe one bounded row splice")
  in
  configure_plain_graph session;
  ignore
    (dispatch_outliner session (`Assoc [ "type", `String "tapBlock"; "uuid", `String "source" ]));
  ignore
    (dispatch_outliner
       session
       (`Assoc
         [ "type", `String "textChanged"
         ; "title", `String "Hello"
         ; "caretUTF16Offset", `Int 5
         ]));
  let first_split =
    dispatch_outliner
      session
      (`Assoc
        [ "type", `String "returnPressed"
        ; "uuid", `String "source"
        ])
  in
  assert_bounded_structural_patch "first split" first_split;
  let first_uuid =
    required_assoc "outlinerState" first_split
    |> required_assoc "editing"
    |> required_string "uuid"
  in
  let second_split =
    dispatch_outliner
      session
      (`Assoc
        [ "type", `String "returnPressed"
        ; "uuid", `String first_uuid
        ])
  in
  assert_bounded_structural_patch "second split" second_split;
  let second_uuid =
    required_assoc "outlinerState" second_split
    |> required_assoc "editing"
    |> required_string "uuid"
  in
  let merged =
    dispatch_outliner
      session
      (`Assoc
        [ "type", `String "backspacePressed"
        ; "uuid", `String second_uuid
        ; "selectionLength", `Int 0
        ])
  in
  assert_bounded_structural_patch "first backward merge" merged;
  assert_equal
    "repeated structural edits keep the inline editor focused"
    first_uuid
    (required_assoc "outlinerState" merged
     |> required_assoc "editing"
     |> required_string "uuid");
  let stale_repeat =
    dispatch_outliner
      session
      (`Assoc
        [ "type", `String "backspacePressed"
        ; "uuid", `String second_uuid
        ; "selectionLength", `Int 0
        ])
  in
  assert_equal
    "a repeated backspace from the removed editor cannot merge another block"
    first_uuid
    (required_assoc "outlinerState" stale_repeat
     |> required_assoc "editing"
     |> required_string "uuid");
  let merged_again =
    dispatch_outliner
      session
      (`Assoc
        [ "type", `String "backspacePressed"
        ; "uuid", `String first_uuid
        ; "selectionLength", `Int 0
        ])
  in
  assert_bounded_structural_patch "second backward merge" merged_again;
  assert_equal
    "consecutive empty-block deletes use the latest pending projection"
    "source"
    (required_assoc "outlinerState" merged_again
     |> required_assoc "editing"
     |> required_string "uuid");
  if !prepare_calls <> 0
  then failwith "user-visible outliner dispatch must not wait for authoritative tx preparation";
  let first_request =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  Hashtbl.replace authoritative first_uuid ();
  server_t := 43;
  ignore
    (Logseq_chat_rpc.call session
       (Printf.sprintf
          {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":%d,\"status\":200,\"body\":\"{\\\"t\\\":43}\",\"error\":null}"}}|}
          (required_int "id" first_request)));
  let second_request =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  let second_entry = required_assoc "bodyObject" second_request |> required_first_assoc "txs" in
  assert_int_equal
    "dependent split rebases onto the latest authoritative cursor"
    43
    (required_assoc "bodyObject" second_request |> required_int "t-before");
  assert_equal
    "dependent split activates after its source is authoritative"
    "split-block"
    (required_string "outliner-op" second_entry);
  Hashtbl.replace authoritative second_uuid ();
  server_t := 44;
  ignore
    (Logseq_chat_rpc.call session
       (Printf.sprintf
          {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":%d,\"status\":200,\"body\":\"{\\\"t\\\":44}\",\"error\":null}"}}|}
          (required_int "id" second_request)));
  let merge_request =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request |> Option.get
  in
  let merge_entry = required_assoc "bodyObject" merge_request |> required_first_assoc "txs" in
  assert_int_equal
    "dependent merge rebases onto the latest authoritative cursor"
    44
    (required_assoc "bodyObject" merge_request |> required_int "t-before");
  assert_equal
    "dependent delete merge activates without losing keyboard focus"
    "merge-blocks"
    (required_string "outliner-op" merge_entry)
;;

let () =
  (* Page-scoped structural editing must keep using the optimistic projection
     when the page reader has not observed newly staged blocks yet. *)
  let page : Logseq_chat_lg_core_native.entity_summary = Logseq_chat_lg_core_native.{ uuid = "page-lag"; title = "Lagging page" } in
  let source =
    { (remote_block "page-source" "Hello") with
      Logseq_chat_lg_core_native.page_id = page.uuid
    ; parent_id = Some page.uuid
    ; order = Some "a0"
    }
  in
  let interleaved_reference =
    { (remote_block "other-page-reference" "Links lagging page") with
      Logseq_chat_lg_core_native.page_id = "other-page"
    ; parent_id = Some "other-page"
    ; order = Some "a1"
    }
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_sidebar_pages:(fun () ->
        Some Logseq_chat_lg_core_native.{ favorites = Rrbvec.of_list [ page ]; recent_pages = Rrbvec.of_list [] })
      ~graph_page_blocks:(fun uuid ->
        if String.equal uuid page.uuid then Some [ source ] else None)
      ~graph_node_references:(fun uuid ->
        if String.equal uuid page.uuid then Some [ interleaved_reference ] else None)
      ~stage_operation:(fun _ -> Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"selectPage","payload":"page-lag"}}|});
  ignore
    (dispatch_outliner
       session
       (`Assoc [ "type", `String "tapBlock"; "uuid", `String source.uuid ]));
  let editing_uuid response =
    required_assoc "outlinerState" response
    |> required_assoc "editing"
    |> required_string "uuid"
  in
  let split uuid =
    dispatch_outliner
      session
      (`Assoc [ "type", `String "returnPressed"; "uuid", `String uuid ])
    |> editing_uuid
  in
  let merge uuid =
    dispatch_outliner
      session
      (`Assoc
        [ "type", `String "backspacePressed"
        ; "uuid", `String uuid
        ; "selectionLength", `Int 0
        ])
    |> editing_uuid
  in
  let first_empty = split source.uuid in
  let second_empty = split first_empty in
  session.semantic_queue <- [];
  session.semantic_active <- None;
  let first_empty_after_merge = merge second_empty in
  assert_equal
    "the first page-scoped delete focuses the previous optimistic block"
    first_empty
    first_empty_after_merge;
  assert_equal
    "consecutive page-scoped deletes survive a lagging page reader"
    source.uuid
    (merge first_empty_after_merge)
;;

let () =
  (* Node routes must use the optimistic projection while the page reader is
     still behind, just like sidebar page editing does. *)
  let page : Logseq_chat_lg_core_native.entity_summary = Logseq_chat_lg_core_native.{ uuid = "node-lag-page"; title = "Node lag page" } in
  let source =
    { (remote_block "node-lag-source" "Hello") with
      Logseq_chat_lg_core_native.page_id = page.uuid
    ; parent_id = Some page.uuid
    ; order = Some "a0"
    }
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_page_blocks:(fun uuid ->
        if String.equal uuid page.uuid then Some [ source ] else None)
      ~graph_node_destination:(fun uuid ->
        if String.equal uuid page.uuid then Some (page, false) else None)
      ~stage_operation:(fun _ -> Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"openNode","payload":"{\"uuid\":\"node-lag-page\"}"}}|});
  ignore
    (dispatch_outliner
       session
       (`Assoc [ "type", `String "tapBlock"; "uuid", `String source.uuid ]));
  let editing_uuid response =
    let route = required_first_assoc "nodeRoutes" response in
    required_assoc "outlinerState" route
    |> required_assoc "editing"
    |> required_string "uuid"
  in
  let split uuid =
    dispatch_outliner
      session
      (`Assoc [ "type", `String "returnPressed"; "uuid", `String uuid ])
    |> editing_uuid
  in
  let first_empty = split source.uuid in
  let second_empty = split first_empty in
  if String.equal first_empty second_empty
  then failwith "consecutive node-route Enter must create distinct blocks";
  ignore
    (dispatch_outliner session
       (`Assoc [ "type", `String "tapBlock"; "uuid", `String source.uuid ]));
  let inserted = split source.uuid in
  let response =
    dispatch_outliner session
      (`Assoc [ "type", `String "caretMoved"; "caretUTF16Offset", `Int 0 ])
  in
  let rows = required_first_assoc "nodeRoutes" response |> required_list "outlinerRows" in
  let ids = List.map (function
    | `Assoc row -> required_assoc "block" row |> required_string "uuid"
    | _ -> failwith "expected an outliner row") rows in
  if ids <> [ source.uuid; inserted; first_empty; second_empty ]
  then failwith ("node-route insertion moved to the bottom: " ^ String.concat "," ids);
  let expected = ref ids in
  for _ = 1 to 20 do
    ignore (dispatch_outliner session
      (`Assoc [ "type", `String "tapBlock"; "uuid", `String source.uuid ]));
    let inserted = split source.uuid in
    expected := source.uuid :: inserted :: List.tl !expected;
    let response = dispatch_outliner session
      (`Assoc [ "type", `String "caretMoved"; "caretUTF16Offset", `Int 0 ]) in
    let rows = required_first_assoc "nodeRoutes" response |> required_list "outlinerRows" in
    let ids = List.map (function
      | `Assoc row -> required_assoc "block" row |> required_string "uuid"
      | _ -> failwith "expected an outliner row") rows in
    if ids <> !expected then failwith "repeated insertion must stay after the first block"
  done
;;


let () =
  (* Editing keeps local structure, but live properties must replace stale
     metadata in the optimistic overlay before staging another property edit. *)
  let page : Logseq_chat_lg_core_native.entity_summary = Logseq_chat_lg_core_native.{ uuid = "status-page"; title = "Status page" } in
  let source =
    { (remote_block "status-source" "Task") with
      Logseq_chat_lg_core_native.page_id = page.uuid
    ; parent_id = Some page.uuid
    ; order = Some "a0"
    }
  in
  let todo =
    Logseq_chat_lg_core_native.
      { uuid = "status-todo"
      ; ident = Some "logseq.property/status.todo"
      ; title = "Todo"
      ; icon_type = None
      ; icon_id = None
      ; icon_color = None
      }
  in
  let live_blocks = ref [ source ] in
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_sidebar_pages:(fun () ->
        Some Logseq_chat_lg_core_native.{ favorites = Rrbvec.of_list [ page ]; recent_pages = Rrbvec.of_list [] })
      ~graph_page_blocks:(fun uuid ->
        if String.equal uuid page.uuid then Some !live_blocks else None)
      ~stage_operation:(fun operation -> staged := !staged @ [ operation ]; Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"selectPage","payload":"status-page"}}|});
  ignore
    (dispatch_outliner
       session
       (`Assoc [ "type", `String "tapBlock"; "uuid", `String source.uuid ]));
  live_blocks := [ { source with Logseq_chat_lg_core_native.status = Some todo } ];
  ignore
    (dispatch_outliner
       session
       (`Assoc
         [ "type", `String "setTaskStatus"
         ; "uuid", `String source.uuid
         ; "statusIdent", `String "logseq.property/status.doing"
         ]));
  match !staged with
  | [ { Logseq_chat_lg_core_native.intent =
          Set_property
            { expected = Some (Ref_ident "logseq.property/status.todo"); _ }
      ; _ } ] -> ()
  | _ -> failwith "editing must stage task status against live property metadata"
;;

let () =
  let page : Logseq_chat_lg_core_native.entity_summary = Logseq_chat_lg_core_native.{ uuid = "task-page"; title = "Task page" } in
  let todo =
    Logseq_chat_lg_core_native.
      { uuid = "status-todo"
      ; ident = Some "logseq.property/status.todo"
      ; title = "Todo"
      ; icon_type = None
      ; icon_id = None
      ; icon_color = None
      }
  in
  let source =
    { (remote_block "task-source" "Todo") with
      Logseq_chat_lg_core_native.page_id = page.uuid
    ; parent_id = Some page.uuid
    ; order = Some "a0"
    ; status = Some todo
    ; tags = [ { uuid = "tag-card"; title = "Card" } ]
    ; references = [ { uuid = "reference"; title = "Reference" } ]
    ; breadcrumbs = [ { uuid = "ancestor"; title = "Ancestor" } ]
    ; is_asset = true
    ; asset_type = Some "image/jpeg"
    ; asset_size = Some 42
    ; asset_checksum = Some "checksum"
    ; local_path = Some "/tmp/source.jpg"
    }
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_sidebar_pages:(fun () ->
        Some Logseq_chat_lg_core_native.{ favorites = Rrbvec.of_list [ page ]; recent_pages = Rrbvec.of_list [] })
      ~graph_page_blocks:(fun uuid ->
        if String.equal uuid page.uuid then Some [ source ] else None)
      ~stage_operation:(fun _ -> Ok ())
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"selectPage","payload":"task-page"}}|});
  ignore
    (dispatch_outliner
       session
       (`Assoc [ "type", `String "tapBlock"; "uuid", `String source.uuid ]));
  let response =
    dispatch_outliner
      session
      (`Assoc [ "type", `String "returnPressed"; "uuid", `String source.uuid ])
  in
  let inserted =
    required_list "blocks" response
    |> List.filter_map (function
      | `Assoc fields when required_string "uuid" fields <> source.uuid -> Some fields
      | _ -> None)
  in
  match inserted with
  | [ fields ] ->
    (match assoc "status" fields with
     | Some `Null | None -> ()
     | _ -> failwith "a block created from a TODO block must not inherit its task status");
    if required_list "tags" fields <> []
    then failwith "a split block must not inherit tags";
    if required_list "references" fields <> []
    then failwith "a split block must not inherit references";
    if required_list "breadcrumbs" fields <> []
    then failwith "a split block must not inherit breadcrumbs";
    if required_bool "isAsset" fields
    then failwith "a split block must not inherit asset metadata"
  | _ -> failwith "splitting a TODO block must return exactly one new block"
;;

let () =
  let today_page : Logseq_chat_lg_core_native.entity_summary = Logseq_chat_lg_core_native.{ uuid = "journal-today"; title = "Today" } in
  let source =
    { (remote_block "journal-source" "Hello") with
      Logseq_chat_lg_core_native.page_id = today_page.uuid
    ; parent_id = Some today_page.uuid
    ; order = Some "a0"
    ; journal = Some ("Today", 20260818)
    }
  in
  let child =
    { (remote_block "journal-child" "Child") with
      Logseq_chat_lg_core_native.page_id = today_page.uuid
    ; parent_id = Some source.uuid
    ; order = Some "a0"
    ; journal = Some ("Today", 20260818)
    }
  in
  let orders =
    match LG.logseq_chat_fractional_order_n_between (Some "a0") None 20 with
    | Ok orders -> Rrbvec.to_list orders
    | Error message -> failwith message
  in
  let distant =
    List.init 100 (fun journal_index ->
      let page_id = "journal-" ^ string_of_int journal_index in
      List.mapi
        (fun block_index order ->
          { (remote_block
               (page_id ^ "-block-" ^ string_of_int block_index)
               "Unrelated") with
            Logseq_chat_lg_core_native.page_id
              = page_id
          ; parent_id = Some page_id
          ; order = Some order
          ; journal = Some (page_id, 20260700 + journal_index)
          })
        orders)
    |> List.concat
  in
  let today_blocks = ref [ source; child ] in
  let full_graph_reads = ref 0 in
  let page_reads = ref 0 in
  let stage operation =
    (match operation.Logseq_chat_lg_core_native.intent with
     | Split_block { uuid; before; after; new_uuid; new_order; created_at; _ } ->
       let original =
         List.find
           (fun (block : Logseq_chat_lg_core_native.block) -> String.equal block.uuid uuid)
           !today_blocks
       in
       today_blocks :=
         List.map
           (fun (block : Logseq_chat_lg_core_native.block) ->
             if String.equal block.uuid uuid then { block with title = before } else block)
           !today_blocks
         @ [ { original with
               uuid = new_uuid
             ; title = after
             ; order = Some new_order
             ; created_at
             ; updated_at = created_at
             } ]
     | _ -> ());
    Ok ()
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_blocks:(fun () ->
        incr full_graph_reads;
        Some (distant @ !today_blocks))
      ~graph_page_blocks:(fun page_uuid ->
        if not (String.equal page_uuid today_page.uuid)
        then failwith "journal Enter loaded an unrelated page";
        incr page_reads;
        Some !today_blocks)
      ~graph_node_destination:(fun uuid ->
        if String.equal uuid source.uuid then Some (today_page, true) else None)
      ~stage_operation:stage
      ~prepare_operation:prepare_test_operation
      ()
  in
  configure_plain_graph session;
  ignore
    (dispatch_outliner
       session
       (`Assoc [ "type", `String "tapBlock"; "uuid", `String source.uuid ]));
  full_graph_reads := 0;
  page_reads := 0;
  let split =
    dispatch_outliner
      session
      (`Assoc
        [ "type", `String "returnPressed"
        ; "uuid", `String source.uuid
        ; "title", `String source.title
        ; "caretUTF16Offset", `Int 5
        ])
  in
  if !full_graph_reads <> 0
  then failwith "journal Enter must not reload every journal block";
  if !page_reads <> 1
  then failwith "journal Enter must load its page once before staging";
  (match required_list "outlinerRowSplices" split with
   | [ `Assoc splice ] ->
     assert_equal
       "journal split inserts after the source subtree"
       child.uuid
       (required_string "afterBlockId" splice);
     if List.length (required_list "rows" splice) <> 1
     then failwith "journal split must return exactly one inserted row"
  | _ -> failwith "journal split must return one anchored row splice")
;;

let () =
  let graph_a_model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let graph_b_model = (Logseq_chat_lg_core_native.logseq_chat_cache_model_create None) in
  let session =
    Logseq_chat_rpc.create
      ~open_graph:(fun _ -> Ok ())
      ~model_for_graph:(fun ~graph_id ->
        if String.equal graph_id "graph-a" then graph_a_model else graph_b_model)
      ()
  in
  let open_graph graph_id =
    let payload =
      Yojson.Basic.to_string
        (`Assoc
          [ "graphId", `String graph_id
          ; "activePath", `String ("/graphs/" ^ graph_id ^ "/graph.sqlite")
          ; "checkpointPath", `String ("/graphs/" ^ graph_id ^ "/sync.checkpoint")
          ])
    in
    let request =
      Yojson.Basic.to_string
        (`Assoc
          [ "apiVersion", `Int 1
          ; "method", `String "dispatch"
          ; ( "params"
            , `Assoc [ "action", `String "openGraph"; "payload", `String payload ] )
          ])
    in
    ignore (Logseq_chat_rpc.call session request)
  in
  open_graph "graph-a";
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"graph-a-asset\",\"title\":\"photo.jpg\",\"now\":1,\"assetType\":\"jpg\",\"assetSize\":4,\"assetChecksum\":\"abcd\",\"localPath\":\"Assets/photo.jpg\"}"}}|});
  if List.length (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_pending_blocks (session.model))) <> 1
  then failwith "graph A should contain its pending asset";
  open_graph "graph-b";
  if (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_pending_blocks (session.model))) <> []
  then failwith "graph B must not inherit graph A's optimistic projection";
  open_graph "graph-a";
  if List.length (Rrbvec.to_list (Logseq_chat_lg_core_native.logseq_chat_cache_model_pending_blocks (session.model))) <> 1
  then failwith "switching back should restore graph A's optimistic projection"
;;


let () =
  let parent = remote_block "parent" "Parent" in
  let child = { (remote_block "child" "Child") with Logseq_chat_lg_core_native.parent_id = Some "parent" } in
  let staged = ref [] in
  let session = Logseq_chat_rpc.create
    ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
    ~sync_cursor:(fun () -> Some 92)
    ~graph_blocks:(fun () -> Some [parent; child])
    ~stage_operation:(fun operation -> staged := operation :: !staged; Ok ())
    ~prepare_operation:prepare_test_operation () in
  configure_plain_graph session;
  ignore (dispatch_outliner session (`Assoc ["type", `String "tapBlock"; "uuid", `String "parent"]));
  ignore (dispatch_outliner session (`Assoc ["type", `String "textChanged"; "title", `String "Changed parent"; "caretUTF16Offset", `Int 14]));
  let collapsed = dispatch_outliner session (`Assoc ["type", `String "toggleCollapsed"; "uuid", `String "parent"]) in
  if List.assoc_opt "editing" (required_assoc "outlinerState" collapsed) <> Some `Null
  then failwith "collapse must finish the active editor";
  if required_list "outlinerRowSplices" collapsed = []
  then failwith "collapse after editing must remove child rows as well as saving the title";
  if List.length !staged <> 1 then failwith "collapse saves the pending title exactly once"
;;

let () =
  let staged = ref [] in
  let session = Logseq_chat_rpc.create
    ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
    ~sync_cursor:(fun () -> Some 92)
    ~graph_blocks:(fun () -> Some [remote_block "editing" "Original"])
    ~stage_operation:(fun operation -> staged := operation :: !staged; Ok ())
    ~prepare_operation:prepare_test_operation () in
  configure_plain_graph session;
  ignore (dispatch_outliner session (`Assoc ["type", `String "tapBlock"; "uuid", `String "editing"]));
  ignore (dispatch_outliner session (`Assoc ["type", `String "textChanged"; "title", `String "Draft [[Novel]]"; "caretUTF16Offset", `Int 13]));
  let result = dispatch_outliner session (`Assoc ["type", `String "chooseAutocomplete"; "value", `String "Novel"]) in
  let editing = required_assoc "editing" (required_assoc "outlinerState" result) in
  assert_equal "new page keeps paired reference in the draft" "Draft [[Novel]]" (required_string "title" editing);
  match !staged with
  | [operation] ->
    (match (Logseq_chat_lg_core_native.logseq_chat_pending_ops_intent_json
              operation.intent) with
     | `Assoc fields -> assert_equal "new page stages creation without saving the block" "create-page" (required_string "type" fields)
     | _ -> failwith "new page operation must be serializable")
  | _ -> failwith "choosing New page must create exactly one real page without saving the draft"
;;

let () =
  let live = ref (remote_block "source" "Original") in
  let session = Logseq_chat_rpc.create
    ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
    ~sync_cursor:(fun () -> Some 92)
    ~graph_blocks:(fun () -> Some [!live])
    ~stage_operation:(fun operation ->
        (match operation.Logseq_chat_lg_core_native.intent with
       | Save_title { title; _ } ->
         live := { !live with title; references = [{ uuid = "target"; title = "New page" }] }
       | _ -> ());
      Ok ())
    ~prepare_operation:prepare_test_operation () in
  configure_plain_graph session;
  ignore (dispatch_outliner session (`Assoc ["type", `String "tapBlock"; "uuid", `String "source"]));
  ignore (dispatch_outliner session (`Assoc ["type", `String "textChanged"; "title", `String "See [[target]]"; "caretUTF16Offset", `Int 14]));
  let result = dispatch_outliner session (`Assoc ["type", `String "saveEditing"]) in
  let rec has_reference = function
    | `Assoc fields ->
      List.assoc_opt "type" fields = Some (`String "nodeReference")
      || List.exists (fun (_, value) -> has_reference value) fields
    | `List values -> List.exists has_reference values
    | _ -> false in
  if not (has_reference (`Assoc result))
  then failwith "save patch must immediately render newly staged reference metadata"
;;

let () =
  (* Exercise the host-visible cursor used by entity/pull while several asset
     uploads and metadata acknowledgements run ahead of WebSocket replay. *)
  List.iter (fun timing ->
    let replay_first = timing = 1 in
    let deferred_replay = timing = 2 in
    let state = Logseq_chat_lg_core_native.logseq_chat_sync_session_create_state
        "plain-1" "65.33" 42 in
    let attribute =
      { Datascript.cardinality = One; unique = Some Identity; indexed = true;
        is_component = false; no_history = false; doc = None;
        value_type = Some UuidType; tuple_attrs = None; tuple_types = None } in
    let conn = Datascript.create_conn ~schema:["block/uuid", attribute] () in
    let applied_count = ref 0 in
    let session = Logseq_chat_rpc.create
        ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
        ~sync_cursor:(fun () -> Some (Logseq_chat_lg_core_native.logseq_chat_sync_session_applied_server_t state))
        ~graph_blocks:(fun () -> Some [])
        ~journal_page_id:(fun ~journal_day:_ -> Some "journal-page")
        ~stage_operation:(fun _ -> Ok ())
        ~prepare_operation:prepare_test_operation
        ~apply_sync_event:(fun payload ->
          let fields = from_string payload |> function `Assoc fields -> fields | _ -> assert false in
          let change : Logseq_chat_lg_core_native.sync_change_set = { format_version = 1;
            graph_id = "plain-1"; schema_version = "65.33";
            t_before = required_int "before" fields; t = required_int "t" fields;
            upserts = List.init (required_int "t" fields - required_int "before" fields)
              (fun offset ->
                let module V = Transit_core.Json in
                let index = required_int "before" fields - 42 + offset + 1 in
                let uuid = Printf.sprintf "00000000-0000-4000-8000-%012d" index in
                { Logseq_chat_lg_core_native.id = V.Array [V.Keyword "block/uuid"; V.Uuid uuid];
                  attrs = [V.Keyword "block/uuid", V.Uuid uuid;
                           V.Keyword "block/title", V.String "photo.jpg"] });
            deleted = []; operation_ids = [] } in
          Logseq_chat_lg_core_native.logseq_chat_sync_session_apply_validated_change_set state change
            (fun change ->
              Logseq_chat_lg_core_native.logseq_chat_entity_sync_apply_change_set
                (fun value -> Ok value)
                conn
                change
              |> Result.map (fun () -> incr applied_count))
          |> Result.map_error (fun _ -> "sync cursor mismatch")) () in
    let dispatch action payload =
      let params = ["action", `String action] @
        (match payload with None -> [] | Some value -> ["payload", `String (to_string value)]) in
      Logseq_chat_rpc.call session
        (to_string (`Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
                           "params", `Assoc params])) in
    let result response = match from_string response with
      | `Assoc fields when assoc "ok" fields = Some (`Bool true) -> required_assoc "result" fields
      | _ -> failwith ("multi-asset dispatch failed: " ^ response) in
    let complete request body = dispatch "completePendingSync" (Some (`Assoc
      ["id", `Int (required_int "id" request); "status", `Int 200;
       "body", `String (to_string body); "error", `Null])) in
    configure_plain_graph session;
    for index = 1 to 3 do
      ignore (dispatch "addAsset" (Some (`Assoc [
        "uuid", `String (Printf.sprintf "00000000-0000-4000-8000-%012d" index);
        "title", `String "photo.jpg"; "now", `Int (1788000000000 + index);
        "assetType", `String "jpg"; "assetSize", `Int 4;
        "assetChecksum", `String "abcd"; "localPath", `String "Assets/photo.jpg"])))
    done;
    let next = ref (dispatch "beginPendingSync" None |> pending_request |> Option.get) in
    for index = 1 to 3 do
      assert_equal "each asset uploads bytes first" "PUT" (required_string "method" !next);
      let tx = complete !next (`Assoc ["ok", `Bool true]) |> pending_request |> Option.get in
      let before = Logseq_chat_lg_core_native.logseq_chat_sync_session_applied_server_t state in
      let accepted = 42 + index in
      if replay_first then ignore (dispatch "applySyncEvent"
        (Some (`Assoc ["before", `Int before; "t", `Int accepted])) |> result);
      let completion = complete tx (`Assoc ["type", `String "tx/batch/ok"; "t", `Int accepted]) in
      let visible = completion |> result |> required_int "appliedServerT" in
      assert_int_equal "asset completion reports only the applied cursor"
        (Logseq_chat_lg_core_native.logseq_chat_sync_session_applied_server_t state) visible;
      let snapshot_cursor = dispatch "startWebSocket" None |> result |> required_int "appliedServerT" in
      assert_int_equal "full snapshots preserve the same applied cursor" visible snapshot_cursor;
      if not replay_first && not deferred_replay then ignore (dispatch "applySyncEvent"
        (Some (`Assoc ["before", `Int snapshot_cursor; "t", `Int accepted])) |> result);
      if index < 3 then next := (dispatch "beginPendingSync" None |> pending_request |> Option.get)
    done;
    if deferred_replay then ignore (dispatch "applySyncEvent"
      (Some (`Assoc ["before", `Int 42; "t", `Int 45])) |> result);
    assert_int_equal "all asset replays applied" (if deferred_replay then 1 else 3) !applied_count;
    assert_int_equal "final applied cursor" 45 (Logseq_chat_lg_core_native.logseq_chat_sync_session_applied_server_t state);
    let asset_count = Datascript.datoms (Datascript.conn_db conn) Datascript.Aevt
      ~a:"block/uuid" () |> List.of_seq |> List.length in
    assert_int_equal "replay materializes every asset exactly once" 3 asset_count
  ) [0; 1; 2]
;;

let () =
  let session = Logseq_chat_rpc.create
      ~sync_cursor:(fun () -> Some 60)
      ~prepare_operation:prepare_test_operation () in
  let operation : Logseq_chat_lg_core_native.pending_operation =
    { operation_id = "late-ack"; base_t = 60; state = Queued;
      intent = Save_title { uuid = "remote"; expected_title = "Old"; title = "New" } } in
  configure_plain_graph session;
  session.semantic_queue <- [{ Logseq_chat_rpc.operation }];
  Logseq_chat_rpc.activate_semantic_request ~t_before:43 session (Option.get session.config);
  let request = Option.get session.semantic_active in
  let body = from_string (Option.get request.request.body) in
  match body with
  | `Assoc fields -> assert_int_equal "late HTTP acknowledgement cannot rewind transport cursor"
      60 (required_int "t-before" fields)
  | _ -> failwith "expected transaction request body"
;;
