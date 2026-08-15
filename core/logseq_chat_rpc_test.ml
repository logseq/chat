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

let encrypted_graph_catalog =
  {|{"graphs":[{"graph-id":"encrypted-1","graph-name":"Private","graph-e2ee?":true,"graph-ready-for-use?":true}]}|}
;;

let configure_encrypted_graph session =
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"configure","payload":"{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"\",\"token\":\"access\"}"}}|})
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
  let requests = ref [] in
  let uploads = ref [] in
  let send (request : Logseq_chat_api.request) =
    requests := request :: !requests;
    Ok Logseq_chat_api.{ status = 201; body = {|{"uuid":"encrypted-created"}|} }
  in
  let upload (request : Logseq_chat_api.file_upload) =
    uploads := request :: !uploads;
    Ok Logseq_chat_api.{ status = 201; body = {|{"uuid":"encrypted-asset"}|} }
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some encrypted_graph_catalog)
      ~graph_unlocked:(fun ~graph_id:_ -> true)
      ~encrypt_title:(fun ~graph_id:_ title -> Ok ("cipher(" ^ title ^ ")"))
      ~encrypt_asset_file:(fun ~graph_id:_ ~source_path:_ ->
        Ok ("/tmp/encrypted-asset.transit", 4096))
      ~journal_page_id:(fun ~journal_day ->
        if journal_day = 20260412 then Some "real-journal-page" else None)
      ~send
      ~upload_file:upload
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
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"send","payload":"{\"text\":\"Secret block\",\"uuid\":\"encrypted-local\",\"now\":1776000000000}"}}|});
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"syncPending"}}|});
  match !requests with
  | request :: _ ->
    assert_equal "encrypted capture method" "POST" request.method_;
    assert_equal
      "encrypted capture body"
      {|{"page-id":"real-journal-page","blocks":[{"uuid":"encrypted-local","title":"cipher(Secret block)"}]}|}
      (Option.value request.body ~default:"")
  | [] -> failwith "encrypted capture should use semantic REST"
;;

let () =
  let uploaded = ref None in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some encrypted_graph_catalog)
      ~graph_unlocked:(fun ~graph_id:_ -> true)
      ~encrypt_title:(fun ~graph_id:_ title -> Ok ("cipher(" ^ title ^ ")"))
      ~encrypt_asset_file:(fun ~graph_id:_ ~source_path ->
        assert_equal "asset encryption source" "/documents/photo.jpg" source_path;
        Ok ("/tmp/photo.transit", 4096))
      ~journal_page_id:(fun ~journal_day:_ -> Some "real-journal-page")
      ~send:(fun _ -> Error "unexpected plain request")
      ~upload_file:(fun request ->
        uploaded := Some request;
        Ok Logseq_chat_api.{ status = 201; body = {|{"uuid":"asset-local"}|} })
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
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"asset-local\",\"title\":\"photo.jpg\",\"now\":1776000000000,\"assetType\":\"jpg\",\"assetSize\":2048,\"assetChecksum\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"localPath\":\"/documents/photo.jpg\"}"}}|});
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"syncPending"}}|});
  match !uploaded with
  | Some upload ->
    assert_equal "encrypted upload path" "/tmp/photo.transit" upload.file_path;
    if not (String.contains upload.request.url '?')
    then failwith "encrypted asset request must include metadata";
    let contains fragment =
      try
        ignore (Str.search_forward (Str.regexp_string fragment) upload.request.url 0);
        true
      with Not_found -> false
    in
    if not (contains "size=2048&upload-size=4096")
    then failwith "encrypted asset must preserve logical and encoded sizes";
    if not (contains "title=cipher%28photo.jpg%29&page-id=real-journal-page")
    then failwith "encrypted asset must use ciphertext title and real journal page"
  | None -> failwith "encrypted asset should upload its encrypted payload"
;;

let () =
  let requests = ref [] in
  let send (request : Logseq_chat_api.request) =
    requests := !requests @ [ request ];
    if String.ends_with ~suffix:"/pages" request.url
    then
      Ok
        Logseq_chat_api.
          { status = 201
          ; body = {|{"uuid":"00000001-2026-0412-0000-000000000000"}|}
          }
    else Ok Logseq_chat_api.{ status = 201; body = {|{"uuid":"encrypted-missing-day"}|} }
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some encrypted_graph_catalog)
      ~graph_unlocked:(fun ~graph_id:_ -> true)
      ~encrypt_title:(fun ~graph_id:_ title -> Ok ("cipher(" ^ title ^ ")"))
      ~journal_page_id:(fun ~journal_day:_ -> None)
      ~send
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
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"send","payload":"{\"text\":\"First block of the day\",\"uuid\":\"encrypted-missing-day\",\"now\":1776000000000}"}}|});
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"syncPending"}}|});
  match !requests with
  | [ page_request; capture_request ] ->
    assert_equal "encrypted journal create method" "POST" page_request.method_;
    assert_equal
      "encrypted journal create URL"
      "http://127.0.0.1:8787/api/v1/graphs/encrypted-1/pages"
      page_request.url;
    assert_equal
      "encrypted journal create body"
      {|{"uuid":"00000001-2026-0412-0000-000000000000","title":"cipher(Apr 12th, 2026)","name":"cipher(apr 12th, 2026)","journal-day":20260412}|}
      (Option.value page_request.body ~default:"");
    assert_equal
      "capture after encrypted journal creation"
      {|{"page-id":"00000001-2026-0412-0000-000000000000","blocks":[{"uuid":"encrypted-missing-day","title":"cipher(First block of the day)"}]}|}
      (Option.value capture_request.body ~default:"")
  | requests ->
    failwith
      (Printf.sprintf
         "encrypted missing journal sync expected two semantic requests, got %d"
         (List.length requests))
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
