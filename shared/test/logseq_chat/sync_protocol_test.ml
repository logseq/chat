open Test_util

module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json
module Ds = Datascript

let uuid = "7b45785d-710c-47f8-9e7e-e9c4f5229830"

let second_uuid = "7b45785d-710c-47f8-9e7e-e9c4f5229831"

let identity_value uuid =
  Value.Array [ Value.Keyword "block/uuid"; Value.Uuid uuid ]

let task_tag =
  Value.Set
    [
      Value.Array
        [ Value.Keyword "db/ident"; Value.Keyword "logseq.class/Task" ];
    ]

let payload =
  Value.Map
    [
      (Value.Keyword "format-version", Value.Int 1);
      (Value.Keyword "graph-id", Value.String "graph-1");
      (Value.Keyword "schema-version", Value.String "65.33");
      (Value.Keyword "t-before", Value.Int 41);
      (Value.Keyword "t", Value.Int 42);
      ( Value.Keyword "upserts"
      , Value.Array
          [
            Value.Map
              [
                (Value.Keyword "id", identity_value uuid);
                ( Value.Keyword "attrs"
                , Value.Map
                    [
                      (Value.Keyword "block/uuid", Value.Uuid uuid);
                      ( Value.Keyword "block/title"
                      , Value.String "Encrypted or plain title" );
                      (Value.Keyword "block/tags", task_tag);
                    ] );
              ];
          ] );
      (Value.Keyword "deleted", Value.Array []);
      ( Value.Keyword "operation-ids"
      , Value.Array [ Value.String "op-delete"; Value.String "op-title" ] );
    ]

let decode payload =
  match Sync_protocol.decode_change_set (Codec.to_string payload) with
  | Ok change -> change
  | Error message -> failwith message

let lookup_preserves_first_false_and_null_values () =
  List.iter
    (fun lookup ->
       List.iter
         (fun input ->
            let entries =
              [ (Value.Keyword "key", input); (Value.Keyword "key", Value.Int 42) ]
            in
            check_eq (Some input) (lookup "key" entries);
            check (lookup "missing" entries = None))
         [ Value.Null; Value.Bool false; Value.Int 0; Value.String "" ])
    [ Sync_protocol.field; Sync_checkpoint.field ];
  List.iter
    (fun input ->
       let entries =
         [ (Ds.Keyword "key", input); (Ds.Keyword "key", Ds.Int 42) ]
       in
       check_eq (Some input) (Flashcards.map_value "key" entries);
       check (Flashcards.map_value "missing" entries = None))
    [ Ds.Nil; Ds.Bool false; Ds.Int 0; Ds.String "" ]

let wire_contract_preserves_identities_sets_and_cursors () =
  let change = decode payload in
  check_eq 1 change.format_version;
  check_eq "graph-1" change.graph_id;
  check_eq "65.33" change.schema_version;
  check_eq 41 change.t_before;
  check_eq 42 change.t;
  check_eq [ "op-delete"; "op-title" ] change.operation_ids;
  check_eq [ uuid ] (Sync_protocol.changed_block_uuids change);
  check_eq 1 (List.length change.upserts);
  let entity = List.nth change.upserts 0 in
  check_eq (identity_value uuid) entity.id;
  check_eq (Some task_tag)
    (Sync_protocol.field "block/tags" entity.attrs);
  let repeated =
    { change with
      upserts = change.upserts @ change.upserts;
      deleted =
        [
          identity_value uuid;
          Value.Array
            [ Value.Keyword "db/ident"; Value.Keyword "logseq.class/Card" ];
          identity_value second_uuid;
          identity_value second_uuid;
        ];
    }
  in
  check_eq [ uuid; second_uuid ]
    (Sync_protocol.changed_block_uuids repeated)

let operation_identities_are_optional_but_must_be_strings () =
  match payload with
  | Value.Map fields ->
    let without =
      List.filter
        (fun (key, _) -> key <> Value.Keyword "operation-ids")
        fields
    in
    check_eq []
      (decode (Value.Map without)).Sync_protocol.operation_ids;
    (match
       Sync_protocol.decode_change_set
         (Codec.to_string
            (Value.Map
               ((Value.Keyword "operation-ids", Value.Array [ Value.Int 1 ])
                :: without)))
     with
     | Error _ -> check true
     | Ok _ -> fail "non-string operation identity accepted")
  | _ -> fail "expected a map fixture"

let reset_event_contract () =
  check_eq
    (Ok
       (Sync_protocol.Reset
          { reason = "cursor-expired"; snapshot_required = true }))
    (Sync_protocol.decode_event "reset"
       (Codec.to_string
          (Value.Map
             [
               (Value.Keyword "reason", Value.String "cursor-expired");
               (Value.Keyword "snapshot-required", Value.Bool true);
             ])))

let numeric_server_local_identities_are_rejected () =
  match payload with
  | Value.Map fields ->
    let fields =
      List.filter (fun (key, _) -> key <> Value.Keyword "upserts") fields
    in
    let malformed =
      Value.Map
        (( Value.Keyword "upserts"
         , Value.Array
             [
               Value.Map
                 [
                   (Value.Keyword "id", Value.Int 123);
                   (Value.Keyword "attrs", Value.Map []);
                 ];
             ] )
        :: fields)
    in
    (match Sync_protocol.decode_change_set (Codec.to_string malformed) with
     | Error _ -> check true
     | Ok _ -> fail "numeric server-local entity identity accepted")
  | _ -> fail "expected a map fixture"

let cases =
  [
    case "lookup preserves first false and null values"
      lookup_preserves_first_false_and_null_values;
    case "wire contract preserves identities sets and cursors"
      wire_contract_preserves_identities_sets_and_cursors;
    case "operation identities are optional but must be strings"
      operation_identities_are_optional_but_must_be_strings;
    case "reset event contract" reset_event_contract;
    case "numeric server local identities are rejected"
      numeric_server_local_identities_are_rejected;
  ]
