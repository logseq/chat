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
