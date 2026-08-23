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
    ; "audio", Audio
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
      ; title = "See [[target]]"
      ; page_id = "page"
      ; parent_id = None
      ; order = None
      ; created_at = 0
      ; updated_at = 0
      ; sync_status = "synced"
      ; tags = []
      ; references = [ { uuid = "target"; title = "Target block" } ]
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
  match Logseq_chat_rpc.block_json block with
  | `Assoc fields ->
    (match required_list "markup" fields with
     | [ `Assoc [ "type", `String "text"; "text", `String "See " ]
       ; `Assoc
           [ "type", `String "nodeReference"
           ; "uuid", `String "target"
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

let () =
  let created = ref false in
  let provisioned = ref None in
  let session =
    Logseq_chat_rpc.create
      ~send:(fun request ->
        if String.equal request.Logseq_chat_api.method_ "POST"
           && String.ends_with ~suffix:"/graphs" request.url
        then (
          created := true;
          Ok Logseq_chat_api.{ status = 201; body = {|{"graph-id":"new-private"}|} })
        else if String.ends_with ~suffix:"/graphs" request.url
        then
          Ok
            Logseq_chat_api.
              { status = 200
              ; body =
                  (if !created
                   then
                     {|{"graphs":[{"graph-id":"new-private","graph-name":"Private notes","schema-version":"65.33","graph-e2ee?":true,"graph-ready-for-use?":true}]}|}
                   else {|{"graphs":[]}|})
              }
        else Error ("unexpected request: " ^ request.url))
      ~provision_graph_key:(fun config ->
        provisioned := Some config.Logseq_chat_api.graph_id;
        Ok ())
      ()
  in
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"configure","payload":"{\"baseUrl\":\"https://api.example\",\"graphId\":\"\",\"token\":\"access\"}"}}|});
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"createSyncGraph","payload":"{\"name\":\"Private notes\",\"isEncrypted\":true}"}}|}
    |> from_string
  in
  (match response with
   | `Assoc fields ->
     (match assoc "ok" fields with
      | Some (`Bool true) -> ()
      | _ -> failwith "encrypted graph creation should succeed")
   | _ -> failwith "createSyncGraph should return an RPC response");
  if !provisioned <> Some "new-private"
  then failwith "encrypted graph creation must provision its AES key"
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
  let response =
    Logseq_chat_rpc.call
      (Logseq_chat_rpc.create ())
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"loadFlashcards","payload":"1776000000000"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    if not (required_bool "ok" fields) then failwith "loading flashcards should succeed";
    let result = required_assoc "result" fields in
    if required_list "flashcards" result <> []
    then failwith "a session without an open graph has no due flashcards"
  | _ -> failwith "loadFlashcards should return an RPC response"
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
  let capture_response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"send","payload":"{\"text\":\"First title\",\"uuid\":\"async-local\",\"now\":1776000000000}"}}|}
  in
  (match from_string capture_response with
   | `Assoc fields ->
     let result = required_assoc "result" fields in
     if not (required_bool "hasPendingSemanticOperations" result)
     then failwith "pending block writes must publish live pending state"
   | _ -> failwith "capture response must be an RPC object");
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
      ; title = "Old title"
      ; page_id = "journal-page"
      ; parent_id = None
      ; order = None
      ; created_at = 1_776_000_000_000
      ; updated_at = 1_776_000_000_000
      ; sync_status = "synced"
      ; tags = []
      ; references = []
      ; breadcrumbs = []
      ; status = Some { uuid = "todo"; ident = None; title = "Todo"; icon_type = None; icon_id = None; icon_color = None }
      ; is_asset = false
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
  let staged = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some encrypted_graph_catalog)
      ~graph_unlocked:(fun ~graph_id:_ -> true)
      ~sync_cursor:(fun () -> Some 91)
      ~journal_page_id:(fun ~journal_day:_ -> None)
      ~stage_operation:(fun operation ->
        staged := !staged @ [ operation ];
        Ok ())
      ~prepare_operation:(fun operation ->
        Ok
          ( Logseq_chat_pending_ops.outliner_op operation.Logseq_chat_pending_ops.intent
          , "[]" ))
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
  (match !staged with
   | [ { Logseq_chat_pending_ops.intent = Create_journal { block_uuid; title; _ }; _ }
     ; { intent = Set_property { uuid; attr; _ }; _ }
     ] ->
     assert_equal "encrypted task journal block" "encrypted-async" block_uuid;
     assert_equal "encrypted task title" "Secret task" title;
     assert_equal "encrypted task status block" "encrypted-async" uuid;
     assert_equal "encrypted task status property" "logseq.property/status" attr
   | _ -> failwith "encrypted task must stage journal insertion and status operations");
  let journal_request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
    |> Option.get
  in
  assert_equal
    "encrypted task journal tx"
    "http://127.0.0.1:8787/sync/encrypted-1/tx/batch"
    (required_string "url" journal_request);
  let status_request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":1,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/batch/ok\\\",\\\"t\\\":92}\",\"error\":null}"}}|}
    |> pending_request
    |> Option.get
  in
  assert_equal
    "encrypted task status tx"
    "http://127.0.0.1:8787/sync/encrypted-1/tx/batch"
    (required_string "url" status_request);
  let finished =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":2,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/batch/ok\\\",\\\"t\\\":93}\",\"error\":null}"}}|}
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
  let session =
    Logseq_chat_rpc.create ~load_graph_catalog:(fun () -> Some plain_graph_catalog) ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"send","payload":"{\"text\":\"Canceled request\",\"uuid\":\"canceled-pending\",\"now\":1776000000000}"}}|});
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|});
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"cancelPendingSync"}}|});
  let late =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":1,\"status\":201,\"body\":\"{\\\"uuid\\\":\\\"canceled-pending\\\"}\",\"error\":null}"}}|}
    |> from_string
  in
  match late with
  | `Assoc fields when required_bool "ok" fields -> ()
  | _ -> failwith "a completion arriving after cancellation must be an idempotent no-op"
;;

let () =
  let session =
    Logseq_chat_rpc.create ~load_graph_catalog:(fun () -> Some plain_graph_catalog) ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"send","payload":"{\"text\":\"Duplicate completion\",\"uuid\":\"duplicate-pending\",\"now\":1776000000000}"}}|});
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|});
  let completion =
    {|{"apiVersion":1,"method":"dispatch","params":{"action":"completePendingSync","payload":"{\"id\":1,\"status\":201,\"body\":\"{\\\"uuid\\\":\\\"duplicate-pending\\\"}\",\"error\":null}"}}|}
  in
  ignore (Logseq_chat_rpc.call session completion);
  let duplicate = Logseq_chat_rpc.call session completion |> from_string in
  match duplicate with
  | `Assoc fields when required_bool "ok" fields -> ()
  | _ -> failwith "a duplicate completion must be an idempotent no-op"
;;

let () =
  let unlocked = ref false in
  let loaded = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some encrypted_graph_catalog)
      ~load_cached_graph_key:(fun config ->
        loaded := config.Logseq_chat_api.graph_id :: !loaded;
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
  let parent =
    Logseq_chat_model.
      { uuid = "page-parent"; title = "Parent"; page_id = "selected-page"
      ; parent_id = Some "selected-page"; order = Some "a0"; created_at = 1; updated_at = 1
      ; sync_status = "synced"; tags = []; references = []; breadcrumbs = []
      ; status = None; is_asset = false; asset_type = None; asset_size = None
      ; asset_checksum = None; local_path = None; journal = None
      }
  in
  let session =
    Logseq_chat_rpc.create
      ~graph_page_blocks:(fun page_id ->
        if String.equal page_id "selected-page" then Some [ parent ] else Some [])
      ()
  in
  session.selected_sidebar_page <-
    Some Logseq_chat_graph_read.{ uuid = "selected-page"; title = "Selected page" };
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
      ; title = "Referenced block"
      ; page_id = page.uuid
      ; parent_id = Some page.uuid
      ; order = Some "a0"
      ; created_at = 1
      ; updated_at = 1
      ; sync_status = "synced"
      ; tags = []
      ; references = []
      ; breadcrumbs = [ { uuid = page.uuid; title = page.title } ]
      ; status = None
      ; is_asset = false
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
        | "tag-1" -> Some (page, false)
        | _ -> None)
      ~graph_page_blocks:(fun uuid -> if uuid = page.uuid then Some [ block ] else None)
      ~graph_tag_pages:(fun () -> Some [ Logseq_chat_graph_read.{ uuid = "tag-1"; title = "Tag one" } ])
      ~graph_node_is_tag:(String.equal "tag-1")
      ~graph_node_references:(fun uuid -> if uuid = "block-1" then Some [ block ] else None)
      ~graph_tag_objects:(fun uuid -> if uuid = "tag-1" then Some [ block ] else None)
      ()
  in
  let opened =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"openNode","payload":"{\"uuid\":\"block-1\"}"}}|}
    |> from_string
  in
  (match opened with
   | `Assoc fields ->
     let result = required_assoc "result" fields in
     (match assoc "selectedPage" result with
      | Some `Null -> ()
      | _ -> failwith "opening a node route must not replace the root projection");
     let route = required_first_assoc "nodeRoutes" result in
     assert_equal "node route id" "block-1" (required_string "uuid" route);
     assert_equal "node page" "page-1" (required_assoc "page" route |> required_string "uuid");
     (match required_assoc "outlinerState" route |> required_list "zoomedBlockIds" with
      | [ `String "block-1" ] -> ()
      | _ -> failwith "ordinary node navigation must zoom to the referenced block");
     let related = required_first_assoc "relatedBlocks" route in
     assert_equal "projected node reference" "block-1" (required_string "uuid" related);
     ignore (required_list "breadcrumbs" related)
   | _ -> failwith "openNode should return an RPC response");
  let edit_patch =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"outlinerEvent","payload":"{\"type\":\"tapBlock\",\"uuid\":\"block-1\"}"}}|}
    |> from_string
  in
  (match edit_patch with
   | `Assoc fields ->
     let result = required_assoc "result" fields in
     if required_bool "isOutlinerPatch" result
     then failwith "node route editing must refresh its independent projection";
     let route = required_first_assoc "nodeRoutes" result in
     (match required_assoc "outlinerState" route |> assoc "editing" with
      | Some (`Assoc editing) -> assert_equal "editing route block" "block-1" (required_string "uuid" editing)
      | _ -> failwith "node route editing state is missing")
   | _ -> failwith "tapBlock should return an outliner patch");
  let objects =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"openNode","payload":"{\"uuid\":\"tag-1\"}"}}|}
    |> from_string
  in
  match objects with
  | `Assoc fields ->
    let routes = required_assoc "result" fields |> required_list "nodeRoutes" in
    if List.length routes <> 2 then failwith "nested node navigation must retain both projections";
    let route =
      match List.rev routes with `Assoc route :: _ -> route | _ -> failwith "missing tag route"
    in
    if not (required_bool "isTag" route) then failwith "block/tags must identify tag routes";
    let related = required_first_assoc "relatedBlocks" route in
    assert_equal "projected tag object" "block-1" (required_string "uuid" related);
    ignore (required_list "breadcrumbs" related);
    let closed =
      Logseq_chat_rpc.call session
        {|{"apiVersion":1,"method":"dispatch","params":{"action":"closeNode"}}|}
      |> from_string
    in
    (match closed with
     | `Assoc fields ->
       let routes = required_assoc "result" fields |> required_list "nodeRoutes" in
       if List.length routes <> 1 then failwith "closing a node must restore the previous projection"
     | _ -> failwith "closeNode should return an RPC response")
  | _ -> failwith "loadTagObjects should return projected objects"
;;

let () =
  (* Selecting a tag (class) page from the sidebar must project its tagged
     objects without a separate loadTagObjects round trip. *)
  let tag_page = Logseq_chat_graph_read.{ uuid = "tag-1"; title = "Task" } in
  let tagged =
    Logseq_chat_model.
      { uuid = "task-1"
      ; title = "Do the thing"
      ; page_id = "page-1"
      ; parent_id = Some "page-1"
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
  in
  let linked = { tagged with uuid = "reference-1"; title = "Links Task" } in
  let session =
    Logseq_chat_rpc.create
      ~graph_sidebar_pages:(fun () ->
        Some Logseq_chat_graph_read.{ favorites = [ tag_page ]; recent_pages = [] })
      ~graph_page_blocks:(fun _ -> Some [])
      ~graph_node_is_tag:(String.equal tag_page.uuid)
      ~graph_tag_objects:(fun uuid ->
        if String.equal uuid tag_page.uuid then Some [ tagged ] else None)
      ~graph_node_references:(fun uuid ->
        if String.equal uuid tag_page.uuid then Some [ linked ] else None)
      ()
  in
  let response =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"selectPage","payload":"tag-1"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    let result = required_assoc "result" fields in
    if not (required_bool "selectedPageIsTag" result)
    then failwith "selecting a tag page must mark the projection as a tag";
    let related = required_first_assoc "relatedBlocks" result in
    assert_equal "sidebar tag object" "task-1" (required_string "uuid" related);
    let linked_references = required_first_assoc "linkedReferenceBlocks" result in
    assert_equal
      "sidebar tag linked reference"
      "reference-1"
      (required_string "uuid" linked_references)
  | _ -> failwith "selectPage should return an RPC response"
;;

let () =
  (* Sidebar page selection keeps the original non-route interaction while
     projecting the same linked references as a node view. *)
  let page = Logseq_chat_graph_read.{ uuid = "page-1"; title = "Page one" } in
  let reference =
    Logseq_chat_model.
      { uuid = "reference-1"
      ; title = "Links Page one"
      ; page_id = "journal-1"
      ; parent_id = Some "journal-1"
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
  in
  let session =
    Logseq_chat_rpc.create
      ~graph_sidebar_pages:(fun () ->
        Some Logseq_chat_graph_read.{ favorites = [ page ]; recent_pages = [] })
      ~graph_page_blocks:(fun _ -> Some [])
      ~graph_node_references:(fun uuid ->
        if String.equal uuid page.uuid then Some [ reference ] else None)
      ()
  in
  let response =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"selectPage","payload":"page-1"}}|}
    |> from_string
  in
  match response with
  | `Assoc fields ->
    let result = required_assoc "result" fields in
    if required_bool "selectedPageIsTag" result
    then failwith "a regular sidebar page must not be projected as a tag";
    let related = required_first_assoc "relatedBlocks" result in
    assert_equal "sidebar linked reference" "reference-1" (required_string "uuid" related);
    let routes = required_list "nodeRoutes" result in
    if routes <> [] then failwith "sidebar page selection must not create a node route"
  | _ -> failwith "selectPage should return an RPC response"
;;

let () =
  (* searchNodes projects sqlite search hits with page context and
     breadcrumbs, and clears them for blank queries. *)
  let hit =
    Logseq_chat_search_index.
      { uuid = "block-1"
      ; title = "Search me"
      ; is_page = false
      ; page = Some Logseq_chat_graph_read.{ uuid = "page-1"; title = "Page one" }
      ; breadcrumbs = [ Logseq_chat_model.{ uuid = "page-1"; title = "Page one" } ]
      }
  in
  let session =
    Logseq_chat_rpc.create
      ~graph_search:(fun query -> if String.equal query "search" then [ hit ] else [])
      ()
  in
  let response =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"searchNodes","payload":"search"}}|}
    |> from_string
  in
  (match response with
   | `Assoc fields ->
     let result = required_assoc "result" fields in
     assert_equal "search query echoed" "search" (required_string "searchQuery" result);
     let first = required_first_assoc "searchResults" result in
     assert_equal "search hit uuid" "block-1" (required_string "uuid" first);
     assert_equal "search hit title" "Search me" (required_string "title" first);
     if required_bool "isPage" first then failwith "block hits must not be pages";
     assert_equal
       "search hit page"
       "page-1"
       (required_assoc "page" first |> required_string "uuid");
     (match required_list "breadcrumbs" first with
      | [ `Assoc crumb ] -> assert_equal "search breadcrumb" "Page one" (required_string "title" crumb)
      | _ -> failwith "search hit should include breadcrumbs")
   | _ -> failwith "searchNodes should return an RPC response");
  let cleared =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"searchNodes","payload":""}}|}
    |> from_string
  in
  match cleared with
  | `Assoc fields ->
    (match required_assoc "result" fields |> required_list "searchResults" with
     | [] -> ()
     | _ -> failwith "blank queries must clear search results")
  | _ -> failwith "searchNodes should clear results"
;;

let () =
  (* Navigation must resolve from the same projected blocks that produced the
     visible UI. A transport refresh can make the dedicated destination index
     temporarily unavailable while the current projection is still valid. *)
  let page_uuid = "projected-page" in
  let projected =
    Logseq_chat_model.
      { uuid = "projected-block"
      ; title = "Projected block"
      ; page_id = page_uuid
      ; parent_id = Some page_uuid
      ; order = Some "a0"
      ; created_at = 1
      ; updated_at = 1
      ; sync_status = "pending"
      ; tags = []
      ; references = []
      ; breadcrumbs = [ { uuid = page_uuid; title = "Projected page" } ]
      ; status = None
      ; is_asset = false
      ; asset_type = None
      ; asset_size = None
      ; asset_checksum = None
      ; local_path = None
      ; journal = None
      }
  in
  let session =
    Logseq_chat_rpc.create
      ~graph_blocks:(fun () -> Some [ projected ])
      ~graph_page_blocks:(fun uuid ->
        if String.equal uuid page_uuid then Some [ projected ] else Some [])
      ~graph_node_destination:(fun _ -> None)
      ()
  in
  let open_node uuid =
    Logseq_chat_rpc.call session
      (Printf.sprintf
         {|{"apiVersion":1,"method":"dispatch","params":{"action":"openNode","payload":"{\"uuid\":\"%s\"}"}}|}
         uuid)
    |> from_string
  in
  let assert_opened ~uuid ~zoomed response =
    match response with
    | `Assoc fields ->
      let route = required_assoc "result" fields |> required_first_assoc "nodeRoutes" in
      assert_equal "projected route id" uuid (required_string "uuid" route);
      assert_equal
        "projected route page"
        page_uuid
        (required_assoc "page" route |> required_string "uuid");
      let zoomed_ids = required_assoc "outlinerState" route |> required_list "zoomedBlockIds" in
      if zoomed
      then (match zoomed_ids with [ `String "projected-block" ] -> () | _ -> failwith "projected block must zoom")
      else if zoomed_ids <> []
      then failwith "projected page must not zoom"
    | _ -> failwith "visible projected nodes must remain navigable"
  in
  assert_opened ~uuid:page_uuid ~zoomed:false (open_node page_uuid);
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"closeNode"}}|});
  assert_opened ~uuid:"projected-block" ~zoomed:true (open_node "projected-block")
;;

let () =
  (* A node that only exists in the local chat cache (for example a block
     created while offline) must still open from the cached data instead of
     failing with an endless spinner. *)
  let cached =
    Logseq_chat_model.
      { uuid = "cached-block"
      ; title = "Cached offline block"
      ; page_id = "journal/2026-08-15"
      ; parent_id = Some "journal/2026-08-15"
      ; order = Some "a0"
      ; created_at = 1
      ; updated_at = 1
      ; sync_status = "pending"
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
  let session =
    Logseq_chat_rpc.create ~graph_node_destination:(fun _ -> None) ()
  in
  Logseq_chat_model.upsert_journal_page
    session.model ~title:"Aug 15th, 2026" ~uuid:"journal/2026-08-15" ~journal_day:20260815;
  Logseq_chat_model.upsert_blocks session.model [ cached ] ~refresh_time:1;
  let opened =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"openNode","payload":"{\"uuid\":\"cached-block\"}"}}|}
    |> from_string
  in
  (match opened with
   | `Assoc fields ->
     let route = required_assoc "result" fields |> required_first_assoc "nodeRoutes" in
     assert_equal "cached node route id" "cached-block" (required_string "uuid" route);
     assert_equal
       "cached node page"
       "journal/2026-08-15"
       (required_assoc "page" route |> required_string "uuid");
     assert_equal
       "cached node page title"
       "Aug 15th, 2026"
       (required_assoc "page" route |> required_string "title");
     (match required_assoc "outlinerState" route |> required_list "zoomedBlockIds" with
      | [ `String "cached-block" ] -> ()
      | _ -> failwith "cached node navigation must zoom to the cached block");
     let block = required_first_assoc "blocks" route in
     assert_equal "cached node block" "cached-block" (required_string "uuid" block)
   | _ -> failwith "openNode should fall back to the local block cache");
  let missing =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"openNode","payload":"{\"uuid\":\"missing-block\"}"}}|}
    |> from_string
  in
  match missing with
  | `Assoc fields ->
    let error = required_assoc "error" fields in
    assert_equal "unknown node error" "unknown_node" (required_string "code" error)
  | _ -> failwith "openNode should return an RPC response"
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
        Some Logseq_chat_graph_read.{ favorites = []; recent_pages = [] })
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
  Logseq_chat_model.upsert_blocks
    session.model
    [ Logseq_chat_model.
        { uuid = "editing-block"; title = "Editing"; page_id = "target-page"
        ; parent_id = Some "target-page"; order = None; created_at = 1; updated_at = 1
        ; sync_status = "synced"; tags = []; references = []; breadcrumbs = []
        ; status = None; is_asset = false; asset_type = None; asset_size = None
        ; asset_checksum = None; local_path = None; journal = None
        }
    ]
    ~refresh_time:1;
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"targeted-asset\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"editing-block\"}"}}|});
  let asset = Option.get (Logseq_chat_model.read_block session.model "targeted-asset") in
  assert_equal "RPC targeted asset page" "target-page" asset.page_id;
  assert_equal "RPC targeted asset parent" "editing-block" (Option.get asset.parent_id)
;;

let () =
  let target =
    Logseq_chat_model.
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
  if contains url "page-id="
  then failwith "plain asset upload must let the server resolve today's page"
;;

let () =
  let session =
    Logseq_chat_rpc.create ~load_graph_catalog:(fun () -> Some plain_graph_catalog) ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"addAsset","payload":"{\"uuid\":\"shared-image\",\"title\":\"IMG_0002\",\"now\":2,\"assetType\":\"image/jpeg\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"Assets/shared-IMG_0002.JPG\"}"}}|});
  let asset = Option.get (Logseq_chat_model.read_block session.model "shared-image") in
  assert_equal "shared asset stores normalized type" "jpeg" (Option.get asset.asset_type);
  let request =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"beginPendingSync"}}|}
    |> pending_request
    |> Option.get
  in
  let url = required_string "url" request in
  if not (contains url "file-name=IMG_0002.jpeg")
  then failwith "shared asset upload must include a normalized file extension";
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
  let authoritative_blocks = ref [] in
  let session =
    Logseq_chat_rpc.create
      ~feed_sse:(fun _chunk ->
        authoritative_blocks :=
          [ Logseq_chat_model.
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
  Logseq_chat_model.
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
    Logseq_chat_rpc.create ~feed_sse:(fun _ -> Error "sync schema mismatch") ()
  in
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"feedSSE","payload":"remote-change"}}|}
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
      ~feed_sse:(fun _ ->
        authoritative := [ remote_block "editing-sync" "Local draft"; remote_block "remote-sync" "After" ];
        Ok ())
      ()
  in
  ignore
    (Logseq_chat_rpc.call session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"outlinerEvent","payload":"{\"type\":\"tapBlock\",\"uuid\":\"editing-sync\"}"}}|});
  let synced =
    Logseq_chat_rpc.call session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"feedSSE","payload":"remote-change"}}|}
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
  | _ -> failwith "feedSSE while editing should return a snapshot"
;;

let prepare_test_operation operation =
  Ok
    ( Logseq_chat_pending_ops.outliner_op operation.Logseq_chat_pending_ops.intent
    , "[]" )
;;

let () =
  let staged = ref [] in
  let existing =
    { (remote_block "existing-journal-block" "Existing") with
      Logseq_chat_model.page_id = "journal-page"
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
   | [ { Logseq_chat_pending_ops.intent =
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
  let tag = Logseq_chat_graph_read.{ uuid = "tag-uuid"; title = "Project" } in
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
        (match operation.Logseq_chat_pending_ops.intent with
         | Save_title { uuid; title; _ } ->
           projected :=
             List.map
               (fun (block : Logseq_chat_model.block) ->
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
    match Logseq_chat_fractional_order.n_between (Some "a0") None 100 with
    | Error message -> failwith message
    | Ok orders ->
      List.mapi
        (fun index order ->
          { (remote_block ("delete-tail-" ^ string_of_int index) "Unrelated") with
            Logseq_chat_model.order = Some order
          })
        orders
  in
  let projected = ref (selected_block :: unrelated_tail) in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 91)
      ~graph_blocks:(fun () -> Some !projected)
      ~stage_operation:(fun operation ->
        staged := !staged @ [ operation ];
        (match operation.Logseq_chat_pending_ops.intent with
         | Delete_blocks { uuids } ->
           projected :=
             List.filter
               (fun (block : Logseq_chat_model.block) ->
                 not (List.exists (String.equal block.uuid) uuids))
               !projected
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
   | [ { Logseq_chat_pending_ops.base_t = 91
       ; intent = Delete_blocks { uuids = [ "selected" ] }
       ; _ } ] -> ()
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
  let restore_stage_calls = ref 0 in
  let pending_operations () =
    List.init 200 (fun index ->
      Logseq_chat_pending_ops.
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
    Logseq_chat_pending_ops.
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
        if String.equal operation.Logseq_chat_pending_ops.operation_id "stale-head"
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
    Logseq_chat_pending_ops.
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
  | { Logseq_chat_pending_ops.operation_id = "op-accepted"; state = Accepted 44; _ } :: _ -> ()
  | _ -> failwith "semantic completion must persist the accepted server cursor"
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
  | { Logseq_chat_pending_ops.operation_id = "op-rejected"; state = Retryable; _ } :: _ -> ()
  | _ -> failwith "a tx/reject response must remain retryable despite HTTP 200"
;;

let () =
  let persisted = ref [] in
  let stage (operation : Logseq_chat_pending_ops.t) =
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
  let persisted = ref [] in
  let stage (operation : Logseq_chat_pending_ops.t) =
    persisted :=
      List.filter
        (fun current ->
          current.Logseq_chat_pending_ops.operation_id <> operation.operation_id)
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
          (fun operation ->
            match operation.Logseq_chat_pending_ops.state with
            | Queued | Retryable | Submitted -> true
            | Accepted _ | Applied | Conflicted _ -> false)
          !persisted)
      ()
  in
  configure_plain_graph session;
  List.iter
    (fun operation -> ignore (stage operation))
    [ Logseq_chat_pending_ops.
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
  let unrelated_tail =
    match Logseq_chat_fractional_order.n_between (Some "a0") None 100 with
    | Error message -> failwith message
    | Ok orders ->
      List.mapi
        (fun index order ->
          { (remote_block ("unrelated-" ^ string_of_int index) "Unrelated") with
            Logseq_chat_model.order = Some order
          })
        orders
  in
  let projected = ref (source :: unrelated_tail) in
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
  let page = Logseq_chat_graph_read.{ uuid = "page-lag"; title = "Lagging page" } in
  let source =
    { (remote_block "page-source" "Hello") with
      Logseq_chat_model.page_id = page.uuid
    ; parent_id = Some page.uuid
    ; order = Some "a0"
    }
  in
  let interleaved_reference =
    { (remote_block "other-page-reference" "Links lagging page") with
      Logseq_chat_model.page_id = "other-page"
    ; parent_id = Some "other-page"
    ; order = Some "a1"
    }
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_sidebar_pages:(fun () ->
        Some Logseq_chat_graph_read.{ favorites = [ page ]; recent_pages = [] })
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
  (* Editing keeps local structure, but live properties must replace stale
     metadata in the optimistic overlay before staging another property edit. *)
  let page = Logseq_chat_graph_read.{ uuid = "status-page"; title = "Status page" } in
  let source =
    { (remote_block "status-source" "Task") with
      Logseq_chat_model.page_id = page.uuid
    ; parent_id = Some page.uuid
    ; order = Some "a0"
    }
  in
  let todo =
    Logseq_chat_model.
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
        Some Logseq_chat_graph_read.{ favorites = [ page ]; recent_pages = [] })
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
  live_blocks := [ { source with Logseq_chat_model.status = Some todo } ];
  ignore
    (dispatch_outliner
       session
       (`Assoc
         [ "type", `String "setTaskStatus"
         ; "uuid", `String source.uuid
         ; "statusIdent", `String "logseq.property/status.doing"
         ]));
  match !staged with
  | [ { Logseq_chat_pending_ops.intent =
          Set_property
            { expected = Some (Ref_ident "logseq.property/status.todo"); _ }
      ; _ } ] -> ()
  | _ -> failwith "editing must stage task status against live property metadata"
;;

let () =
  let page = Logseq_chat_graph_read.{ uuid = "task-page"; title = "Task page" } in
  let todo =
    Logseq_chat_model.
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
      Logseq_chat_model.page_id = page.uuid
    ; parent_id = Some page.uuid
    ; order = Some "a0"
    ; status = Some todo
    }
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~sync_cursor:(fun () -> Some 42)
      ~graph_sidebar_pages:(fun () ->
        Some Logseq_chat_graph_read.{ favorites = [ page ]; recent_pages = [] })
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
     | _ -> failwith "a block created from a TODO block must not inherit its task status")
  | _ -> failwith "splitting a TODO block must return exactly one new block"
;;

let () =
  let today_page = Logseq_chat_graph_read.{ uuid = "journal-today"; title = "Today" } in
  let source =
    { (remote_block "journal-source" "Hello") with
      Logseq_chat_model.page_id = today_page.uuid
    ; parent_id = Some today_page.uuid
    ; order = Some "a0"
    ; journal = Some ("Today", 20260818)
    }
  in
  let child =
    { (remote_block "journal-child" "Child") with
      Logseq_chat_model.page_id = today_page.uuid
    ; parent_id = Some source.uuid
    ; order = Some "a0"
    ; journal = Some ("Today", 20260818)
    }
  in
  let orders =
    match Logseq_chat_fractional_order.n_between (Some "a0") None 20 with
    | Ok orders -> orders
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
            Logseq_chat_model.page_id
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
    (match operation.Logseq_chat_pending_ops.intent with
     | Split_block { uuid; before; after; new_uuid; new_order; created_at; _ } ->
       let original =
         List.find
           (fun (block : Logseq_chat_model.block) -> String.equal block.uuid uuid)
           !today_blocks
       in
       today_blocks :=
         List.map
           (fun (block : Logseq_chat_model.block) ->
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
  let graph_a_model = Logseq_chat_model.create () in
  let graph_b_model = Logseq_chat_model.create () in
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
  if List.length (Logseq_chat_model.pending_blocks session.model) <> 1
  then failwith "graph A should contain its pending asset";
  open_graph "graph-b";
  if Logseq_chat_model.pending_blocks session.model <> []
  then failwith "graph B must not inherit graph A's optimistic projection";
  open_graph "graph-a";
  if List.length (Logseq_chat_model.pending_blocks session.model) <> 1
  then failwith "switching back should restore graph A's optimistic projection"
;;

let () =
  let favorite = ref false in
  let calls = ref [] in
  let page = Logseq_chat_graph_read.{ uuid = "page-favorite"; title = "Favorite me" } in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~graph_sidebar_pages:(fun () ->
        Some
          Logseq_chat_graph_read.
            { favorites = (if !favorite then [ page ] else [])
            ; recent_pages = [ page ]
            })
      ~graph_set_page_favorite:(fun ~page_uuid ~favorite:value ~operation_id ~now ->
        calls := (page_uuid, value, operation_id, now) :: !calls;
        favorite := value;
        Ok ())
      ()
  in
  configure_plain_graph session;
  let set value operation_id =
    let payload =
      Yojson.Basic.to_string
        (`Assoc
          [ "pageUuid", `String page.uuid
          ; "favorite", `Bool value
          ; "operationId", `String operation_id
          ; "now", `Int 100
          ])
    in
    Logseq_chat_rpc.call
      session
      (Yojson.Basic.to_string
         (`Assoc
           [ "apiVersion", `Int 1
           ; "method", `String "dispatch"
           ; ( "params"
             , `Assoc [ "action", `String "setPageFavorite"; "payload", `String payload ] )
           ]))
    |> from_string
  in
  let favorited = set true "favorite-op" in
  (match favorited with
   | `Assoc fields ->
     let result = required_assoc "result" fields in
     if List.length (required_list "favorites" result) <> 1
     then failwith "favoriting a page must update the sidebar snapshot immediately"
   | _ -> failwith "setPageFavorite should return an RPC response");
  ignore (set false "unfavorite-op");
  (match List.rev !calls with
   | [ ("page-favorite", true, "favorite-op", 100)
     ; ("page-favorite", false, "unfavorite-op", 100) ] -> ()
  | _ -> failwith "setPageFavorite must preserve the requested semantic operation")
;;

let () =
  let deleted = ref None in
  let page = Logseq_chat_graph_read.{ uuid = "page-delete"; title = "Delete me" } in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~graph_sidebar_pages:(fun () ->
        Some
          Logseq_chat_graph_read.
            { favorites = []
            ; recent_pages = (if Option.is_some !deleted then [] else [ page ])
            })
      ~graph_delete_page:(fun ~page_uuid ~operation_id ~now ->
        deleted := Some (page_uuid, operation_id, now);
        Ok ())
      ()
  in
  configure_plain_graph session;
  let payload =
    Yojson.Basic.to_string
      (`Assoc
        [ "pageUuid", `String page.uuid
        ; "operationId", `String "delete-page-op"
        ; "now", `Int 100
        ])
  in
  let response =
    Logseq_chat_rpc.call
      session
      (Yojson.Basic.to_string
         (`Assoc
           [ "apiVersion", `Int 1
           ; "method", `String "dispatch"
           ; "params", `Assoc [ "action", `String "deletePage"; "payload", `String payload ]
           ]))
    |> from_string
  in
  (match response with
   | `Assoc fields ->
     let result = required_assoc "result" fields in
     if required_list "recentPages" result <> []
     then failwith "deleting a page must update the sidebar snapshot immediately"
   | _ -> failwith "deletePage should return an RPC response");
  match !deleted with
  | Some ("page-delete", "delete-page-op", 100) -> ()
  | _ -> failwith "deletePage must preserve page UUID, operation ID, and time"
;;

let () =
  let now = 1_776_000_000_000 in
  let reviewed = ref None in
  let due_card =
    Logseq_chat_flashcards.
      { block = remote_block "flashcard" "Question {{cloze answer}}"
      ; children = []
      ; card = new_card ~now
      }
  in
  let session =
    Logseq_chat_rpc.create
      ~load_graph_catalog:(fun () -> Some plain_graph_catalog)
      ~graph_due_flashcards:(fun ~now:_ -> if Option.is_some !reviewed then [] else [ due_card ])
      ~graph_review_flashcard:(fun ~uuid ~rating ~now ~operation_id ->
        reviewed := Some (uuid, rating, now, operation_id);
        Ok ())
      ()
  in
  configure_plain_graph session;
  ignore
    (Logseq_chat_rpc.call
       session
       {|{"apiVersion":1,"method":"dispatch","params":{"action":"loadFlashcards","payload":"1776000000000"}}|});
  let response =
    Logseq_chat_rpc.call
      session
      {|{"apiVersion":1,"method":"dispatch","params":{"action":"reviewFlashcard","payload":"{\"uuid\":\"flashcard\",\"rating\":\"good\",\"now\":1776000000000,\"operationId\":\"review-op\"}"}}|}
    |> from_string
  in
  (match response with
   | `Assoc fields ->
     if not (required_bool "ok" fields) then failwith "reviewing a flashcard should succeed";
     let result = required_assoc "result" fields in
     if required_list "flashcards" result <> []
     then failwith "reviewed card must immediately leave the due queue"
   | _ -> failwith "reviewFlashcard should return an RPC response");
  match !reviewed with
  | Some ("flashcard", Logseq_chat_flashcards.Good, value, "review-op") when value = now -> ()
  | _ -> failwith "reviewFlashcard must preserve UUID, rating, time, and operation id"
;;
