open Test_util

module Ds = Datascript
module Value = Transit_core.Json
module Protocol = Sync_protocol
module Sync = Entity_sync
module Storage = Storage_codec

let one = Storage.default_schema_attr

let uuid_schema =
  {
    one with
    Ds.value_type = Some Ds.UuidType;
    unique = Some Ds.Identity;
    indexed = true;
  }

let string_schema = { one with Ds.value_type = Some Ds.StringType }

let ref_schema = { one with Ds.value_type = Some Ds.RefType }

let wire_identity uuid =
  Value.Array [ Value.Keyword "block/uuid"; Value.Uuid uuid ]

let wire_block uuid title =
  [
    (Value.Keyword "block/uuid", Value.Uuid uuid);
    (Value.Keyword "block/title", Value.String title);
  ]

let entity uuid attrs : Protocol.sync_entity =
  { Protocol.id = wire_identity uuid; attrs }

let change_set upserts deleted : Protocol.sync_change_set =
  {
    Protocol.format_version = 1;
    graph_id = "graph-1";
    schema_version = "65.33";
    t_before = 7;
    t = 8;
    upserts;
    deleted;
    operation_ids = [];
  }

let eid db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid -> eid
  | None -> failwith ("missing entity: " ^ uuid)

let values db eid attr =
  List.map
    (fun (d : Ds.datom) -> d.Ds.v)
    (List.of_seq (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:attr ()))

let pending_identities_retain_new_entities_and_skip_existing_ones () =
  let conn = Ds.create_conn ~schema:[ ("block/uuid", uuid_schema) ] () in
  ignore
    (Ds.transact_conn conn
       [ Ds.Add (Ds.Entity_id 1, "block/uuid", Ds.Uuid "existing") ]);
  match
    Sync.pending_temp_ids (Ds.conn_db conn)
      [ entity "existing" []; entity "child" []; entity "parent" [] ]
  with
  | Ok pending ->
    check_eq 2 (List.length pending);
    check_eq
      [ Ds.Uuid "child"; Ds.Uuid "parent" ]
      (List.sort_uniq compare
         (List.map
            (fun (p : Sync.pending_temp_id) -> p.identity_value)
            pending));
    check_eq
      [
        Ds.Temp_id "remote:block/uuid:child";
        Ds.Temp_id "remote:block/uuid:parent";
      ]
      (List.sort_uniq compare
         (List.map (fun (p : Sync.pending_temp_id) -> p.entity_ref) pending))
  | Error message -> failwith message

let authoritative_changes_replace_retract_and_resolve_reference_identities ()
    =
  let schema =
    [
      ("block/uuid", uuid_schema);
      ("block/title", string_schema);
      ("block/collapsed?", one);
      ("block/parent", ref_schema);
      ("block/tags", { ref_schema with Ds.cardinality = Ds.Many });
      ("block/properties", one);
    ]
  in
  let old = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" in
  let parent = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec9" in
  let tag = "018f7850-c6aa-7da0-8b3f-6dbb64aa4eca" in
  let fresh = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ecb" in
  let doomed = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ecc" in
  let remote_parent = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ecd" in
  let remote_child = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ece" in
  let conn = Ds.create_conn ~schema () in
  ignore
    (Ds.transact_conn conn
       [
         Ds.Add (Ds.Entity_id 1, "block/uuid", Ds.Uuid old);
         Ds.Add (Ds.Entity_id 1, "block/title", Ds.String "Before");
         Ds.Add (Ds.Entity_id 1, "block/collapsed?", Ds.Bool true);
         Ds.Add (Ds.Entity_id 2, "block/uuid", Ds.Uuid parent);
         Ds.Add (Ds.Entity_id 2, "block/title", Ds.String "Parent");
         Ds.Add (Ds.Entity_id 3, "block/uuid", Ds.Uuid tag);
         Ds.Add (Ds.Entity_id 3, "block/title", Ds.String "Tag");
         Ds.Add (Ds.Entity_id 4, "block/uuid", Ds.Uuid doomed);
         Ds.Add (Ds.Entity_id 4, "block/title", Ds.String "Delete me");
       ]);
  let changes =
    change_set
      [
        entity old
          (wire_block old "After"
          @ [
              (Value.Keyword "block/parent", wire_identity parent);
              ( Value.Keyword "block/tags"
              , Value.Set [ wire_identity tag ] );
              ( Value.Keyword "block/properties"
              , Value.Map
                  [ (Value.Keyword "priority", Value.Keyword "A") ] );
            ]);
        entity fresh (wire_block fresh "Created");
        entity remote_child
          (wire_block remote_child "Remote child"
          @ [ (Value.Keyword "block/parent", wire_identity remote_parent) ]);
        entity remote_parent (wire_block remote_parent "Remote parent");
      ]
      [ wire_identity doomed ]
  in
  check_ok (Sync.apply_change_set (fun v -> Ok v) conn changes);
  let db = Ds.conn_db conn in
  let old_eid = eid db old in
  check_eq [ Ds.String "After" ] (values db old_eid "block/title");
  check_eq [] (values db old_eid "block/collapsed?");
  check_eq [ Ds.Ref (eid db parent) ] (values db old_eid "block/parent");
  check_eq [ Ds.Ref (eid db tag) ] (values db old_eid "block/tags");
  check_eq
    [ Ds.Map [ (Ds.Keyword "priority", Ds.Keyword "A") ] ]
    (values db old_eid "block/properties");
  check (Ds.entid db "block/uuid" (Ds.Uuid fresh) <> None);
  check_eq
    [ Ds.Ref (eid db remote_parent) ]
    (values db (eid db remote_child) "block/parent");
  check_eq None (Ds.entid db "block/uuid" (Ds.Uuid doomed))

let encrypted_server_attributes_are_plaintext_in_local_datascript () =
  let conn =
    Ds.create_conn
      ~schema:
        [
          ("block/uuid", uuid_schema);
          ("block/title", string_schema);
          ("block/name", string_schema);
        ]
      ()
  in
  let changes =
    {
      (change_set
         [
           entity "encrypted-block"
             (wire_block "encrypted-block" "cipher:Title"
             @ [
                 (Value.Keyword "block/name", Value.String "cipher:title");
               ]);
         ]
         [])
      with
      Protocol.graph_id = "encrypted-graph";
      t_before = 0;
      t = 1;
    }
  in
  let decrypt value =
    if String.starts_with ~prefix:"cipher:" value then
      Ok (String.sub value 7 (String.length value - 7))
    else Error "expected ciphertext"
  in
  check_ok (Sync.apply_change_set decrypt conn changes);
  let db = Ds.conn_db conn in
  let eid = eid db "encrypted-block" in
  check_eq [ Ds.String "Title" ] (values db eid "block/title");
  check_eq [ Ds.String "title" ] (values db eid "block/name")

let failed_decryption_stops_at_first_error_without_committing_any_change () =
  let conn =
    Ds.create_conn
      ~schema:
        [ ("block/uuid", uuid_schema); ("block/title", string_schema) ]
      ()
  in
  ignore
    (Ds.transact_conn conn
       [
         Ds.Add (Ds.Entity_id 1, "block/uuid", Ds.Uuid "existing");
         Ds.Add (Ds.Entity_id 1, "block/title", Ds.String "Original");
       ]);
  let before = Ds.conn_db conn in
  let calls = ref [] in
  let decrypt ciphertext =
    calls := !calls @ [ ciphertext ];
    if ciphertext = "broken" then Error "decryption failed"
    else Ok ciphertext
  in
  let changes =
    {
      (change_set
         [
           entity "existing" (wire_block "existing" "Updated");
           entity "broken-block" (wire_block "broken-block" "broken");
           entity "later-block" (wire_block "later-block" "must not decrypt");
         ]
         [ wire_identity "existing" ])
      with
      Protocol.graph_id = "encrypted-graph";
      t_before = 0;
      t = 1;
    }
  in
  check_eq (Error "decryption failed")
    (Sync.apply_change_set decrypt conn changes);
  check_eq [ "Updated"; "broken" ] !calls;
  check (before == Ds.conn_db conn)

let cases =
  [
    case "pending identities retain new entities and skip existing ones"
      pending_identities_retain_new_entities_and_skip_existing_ones;
    case "authoritative changes replace retract and resolve reference identities"
      authoritative_changes_replace_retract_and_resolve_reference_identities;
    case "encrypted server attributes are plaintext in local datascript"
      encrypted_server_attributes_are_plaintext_in_local_datascript;
    case "failed decryption stops at first error without committing any change"
      failed_decryption_stops_at_first_error_without_committing_any_change;
  ]
