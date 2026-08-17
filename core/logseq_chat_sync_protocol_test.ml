open Transit_core.Json

let fail label = failwith label

let uuid = "7b45785d-710c-47f8-9e7e-e9c4f5229830"

let payload =
  Map
    [ Keyword "format-version", Int 1
    ; Keyword "graph-id", String "graph-1"
    ; Keyword "schema-version", String "65.33"
    ; Keyword "t-before", Int 41
    ; Keyword "t", Int 42
    ; ( Keyword "upserts"
      , Array
          [ Map
              [ ( Keyword "id"
                , Array [ Keyword "block/uuid"; Uuid uuid ] )
              ; ( Keyword "attrs"
                , Map
                    [ Keyword "block/uuid", Uuid uuid
                    ; Keyword "block/title", String "Encrypted or plain title"
                    ; ( Keyword "block/tags"
                      , Set [ Array [ Keyword "db/ident"; Keyword "logseq.class/Task" ] ] )
                    ] )
              ]
          ] )
    ; Keyword "deleted", Array []
    ; Keyword "operation-ids", Array [ String "op-delete"; String "op-title" ]
    ]
;;

let () =
  let wire = Transit_native.Transit.Json.to_string payload in
  match Logseq_chat_sync_protocol.decode_change_set wire with
  | Error message -> fail message
  | Ok change ->
    if change.format_version <> 1 then fail "format version changed";
    if not (String.equal change.graph_id "graph-1") then fail "graph id changed";
    if not (String.equal change.schema_version "65.33") then fail "schema changed";
    if change.t_before <> 41 || change.t <> 42 then fail "cursor changed";
    if change.operation_ids <> [ "op-delete"; "op-title" ]
    then fail "operation identities were not preserved";
    (match change.upserts with
     | [ entity ] ->
       (match entity.id with
        | Array [ Keyword "block/uuid"; Uuid actual ] when String.equal actual uuid -> ()
        | _ -> fail "typed UUID identity was not preserved");
       (match List.assoc_opt (Keyword "block/tags") entity.attrs with
        | Some (Set [ Array [ Keyword "db/ident"; Keyword "logseq.class/Task" ] ]) -> ()
        | _ -> fail "typed set/reference value was not preserved")
     | _ -> fail "expected one upsert")
;;

let () =
  let without_operation_ids =
    match payload with
    | Map fields ->
      Map (List.filter (fun (key, _) -> key <> Keyword "operation-ids") fields)
    | _ -> assert false
  in
  let wire = Transit_native.Transit.Json.to_string without_operation_ids in
  match Logseq_chat_sync_protocol.decode_change_set wire with
  | Ok { operation_ids = []; _ } -> ()
  | Ok _ -> fail "missing operation-ids must decode as an empty compatibility field"
  | Error message -> fail message
;;

let () =
  let malformed_operation_ids =
    match payload with
    | Map fields ->
      Map
        ((Keyword "operation-ids", Array [ Int 1 ])
         :: List.remove_assoc (Keyword "operation-ids") fields)
    | _ -> assert false
  in
  let wire = Transit_native.Transit.Json.to_string malformed_operation_ids in
  match Logseq_chat_sync_protocol.decode_change_set wire with
  | Error _ -> ()
  | Ok _ -> fail "operation-ids must contain only strings"
;;

let () =
  let reset =
    Map
      [ Keyword "reason", String "cursor-expired"
      ; Keyword "snapshot-required", Bool true
      ]
    |> Transit_native.Transit.Json.to_string
  in
  match Logseq_chat_sync_protocol.decode_event ~event_name:"reset" reset with
  | Ok (Reset { reason = "cursor-expired"; snapshot_required = true }) -> ()
  | _ -> fail "reset event was not decoded"
;;

let () =
  let malformed =
    Map
      [ Keyword "format-version", Int 1
      ; Keyword "graph-id", String "graph-1"
      ; Keyword "schema-version", String "65.33"
      ; Keyword "t-before", Int 1
      ; Keyword "t", Int 2
      ; ( Keyword "upserts"
        , Array [ Map [ Keyword "id", Int 123; Keyword "attrs", Map [] ] ] )
      ; Keyword "deleted", Array []
      ]
    |> Transit_native.Transit.Json.to_string
  in
  match Logseq_chat_sync_protocol.decode_change_set malformed with
  | Error _ -> ()
  | Ok _ -> fail "numeric server-local entity ids must be rejected"
;;
