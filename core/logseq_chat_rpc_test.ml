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
