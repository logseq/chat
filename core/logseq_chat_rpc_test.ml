open Yojson.Basic

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

let () =
  let open Logseq_chat_outliner_state in
  let cases =
    [ "task", Task
    ; "outdent", Outdent
    ; "indent", Indent
    ; "tag", Tag_action
    ; "pageReference", Page_reference
    ; "camera", Camera
    ; "attachment", Attachment
    ; "hideKeyboard", Hide_keyboard
    ; "copy", Copy
    ; "delete", Delete
    ; "copyReference", Copy_reference
    ; "copyURL", Copy_url
    ; "unselect", Unselect
    ]
  in
  List.iter
    (fun (wire, expected) ->
      match Logseq_chat_rpc.toolbar_action wire with
      | Ok actual when actual = expected -> ()
      | Ok _ -> failwith ("wrong toolbar action mapping: " ^ wire)
      | Error message -> failwith ("missing toolbar action mapping: " ^ wire ^ ": " ^ message))
    cases;
  match Logseq_chat_rpc.toolbar_action "unsupported" with
  | Error "unknown outliner toolbar action" -> ()
  | _ -> failwith "unknown toolbar actions must be rejected"
;;

let assert_int_equal label expected actual =
  if expected <> actual
  then
    failwith
      (Printf.sprintf "%s: expected %d, got %d" label expected actual)
;;

let () =
  let block =
    Logseq_chat_model.
      { uuid = "source"
      ; kind = "block"
      ; title = "See [[target]]"
      ; page_id = "page"
      ; parent_id = None
      ; order = None
      ; created_at = 0
      ; updated_at = 0
      ; sync_status = "synced"
      ; tags = []
      ; references = [ { uuid = "target"; kind = "block"; title = "Target block" } ]
      ; status = None
      ; asset_type = None
      ; asset_size = None
      ; asset_checksum = None
      ; local_path = None
      ; journal = None
      }
  in
  match Logseq_chat_rpc.block_json block with
  | `Assoc fields ->
    (match required_list "markup" fields with
     | [ `Assoc [ "type", `String "text"; "text", `String "See " ]
       ; `Assoc
           [ "type", `String "nodeReference"
           ; "uuid", `String "target"
           ; "kind", `String "block"
           ; "title", `String "Target block"
           ]
       ] -> ()
     | _ -> failwith "block JSON must publish the OCaml mldoc render tree")
  | _ -> failwith "block JSON must remain an object"
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
  let response =
    Logseq_chat_rpc.call
      (Logseq_chat_rpc.create ())
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"syncPending"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    if required_bool "ok" fields then failwith "legacy syncPending action must be rejected";
    let error = required_assoc "error" fields in
    assert_equal "legacy syncPending error" "unknown_action" (required_string "code" error)
  | _ -> failwith "legacy syncPending rejection should return an RPC response"
;;

let () =
  let legacy_send_count = ref 0 in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~send:(fun _request ->
        incr legacy_send_count;
        failwith "the asynchronous pending pump must not call the legacy transport")
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"send","payload":"{\"text\":\"First title\",\"uuid\":\"async-local\",\"now\":1776000000000}"}}|});
  let request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
    |> Option.get
  in
  assert_equal "pending method" "POST" (required_string "method" request);
  assert_equal
    "pending URL"
    "http://127.0.0.1:8787/api/v1/graphs/plain-1/capture"
    (required_string "url" request);
  assert_int_equal "pending request id" 1 (required_int "id" request);
  if !legacy_send_count <> 0 then failwith "beginPendingSync performed blocking I/O";

  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"updateBlock","payload":"{\"uuid\":\"async-local\",\"title\":\"Edited while sending\",\"status\":null}"}}|});
  let completion =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":1,\"status\":201,\"body\":\"{\\\"uuid\\\":\\\"async-local\\\"}\",\"error\":null}"}}|}
  in
  if Option.is_some (pending_request completion)
  then failwith "one-item pending pump should finish after completion";
  match Logseq_chat_model.read_block session.model "async-local" with
  | Some block ->
    assert_equal "concurrent edit title" "Edited while sending" block.title;
    assert_equal "concurrent edit remains pending" "pending" block.sync_status
  | None -> failwith "completed pending block disappeared"
;;

let () =
  let authoritative =
    Logseq_chat_model.
      { uuid = "remote-task"
      ; kind = "task"
      ; title = "Old title"
      ; page_id = "journal-page"
      ; parent_id = None
      ; order = None
      ; created_at = 1_776_000_000_000
      ; updated_at = 1_776_000_000_000
      ; sync_status = "synced"
      ; tags = []
      ; references = []
      ; status = Some { uuid = "todo"; ident = None; title = "Todo"; icon_type = None; icon_id = None; icon_color = None }
      ; asset_type = None
      ; asset_size = None
      ; asset_checksum = None
      ; local_path = None
      ; journal = None
      }
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~graph_blocks:(fun () -> Some [ authoritative ])
      ()
  in
  configure_plain_graph session;
  Logseq_chat_model.upsert_blocks session.model [ authoritative ] ~refresh_time:authoritative.updated_at;
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"updateBlock","payload":"{\"uuid\":\"remote-task\",\"title\":\"New title\",\"status\":{\"uuid\":\"doing\",\"title\":\"Doing\"}}"}}|});
  let title_request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
    |> Option.get
  in
  assert_equal "update title method" "PATCH" (required_string "method" title_request);
  let status_request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":1,\"status\":200,\"body\":\"{}\",\"error\":null}"}}|}
    |> pending_request
    |> Option.get
  in
  assert_equal "update status method" "PUT" (required_string "method" status_request);
  if not (String.ends_with ~suffix:"/properties/Status" (required_string "url" status_request))
  then failwith "task update must follow title PATCH with status PUT";
  let finished =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":2,\"status\":200,\"body\":\"{}\",\"error\":null}"}}|}
  in
  if Option.is_some (pending_request finished) then failwith "task update pump did not finish";
  match Logseq_chat_model.read_block session.model "remote-task" with
  | Some block -> assert_equal "updated task submitted" "submitted" block.sync_status
  | None -> failwith "updated task disappeared"
;;

let () =
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some encrypted_graph_catalog)
      ~graph_unlocked:(fun ~graph_id:_ -> true)
      ~encrypt_title:(fun ~graph_id:_ title -> Ok ("cipher(" ^ title ^ ")"))
      ~journal_page_id:(fun ~journal_day:_ -> None)
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
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"sendTask","payload":"{\"text\":\"Secret task\",\"uuid\":\"encrypted-async\",\"now\":1776000000000,\"status\":{\"uuid\":\"todo\",\"title\":\"Todo\"}}"}}|});
  let page_request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
    |> Option.get
  in
  if not (String.ends_with ~suffix:"/pages" (required_string "url" page_request))
  then failwith "encrypted pending pump must create a missing journal first";
  let task_request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":1,\"status\":201,\"body\":\"{}\",\"error\":null}"}}|}
    |> pending_request
    |> Option.get
  in
  if not (String.ends_with ~suffix:"/tasks" (required_string "url" task_request))
  then failwith "encrypted pending pump must continue with semantic task REST";
  let body = required_string "body" task_request in
  if
    not (contains body {|"title":"cipher(Secret task)"|})
    || not (contains body {|"page-id":"00000001-2026-0412-0000-000000000000"|})
  then failwith "encrypted pending task must contain ciphertext and its journal page";
  let finished =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":2,\"status\":201,\"body\":\"{\\\"uuid\\\":\\\"encrypted-async\\\"}\",\"error\":null}"}}|}
  in
  if Option.is_some (pending_request finished) then failwith "encrypted task pump did not finish"
;;

let () =
  let cleaned = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some encrypted_graph_catalog)
      ~graph_unlocked:(fun ~graph_id:_ -> true)
      ~encrypt_title:(fun ~graph_id:_ title -> Ok ("cipher(" ^ title ^ ")"))
      ~encrypt_asset_file:(fun ~graph_id:_ ~source_path ->
        assert_equal "asset encryption source" "/documents/photo.jpg" source_path;
        Ok ("/tmp/photo.transit", 4096))
      ~journal_page_id:(fun ~journal_day:_ -> Some "real-journal-page")
      ~cleanup_file:(fun path -> cleaned := path :: !cleaned)
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
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"asset-async\",\"title\":\"photo.jpg\",\"now\":1776000000000,\"assetType\":\"jpg\",\"assetSize\":2048,\"assetChecksum\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"localPath\":\"/documents/photo.jpg\"}"}}|});
  let request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
    |> Option.get
  in
  assert_equal "encrypted asset method" "POST" (required_string "method" request);
  assert_equal "encrypted asset path" "/tmp/photo.transit" (required_string "filePath" request);
  assert_equal "encrypted asset content type" "text/plain" (required_string "contentType" request);
  let url = required_string "url" request in
  if not (contains url "size=2048&upload-size=4096")
  then failwith "encrypted asset must preserve logical and encoded sizes";
  if not (contains url "title=cipher%28photo.jpg%29&page-id=real-journal-page")
  then failwith "encrypted asset must use ciphertext title and real journal page";
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"cancelPendingSync"}}|});
  if !cleaned <> [ "/tmp/photo.transit" ]
  then failwith "cancelPendingSync must remove the temporary encrypted asset"
;;

let () =
  let session =
    Logseq_chat_rpc.create ~load_graph_catalog:(fun () -> Some plain_graph_catalog) ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"send","payload":"{\"text\":\"Retry later\",\"uuid\":\"failed-async\",\"now\":1776000000000}"}}|});
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|});
  let stale =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":99,\"status\":201,\"body\":\"{}\",\"error\":null}"}}|}
    |> from_string
  in
  (match stale with
   | `Assoc fields ->
     (match assoc "ok" fields with Some (`Bool false) -> () | _ -> failwith "stale completion must fail")
   | _ -> failwith "stale completion must return an RPC error");
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":1,\"status\":null,\"body\":null,\"error\":\"offline\"}"}}|});
  match Logseq_chat_model.read_block session.model "failed-async" with
  | Some block -> assert_equal "transport failure status" "failed" block.sync_status
  | None -> failwith "failed pending block disappeared"
;;

let () =
  let unlocked = ref false in
  let loaded = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some encrypted_graph_catalog)
      ~load_cached_graph_key:(fun ~graph_id ->
        loaded := graph_id :: !loaded;
        Error "not cached")
      ~graph_unlocked:(fun ~graph_id:_ -> !unlocked)
      ()
  in
  configure_encrypted_graph session;
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"selectGraph","payload":"encrypted-1"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    (match assoc "ok" fields with
     | Some (`Bool true) -> ()
     | _ -> failwith "encrypted graph selection should succeed");
    let result = required_assoc "result" fields in
    if not (required_bool "isGraphEncrypted" result)
    then failwith "selected encrypted graph must be identified as encrypted";
    if required_bool "isGraphUnlocked" result
    then failwith "encrypted graph without a cached key must remain locked";
    if !loaded <> [ "encrypted-1" ]
    then failwith "encrypted graph selection must try the offline key cache"
  | _ -> failwith "selectGraph should return an RPC response"
;;

let () =
  let unlocked = ref false in
  let received = ref None in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some encrypted_graph_catalog)
      ~unlock_graph:(fun _config ~password ->
        received := Some password;
        unlocked := true;
        Ok ())
      ~graph_unlocked:(fun ~graph_id:_ -> !unlocked)
      ()
  in
  configure_encrypted_graph session;
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"selectGraph","payload":"encrypted-1"}}|});
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"unlockGraph","payload":"correct horse"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    (match assoc "ok" fields with
     | Some (`Bool true) -> ()
     | _ -> failwith "unlockGraph should succeed");
    if !received <> Some "correct horse"
    then failwith "unlockGraph must pass the password to the native keyring";
    let result = required_assoc "result" fields in
    if not (required_bool "isGraphUnlocked" result)
    then failwith "successful unlock must update graph state"
  | _ -> failwith "unlockGraph should return an RPC response"
;;

let () =
  let session = Logseq_chat_rpc.create () in
  let response =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"send","payload":"{\"text\":\"Optimistic capture\",\"uuid\":\"local-swift\",\"now\":1776000000000}"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    let result = required_assoc "result" fields in
    let blocks = required_list "blocks" result in
    (match blocks with
     | `Assoc block :: _ ->
       assert_equal "uuid" "local-swift" (required_string "uuid" block);
       assert_equal "title" "Optimistic capture" (required_string "title" block);
       assert_equal "sync status" "pending" (required_string "syncStatus" block);
       assert_int_equal "created at" 1_776_000_000_000 (required_int "createdAt" block)
     | _ -> failwith "expected one returned block")
  | _ -> failwith "expected RPC response object"
;;

let () =
  let session = Logseq_chat_rpc.create () in
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"configure","payload":"{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"cached-graph\",\"graphName\":\"Sync 2\",\"token\":\"\"}"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    let result = required_assoc "result" fields in
    assert_equal "cached graph id" "cached-graph" (required_string "selectedGraphId" result);
    assert_equal "cached graph name" "Sync 2" (required_string "graphName" result)
  | _ -> failwith "configure should restore a cached graph name"
;;

let () =
  let session = Logseq_chat_rpc.create () in
  let response =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"clearRelated"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    let result = required_assoc "result" fields in
    ignore (required_list "relatedBlocks" result)
  | _ -> failwith "clearRelated should expose related blocks"
;;

let () =
  let page = Logseq_chat_graph_read.{ uuid = "page-1"; title = "Page one" } in
  let block =
    Logseq_chat_model.
      { uuid = "block-1"
      ; kind = "block"
      ; title = "Referenced block"
      ; page_id = page.uuid
      ; parent_id = Some page.uuid
      ; order = Some "a0"
      ; created_at = 1
      ; updated_at = 1
      ; sync_status = "synced"
      ; tags = []
      ; references = []
      ; status = None
      ; asset_type = None
      ; asset_size = None
      ; asset_checksum = None
      ; local_path = None
      ; journal = None
      }
  in
  let session =
    Logseq_chat_rpc.create
      ~graph_node_destination:(function
        | "page-1" -> Some (page, false)
        | "block-1" -> Some (page, true)
        | _ -> None)
      ~graph_page_blocks:(fun uuid -> if uuid = page.uuid then Some [ block ] else None)
      ~graph_node_references:(fun uuid -> if uuid = "block-1" then Some [ block ] else None)
      ~graph_tag_objects:(fun uuid -> if uuid = "tag-1" then Some [ block ] else None)
      ()
  in
  let opened =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"openNode","payload":"block-1"}}|}
    |> from_string
  in
  (match opened with
   | `Assoc fields ->
     let result = required_assoc "result" fields in
     assert_equal "node page" "page-1" (required_assoc "selectedPage" result |> required_string "uuid");
     (match required_assoc "outlinerState" result |> required_list "zoomedBlockIds" with
      | [ `String "block-1" ] -> ()
      | _ -> failwith "ordinary node navigation must zoom to the referenced block");
     let related = required_first_assoc "relatedBlocks" result in
     assert_equal "projected node reference" "block-1" (required_string "uuid" related)
   | _ -> failwith "openNode should return an RPC response");
  let objects =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"loadTagObjects","payload":"tag-1"}}|}
    |> from_string
  in
  match objects with
  | `Assoc fields ->
    let related = required_assoc "result" fields |> required_first_assoc "relatedBlocks" in
    assert_equal "projected tag object" "block-1" (required_string "uuid" related)
  | _ -> failwith "loadTagObjects should return projected objects"
;;

let () =
  let window = ref 7 in
  let session =
    Logseq_chat_rpc.create
      ~load_older_journals:(fun () -> window := !window + 7)
      ~has_older_journals:(fun () -> !window < 14)
      ()
  in
  let initial =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"snapshot","params":{}}|}
    |> from_string
  in
  (match initial with
   | `Assoc fields ->
     if not (required_assoc "result" fields |> required_bool "hasOlderJournals")
     then failwith "snapshot must expose the bounded journal window"
   | _ -> failwith "snapshot should return an RPC response");
  let expanded =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"loadOlderJournals"}}|}
    |> from_string
  in
  match expanded with
  | `Assoc fields ->
    if required_assoc "result" fields |> required_bool "hasOlderJournals"
    then failwith "loadOlderJournals must expand the core-owned window"
  | _ -> failwith "loadOlderJournals should return an RPC response"
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
    Logseq_chat_model.
      { uuid = "restored-journal-block"
      ; kind = "block"
      ; title = "Restored from the graph snapshot"
      ; page_id = "journal-page"
      ; parent_id = Some "journal-page"
      ; order = Some "a0"
      ; created_at = 1_776_000_000_000
      ; updated_at = 1_776_000_000_000
      ; sync_status = "synced"
      ; tags = []
      ; references = []
      ; status = None
      ; asset_type = None
      ; asset_size = None
      ; asset_checksum = None
      ; local_path = None
      ; journal = Some ("Aug 15th, 2026", 20260815)
      }
  in
  let session =
    Logseq_chat_rpc.create
      ~open_graph:(fun _payload -> Ok ())
      ~graph_blocks:(fun () -> Some [ authoritative ])
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

let assert_dispatch_block action payload expected_kind expected_uuid =
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
       assert_equal (action ^ " kind") expected_kind (required_string "kind" block);
       assert_equal (action ^ " uuid") expected_uuid (required_string "uuid" block)
     | _ -> failwith (action ^ " should return one optimistic block"))
  | _ -> failwith (action ^ " should return an RPC response")
;;

let () =
  assert_dispatch_block
    "sendTask"
    {|{"text":"Follow up","uuid":"task-local","now":1776000000000,"status":{"uuid":"status-waiting","ident":"user.status/waiting","title":"Waiting","iconType":"tabler-icon","iconId":"clock"}}|}
    "task" "task-local";
  assert_dispatch_block
    "addAsset"
    {|{"uuid":"asset-local","title":"photo.jpg","now":1776000000001,"assetType":"jpg","assetSize":2048,"assetChecksum":"abc","localPath":"/documents/photo.jpg"}|}
    "asset" "asset-local"
;;

let () =
  let authoritative_blocks = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~feed_sse:(fun _chunk ->
        authoritative_blocks :=
          [ Logseq_chat_model.
              { uuid = "local-self-echo"
              ; kind = "block"
              ; title = "Synced capture"
              ; page_id = "journal/2026-08-15"
              ; parent_id = None
              ; order = None
              ; created_at = 1_776_000_000_000
              ; updated_at = 1_776_000_000_000
              ; sync_status = "synced"
              ; tags = []
              ; references = []
              ; status = None
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
  if List.length (Logseq_chat_model.pending_blocks session.model) <> 1
  then failwith "local capture should start pending";
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"feedSSE","payload":"self-echo"}}|});
  if Logseq_chat_model.pending_blocks session.model <> []
  then failwith "authoritative SSE self-echo should clear local pending state"
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
  ignore (Logseq_chat_model.mark_block_synced session.model ~uuid:"synced-asset");
  authoritative_blocks :=
    [ Logseq_chat_model.
        { uuid = "synced-asset"
        ; kind = "block"
        ; title = "photo.png"
        ; page_id = "journal/2026-08-15"
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
       assert_equal "synced asset kind" "asset" (required_string "kind" block);
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
  Logseq_chat_model.
    { uuid
    ; kind = "block"
    ; title
    ; page_id = "page"
    ; parent_id = Some "page"
    ; order = Some "a0"
    ; created_at = 1
    ; updated_at = 1
    ; sync_status = "synced"
    ; tags = []
    ; references = []
    ; status = None
    ; asset_type = None
    ; asset_size = None
    ; asset_checksum = None
    ; local_path = None
    ; journal = None
    }
;;

let prepare_test_operation operation =
  Ok
    ( Logseq_chat_pending_ops.outliner_op operation.Logseq_chat_pending_ops.intent
    , "[]" )
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
      Logseq_chat_model.parent_id = Some parent.uuid
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
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 91)
      ~graph_blocks:(fun () -> Some [ remote_block "selected" "Selected" ])
      ~stage_operation:(fun operation -> staged := !staged @ [ operation ]; Ok ())
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
   | [ { Logseq_chat_pending_ops.base_t = 91
       ; intent = Delete_blocks { uuids = [ "selected" ] }
       ; _ } ] -> ()
   | _ -> failwith "confirmed outliner delete must stage one semantic operation");
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
  | [ { Logseq_chat_pending_ops.base_t = 92
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
      Logseq_chat_model.parent_id = Some "parent"
    }
  in
  let sibling =
    { (remote_block "sibling" "Sibling") with
      Logseq_chat_model.order = Some "a1"
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
  (match required_list "outlinerRows" collapsed with
   | [ `Assoc parent_row; `Assoc sibling_row ] ->
     assert_equal
       "collapsed first row"
       "parent"
       (required_assoc "block" parent_row |> required_string "uuid");
     if not (required_bool "isCollapsed" parent_row)
     then failwith "collapsed row must expose reducer state";
     assert_equal
       "collapsed sibling row"
       "sibling"
       (required_assoc "block" sibling_row |> required_string "uuid")
   | _ -> failwith "collapsed outliner rows must hide descendants");
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
  (match required_list "outlinerRows" zoomed with
   | [ `Assoc row ] ->
     assert_equal "zoomed row" "parent" (required_assoc "block" row |> required_string "uuid")
   | _ -> failwith "zoom must expose only the selected subtree")
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
   | [ { Logseq_chat_pending_ops.operation_id = "op-title"
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
  | { Logseq_chat_pending_ops.operation_id = "op-accepted"; state = Accepted 44; _ } :: _ -> ()
  | _ -> failwith "semantic completion must persist the accepted server cursor"
;;

let () =
  let persisted = ref [] in
  let stage operation =
    persisted :=
      List.filter
        (fun pending ->
          not
            (String.equal
               pending.Logseq_chat_pending_ops.operation_id
               operation.Logseq_chat_pending_ops.operation_id))
        !persisted
      @ [ operation ];
    Ok ()
  in
  let pending_operations () =
    List.filter
      (fun operation ->
        match operation.Logseq_chat_pending_ops.state with
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
   | [ { Logseq_chat_pending_ops.operation_id = "op-retry"; state = Retryable; _ } ] -> ()
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
   | [ { Logseq_chat_pending_ops.operation_id = "op-delete"
       ; base_t = 77
       ; intent = Delete_blocks { uuids = [ "delete-me" ] }
       ; _ } ] -> ()
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
   | [ { Logseq_chat_pending_ops.operation_id = "op-split"
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
   | [ { Logseq_chat_pending_ops.operation_id = "op-merge"
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
   | [ { Logseq_chat_pending_ops.intent = Move_blocks { moves = [ first; second ] }; _ } ] ->
     assert_equal "first moved block" "first" first.uuid;
     assert_equal "second moved block" "second" second.uuid
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
  | [ { Logseq_chat_pending_ops.intent = Delete_blocks { uuids = [ "first"; "second" ] }; _ } ] -> ()
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
   | [ { Logseq_chat_pending_ops.operation_id = "op-status"
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
    Logseq_chat_model.
      { uuid = "offline-edit"
      ; kind = "block"
      ; title = "Server title"
      ; page_id = "journal/2026-08-15"
      ; parent_id = None
      ; order = None
      ; created_at = 1_776_000_000_000
      ; updated_at = 1_776_000_000_000
      ; sync_status = "synced"
      ; tags = []
      ; references = []
      ; status = None
      ; asset_type = None
      ; asset_size = None
      ; asset_checksum = None
      ; local_path = None
      ; journal = None
      }
  in
  let session =
    Logseq_chat_rpc.create ~graph_blocks:(fun () -> Some [ authoritative ]) ()
  in
  Logseq_chat_model.upsert_journal_page
    session.model ~uuid:"journal/2026-08-15" ~journal_day:20260815;
  Logseq_chat_model.upsert_blocks
    session.model [ authoritative ] ~refresh_time:1_776_000_000_000;
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"updateBlock","payload":"{\"uuid\":\"offline-edit\",\"title\":\"Edited offline\",\"status\":null}"}}|}
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
  let projected = ref [ source ] in
  let server_t = ref 42 in
  let authoritative = Hashtbl.create 8 in
  let prepare_calls = ref 0 in
  Hashtbl.add authoritative "source" ();
  let find_projected uuid =
    List.find_opt
      (fun (block : Logseq_chat_model.block) -> String.equal block.uuid uuid)
      !projected
  in
  let replace_projected uuid update =
    projected :=
      List.map
        (fun (block : Logseq_chat_model.block) ->
          if String.equal block.uuid uuid then update block else block)
        !projected
  in
  let stage operation =
    (match operation.Logseq_chat_pending_ops.intent with
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
           (fun (block : Logseq_chat_model.block) -> not (String.equal block.uuid uuid))
           !projected
     | _ -> ());
    Ok ()
  in
  let prepare operation =
    incr prepare_calls;
    let exists uuid = Hashtbl.mem authoritative uuid in
    let dependencies_exist =
      match operation.Logseq_chat_pending_ops.intent with
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
  let first_split = dispatch_outliner session (`Assoc [ "type", `String "returnPressed" ]) in
  let first_uuid =
    required_assoc "outlinerState" first_split
    |> required_assoc "editing"
    |> required_string "uuid"
  in
  let second_split = dispatch_outliner session (`Assoc [ "type", `String "returnPressed" ]) in
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
        ; "selectionLength", `Int 0
        ])
  in
  assert_equal
    "repeated structural edits keep the inline editor focused"
    first_uuid
    (required_assoc "outlinerState" merged
     |> required_assoc "editing"
     |> required_string "uuid");
  let merged_again =
    dispatch_outliner
      session
      (`Assoc
        [ "type", `String "backspacePressed"
        ; "selectionLength", `Int 0
        ])
  in
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
