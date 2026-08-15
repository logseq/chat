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
