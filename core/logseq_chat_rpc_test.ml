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
